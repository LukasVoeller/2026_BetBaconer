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
        static let learningPostProcessingEnabled = "learningPostProcessingEnabled"
    }

    private enum SecretKeys {
        static let theOddsAPIKey = "theOddsAPIKey"
    }

    // MARK: - State

    var season: String = "2025"
    var codexRunCount: Int = {
        let stored = UserDefaults.standard.integer(forKey: Keys.codexRunCount)
        return stored == 0 ? 5 : stored
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
    var kicktippMatchFields: [KicktippMatchField] = []
    var orderedSuggestedTips: [SuggestedTip] {
        orderedTips(suggestedTips)
    }
    var bettingOdds: [BettingOdds] = []
    var playerAbsences: [PlayerAbsence] = []
    var teamMetadata: [TeamMetadata] = []
    var matchWeather: [MatchWeather] = []
    var nextSpieltag: Int?
    var tipHistory: [TipGenerationRecord] = [] {
        didSet {
            persistTipHistory()
        }
    }
    var predictionRuns: [PredictionRun] = [] {
        didSet { persistLearningStore() }
    }
    var learningState: LearningState = .empty {
        didSet { persistLearningStore() }
    }
    var learningPostProcessingEnabled: Bool = UserDefaults.standard.object(forKey: Keys.learningPostProcessingEnabled) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(learningPostProcessingEnabled, forKey: Keys.learningPostProcessingEnabled)
        }
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
    private let predictionStore = PredictionStore()
    private let predictionEvaluator = PredictionEvaluator()
    private let predictionPostProcessor = PredictionPostProcessor()
    private let ensembleService = EnsembleService()
    private let codexCLIService = CodexCLIService()
    private let secretStore = KeychainSecretStore()
    private let tipHistoryStore = TipHistoryStore()

    private var oddsAPIService: TheOddsAPIService {
        TheOddsAPIService(apiKey: theOddsAPIKey)
    }

    // MARK: - Init

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
        } catch {
            errorMessage = error.localizedDescription
        }

        do {
            let loaded = try predictionStore.load()
            predictionRuns = loaded.runs
            learningState = loaded.learningState
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
            importedResponse = ""
            self.nextSpieltag = nextSpieltag

            guard !upcoming.isEmpty else {
                throw ValidationError.noUpcomingMatches
            }

            infoMessage = "Lese Wettquoten..."
            bettingOdds = []
            do {
                let apiOdds = try await oddsAPIService.fetchBundesligaOdds()
                bettingOdds = remapOddsToUpcomingMatches(apiOdds, upcomingMatches: upcoming)
                appendConsole("[Quoten] \(bettingOdds.count)/\(upcoming.count) Quoten aus The Odds API geladen.\n")
            } catch {
                appendConsole("[Quoten] The Odds API fehlgeschlagen: \(error.localizedDescription)\n")
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

            try validateWorkflowInputs(upcomingMatches: upcoming)

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

            infoMessage = "Lade Wetterdaten..."
            do {
                matchWeather = try await weatherService.fetchWeather(for: upcomingMatches, teamMetadata: teamMetadata)
                appendConsole("[Open-Meteo] \(matchWeather.count) Wetter-Eintraege geladen.\n")
            } catch {
                appendConsole("[Open-Meteo] Fehler: \(error.localizedDescription)\n")
                matchWeather = []
            }

            infoMessage = "Erzeuge Prompt..."
            generatedPrompt = tipWorkflowService.buildPrompt(
                season: seasonValue,
                finishedResults: finishedResults,
                upcomingMatches: upcomingMatches,
                bettingOdds: bettingOdds,
                playerAbsences: playerAbsences,
                teamMetadata: teamMetadata,
                matchWeather: matchWeather,
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
            self.predictionRuns = summary.runs
            self.learningState = summary.learningState
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
            self.kicktippStatus = "\(fields.count) Kicktipp-Spiele erkannt"
            self.infoMessage = "Kicktipp-Tippabgabe fuer die Runde wurde geladen."
        }
    }

    func readKicktippMatches() async {
        await perform {
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
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
            try await self.kicktippAutomation.submitTips()
            self.kicktippStatus = "Tipps abgesendet"
            self.infoMessage = "Die Kicktipp-Tipps wurden abgesendet."
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
        infoMessage = "Importierte Tipps als Text in die Zwischenablage kopiert."
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
        if !heimAbsences.isEmpty {
            lines.append(contentsOf: formattedAbsenceLines(team: tip.heim, absences: heimAbsences))
        }
        if !gastAbsences.isEmpty {
            lines.append(contentsOf: formattedAbsenceLines(team: tip.gast, absences: gastAbsences))
        }

        return lines.joined(separator: "\n")
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

        appendConsole("[Ensemble] Mehrheitsaggregation ueber \(successfulRuns.count) Lauf/Laeufe abgeschlossen.\n")
        let aggregatedTips = try ensembleService.aggregateTips(
            from: successfulRuns,
            upcomingMatches: upcomingMatches,
            bettingOdds: bettingOdds
        )
        let oddsByKey = ensembleService.remappedOdds(bettingOdds: bettingOdds, upcomingMatches: upcomingMatches)
        let postProcessedTips = predictionPostProcessor.process(
            tips: aggregatedTips,
            learningState: learningState,
            oddsByMatch: oddsByKey,
            isEnabled: learningPostProcessingEnabled
        )
        if postProcessedTips != aggregatedTips {
            appendConsole("[Learning] Regelbasierte Nachkorrektur angewendet.\n")
        }
        importedResponse = tipWorkflowService.encodeTipsAsJSON(postProcessedTips)
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

    private func recordPredictionRun(tips: [SuggestedTip], rawPrompt: String, rawResponse: String) {
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
                modelName: "codex-cli-ensemble",
                promptVersion: "self-learning-v1",
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
        let targetSpieltag = upcomingMatches.first?.spieltag
        let historyForMatchday = tipHistory.filter { $0.spieltag == targetSpieltag }

        return upcomingMatches.map { match in
            let homeStats = teamPerformance(for: match.heim)
            let awayStats = teamPerformance(for: match.gast)
            let homeAbsences = groupedAbsences[normalizeTeamName(match.heim)] ?? []
            let awayAbsences = groupedAbsences[normalizeTeamName(match.gast)] ?? []
            let odds = oddsByKey[normalizedTeamKey(match.heim, match.gast)]

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
                consistencySignalSummary: consistencySignalSummary(for: match, history: historyForMatchday)
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

    private func validateWorkflowInputs(upcomingMatches: [UpcomingMatch]) throws {
        guard bettingOdds.count == upcomingMatches.count else {
            throw ValidationError.incompleteOddsCoverage(expected: upcomingMatches.count, actual: bettingOdds.count)
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
