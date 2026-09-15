import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {

    // MARK: - Keys

    private enum Keys {
        static let codexRunCount                = "codexRunCount"
        static let kicktippCompetitionSlug      = "kicktippCompetitionSlug"
        static let codexPath                    = "codexPath"
    }

    private enum SecretKeys {
        static let theOddsAPIKey = "theOddsAPIKey"
    }

    // MARK: - State

    var season: String = String(AppState.currentBundesligaSeason())
    var codexRunCount: Int = {
        let stored = UserDefaults.standard.integer(forKey: Keys.codexRunCount)
        return stored == 0 ? 1 : stored
    }() {
        didSet {
            codexRunCount = min(max(codexRunCount, 1), 9)
            UserDefaults.standard.set(codexRunCount, forKey: Keys.codexRunCount)
        }
    }
    var kicktippCompetitionSlug: String = UserDefaults.standard.string(forKey: Keys.kicktippCompetitionSlug) ?? "" {
        didSet { UserDefaults.standard.set(kicktippCompetitionSlug, forKey: Keys.kicktippCompetitionSlug) }
    }
    var theOddsAPIKey: String = "" {
        didSet {
            do {
                let trimmed = theOddsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    try secretStore.deleteSecret(account: SecretKeys.theOddsAPIKey)
                } else {
                    try secretStore.saveSecret(trimmed, account: SecretKeys.theOddsAPIKey)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    var codexPath: String = UserDefaults.standard.string(forKey: Keys.codexPath) ?? "/opt/homebrew/bin/codex" {
        didSet { UserDefaults.standard.set(codexPath, forKey: Keys.codexPath) }
    }
    var generatedPrompt: String = ""
    var importedResponse: String = ""
    var consoleOutput: String = ""
    var codexStatus: String = "Unbekannt"
    var codexDeviceAuthURL: String = ""
    var codexDeviceCode: String = ""
    var kicktippStatus: String = "Nicht verbunden"

    var finishedResults: [FinishedMatch] = []
    var upcomingMatches: [UpcomingMatch] = []
    var suggestedTips: [SuggestedTip] = []
    var seasonQuestionTips: [SeasonQuestionTip] = []
    var kicktippMatchFields: [KicktippMatchField] = []
    var orderedSuggestedTips: [SuggestedTip] {
        orderedTips(suggestedTips)
    }
    var bettingOdds: [BettingOdds] = []
    var overUnderOdds: [OverUnderOdds] = []
    var bttsOdds: [BTTSOdds] = []
    var handicapOdds: [HandicapOdds] = []
    var playerAbsences: [PlayerAbsence] = []
    var teamMetadata: [TeamMetadata] = []
    var matchWeather: [MatchWeather] = []
    var matchReferees: [MatchReferee] = []
    var teamExtraFixtures: [TeamExtraFixture] = []
    var teamShotsStats: [TeamSeasonShots] = []
    var llmMatchEnrichments: [LLMMatchEnrichment] = []
    var matchExpectedGoals: [MatchExpectedGoals] = []
    var nextSpieltag: Int?
    var tipHistory: [TipGenerationRecord] = [] {
        didSet {
            persistTipHistory()
        }
    }
    var latestTipHistory: [TipGenerationRecord] {
        Self.latestTipHistory(from: tipHistory)
    }
    var predictionRuns: [PredictionRun] = [] {
        didSet { persistLearningStore() }
    }
    var evaluatedMatchdayRuns: [PredictionRun] {
        Self.evaluatedMatchdayRuns(from: predictionRuns)
    }
    var learningState: LearningState = .empty {
        didSet { persistLearningStore() }
    }
    var isBusy = false
    var errorMessage: String?
    var infoMessage: String?

    let kicktippAutomation = KicktippAutomation()

    // MARK: - Services

    private let ligaService = OpenLigaDBService()
    private let tipWorkflowService = TipWorkflowService()
    private let sofaScoreService = SofaScoreService()
    private let teamMetadataService = TheSportsDBService()
    private let weatherService = WeatherService()
    private let teamRatingService = TeamRatingService()
    private let predictionStore = PredictionStore()
    private let predictionEvaluator = PredictionEvaluator()
    private let ensembleService = EnsembleService()
    private let codexCLIService = CodexCLIService()
    private let secretStore = KeychainSecretStore()
    private let tipHistoryStore = TipHistoryStore()

    private var oddsAPIService: TheOddsAPIService {
        TheOddsAPIService(apiKey: theOddsAPIKey)
    }

    // MARK: - Init

    static func currentBundesligaSeason(for date: Date = Date()) -> Int {
        let year = Calendar.current.component(.year, from: date)
        let month = Calendar.current.component(.month, from: date)
        return month >= 7 ? year : year - 1
    }

    static func upcomingMatchesForLatestTips(_ record: TipGenerationRecord, predictionRuns: [PredictionRun]) -> [UpcomingMatch] {
        let latestRun = predictionRuns
            .filter { $0.spieltag == record.spieltag }
            .max { $0.createdAt < $1.createdAt }

        if let latestRun {
            return latestRun.matches.map {
                UpcomingMatch(spieltag: $0.spieltag, datum: $0.kickoffAt, heim: $0.heim, gast: $0.gast)
            }
        }

        return record.tips.map {
            UpcomingMatch(spieltag: $0.spieltag, datum: "", heim: $0.heim, gast: $0.gast)
        }
    }

    static func evaluatedMatchdayRuns(from runs: [PredictionRun]) -> [PredictionRun] {
        Dictionary(grouping: runs.filter { $0.matches.contains(where: \.isEvaluated) }) {
            "\($0.seasonIdentifier)|\($0.spieltag)"
        }
        .compactMap { _, runs in runs.max { $0.createdAt < $1.createdAt } }
        .sorted { ($0.seasonIdentifier, $0.spieltag) > ($1.seasonIdentifier, $1.spieltag) }
    }

    static func latestTipHistory(from records: [TipGenerationRecord]) -> [TipGenerationRecord] {
        Dictionary(grouping: records) { "\(currentBundesligaSeason(for: $0.timestamp))|\($0.spieltag)" }
            .compactMap { _, records in records.max { $0.timestamp < $1.timestamp } }
            .sorted {
                (currentBundesligaSeason(for: $0.timestamp), $0.spieltag) >
                (currentBundesligaSeason(for: $1.timestamp), $1.spieltag)
            }
    }

    static func manualTips(from fields: [KicktippMatchField], upcomingMatches: [UpcomingMatch]) -> [SuggestedTip] {
        let matchesByKey = Dictionary(uniqueKeysWithValues: upcomingMatches.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        })

        return fields.compactMap { field in
            guard let match = matchesByKey[normalizedTeamKey(field.heim, field.gast)],
                  let homeGoals = Int(field.existingHeim.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let awayGoals = Int(field.existingGast.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }

            return SuggestedTip(
                spieltag: match.spieltag,
                heim: match.heim,
                gast: match.gast,
                toreHeim: homeGoals,
                toreGast: awayGoals,
                rationale: "Manuell in Kicktipp eingetragener Tipp."
            )
        }
    }

    init() {
        do {
            theOddsAPIKey = try secretStore.loadSecret(account: SecretKeys.theOddsAPIKey)
                ?? ProcessInfo.processInfo.environment["THE_ODDS_API_KEY"]
                ?? ""
        } catch {
            theOddsAPIKey = ProcessInfo.processInfo.environment["THE_ODDS_API_KEY"] ?? ""
            errorMessage = error.localizedDescription
        }

        do {
            tipHistory = try tipHistoryStore.load()
            if let latestTips = tipHistory.last {
                suggestedTips = latestTips.tips
                bettingOdds = latestTips.odds
            }
            if !suggestedTips.isEmpty {
                importedResponse = tipWorkflowService.encodeTipsAsJSON(suggestedTips)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        do {
            let loaded = try predictionStore.load()
            predictionRuns = loaded.runs
            learningState = loaded.learningState
            restoreUpcomingMatchesFromLatestTips()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Workflow

    func initializeKicktipp() async {
        let loggedIn = await kicktippAutomation.isLoggedIn()
        if loggedIn && !kicktippCompetitionSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await loadKicktippMatchday()
        } else {
            openKicktippLogin()
        }
    }

    func runWorkflow() async {
        guard !isBusy else { return }

        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let seasonValue = try parsedSeason()

            infoMessage = "Lade Bundesliga-Daten..."
            let (finished, nextSpieltag, upcoming) = try await ligaService.fetchSeason(season: seasonValue)
            finishedResults = finished
            upcomingMatches = upcoming
            suggestedTips = []
            matchExpectedGoals = []
            importedResponse = ""
            self.nextSpieltag = nextSpieltag

            guard !upcoming.isEmpty else {
                throw ValidationError.noUpcomingMatches
            }

            infoMessage = "Lese Wettquoten..."
            bettingOdds = []
            overUnderOdds = []
            bttsOdds = []
            handicapOdds = []
            if !theOddsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let allMarketOdds = try await oddsAPIService.fetchAllMarketOdds()
                    bettingOdds = remapOddsToUpcomingMatches(allMarketOdds.h2h, upcomingMatches: upcoming)
                    overUnderOdds = remapOverUnderToUpcomingMatches(allMarketOdds.overUnder, upcomingMatches: upcoming)
                    bttsOdds = remapBTTSToUpcomingMatches(allMarketOdds.btts, upcomingMatches: upcoming)
                    handicapOdds = remapHandicapToUpcomingMatches(allMarketOdds.handicap, upcomingMatches: upcoming)
                    appendConsole("[Quoten] \(bettingOdds.count)/\(upcoming.count) Quoten aus The Odds API geladen.\n")
                } catch {
                    appendConsole("[Quoten] The Odds API fehlgeschlagen: \(error.localizedDescription)\n")
                }
            } else {
                appendConsole("[Quoten] The Odds API nicht konfiguriert, nutze Kicktipp-Fallback.\n")
            }

            if bettingOdds.count < upcoming.count {
                try await ensureKicktippMatchdayReadyForExtraction()
                let kicktippOddsResult = await kicktippAutomation.extractOdds(competitionSlug: kicktippCompetitionSlug)
                appendConsole(kicktippOddsResult.log)

                let remappedKicktippOdds = remapOddsToUpcomingMatches(kicktippOddsResult.odds, upcomingMatches: upcoming)
                let existingOddsByMatchKey = ensembleService.remappedOdds(bettingOdds: bettingOdds, upcomingMatches: upcoming)
                let kicktippOddsByMatchKey = ensembleService.remappedOdds(bettingOdds: remappedKicktippOdds, upcomingMatches: upcoming)

                bettingOdds = upcoming.compactMap { match in
                    let key = normalizedTeamKey(match.heim, match.gast)
                    return existingOddsByMatchKey[key] ?? kicktippOddsByMatchKey[key]
                }

                if let fields = try? await kicktippAutomation.extractMatchFields() {
                    kicktippMatchFields = fields
                    kicktippStatus = "\(fields.count) Kicktipp-Spiele erkannt"
                }
                appendConsole("[Quoten] Nach Fallback insgesamt \(bettingOdds.count)/\(upcoming.count) Quoten verfuegbar.\n")
            }

            validateWorkflowInputs(upcomingMatches: upcoming)

            infoMessage = "Lade Team- und Stadiondaten..."
            do {
                teamMetadata = try await teamMetadataService.fetchBundesligaTeamMetadata()
                appendConsole("[TheSportsDB] \(teamMetadata.count) Team-Metadaten geladen.\n")
            } catch {
                appendConsole("[TheSportsDB] Fehler: \(error.localizedDescription)\n")
                teamMetadata = []
            }

            infoMessage = "Lade Verletzungen & Sperren..."
            do {
                let absences = try await sofaScoreService.fetchAbsences()
                playerAbsences = absences
                appendConsole("[SofaScore] \(absences.count) Abwesenheiten geladen.\n")
            } catch {
                appendConsole("[SofaScore] Fehler: \(error.localizedDescription)\n")
                playerAbsences = []
            }

            matchReferees = []
            teamExtraFixtures = []
            teamShotsStats = []

            infoMessage = "Lade Wetterdaten..."
            do {
                matchWeather = try await weatherService.fetchWeather(for: upcomingMatches, teamMetadata: teamMetadata)
                appendConsole("[Open-Meteo] \(matchWeather.count) Wetter-Eintraege geladen.\n")
            } catch {
                appendConsole("[Open-Meteo] Fehler: \(error.localizedDescription)\n")
                matchWeather = []
            }

            infoMessage = "Recherchiere fehlende Zusatzdaten..."
            llmMatchEnrichments = await fetchLLMMatchEnrichments(seasonValue: seasonValue)

            infoMessage = "Erzeuge Prompt..."
            generatedPrompt = tipWorkflowService.buildPrompt(
                season: seasonValue,
                finishedResults: finishedResults,
                upcomingMatches: upcomingMatches,
                bettingOdds: bettingOdds,
                overUnderOdds: overUnderOdds,
                bttsOdds: bttsOdds,
                handicapOdds: handicapOdds,
                playerAbsences: playerAbsences,
                teamMetadata: teamMetadata,
                matchWeather: matchWeather,
                matchReferees: matchReferees,
                teamExtraFixtures: teamExtraFixtures,
                teamShotsStats: teamShotsStats,
                llmMatchEnrichments: llmMatchEnrichments,
                tipHistory: tipHistory,
                learningState: learningState
            )

            guard !generatedPrompt.isEmpty else { return }

            try await runPromptEnsembleWithCodex()
        } catch let e as KicktippAutomationError {
            errorMessage = e.localizedDescription
            if case let .noBettingFieldsFound(debugInfo) = e {
                appendConsole("\n[AUTO-LOG] Kicktipp DOM Debug:\n\(debugInfo)\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importTipsFromResponse() {
        errorMessage = nil
        do {
            let tips = try tipWorkflowService.parseTips(from: importedResponse, upcomingMatches: upcomingMatches)
            suggestedTips = tips
            if let spieltag = tips.first?.spieltag {
                let storedOdds = storedOddsSnapshot(for: tips)
                appendConsole("[Verlauf] \(tips.count) Tipps, \(storedOdds.count)/\(tips.count) Quoten gespeichert.\n")
                appendConsole("[Verlauf] Kicktipp-Namen: \(bettingOdds.map { "\($0.heim) vs \($0.gast)" }.joined(separator: ", "))\n")
                tipHistory.append(TipGenerationRecord(id: UUID(), timestamp: Date(), spieltag: spieltag, tips: tips, odds: storedOdds))
            }
            recordPredictionRun(tips: tips, rawPrompt: generatedPrompt, rawResponse: importedResponse)
            infoMessage = "Tipps importiert."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearTipHistory() {
        tipHistory = []
    }

    // MARK: - Learning

    func evaluateLearningData() async {
        await perform {
            if let fields = try? await self.kicktippAutomation.extractMatchFields() {
                self.kicktippMatchFields = fields
            }
            self.syncManualKicktippTipsForLearning(from: self.kicktippMatchFields)

            let seasons = Set(self.predictionRuns.compactMap { Int($0.seasonIdentifier) })
            guard !seasons.isEmpty else {
                self.infoMessage = "Keine auswertbaren Prediction-Runs vorhanden."
                return
            }

            var finishedBySeason: [String: [FinishedMatch]] = [:]
            for season in seasons.sorted() {
                finishedBySeason[String(season)] = try await self.ligaService.fetchFinishedMatches(season: season)
            }

            let summary = self.predictionEvaluator.evaluateRuns(
                self.predictionRuns,
                using: finishedBySeason,
                previousState: self.learningState
            )
            let runsWithClosingLines = await self.enrichEvaluatedRunsWithClosingLines(summary.runs)
            let finalSummary = self.predictionEvaluator.evaluateRuns(
                runsWithClosingLines,
                using: finishedBySeason,
                previousState: summary.learningState
            )
            self.predictionRuns = finalSummary.runs
            self.learningState = finalSummary.learningState
            self.infoMessage = summary.evaluatedMatches == 0
                ? "Keine neuen abgeschlossenen Spiele zum Bewerten gefunden."
                : "\(summary.evaluatedMatches) Vorhersage(n) wurden bewertet."
        }
    }

    func resetLearningData() {
        predictionRuns = []
        learningState = .empty
        infoMessage = "Learning-Daten wurden zurueckgesetzt."
    }

    // MARK: - Kicktipp

    func openKicktippLogin() {
        kicktippAutomation.openLogin()
        kicktippStatus = "Login-Seite geladen"
        infoMessage = "Bitte im eingebetteten Kicktipp-Browser anmelden."
    }

    func loadKicktippMatchday() async {
        await perform {
            try self.kicktippAutomation.loadTippabgabe(for: self.kicktippCompetitionSlug)
            try await self.waitForKicktippPageToFinishLoading()
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            self.syncManualKicktippTipsForLearning(from: fields)
            self.kicktippStatus = "\(fields.count) Kicktipp-Spiele erkannt"
            self.infoMessage = "Kicktipp-Tippabgabe fuer die Runde wurde geladen."
        }
    }

    func readKicktippMatches() async {
        await perform {
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            self.syncManualKicktippTipsForLearning(from: fields)
            self.kicktippStatus = "\(fields.count) Kicktipp-Spiele erkannt"
            self.infoMessage = "Kicktipp-Spiele aus der Seite gelesen."
        }
    }

    func applyTipsToKicktipp() async {
        await perform {
            guard !self.suggestedTips.isEmpty else {
                throw KicktippAutomationError.javaScriptError("Bitte zuerst Tipps importieren oder per Codex erzeugen.")
            }
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            let updates = try self.buildKicktippUpdates(from: fields)
            try await self.kicktippAutomation.applyTips(updates)
            self.kicktippStatus = "Tipps in Formular eingetragen"
            self.infoMessage = "Die importierten Tipps wurden in die Kicktipp-Felder eingetragen. Zum Absenden jetzt 'Tipps an Kicktipp senden' nutzen."
        }
    }

    func submitKicktippTips() async {
        await perform {
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            self.syncManualKicktippTipsForLearning(from: fields)
            try await self.kicktippAutomation.submitTips()
            self.kicktippStatus = "Tipps abgesendet"
            self.infoMessage = "Die Kicktipp-Tipps wurden abgesendet."
        }
    }

    func applySeasonQuestionTipsToKicktipp() async {
        await perform {
            let seasonValue = try self.parsedSeason()
            try await self.ensureKicktippMatchdayReadyForExtraction()
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            let teams = Set(fields.flatMap { [$0.heim, $0.gast] } + self.upcomingMatches.flatMap { [$0.heim, $0.gast] })
            let prompt = self.tipWorkflowService.buildSeasonQuestionPrompt(season: seasonValue, teams: teams.sorted())
            let outputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("betbaconer-season-questions-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outputFile) }

            let arguments = ["exec", "--skip-git-repo-check", "--output-last-message", outputFile.path, "-"]
            let result = try await self.executeCodexCommand(arguments: arguments, standardInput: prompt) { chunk in
                self.appendConsole(self.stripANSI(chunk))
            }
            guard result.exitCode == 0 else {
                throw CodexCLIError.executionFailed("Codex exec fuer Saisonfragen fehlgeschlagen. Siehe Console-Ausgabe.")
            }

            let output = try String(contentsOf: outputFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.seasonQuestionTips = try self.tipWorkflowService.parseSeasonQuestionTips(from: output)
            try await self.kicktippAutomation.applySeasonQuestionTips(self.seasonQuestionTips)
            self.kicktippStatus = "Saisonfragen eingetragen"
            self.infoMessage = "Die Saisonfragen wurden in Kicktipp eingetragen."
        }
    }

    // MARK: - Codex

    func checkCodexLoginStatus() async {
        await runCodexCommand(arguments: ["login", "status"], userFacingAction: "Codex-Status geprueft") { result in
            self.codexStatus = result.exitCode == 0 ? "Angemeldet" : "Nicht angemeldet"
        } onChunk: { chunk in
            self.appendConsole(self.stripANSI(chunk))
        }
    }

    func startCodexLogin() async {
        codexDeviceAuthURL = ""
        codexDeviceCode = ""

        await runCodexCommand(arguments: ["login", "--device-auth"], userFacingAction: "Codex-Login gestartet") { result in
            let cleanOutput = self.stripANSI(result.output)
            self.updateDeviceAuthData(from: cleanOutput)
            self.codexStatus = result.exitCode == 0 ? "Angemeldet" : "Login im Browser abschliessen"
            if !self.codexDeviceAuthURL.isEmpty {
                self.infoMessage = "Device-Auth-URL und Code wurden ausgelesen."
            }
        } onChunk: { chunk in
            let cleanChunk = self.stripANSI(chunk)
            self.appendConsole(cleanChunk)
            self.updateDeviceAuthData(from: self.consoleOutput)
        }
    }

    func openCodexDeviceAuthURL() {
        guard let url = URL(string: codexDeviceAuthURL), !codexDeviceAuthURL.isEmpty else {
            errorMessage = "Keine Device-Auth-URL vorhanden."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copyCodexDeviceCode() {
        guard !codexDeviceCode.isEmpty else {
            errorMessage = "Kein Device-Code vorhanden."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(codexDeviceCode, forType: .string)
        infoMessage = "Device-Code in die Zwischenablage kopiert."
    }

    func runPromptWithCodex() async {
        guard !generatedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Bitte zuerst einen Prompt erzeugen."
            return
        }
        // If already busy (e.g. invoked mid-workflow), run the ensemble directly.
        if isBusy {
            do { try await runPromptEnsembleWithCodex() } catch { errorMessage = error.localizedDescription }
            return
        }
        await perform { try await self.runPromptEnsembleWithCodex() }
    }

    func copyPromptToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(generatedPrompt, forType: .string)
    }

    func copySuggestedTipsAsText() {
        copySuggestedTips(formatter: formattedSuggestedTipText, message: "Alle Tippdetails in die Zwischenablage kopiert.")
    }

    func copySuggestedResultsAsText() {
        copySuggestedTips(formatter: formattedSuggestedResultText, message: "Tipp-Ergebnisse in die Zwischenablage kopiert.")
    }

    private func copySuggestedTips(formatter: (SuggestedTip) -> String, message: String) {
        guard !suggestedTips.isEmpty else {
            errorMessage = "Keine importierten Tipps zum Kopieren vorhanden."
            return
        }

        let text = orderedSuggestedTips
            .map(formattedSuggestedTipText)
            .joined(separator: "\n\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        infoMessage = message
    }

    func clearConsole() {
        consoleOutput = ""
    }

    // MARK: - Private

    private func buildKicktippUpdates(from fields: [KicktippMatchField]) throws -> [(field: KicktippMatchField, tip: SuggestedTip)] {
        var updates: [(field: KicktippMatchField, tip: SuggestedTip)] = []
        var matchedTipIDs = Set<SuggestedTip.ID>()

        for field in fields {
            guard let tip = suggestedTips.first(where: {
                normalizedTeamKey($0.heim, $0.gast) == normalizedTeamKey(field.heim, field.gast)
            }) else {
                continue
            }
            updates.append((field: field, tip: tip))
            matchedTipIDs.insert(tip.id)
        }

        if updates.isEmpty {
            throw KicktippAutomationError.javaScriptError("Keine Kicktipp-Spiele konnten mit den importierten Tipps gematcht werden.")
        }

        let unmatchedTips = suggestedTips.filter { !matchedTipIDs.contains($0.id) }
        if !unmatchedTips.isEmpty {
            let summary = unmatchedTips
                .map { "\($0.heim) vs. \($0.gast)" }
                .joined(separator: ", ")
            throw KicktippAutomationError.javaScriptError("Nicht alle Tipps konnten Kicktipp-Spielen zugeordnet werden: \(summary)")
        }

        return updates
    }

    private func restoreUpcomingMatchesFromLatestTips() {
        guard upcomingMatches.isEmpty, let latestTips = tipHistory.last else { return }
        upcomingMatches = Self.upcomingMatchesForLatestTips(latestTips, predictionRuns: predictionRuns)
        nextSpieltag = upcomingMatches.map(\.spieltag).min()
    }

    func orderedTips(_ tips: [SuggestedTip]) -> [SuggestedTip] {
        guard !tips.isEmpty, !kicktippMatchFields.isEmpty else { return tips }

        let tipsByMatchKey = Dictionary(
            uniqueKeysWithValues: tips.map { (normalizedTeamKey($0.heim, $0.gast), $0) }
        )

        let orderedMatches = kicktippMatchFields.compactMap { field in
            tipsByMatchKey[normalizedTeamKey(field.heim, field.gast)]
        }
        let matchedIDs = Set(orderedMatches.map(\.id))
        let unmatchedTips = tips.filter { !matchedIDs.contains($0.id) }

        return orderedMatches + unmatchedTips
    }

    private func formattedSuggestedTipText(_ tip: SuggestedTip) -> String {
        let odds = bettingOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let overUnder = overUnderOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let btts = bttsOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let handicap = handicapOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let weather = matchWeather.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let enrichment = llmMatchEnrichments.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let expectedGoals = matchExpectedGoals.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let h2h = finishedResults
            .filter { ($0.heim == tip.heim && $0.gast == tip.gast) || ($0.heim == tip.gast && $0.gast == tip.heim) }
            .sorted { ($0.spieltag, $0.datum) > ($1.spieltag, $1.datum) }
            .prefix(5)
        let relevantAbsences = playerAbsences.filter { absence in
            teamNamesLikelyMatch(absence.teamName, tip.heim) || teamNamesLikelyMatch(absence.teamName, tip.gast)
        }
        let heimAbsences = relevantAbsences.filter { teamNamesLikelyMatch($0.teamName, tip.heim) }
        let gastAbsences = relevantAbsences.filter { teamNamesLikelyMatch($0.teamName, tip.gast) }

        var lines = [
            "\(tip.heim) vs. \(tip.gast)",
            "\(tip.toreHeim) : \(tip.toreGast)"
        ]

        if !tip.rationale.isEmpty {
            lines.append(tip.rationale)
        }

        lines.append("")
        lines.append("Faktoren")
        if let expectedGoals {
            lines.append("- Modell: xG \(tip.heim) \(String(format: "%.2f", expectedGoals.home)) | \(tip.gast) \(String(format: "%.2f", expectedGoals.away)); Dixon-Coles/Poisson")
        } else {
            lines.append("- Modell: Dixon-Coles/Poisson")
        }
        if let odds {
            lines.append("- Quoten: 1 \(odds.quoteHeim) | X \(odds.quoteUnentschieden) | 2 \(odds.quoteGast)")
        }
        if let overUnder {
            var market = "- Tormarkt: O/U \(String(format: "%.1f", overUnder.line)) Over \(overUnder.overQuote) | Under \(overUnder.underQuote)"
            if let btts {
                market += "; BTTS Ja \(btts.yesQuote) | Nein \(btts.noQuote)"
            }
            lines.append(market)
        } else if let btts {
            lines.append("- BTTS: Ja \(btts.yesQuote) | Nein \(btts.noQuote)")
        }
        if let handicap {
            let homeSign = handicap.homeHandicap >= 0 ? "+" : ""
            let awaySign = handicap.awayHandicap >= 0 ? "+" : ""
            lines.append("- Handicap: \(tip.heim) \(homeSign)\(handicap.homeHandicap) \(handicap.homeQuote) | \(tip.gast) \(awaySign)\(handicap.awayHandicap) \(handicap.awayQuote)")
        }
        if let weather {
            lines.append("- Wetter: \(formattedWeatherText(weather))")
        }
        if !h2h.isEmpty {
            lines.append("- H2H: " + h2h.map { "\($0.heim) \($0.toreHeim):\($0.toreGast) \($0.gast)" }.joined(separator: " | "))
        }
        if let enrichment {
            lines.append("- LLM Spielerimpact: \(enrichment.playerImpact)")
            lines.append("- LLM Spielerwert: \(enrichment.playerValue)")
            lines.append("- LLM Schiri/Spielstil: \(enrichment.refereeStats)")
            lines.append("- LLM Sharp-Odds: \(enrichment.sharpOdds)")
            lines.append("- LLM Closing/CLV: \(enrichment.closingLine)")
            lines.append("- LLM Lineup-News: \(enrichment.lineup)")
            lines.append("- LLM Lineup-Struktur: \(enrichment.structuredLineup)")
            lines.append("- LLM Historische Basis: \(enrichment.historicalBaseline)")
            lines.append("- LLM Scoreline-Kalibrierung: \(enrichment.scorelineCalibration)")
            lines.append("- LLM Gewichtung: \(enrichment.learnedWeightHint)")
            lines.append("- LLM Datenqualitaet: \(enrichment.dataQuality) | Confidence \(String(format: "%.0f%%", enrichment.confidence * 100))")
            lines.append(String(format: "- LLM xG-Anpassung: Angriff H %+.0f%% / A %+.0f%% | Defensive H %+.0f%% / A %+.0f%% | Total %+.2f | Lineup %+.0f%% | Spielerwert %+.0f%% | Sharp %+.0f%% | CLV %+.0f%% | Remis %+.0f%%",
                                enrichment.homeAttackAdjustment * 100,
                                enrichment.awayAttackAdjustment * 100,
                                enrichment.homeDefenseAdjustment * 100,
                                enrichment.awayDefenseAdjustment * 100,
                                enrichment.totalGoalsAdjustment,
                                enrichment.lineupImpact * 100,
                                enrichment.playerValueImpact * 100,
                                enrichment.sharpMarketDelta * 100,
                                enrichment.closingLineValue * 100,
                                enrichment.scorelineDrawCalibration * 100))
        }

        if !heimAbsences.isEmpty {
            lines.append("")
            lines.append(contentsOf: formattedAbsenceLines(team: tip.heim, absences: heimAbsences))
        }
        if !gastAbsences.isEmpty {
            if heimAbsences.isEmpty { lines.append("") }
            lines.append(contentsOf: formattedAbsenceLines(team: tip.gast, absences: gastAbsences))
        }

        return lines.joined(separator: "\n")
    }

    private func formattedSuggestedResultText(_ tip: SuggestedTip) -> String {
        var lines = [
            "\(tip.heim) vs. \(tip.gast)",
            "\(tip.toreHeim) : \(tip.toreGast)"
        ]
        if !tip.rationale.isEmpty {
            lines.append(tip.rationale)
        }
        return lines.joined(separator: "\n")
    }

    private func formattedWeatherText(_ weather: MatchWeather) -> String {
        let temperature = weather.temperatureCelsius.map { String(format: "%.0f°C", $0) } ?? "Temp unbekannt"
        let precipitation = weather.precipitationMillimeters.map { String(format: "%.1f mm", $0) } ?? "Niederschlag unbekannt"
        let precipitationProbability = weather.precipitationProbability.map { "\($0)%" } ?? "n/a"
        let wind = weather.windSpeedKmh.map { String(format: "%.0f km/h", $0) } ?? "Wind unbekannt"
        return "\(weather.locationName) | \(temperature) | \(precipitation) (\(precipitationProbability)) | Wind \(wind)"
    }

    private func formattedAbsenceLines(team: String, absences: [PlayerAbsence]) -> [String] {
        [team] + absences.map { absence in
            "\(absenceEmoji(for: absence.type)) \(absence.playerName)\(absence.reason.isEmpty ? "" : " - \(absence.reason)")"
        }
    }

    private func storedOddsSnapshot(for tips: [SuggestedTip]) -> [BettingOdds] {
        tips.compactMap { tip in
            guard let matchedOdds = bettingOdds.first(where: {
                teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast)
            }) else {
                return nil
            }

            return BettingOdds(
                heim: tip.heim,
                gast: tip.gast,
                quoteHeim: matchedOdds.quoteHeim,
                quoteUnentschieden: matchedOdds.quoteUnentschieden,
                quoteGast: matchedOdds.quoteGast
            )
        }
    }

    private func remapOverUnderToUpcomingMatches(_ source: [OverUnderOdds], upcomingMatches: [UpcomingMatch]) -> [OverUnderOdds] {
        var remaining = source
        return upcomingMatches.compactMap { match in
            guard let index = remaining.firstIndex(where: {
                teamNamesLikelyMatch($0.heim, match.heim) && teamNamesLikelyMatch($0.gast, match.gast)
            }) else { return nil }
            let odds = remaining.remove(at: index)
            return OverUnderOdds(heim: match.heim, gast: match.gast, line: odds.line, overQuote: odds.overQuote, underQuote: odds.underQuote)
        }
    }

    private func remapBTTSToUpcomingMatches(_ source: [BTTSOdds], upcomingMatches: [UpcomingMatch]) -> [BTTSOdds] {
        var remaining = source
        return upcomingMatches.compactMap { match in
            guard let index = remaining.firstIndex(where: {
                teamNamesLikelyMatch($0.heim, match.heim) && teamNamesLikelyMatch($0.gast, match.gast)
            }) else { return nil }
            let odds = remaining.remove(at: index)
            return BTTSOdds(heim: match.heim, gast: match.gast, yesQuote: odds.yesQuote, noQuote: odds.noQuote)
        }
    }

    private func remapHandicapToUpcomingMatches(_ source: [HandicapOdds], upcomingMatches: [UpcomingMatch]) -> [HandicapOdds] {
        var remaining = source
        return upcomingMatches.compactMap { match in
            guard let index = remaining.firstIndex(where: {
                teamNamesLikelyMatch($0.heim, match.heim) && teamNamesLikelyMatch($0.gast, match.gast)
            }) else { return nil }
            let odds = remaining.remove(at: index)
            return HandicapOdds(heim: match.heim, gast: match.gast, homeHandicap: odds.homeHandicap, homeQuote: odds.homeQuote, awayHandicap: odds.awayHandicap, awayQuote: odds.awayQuote)
        }
    }

    private func remapOddsToUpcomingMatches(_ sourceOdds: [BettingOdds], upcomingMatches: [UpcomingMatch]) -> [BettingOdds] {
        var remainingOdds = sourceOdds

        return upcomingMatches.compactMap { match in
            guard let index = remainingOdds.firstIndex(where: {
                teamNamesLikelyMatch($0.heim, match.heim) && teamNamesLikelyMatch($0.gast, match.gast)
            }) else {
                return nil
            }

            let odds = remainingOdds.remove(at: index)
            return BettingOdds(
                heim: match.heim,
                gast: match.gast,
                quoteHeim: odds.quoteHeim,
                quoteUnentschieden: odds.quoteUnentschieden,
                quoteGast: odds.quoteGast
            )
        }
    }

    private func expectedGoalsByMatch() -> [String: MatchExpectedGoals] {
        let ratingModel = teamRatingService.fit(finishedResults: finishedResults)
        let oddsByKey = ensembleService.remappedOdds(bettingOdds: bettingOdds, upcomingMatches: upcomingMatches)
        let overUnderByKey = Dictionary(uniqueKeysWithValues: overUnderOdds.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        })
        let bttsByKey = Dictionary(uniqueKeysWithValues: bttsOdds.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        })
        let handicapByKey = Dictionary(uniqueKeysWithValues: handicapOdds.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        })
        let restDays = buildRestDaysByTeam()
        let absencesByTeam = Dictionary(grouping: playerAbsences) { normalizeTeamName($0.teamName) }
        let extrasByTeam = Dictionary(grouping: teamExtraFixtures) { normalizeTeamName($0.teamName) }
        let shotsByTeam = Dictionary(uniqueKeysWithValues: teamShotsStats.map { (normalizeTeamName($0.teamName), $0) })
        let weatherByMatch = Dictionary(uniqueKeysWithValues: matchWeather.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        })
        let enrichmentByMatch = Dictionary(uniqueKeysWithValues: llmMatchEnrichments.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        })

        return Dictionary(uniqueKeysWithValues: upcomingMatches.map { match in
            let homeStats = teamPerformance(for: match.heim)
            let awayStats = teamPerformance(for: match.gast)
            let homeMatchCount = finishedResults.filter { $0.heim == match.heim || $0.gast == match.heim }.count
            let awayMatchCount = finishedResults.filter { $0.heim == match.gast || $0.gast == match.gast }.count
            let homeVenueMatchCount = finishedResults.filter { $0.heim == match.heim }.count
            let awayVenueMatchCount = finishedResults.filter { $0.gast == match.gast }.count
            let shrunkHomeStats = (
                goalsPerGame: shrunkRate(homeStats.goalsPerGame, sampleCount: homeMatchCount, prior: 1.45),
                concededPerGame: shrunkRate(homeStats.concededPerGame, sampleCount: homeMatchCount, prior: 1.45)
            )
            let shrunkAwayStats = (
                goalsPerGame: shrunkRate(awayStats.goalsPerGame, sampleCount: awayMatchCount, prior: 1.45),
                concededPerGame: shrunkRate(awayStats.concededPerGame, sampleCount: awayMatchCount, prior: 1.45)
            )
            let homeVenueRaw = venuePerformance(for: match.heim, isHome: true)
            let awayVenueRaw = venuePerformance(for: match.gast, isHome: false)
            let homeVenue = (
                goalsPerGame: shrunkRate(homeVenueRaw.goalsPerGame, sampleCount: homeVenueMatchCount, prior: 1.55),
                concededPerGame: shrunkRate(homeVenueRaw.concededPerGame, sampleCount: homeVenueMatchCount, prior: 1.35)
            )
            let awayVenue = (
                goalsPerGame: shrunkRate(awayVenueRaw.goalsPerGame, sampleCount: awayVenueMatchCount, prior: 1.35),
                concededPerGame: shrunkRate(awayVenueRaw.concededPerGame, sampleCount: awayVenueMatchCount, prior: 1.55)
            )
            let homeAttack = blended(shrunkHomeStats.goalsPerGame, homeVenue.goalsPerGame, venueWeight: 0.3)
            let awayAttack = blended(shrunkAwayStats.goalsPerGame, awayVenue.goalsPerGame, venueWeight: 0.3)
            let homeDefense = blended(shrunkHomeStats.concededPerGame, homeVenue.concededPerGame, venueWeight: 0.3)
            let awayDefense = blended(shrunkAwayStats.concededPerGame, awayVenue.concededPerGame, venueWeight: 0.3)
            var homeXG = 1.45 * (homeAttack / 1.45) * (awayDefense / 1.45) * 1.25
            var awayXG = 1.45 * (awayAttack / 1.45) * (homeDefense / 1.45)
            if let ratingXG = ratingModel?.expectedGoals(homeTeam: match.heim, awayTeam: match.gast) {
                homeXG = ratingXG.home * 0.75 + homeXG * 0.25
                awayXG = ratingXG.away * 0.75 + awayXG * 0.25
            }

            if let shots = shotsByTeam[normalizeTeamName(match.heim)] {
                homeXG = homeXG * 0.75 + shots.shotsOnGoalPerGameHome * shots.shotsOnGoalConversionHome * 0.25
            }
            if let shots = shotsByTeam[normalizeTeamName(match.gast)] {
                awayXG = awayXG * 0.75 + shots.shotsOnGoalPerGameAway * shots.shotsOnGoalConversionAway * 0.25
            }

            let homeAbsenceImpact = absenceImpact(absencesByTeam[normalizeTeamName(match.heim)] ?? [])
            let awayAbsenceImpact = absenceImpact(absencesByTeam[normalizeTeamName(match.gast)] ?? [])
            homeXG *= 1 - homeAbsenceImpact.attack
            awayXG *= 1 - awayAbsenceImpact.attack
            homeXG *= 1 + awayAbsenceImpact.defense
            awayXG *= 1 + homeAbsenceImpact.defense

            homeXG *= restFactor(restDays[normalizeTeamName(match.heim)])
            awayXG *= restFactor(restDays[normalizeTeamName(match.gast)])
            homeXG *= extraFixtureFactor(extrasByTeam[normalizeTeamName(match.heim)] ?? [])
            awayXG *= extraFixtureFactor(extrasByTeam[normalizeTeamName(match.gast)] ?? [])

            if let weather = weatherByMatch[normalizedTeamKey(match.heim, match.gast)] {
                let factor = weatherGoalFactor(weather)
                homeXG *= factor
                awayXG *= factor
            }

            let matchKey = normalizedTeamKey(match.heim, match.gast)
            var drawCalibration = 0.0
            var marketWeightHint = 0.0
            if let enrichment = enrichmentByMatch[matchKey] {
                let confidence = min(max(enrichment.confidence, 0), 1)
                let weight = learnedLLMSignalWeight() * confidence
                homeXG *= 1 + (enrichment.homeAttackAdjustment + enrichment.awayDefenseAdjustment) * weight
                awayXG *= 1 + (enrichment.awayAttackAdjustment + enrichment.homeDefenseAdjustment) * weight
                homeXG *= 1 + (enrichment.lineupImpact + enrichment.playerValueImpact + enrichment.sharpMarketDelta + enrichment.closingLineValue) * weight
                awayXG *= 1 - (enrichment.lineupImpact + enrichment.playerValueImpact + enrichment.sharpMarketDelta + enrichment.closingLineValue) * weight
                if enrichment.totalGoalsAdjustment != 0 {
                    (homeXG, awayXG) = scaleTotal(
                        homeXG: homeXG,
                        awayXG: awayXG,
                        targetTotal: max(0.8, homeXG + awayXG + enrichment.totalGoalsAdjustment * weight),
                        weight: weight
                    )
                }
                if enrichment.historicalGoalBaseline > 0 {
                    (homeXG, awayXG) = scaleTotal(
                        homeXG: homeXG,
                        awayXG: awayXG,
                        targetTotal: enrichment.historicalGoalBaseline,
                        weight: 0.25 * confidence
                    )
                }
                drawCalibration = enrichment.scorelineDrawCalibration * confidence
                marketWeightHint = enrichment.marketWeightHint * confidence
            }

            if let overUnder = overUnderByKey[matchKey],
               let over = parseQuote(overUnder.overQuote),
               let under = parseQuote(overUnder.underQuote),
               over > 0, under > 0 {
                let inv = 1 / over + 1 / under
                let overShare = (1 / over) / inv
                let targetTotal = max(1.2, overUnder.line + (overShare - 0.5) * 1.2)
                (homeXG, awayXG) = scaleTotal(homeXG: homeXG, awayXG: awayXG, targetTotal: targetTotal, weight: 0.35)
            }

            if let btts = bttsByKey[matchKey],
               let yes = parseQuote(btts.yesQuote),
               let no = parseQuote(btts.noQuote),
               yes > 0, no > 0 {
                let inv = 1 / yes + 1 / no
                let yesShare = (1 / yes) / inv
                let lowerTeamBoost = (yesShare - 0.5) * 0.30
                if homeXG < awayXG {
                    homeXG *= 1 + lowerTeamBoost
                } else {
                    awayXG *= 1 + lowerTeamBoost
                }
            }

            if let handicap = handicapByKey[matchKey] {
                let shift = min(0.25, abs(handicap.homeHandicap) * 0.08)
                if handicap.homeHandicap < 0 {
                    homeXG *= 1 + shift
                    awayXG *= 1 - shift
                } else if handicap.homeHandicap > 0 {
                    homeXG *= 1 - shift
                    awayXG *= 1 + shift
                }
            }

            if learningState.sampleSize >= 30 {
                homeXG -= learningState.avgHomeGoalOverprediction * 0.35
                awayXG -= learningState.avgAwayGoalOverprediction * 0.35
                if learningState.highScoreOverpredictionBias > 0 {
                    (homeXG, awayXG) = scaleTotal(
                        homeXG: homeXG,
                        awayXG: awayXG,
                        targetTotal: homeXG + awayXG - learningState.highScoreOverpredictionBias,
                        weight: 0.25
                    )
                }
            }

            if let odds = oddsByKey[matchKey],
               let homeQuote = parseQuote(odds.quoteHeim),
               let drawQuote = parseQuote(odds.quoteUnentschieden),
               let awayQuote = parseQuote(odds.quoteGast),
               homeQuote > 0, drawQuote > 0, awayQuote > 0 {
                let inv = 1 / homeQuote + 1 / drawQuote + 1 / awayQuote
                let homeShare = (1 / homeQuote) / inv + (1 / drawQuote) / inv / 2
                let awayShare = (1 / awayQuote) / inv + (1 / drawQuote) / inv / 2
                let total = max(1.6, homeXG + awayXG)
                let favoriteWinShare = max((1 / homeQuote) / inv, (1 / awayQuote) / inv)
                let baseMarketWeight = favoriteWinShare < 0.45 ? 0.55 : 0.35
                let learnedMarketWeight = learnedMarketWeightAdjustment()
                let marketWeight = min(max(baseMarketWeight + marketWeightHint + learnedMarketWeight, 0.20), 0.75)
                let marketTotal = favoriteWinShare < 0.45 ? min(total, 2.8) : total
                homeXG = homeXG * (1 - marketWeight) + marketTotal * homeShare * marketWeight
                awayXG = awayXG * (1 - marketWeight) + marketTotal * awayShare * marketWeight
            }

            return (
                normalizedTeamKey(match.heim, match.gast),
                MatchExpectedGoals(
                    heim: match.heim,
                    gast: match.gast,
                    home: min(max(homeXG, 0.2), 4.5),
                    away: min(max(awayXG, 0.2), 4.5),
                    drawCalibration: drawCalibration,
                    marketWeightHint: marketWeightHint
                )
            )
        })
    }

    private func venuePerformance(for team: String, isHome: Bool) -> (goalsPerGame: Double, concededPerGame: Double) {
        let matches = finishedResults.filter { isHome ? $0.heim == team : $0.gast == team }
        guard !matches.isEmpty else { return (0, 0) }
        let goals = matches.map { isHome ? $0.toreHeim : $0.toreGast }
        let conceded = matches.map { isHome ? $0.toreGast : $0.toreHeim }
        return (
            Double(goals.reduce(0, +)) / Double(goals.count),
            Double(conceded.reduce(0, +)) / Double(conceded.count)
        )
    }

    private func blended(_ overall: Double, _ venue: Double, venueWeight: Double) -> Double {
        venue > 0 ? overall * (1 - venueWeight) + venue * venueWeight : overall
    }

    private func shrunkRate(_ value: Double, sampleCount: Int, prior: Double) -> Double {
        guard sampleCount > 0 else { return prior }
        let priorWeight = max(2.0, 14.0 - Double(sampleCount) * 2.0)
        return (value * Double(sampleCount) + prior * priorWeight) / (Double(sampleCount) + priorWeight)
    }

    private func learnedMarketWeightAdjustment() -> Double {
        decodedLearningWeights()?.marketWeightAdjustment
            ?? (learningState.brierScore > learningState.marketBrierScore + 0.05 ? 0.10 : 0)
    }

    private func learnedLLMSignalWeight() -> Double {
        decodedLearningWeights()?.llmSignalWeight ?? 0.55
    }

    private func decodedLearningWeights() -> LearningCorrectionWeights? {
        try? JSONDecoder().decode(LearningCorrectionWeights.self, from: Data(learningState.weightsJSON.utf8))
    }

    private func scaleTotal(homeXG: Double, awayXG: Double, targetTotal: Double, weight: Double) -> (Double, Double) {
        let currentTotal = max(0.1, homeXG + awayXG)
        let blendedTotal = currentTotal * (1 - weight) + targetTotal * weight
        let factor = blendedTotal / currentTotal
        return (homeXG * factor, awayXG * factor)
    }

    private func absenceImpact(_ absences: [PlayerAbsence]) -> (attack: Double, defense: Double) {
        let raw = min(0.20, Double(absences.count) * 0.025)
        let attackReasons = ["forward", "wing", "striker", "thigh", "muscle", "illness"]
        let defenseReasons = ["defender", "centre-back", "knee", "ankle", "calf", "surgery"]
        let text = absences.map { "\($0.playerName) \($0.reason)" }.joined(separator: " ").lowercased()
        let attack = raw * (attackReasons.contains { text.contains($0) } ? 1.1 : 0.8)
        let defense = raw * (defenseReasons.contains { text.contains($0) } ? 1.1 : 0.8)
        return (min(0.25, attack), min(0.25, defense))
    }

    private func restFactor(_ days: Int?) -> Double {
        guard let days else { return 1 }
        if days < 4 { return 0.92 }
        if days > 8 { return 1.03 }
        return 1
    }

    private func extraFixtureFactor(_ fixtures: [TeamExtraFixture]) -> Double {
        fixtures.isEmpty ? 1 : max(0.90, 1 - Double(fixtures.count) * 0.04)
    }

    private func weatherGoalFactor(_ weather: MatchWeather) -> Double {
        var factor = 1.0
        if (weather.precipitationMillimeters ?? 0) >= 3 || (weather.precipitationProbability ?? 0) >= 70 {
            factor -= 0.06
        }
        if (weather.windSpeedKmh ?? 0) >= 30 {
            factor -= 0.05
        }
        if let temperature = weather.temperatureCelsius, temperature < 0 || temperature > 30 {
            factor -= 0.03
        }
        return max(0.85, factor)
    }

    private func buildRestDaysByTeam() -> [String: Int] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        func date(from raw: String) -> Date? {
            formatter.date(from: raw) ?? fallbackFormatter.date(from: raw)
        }

        var result: [String: Int] = [:]
        for match in upcomingMatches {
            guard let kickoff = date(from: match.datum) else { continue }
            for team in [match.heim, match.gast] {
                let last = finishedResults
                    .filter { $0.heim == team || $0.gast == team }
                    .compactMap { date(from: $0.datum) }
                    .filter { $0 < kickoff }
                    .max()
                if let last {
                    result[normalizeTeamName(team)] = max(0, Calendar.current.dateComponents([.day], from: last, to: kickoff).day ?? 0)
                }
            }
        }
        return result
    }

    private func parsedSeason() throws -> Int {
        guard let seasonValue = Int(season) else {
            throw ValidationError.invalidSeason
        }
        return seasonValue
    }

    private func appendConsole(_ text: String) {
        consoleOutput += text
        AppLogger.app.debug("\(text, privacy: .public)")
    }

    private func stripANSI(_ text: String) -> String {
        let withoutEscapes = text.replacingOccurrences(of: #"\u{001B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        return withoutEscapes.replacingOccurrences(of: #"\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    }

    private func updateDeviceAuthData(from text: String) {
        if codexDeviceAuthURL.isEmpty {
            codexDeviceAuthURL = firstMatch(in: text, pattern: #"https://auth\.openai\.com/codex/device"#) ?? ""
            if !codexDeviceAuthURL.isEmpty {
                openCodexDeviceAuthURL()
            }
        }
        if codexDeviceCode.isEmpty {
            codexDeviceCode = firstMatch(in: text, pattern: #"\b[A-Z0-9]{4}-[A-Z0-9]{5}\b"#) ?? ""
        }
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private func runCodexCommand(
        arguments: [String],
        standardInput: String? = nil,
        userFacingAction: String,
        afterSuccess: @escaping (CodexCommandResult) throws -> Void = { _ in },
        onChunk: @escaping @MainActor (String) -> Void = { _ in }
    ) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let result = try await executeCodexCommand(arguments: arguments, standardInput: standardInput, onChunk: onChunk)
            try afterSuccess(result)
            if infoMessage?.isEmpty != false {
                infoMessage = userFacingAction
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await operation()
        } catch let e as KicktippAutomationError {
            errorMessage = e.localizedDescription
            if case let .noBettingFieldsFound(debugInfo) = e {
                appendConsole("\n[AUTO-LOG] Kicktipp DOM Debug:\n\(debugInfo)\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func waitForKicktippPageToFinishLoading(timeoutNanoseconds: UInt64 = 15_000_000_000) async throws {
        let start = DispatchTime.now().uptimeNanoseconds

        // Phase 1: wait for loading to START (gives the navigation delegate time to fire)
        // This guards against a race where webView.url already reflects the new URL
        // but isPageLoading hasn't been set to true yet.
        while !kicktippAutomation.isPageLoading {
            if DispatchTime.now().uptimeNanoseconds - start > 2_000_000_000 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Phase 2: wait for loading to FINISH with the correct URL
        while kicktippAutomation.isPageLoading || kicktippAutomation.webView.url?.absoluteString.contains("tippabgabe") != true {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                throw KicktippAutomationError.javaScriptError("Kicktipp-Tippabgabe konnte nicht rechtzeitig geladen werden.")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func ensureKicktippMatchdayReadyForExtraction() async throws {
        let slug = kicktippCompetitionSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else {
            throw KicktippAutomationError.invalidCompetitionSlug
        }

        let currentURL = kicktippAutomation.webView.url?.absoluteString ?? ""
        if !currentURL.contains("/\(slug)/tippabgabe") {
            try kicktippAutomation.loadTippabgabe(for: slug)
        }

        try await waitForKicktippPageToFinishLoading()
    }

    private func executeCodexCommand(
        arguments: [String],
        standardInput: String? = nil,
        onChunk: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> CodexCommandResult {
        appendConsole("\n$ \(codexPath) \(arguments.joined(separator: " "))\n")

        return try await codexCLIService.run(
            executablePath: codexPath,
            arguments: arguments,
            standardInput: standardInput
        ) { chunk in
            Task { @MainActor in
                onChunk(chunk)
            }
        }
    }

    private func fetchLLMMatchEnrichments(seasonValue: Int) async -> [LLMMatchEnrichment] {
        guard !upcomingMatches.isEmpty else { return [] }

        let missingSignals = [
            teamShotsStats.isEmpty ? "Shots-on-Goal und Verwertung" : nil,
            matchReferees.isEmpty ? "Schiedsrichter-Statistiken" : nil,
            teamExtraFixtures.isEmpty ? "Zusatzbelastung durch Europa/Pokal" : nil,
            "Sharp-Odds/Exchange-Check",
            "Lineup- und kurzfristige Teamnews",
            "Spielerwerte nach Minuten, Position, xG/xA, Defensive Actions und Keeper-Wert",
            "Closing-Line-Value oder closing-nahe Marktbewegung",
            "saisonuebergreifende historische Team- und Liga-Basisdaten",
            "Scoreline-Kalibrierung aus historischer Ergebnisverteilung",
            "dynamischer Gewichtungshinweis fuer Markt/Form/Lineup/Spielerimpact"
        ].compactMap { $0 }
        let prompt = tipWorkflowService.buildLLMEnrichmentPrompt(
            season: seasonValue,
            upcomingMatches: upcomingMatches,
            bettingOdds: bettingOdds,
            knownMissingSignals: missingSignals
        )
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("betbaconer-codex-enrichment-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputFile) }

        do {
            let result = try await executeCodexCommand(
                arguments: ["exec", "--skip-git-repo-check", "--output-last-message", outputFile.path, "-"],
                standardInput: prompt
            ) { chunk in
                self.appendConsole(self.stripANSI(chunk))
            }
            guard result.exitCode == 0 else {
                appendConsole("[LLM] Zusatzdaten fehlgeschlagen: Codex exit \(result.exitCode).\n")
                return []
            }
            let output = try String(contentsOf: outputFile, encoding: .utf8)
            let enrichments = try tipWorkflowService.parseLLMMatchEnrichments(from: output, upcomingMatches: upcomingMatches)
            appendConsole("[LLM] \(enrichments.count)/\(upcomingMatches.count) Zusatzdaten-Recherchen geladen.\n")
            return enrichments
        } catch {
            appendConsole("[LLM] Zusatzdaten fehlgeschlagen: \(error.localizedDescription)\n")
            return []
        }
    }

    private func enrichEvaluatedRunsWithClosingLines(_ runs: [PredictionRun]) async -> [PredictionRun] {
        let missing = runs
            .flatMap(\.matches)
            .filter { $0.isEvaluated && self.needsClosingLineUpdate($0) }
        guard !missing.isEmpty else { return runs }

        var updates: [LLMClosingLineUpdate] = []
        let batchSize = 12

        for start in stride(from: missing.startIndex, to: missing.endIndex, by: batchSize) {
            let end = missing.index(start, offsetBy: batchSize, limitedBy: missing.endIndex) ?? missing.endIndex
            let batch = Array(missing[start..<end])
            let prompt = tipWorkflowService.buildClosingLinePrompt(predictions: batch)
            let outputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("betbaconer-codex-closing-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outputFile) }

            do {
                let result = try await executeCodexCommand(
                    arguments: ["exec", "--skip-git-repo-check", "--output-last-message", outputFile.path, "-"],
                    standardInput: prompt
                ) { chunk in
                    self.appendConsole(self.stripANSI(chunk))
                }
                guard result.exitCode == 0 else {
                    appendConsole("[CLV] Closing-Line-Recherche fehlgeschlagen: Codex exit \(result.exitCode).\n")
                    continue
                }
                let output = try String(contentsOf: outputFile, encoding: .utf8)
                updates.append(contentsOf: try tipWorkflowService.parseClosingLineUpdates(from: output))
            } catch {
                appendConsole("[CLV] Closing-Line-Recherche fehlgeschlagen: \(error.localizedDescription)\n")
            }
        }

        appendConsole("[CLV] \(updates.count) Closing-Line-Updates geladen.\n")
        return applyClosingLineUpdates(updates, to: runs)
    }

    private func needsClosingLineUpdate(_ prediction: MatchPrediction) -> Bool {
        guard prediction.evaluatedClosingLineValue == nil else { return false }
        let text = prediction.llmClosingLine?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return text.isEmpty || text.contains("keine") || text.contains("unbekannt") || text.contains("n/a")
    }

    private func applyClosingLineUpdates(_ updates: [LLMClosingLineUpdate], to runs: [PredictionRun]) -> [PredictionRun] {
        let updatesByKey = Dictionary(uniqueKeysWithValues: updates.map {
            ("\($0.spieltag)|\(normalizedTeamKey($0.heim, $0.gast))", $0)
        })
        return runs.map { run in
            var copy = run
            copy.matches = run.matches.map { match in
                guard let update = updatesByKey["\(match.spieltag)|\(normalizedTeamKey(match.heim, match.gast))"] else {
                    return match
                }
                var updated = match
                updated.llmClosingLine = update.closingLine
                updated.evaluatedClosingLineValue = update.closingLineValue
                return updated
            }
            return copy
        }
    }

    private func runPromptEnsembleWithCodex() async throws {
        let runCount = codexRunCount
        var successfulRuns: [[SuggestedTip]] = []
        var failedRuns = 0

        for runIndex in 1...runCount {
            infoMessage = runCount == 1 ? "Codex analysiert..." : "Codex-Lauf \(runIndex)/\(runCount)..."
            let outputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("betbaconer-codex-last-message-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outputFile) }

            do {
                let arguments = ["exec", "--skip-git-repo-check", "--output-last-message", outputFile.path, "-"]
                let result = try await executeCodexCommand(arguments: arguments, standardInput: generatedPrompt) { chunk in
                    self.appendConsole(self.stripANSI(chunk))
                }

                guard result.exitCode == 0 else {
                    throw CodexCLIError.executionFailed("Codex exec fehlgeschlagen. Siehe Console-Ausgabe.")
                }

                let output = try String(contentsOf: outputFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let tips = try tipWorkflowService.parseTips(from: output, upcomingMatches: upcomingMatches)
                successfulRuns.append(tips)
                appendConsole("[Ensemble] Lauf \(runIndex)/\(runCount) erfolgreich geparst.\n")
            } catch {
                failedRuns += 1
                appendConsole("[Ensemble] Lauf \(runIndex)/\(runCount) fehlgeschlagen: \(error.localizedDescription)\n")
            }
        }

        guard !successfulRuns.isEmpty else {
            throw CodexCLIError.executionFailed("Alle Codex-Laeufe sind fehlgeschlagen. Siehe Console-Ausgabe.")
        }

        let minimumSuccessfulRuns = requiredSuccessfulCodexRuns(for: runCount)
        guard successfulRuns.count >= minimumSuccessfulRuns else {
            throw CodexCLIError.executionFailed(
                "Zu wenige erfolgreiche Codex-Laeufe: \(successfulRuns.count)/\(runCount). Mindestens \(minimumSuccessfulRuns) erfolgreiche Laeufe sind erforderlich."
            )
        }

        let expectedGoals = expectedGoalsByMatch()
        matchExpectedGoals = expectedGoals.values.sorted { $0.heim < $1.heim }
        appendConsole("[Ensemble] Poisson-Scoreline ueber \(successfulRuns.count) Lauf/Laeufe berechnet.\n")
        appendConsole("[xG] " + expectedGoals.values
            .sorted { $0.heim < $1.heim }
            .map { String(format: "%@ %.2f : %.2f %@", $0.heim, $0.home, $0.away, $0.gast) }
            .joined(separator: " | ") + "\n")
        let aggregatedTips = try ensembleService.aggregateTips(
            from: successfulRuns,
            upcomingMatches: upcomingMatches,
            bettingOdds: bettingOdds,
            expectedGoals: expectedGoals
        )
        importedResponse = tipWorkflowService.encodeTipsAsJSON(aggregatedTips)
        importTipsFromResponse()
        if failedRuns > 0 {
            appendConsole("[Ensemble] \(failedRuns) Lauf/Laeufe wurden verworfen.\n")
        }
        infoMessage = runCount == 1
            ? "Codex-Ausfuehrung abgeschlossen"
            : "Codex-Ensemble abgeschlossen (\(successfulRuns.count)/\(runCount) Laeufe)"
    }

    private func persistLearningStore() {
        do {
            try predictionStore.save(runs: predictionRuns, learningState: learningState)
        } catch {
            appendConsole("[Learning] Persistenz fehlgeschlagen: \(error.localizedDescription)\n")
        }
    }

    private func persistTipHistory() {
        do {
            try tipHistoryStore.save(tipHistory)
        } catch {
            appendConsole("[Verlauf] Persistenz fehlgeschlagen: \(error.localizedDescription)\n")
        }
    }

    private func syncManualKicktippTipsForLearning(from fields: [KicktippMatchField]) {
        let tips = Self.manualTips(from: fields, upcomingMatches: upcomingMatches)
        guard !tips.isEmpty, !hasPredictionRun(modelName: "kicktipp-manual", tips: tips) else { return }

        recordPredictionRun(tips: tips, rawPrompt: "", rawResponse: "", modelName: "kicktipp-manual")
        appendConsole("[Learning] \(tips.count) manuelle Kicktipp-Tipps fuer Self-Learning gespeichert.\n")
    }

    private func hasPredictionRun(modelName: String, tips: [SuggestedTip]) -> Bool {
        let expected = Dictionary(uniqueKeysWithValues: tips.map {
            (normalizedTeamKey($0.heim, $0.gast), "\($0.toreHeim):\($0.toreGast)")
        })

        return predictionRuns.contains { run in
            guard run.modelName == modelName,
                  run.spieltag == tips.first?.spieltag,
                  run.matches.count == tips.count else {
                return false
            }

            let actual = Dictionary(uniqueKeysWithValues: run.matches.map {
                (normalizedTeamKey($0.heim, $0.gast), "\($0.predictedHomeGoals):\($0.predictedAwayGoals)")
            })
            return actual == expected
        }
    }

    private func recordPredictionRun(tips: [SuggestedTip], rawPrompt: String, rawResponse: String, modelName: String = "codex-cli-ensemble") {
        guard !tips.isEmpty else { return }

        let runId = UUID()
        let createdAt = Date()
        let seasonIdentifier = season.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : season
        let contexts = Dictionary(uniqueKeysWithValues: buildPredictionContexts().map { (normalizedTeamKey($0.upcomingMatch.heim, $0.upcomingMatch.gast), $0) })
        let matches = tips.map { tip -> MatchPrediction in
            let context = contexts[normalizedTeamKey(tip.heim, tip.gast)]
            return MatchPrediction(
                id: UUID(),
                runId: runId,
                spieltag: tip.spieltag,
                heim: tip.heim,
                gast: tip.gast,
                kickoffAt: context?.upcomingMatch.datum ?? "",
                predictedHomeGoals: tip.toreHeim,
                predictedAwayGoals: tip.toreGast,
                predictedOutcome: outcome(forHomeGoals: tip.toreHeim, awayGoals: tip.toreGast),
                rationale: tip.rationale,
                quoteHome: context?.quoteHome,
                quoteDraw: context?.quoteDraw,
                quoteAway: context?.quoteAway,
                homeFormLast5: context?.homeFormLast5,
                awayFormLast5: context?.awayFormLast5,
                homeGoalsPerGame: context?.homeGoalsPerGame,
                awayGoalsPerGame: context?.awayGoalsPerGame,
                homeConcededPerGame: context?.homeConcededPerGame,
                awayConcededPerGame: context?.awayConcededPerGame,
                injuriesHomeCount: context?.injuriesHomeCount,
                injuriesAwayCount: context?.injuriesAwayCount,
                keyAbsenceHome: context?.keyAbsenceHome,
                keyAbsenceAway: context?.keyAbsenceAway,
                consistencySignalSummary: context?.consistencySignalSummary,
                llmLineup: context?.llmLineup,
                llmPlayerValue: context?.llmPlayerValue,
                llmSharpOdds: context?.llmSharpOdds,
                llmClosingLine: context?.llmClosingLine,
                llmHistoricalBaseline: context?.llmHistoricalBaseline,
                llmScorelineCalibration: context?.llmScorelineCalibration,
                dataQuality: context?.dataQuality,
                expectedHomeGoals: context?.expectedHomeGoals,
                expectedAwayGoals: context?.expectedAwayGoals,
                marketWeightHint: context?.marketWeightHint,
                actualHomeGoals: nil,
                actualAwayGoals: nil,
                actualOutcome: nil,
                exactHit: nil,
                tendencyHit: nil,
                goalDiffHit: nil,
                absErrorHomeGoals: nil,
                absErrorAwayGoals: nil,
                totalAbsGoalError: nil,
                evaluatedAt: nil
            )
        }

        predictionRuns.append(
            PredictionRun(
                id: runId,
                createdAt: createdAt,
                spieltag: tips.first?.spieltag ?? 0,
                modelName: modelName,
                promptVersion: "xg-dixon-coles-shrinkage-llm-v4",
                rawPrompt: rawPrompt,
                rawResponse: rawResponse,
                seasonIdentifier: seasonIdentifier,
                matches: matches
            )
        )
    }

    private func buildPredictionContexts() -> [PredictionMatchContext] {
        let oddsByKey = ensembleService.remappedOdds(bettingOdds: bettingOdds, upcomingMatches: upcomingMatches)
        let groupedAbsences = Dictionary(grouping: playerAbsences) { normalizeTeamName($0.teamName) }
        let expectedGoalsByKey = Dictionary(uniqueKeysWithValues: matchExpectedGoals.map { (normalizedTeamKey($0.heim, $0.gast), $0) })
        let enrichmentsByKey = Dictionary(uniqueKeysWithValues: llmMatchEnrichments.map { (normalizedTeamKey($0.heim, $0.gast), $0) })
        let targetSpieltag = upcomingMatches.first?.spieltag
        let historyForMatchday = tipHistory.filter { $0.spieltag == targetSpieltag }

        return upcomingMatches.map { match in
            let homeStats = teamPerformance(for: match.heim)
            let awayStats = teamPerformance(for: match.gast)
            let homeAbsences = groupedAbsences[normalizeTeamName(match.heim)] ?? []
            let awayAbsences = groupedAbsences[normalizeTeamName(match.gast)] ?? []
            let odds = oddsByKey[normalizedTeamKey(match.heim, match.gast)]
            let xg = expectedGoalsByKey[normalizedTeamKey(match.heim, match.gast)]
            let enrichment = enrichmentsByKey[normalizedTeamKey(match.heim, match.gast)]

            return PredictionMatchContext(
                upcomingMatch: match,
                quoteHome: parseQuote(odds?.quoteHeim),
                quoteDraw: parseQuote(odds?.quoteUnentschieden),
                quoteAway: parseQuote(odds?.quoteGast),
                homeFormLast5: homeStats.formLast5,
                awayFormLast5: awayStats.formLast5,
                homeGoalsPerGame: homeStats.goalsPerGame,
                awayGoalsPerGame: awayStats.goalsPerGame,
                homeConcededPerGame: homeStats.concededPerGame,
                awayConcededPerGame: awayStats.concededPerGame,
                injuriesHomeCount: homeAbsences.count,
                injuriesAwayCount: awayAbsences.count,
                keyAbsenceHome: homeAbsences.first.map { "\($0.playerName) (\($0.type))" },
                keyAbsenceAway: awayAbsences.first.map { "\($0.playerName) (\($0.type))" },
                consistencySignalSummary: consistencySignalSummary(for: match, history: historyForMatchday),
                llmLineup: enrichment?.structuredLineup,
                llmPlayerValue: enrichment?.playerValue,
                llmSharpOdds: enrichment?.sharpOdds,
                llmClosingLine: enrichment?.closingLine,
                llmHistoricalBaseline: enrichment?.historicalBaseline,
                llmScorelineCalibration: enrichment?.scorelineCalibration,
                dataQuality: enrichment?.dataQuality,
                expectedHomeGoals: xg?.home,
                expectedAwayGoals: xg?.away,
                marketWeightHint: xg?.marketWeightHint
            )
        }
    }

    private func teamPerformance(for team: String) -> (formLast5: String, goalsPerGame: Double, concededPerGame: Double) {
        let matches = finishedResults
            .filter { $0.heim == team || $0.gast == team }
            .sorted { ($0.spieltag, $0.datum) > ($1.spieltag, $1.datum) }

        guard !matches.isEmpty else {
            return ("-", 0, 0)
        }

        let form = matches.prefix(5).map { match -> String in
            let homeGoals = match.heim == team ? match.toreHeim : match.toreGast
            let awayGoals = match.heim == team ? match.toreGast : match.toreHeim
            return homeGoals > awayGoals ? "S" : homeGoals == awayGoals ? "U" : "N"
        }.joined(separator: "-")

        let goals = matches.map { $0.heim == team ? $0.toreHeim : $0.toreGast }
        let conceded = matches.map { $0.heim == team ? $0.toreGast : $0.toreHeim }

        return (
            form.isEmpty ? "-" : form,
            Double(goals.reduce(0, +)) / Double(goals.count),
            Double(conceded.reduce(0, +)) / Double(conceded.count)
        )
    }

    private func consistencySignalSummary(for match: UpcomingMatch, history: [TipGenerationRecord]) -> String? {
        let entries = history.compactMap { record in
            record.tips.first { normalizedTeamKey($0.heim, $0.gast) == normalizedTeamKey(match.heim, match.gast) }
        }
        guard !entries.isEmpty else { return nil }
        let grouped = Dictionary(grouping: entries) { "\($0.toreHeim):\($0.toreGast)" }
        let summary = grouped.sorted { $0.value.count > $1.value.count }
            .map { "\($0.value.count)x \($0.key)" }
            .joined(separator: ", ")
        return summary
    }

    private func parseQuote(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value.replacingOccurrences(of: ",", with: "."))
    }

    private func validateWorkflowInputs(upcomingMatches: [UpcomingMatch]) {
        if bettingOdds.count < upcomingMatches.count {
            appendConsole("[Quoten] Warnung: Nur \(bettingOdds.count)/\(upcomingMatches.count) Quoten verfuegbar – Workflow laeuft ohne vollstaendige Quotendaten.\n")
        }
    }

    private func requiredSuccessfulCodexRuns(for configuredRuns: Int) -> Int {
        guard configuredRuns > 1 else { return 1 }
        return max(2, Int(ceil(Double(configuredRuns) * 0.6)))
    }
}

enum ValidationError: LocalizedError {
    case invalidSeason
    case noUpcomingMatches
    case incompleteOddsCoverage(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .invalidSeason:
            return "Bitte eine gueltige Saison eintragen."
        case .noUpcomingMatches:
            return "Kein offener Spieltag gefunden."
        case let .incompleteOddsCoverage(expected, actual):
            return "Unvollstaendige Quotenabdeckung: \(actual)/\(expected) Spiele. Der Workflow bricht aus Sicherheitsgruenden ab."
        }
    }
}
