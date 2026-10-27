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
        static let kicktippRules                = "kicktippRules"
        static let kicktippPlayerName           = "kicktippPlayerName"
        static let useRankingStrategy           = "useRankingStrategy"
        static let learnedMarketWeight          = "learnedMarketWeight"
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
    var kicktippRules: KicktippRules = UserDefaults.standard.data(forKey: Keys.kicktippRules)
        .flatMap { try? JSONDecoder().decode(KicktippRules.self, from: $0) } ?? .standard {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(kicktippRules), forKey: Keys.kicktippRules) }
    }
    /// Own player name in the Kicktipp group, used to locate the ranking position.
    var kicktippPlayerName: String = UserDefaults.standard.string(forKey: Keys.kicktippPlayerName) ?? "" {
        didSet { UserDefaults.standard.set(kicktippPlayerName, forKey: Keys.kicktippPlayerName) }
    }
    var useRankingStrategy: Bool = UserDefaults.standard.bool(forKey: Keys.useRankingStrategy) {
        didSet { UserDefaults.standard.set(useRankingStrategy, forKey: Keys.useRankingStrategy) }
    }
    /// Share of the bookmaker market in expected goals; learned from the odds archive by the backtest.
    var learnedMarketWeight: Double = (UserDefaults.standard.object(forKey: Keys.learnedMarketWeight) as? Double) ?? ModelBacktestService.defaultMarketWeight {
        didSet { UserDefaults.standard.set(learnedMarketWeight, forKey: Keys.learnedMarketWeight) }
    }
    var backtestReport = ""
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
    /// Every odds snapshot the app has seen (latest per match), the basis for learning the market weight.
    var oddsArchive: [ArchivedOdds] = [] {
        didSet { persistLearningStore() }
    }
    /// Finished matches of earlier seasons (start year -> matches) for the rating model and backtests.
    private var historicalSeasons: [Int: [FinishedMatch]] = [:]
    /// Fellow players' tips of finished matchdays, read from the Kicktipp tip overview.
    var communityMatchdays: [CommunityMatchday] = [] {
        didSet { persistLearningStore() }
    }
    var currentSeasonCommunity: [CommunityMatchday] {
        communityMatchdays.filter { $0.season == season.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    var inferredKicktippRules: InferredKicktippRules? {
        communityService.inferRules(from: currentSeasonCommunity)
    }
    var communityBacktest: [CommunityBacktestRow] {
        communityService.backtest(runs: predictionRuns, matchdays: currentSeasonCommunity, rules: kicktippRules)
    }
    var rankingStrategy: RankingStrategy? {
        let name = kicktippPlayerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let nextSpieltag else { return nil }
        return communityService.rankingStrategy(playerName: name, matchdays: currentSeasonCommunity, nextSpieltag: nextSpieltag)
    }
    var isBusy = false
    /// Kicktipp fields that already hold a different tip and would be overwritten; non-empty asks the UI for confirmation.
    var pendingKicktippOverwrites: [String] = []
    private var activeCodexProcess: CodexProcessHandle?
    /// Set when a store could not be loaded nor backed up; saving would destroy the unreadable file.
    private var tipHistoryPersistenceDisabled = false
    private var learningPersistenceDisabled = false
    private var codexCancelRequested = false
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
    private let communityService = KicktippCommunityService()
    private var ensembleService: EnsembleService {
        var service = EnsembleService(rules: kicktippRules)
        let community = currentSeasonCommunity
        if !community.isEmpty {
            service.crowdTipHomeFavorite = communityService.typicalCrowdTip(homeFavored: true, matchdays: community)
            service.crowdTipAwayFavorite = communityService.typicalCrowdTip(homeFavored: false, matchdays: community)
        }
        if useRankingStrategy {
            service.strategy = rankingStrategy
        }
        return service
    }
    private let codexCLIService = CodexCLIService()
    private let secretStore = KeychainSecretStore()
    private let tipHistoryStore = TipHistoryStore()

    private var oddsAPIService: TheOddsAPIService {
        TheOddsAPIService(apiKey: theOddsAPIKey)
    }

    // MARK: - Init

    /// Bump whenever tip selection changes, so backtesting stays separated per model version.
    static let promptVersion = "rating-market-ev-kicktipp-v6"

    static func currentBundesligaSeason(for date: Date = Date()) -> Int {
        let year = Calendar.current.component(.year, from: date)
        let month = Calendar.current.component(.month, from: date)
        return month >= 7 ? year : year - 1
    }

    static func upcomingMatchesForLatestTips(_ record: TipGenerationRecord, predictionRuns: [PredictionRun]) -> [UpcomingMatch] {
        let recordSeason = String(currentBundesligaSeason(for: record.timestamp))
        let latestRun = predictionRuns
            .filter { $0.seasonIdentifier == recordSeason && $0.spieltag == record.spieltag }
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
        .compactMap { _, runs in runs.max(by: PredictionRun.learningOrder) }
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

    static func stabilizeShortTermTips(
        _ tips: [SuggestedTip],
        previousRuns: [PredictionRun],
        currentRuns: [[SuggestedTip]],
        seasonIdentifier: String,
        now: Date = Date(),
        window: TimeInterval = 2 * 60 * 60
    ) -> (tips: [SuggestedTip], stabilizedCount: Int) {
        guard let spieltag = tips.first?.spieltag, !currentRuns.isEmpty else {
            return (tips, 0)
        }

        guard let previousRun = previousRuns
            .filter({
                $0.modelName == PredictionRun.ensembleModelName
                    && $0.seasonIdentifier == seasonIdentifier
                    && $0.spieltag == spieltag
                    && !$0.matches.contains(where: \.isEvaluated)
                    && now.timeIntervalSince($0.createdAt) >= 0
                    && now.timeIntervalSince($0.createdAt) <= window
            })
            .sorted(by: { $0.createdAt > $1.createdAt })
            .first else {
            return (tips, 0)
        }

        let previousByKey = Dictionary(previousRun.matches.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        }, uniquingKeysWith: { first, _ in first })
        let consensusThreshold = max(2, Int(ceil(Double(currentRuns.count) * 0.75)))
        var stabilizedCount = 0

        let stabilizedTips = tips.map { tip -> SuggestedTip in
            let key = normalizedTeamKey(tip.heim, tip.gast)
            guard let previous = previousByKey[key],
                  previous.predictedHomeGoals != tip.toreHeim || previous.predictedAwayGoals != tip.toreGast else {
                return tip
            }

            let currentScore = "\(tip.toreHeim):\(tip.toreGast)"
            let currentVotes = currentRuns.filter { run in
                run.contains {
                    normalizedTeamKey($0.heim, $0.gast) == key
                        && "\($0.toreHeim):\($0.toreGast)" == currentScore
                }
            }.count
            guard currentVotes < consensusThreshold else { return tip }

            stabilizedCount += 1
            return SuggestedTip(
                spieltag: tip.spieltag,
                heim: tip.heim,
                gast: tip.gast,
                toreHeim: previous.predictedHomeGoals,
                toreGast: previous.predictedAwayGoals,
                rationale: previous.rationale.isEmpty
                    ? "Stabilisiert: neuer Kurzfrist-Run ohne starken Konsens."
                    : previous.rationale
            )
        }

        return (stabilizedTips, stabilizedCount)
    }

    static func manualTips(from fields: [KicktippMatchField], upcomingMatches: [UpcomingMatch]) -> [SuggestedTip] {
        let matchesByKey = Dictionary(upcomingMatches.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        }, uniquingKeysWith: { first, _ in first })

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
            if case .failedToLoad(backup: nil)? = error as? TipHistoryStoreError {
                tipHistoryPersistenceDisabled = true
            }
        }

        do {
            let loaded = try predictionStore.load()
            predictionRuns = loaded.runs
            learningState = loaded.learningState
            communityMatchdays = loaded.community
            oddsArchive = loaded.oddsArchive
            restoreUpcomingMatchesFromLatestTips()
        } catch {
            errorMessage = error.localizedDescription
            if case .failedToLoad(backup: nil)? = error as? PredictionStoreError {
                learningPersistenceDisabled = true
            }
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
        codexCancelRequested = false
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
            await loadHistoricalSeasons(before: seasonValue, count: 2)

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
            archiveCurrentOdds(season: String(seasonValue))

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

            if !kicktippCompetitionSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                infoMessage = "Lese Tipps und Quoten vergangener Spieltage..."
                await syncCommunityTips(seasonValue: seasonValue)
                await backfillKicktippOdds(seasonValue: seasonValue)
                do {
                    try await ensureKicktippMatchdayReadyForExtraction()
                } catch {
                    appendConsole("[Mitspieler] Zurueck zur Tippabgabe fehlgeschlagen: \(error.localizedDescription)\n")
                }
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
                llmMatchEnrichments: llmMatchEnrichments,
                tipHistory: tipHistory,
                learningState: learningState,
                communitySummary: communityService.promptSummary(
                    matchdays: currentSeasonCommunity,
                    rules: kicktippRules,
                    backtest: communityBacktest,
                    strategy: useRankingStrategy ? rankingStrategy : nil
                )
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
        importTipsFromResponse(probabilityModels: [:])
    }

    private func importTipsFromResponse(probabilityModels: [String: EnsembleService.MatchProbabilityModel]) {
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
            recordPredictionRun(tips: tips, rawPrompt: generatedPrompt, rawResponse: importedResponse, probabilityModels: probabilityModels)
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

    func loadCommunityTips() async {
        await perform {
            let seasonValue = try self.parsedSeason()
            if self.finishedResults.isEmpty {
                self.finishedResults = try await self.ligaService.fetchFinishedMatches(season: seasonValue)
            }
            await self.syncCommunityTips(seasonValue: seasonValue)
            await self.backfillKicktippOdds(seasonValue: seasonValue)
            try await self.ensureKicktippMatchdayReadyForExtraction()
            self.infoMessage = "\(self.currentSeasonCommunity.count) Spieltage mit Mitspieler-Tipps, \(self.oddsArchive.count) archivierte Quoten."
        }
    }

    /// Walk-forward backtest over the last seasons; learns the market weight once the odds archive is large enough.
    func runModelBacktest() async {
        await perform {
            let seasonValue = try self.parsedSeason()
            self.infoMessage = "Lade Saisons fuer den Backtest..."
            await self.loadHistoricalSeasons(before: seasonValue, count: 6)
            var seasons = self.historicalSeasons
            seasons[seasonValue] = self.finishedResults.isEmpty
                ? try await self.ligaService.fetchFinishedMatches(season: seasonValue)
                : self.finishedResults
            let backtest = ModelBacktestService(rules: self.kicktippRules)
            let archive = self.oddsArchive
            self.infoMessage = "Backtest laeuft..."
            let report = await Task.detached(priority: .userInitiated) {
                backtest.run(seasons: seasons, oddsArchive: archive, evaluatedSeasons: (seasonValue - 4)...seasonValue)
            }.value
            if let best = report.bestMarketWeight {
                self.learnedMarketWeight = best
            }
            self.backtestReport = report.summary
            self.appendConsole("[Backtest]\n\(report.summary)\n")
            self.infoMessage = "Backtest abgeschlossen."
        }
    }

    private func loadHistoricalSeasons(before seasonValue: Int, count: Int) async {
        for year in (seasonValue - count)..<seasonValue where historicalSeasons[year] == nil {
            do {
                historicalSeasons[year] = try await ligaService.fetchFinishedMatches(season: year)
            } catch {
                appendConsole("[OpenLigaDB] Saison \(year) nicht geladen: \(error.localizedDescription)\n")
            }
        }
    }

    /// Keeps the latest odds per match; the snapshot closest to kickoff wins.
    private func archiveCurrentOdds(season: String) {
        let overUnderByKey = Dictionary(overUnderOdds.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
        let snapshots = upcomingMatches.compactMap { match -> ArchivedOdds? in
            let key = normalizedTeamKey(match.heim, match.gast)
            guard let odds = bettingOdds.first(where: { normalizedTeamKey($0.heim, $0.gast) == key }) else { return nil }
            let overUnder = overUnderByKey[key]
            return ArchivedOdds(
                season: season, spieltag: match.spieltag, heim: match.heim, gast: match.gast,
                quoteHeim: odds.quoteHeim, quoteUnentschieden: odds.quoteUnentschieden, quoteGast: odds.quoteGast,
                overUnderLine: overUnder?.line, overQuote: overUnder?.overQuote, underQuote: overUnder?.underQuote,
                capturedAt: Date()
            )
        }
        mergeIntoOddsArchive(snapshots)
    }

    private func mergeIntoOddsArchive(_ snapshots: [ArchivedOdds]) {
        guard !snapshots.isEmpty else { return }
        let replaced = Set(snapshots.map { "\($0.season)|\($0.spieltag)|\(normalizedTeamKey($0.heim, $0.gast))" })
        oddsArchive = oddsArchive.filter { !replaced.contains("\($0.season)|\($0.spieltag)|\(normalizedTeamKey($0.heim, $0.gast))") } + snapshots
    }

    /// Reads the odds Kicktipp shows on the tip page of finished matchdays that are not archived yet.
    private func backfillKicktippOdds(seasonValue: Int) async {
        let seasonKey = String(seasonValue)
        let archived = Set(oddsArchive.filter { $0.season == seasonKey }.map(\.spieltag))
        let missing = Set(finishedResults.map(\.spieltag))
            .filter { matchday in !archived.contains(matchday) && (nextSpieltag.map { matchday < $0 } ?? true) }
            .sorted()
        var stored = 0
        for spieltag in missing {
            do {
                try kicktippAutomation.loadTippabgabe(for: kicktippCompetitionSlug, spieltag: spieltag)
                try await waitForKicktippPageToFinishLoading(urlContaining: "spieltagIndex=\(spieltag)")
            } catch {
                appendConsole("[Quoten-Archiv] Spieltag \(spieltag) nicht geladen: \(error.localizedDescription)\n")
                break
            }
            let extracted = await kicktippAutomation.extractOddsFromPage()
            let results = finishedResults.filter { $0.spieltag == spieltag }
            let snapshots = extracted.odds.compactMap { odds -> ArchivedOdds? in
                guard let match = results.first(where: { matchesLikelyEqual($0.heim, $0.gast, odds.heim, odds.gast) }) else { return nil }
                return ArchivedOdds(
                    season: seasonKey, spieltag: spieltag, heim: match.heim, gast: match.gast,
                    quoteHeim: odds.quoteHeim, quoteUnentschieden: odds.quoteUnentschieden, quoteGast: odds.quoteGast,
                    overUnderLine: nil, overQuote: nil, underQuote: nil,
                    capturedAt: parseKickoffDate(match.datum) ?? Date()
                )
            }
            if snapshots.isEmpty {
                appendConsole("[Quoten-Archiv] Kicktipp zeigt fuer Spieltag \(spieltag) keine Quoten; Nachladen beendet.\n\(extracted.log)")
                break
            }
            mergeIntoOddsArchive(snapshots)
            stored += snapshots.count
        }
        if stored > 0 {
            appendConsole("[Quoten-Archiv] \(stored) historische Quoten aus Kicktipp gespeichert (gesamt \(oddsArchive.count)).\n")
        }
    }

    func adoptInferredKicktippRules() {
        guard let inferred = inferredKicktippRules else { return }
        kicktippRules = inferred.rules
        infoMessage = "Punkteregel aus den Mitspieler-Tipps uebernommen."
    }

    /// Reads the tip overview of every finished matchday that is missing, plus the latest one (totals change).
    /// Failures are logged and never abort the tip workflow.
    private func syncCommunityTips(seasonValue: Int) async {
        let seasonKey = String(seasonValue)
        let slug = kicktippCompetitionSlug
        let finishedMatchdays = Set(finishedResults.map(\.spieltag)).filter { matchday in
            nextSpieltag.map { matchday < $0 } ?? true
        }
        let stored = Set(communityMatchdays.filter { $0.season == seasonKey }.map(\.spieltag))
        let latest = finishedMatchdays.max()
        let toLoad = finishedMatchdays.filter { !stored.contains($0) || $0 == latest }.sorted()
        guard !toLoad.isEmpty else { return }

        var loaded: [CommunityMatchday] = []
        for spieltag in toLoad {
            do {
                try kicktippAutomation.loadCommunityOverview(for: slug, spieltag: spieltag)
                try await waitForKicktippPageToFinishLoading(urlContaining: "spieltagIndex=\(spieltag)")
                let extracted = try await kicktippAutomation.extractCommunityTable()
                do {
                    loaded.append(try communityService.parse(table: extracted.table, season: seasonKey, spieltag: spieltag, finishedMatches: finishedResults))
                } catch {
                    appendConsole("\n[AUTO-LOG] Kicktipp-Tippuebersicht Spieltag \(spieltag):\n\(extracted.raw.prefix(3000))\n")
                    throw error
                }
            } catch {
                appendConsole("[Mitspieler] Spieltag \(spieltag) nicht gelesen: \(error.localizedDescription)\n")
                break
            }
        }
        guard !loaded.isEmpty else { return }

        let replaced = Set(loaded.map(\.spieltag))
        communityMatchdays = communityMatchdays.filter { $0.season != seasonKey || !replaced.contains($0.spieltag) } + loaded
        appendConsole("[Mitspieler] \(loaded.count) Spieltag(e) gelesen, \(currentSeasonCommunity.count) gespeichert.\n")

        if let inferred = inferredKicktippRules, inferred.rules != kicktippRules {
            let rules = inferred.rules
            appendConsole(String(
                format: "[Mitspieler] Erkannte Punkteregel %.0f/%.0f/%.0f, Remis-Tordifferenz %@ (aus %d Tipps) weicht von den Einstellungen ab.\n",
                rules.exactScorePoints, rules.goalDifferencePoints, rules.tendencyPoints,
                rules.drawCountsAsGoalDifference ? "ja" : "nein", inferred.sampleCount
            ))
            infoMessage = "Punkteregel der Tipprunde weicht von den Einstellungen ab, siehe Einstellungen."
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

    func applyTipsToKicktipp(confirmOverwrite: Bool = false) async {
        pendingKicktippOverwrites = []
        await perform {
            guard !self.suggestedTips.isEmpty else {
                throw KicktippAutomationError.javaScriptError("Bitte zuerst Tipps importieren oder per Codex erzeugen.")
            }
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            let updates = try self.buildKicktippUpdates(from: fields)

            let overwrites = Self.kicktippOverwrites(updates)
            if !overwrites.isEmpty && !confirmOverwrite {
                self.pendingKicktippOverwrites = overwrites
                return
            }

            try await self.kicktippAutomation.applyTips(updates)

            let readBack = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = readBack
            let mismatches = Self.kicktippMismatches(expected: updates.map(\.tip), fields: readBack)
            guard mismatches.isEmpty else {
                throw KicktippAutomationError.javaScriptError("Kicktipp-Felder enthalten nach dem Eintragen abweichende Werte: \(mismatches.joined(separator: ", "))")
            }
            self.kicktippStatus = "Tipps in Formular eingetragen"
            self.infoMessage = "\(updates.count) Tipps eingetragen und geprueft. Zum Absenden 'Tipps absenden' nutzen."
        }
    }

    /// Fields that already hold a different, non-empty tip.
    nonisolated static func kicktippOverwrites(_ updates: [(field: KicktippMatchField, tip: SuggestedTip)]) -> [String] {
        updates.compactMap { update in
            let home = update.field.existingHeim.trimmingCharacters(in: .whitespaces)
            let away = update.field.existingGast.trimmingCharacters(in: .whitespaces)
            guard !home.isEmpty || !away.isEmpty,
                  home != String(update.tip.toreHeim) || away != String(update.tip.toreGast) else {
                return nil
            }
            return "\(update.tip.heim) vs. \(update.tip.gast): \(home):\(away) -> \(update.tip.toreHeim):\(update.tip.toreGast)"
        }
    }

    /// Tips whose Kicktipp field values differ from the expected score.
    nonisolated static func kicktippMismatches(expected tips: [SuggestedTip], fields: [KicktippMatchField]) -> [String] {
        tips.compactMap { tip in
            guard let field = fields.first(where: { matchesLikelyEqual($0.heim, $0.gast, tip.heim, tip.gast) }) else {
                return "\(tip.heim) vs. \(tip.gast) fehlt"
            }
            let value = "\(field.existingHeim.trimmingCharacters(in: .whitespaces)):\(field.existingGast.trimmingCharacters(in: .whitespaces))"
            return value == "\(tip.toreHeim):\(tip.toreGast)" ? nil : "\(tip.heim) vs. \(tip.gast) (\(value))"
        }
    }

    func submitKicktippTips() async {
        await perform {
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            let deviations = Self.kicktippMismatches(expected: self.suggestedTips, fields: fields)
            if !deviations.isEmpty {
                self.appendConsole("[Kicktipp] Formular weicht von importierten Tipps ab: \(deviations.joined(separator: ", "))\n")
            }
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

            let arguments = Self.codexExecArguments(outputFile: outputFile)
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
        await runCodexCommand(arguments: ["login", "status"], timeout: 60, userFacingAction: "Codex-Status geprueft") { result in
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
            .map(formatter)
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
        let tipMatchdays = Set(suggestedTips.map(\.spieltag))
        guard tipMatchdays.count == 1, let tipMatchday = tipMatchdays.first else {
            throw KicktippAutomationError.javaScriptError("Die importierten Tipps gehoeren zu mehreren Spieltagen.")
        }
        if let nextSpieltag, nextSpieltag != tipMatchday {
            throw KicktippAutomationError.javaScriptError("Die Tipps gehoeren zu Spieltag \(tipMatchday), offen ist Spieltag \(nextSpieltag). Bitte neu generieren.")
        }

        var updates: [(field: KicktippMatchField, tip: SuggestedTip)] = []
        var matchedTipIDs = Set<SuggestedTip.ID>()

        for field in fields {
            let fieldKey = normalizedTeamKey(field.heim, field.gast)
            guard let tip = suggestedTips.first(where: { normalizedTeamKey($0.heim, $0.gast) == fieldKey })
                ?? suggestedTips.first(where: { matchesLikelyEqual($0.heim, $0.gast, field.heim, field.gast) }),
                  !matchedTipIDs.contains(tip.id) else {
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

    /// Model probabilities of the newest ensemble run for this match (manual and single Codex runs carry none).
    func latestEnsemblePrediction(for tip: SuggestedTip) -> MatchPrediction? {
        let key = normalizedTeamKey(tip.heim, tip.gast)
        return predictionRuns
            .filter { $0.modelName == PredictionRun.ensembleModelName && $0.spieltag == tip.spieltag }
            .max { $0.createdAt < $1.createdAt }?
            .matches
            .first { normalizedTeamKey($0.heim, $0.gast) == key }
    }

    func orderedTips(_ tips: [SuggestedTip]) -> [SuggestedTip] {
        guard !tips.isEmpty, !kicktippMatchFields.isEmpty else { return tips }

        let tipsByMatchKey = Dictionary(
            tips.map { (normalizedTeamKey($0.heim, $0.gast), $0) },
            uniquingKeysWith: { first, _ in first }
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

    /// Rating model over the current and two previous seasons (parameters from the walk-forward grid search).
    private func fittedRatingModel() -> TeamRatingModel? {
        guard let seasonValue = Int(season) else { return nil }
        let previousTeams = Set((historicalSeasons[seasonValue - 1] ?? []).flatMap { [normalizeTeamName($0.heim), normalizeTeamName($0.gast)] })
        let currentTeams = Set((finishedResults.map { ($0.heim, $0.gast) } + upcomingMatches.map { ($0.heim, $0.gast) })
            .flatMap { [normalizeTeamName($0.0), normalizeTeamName($0.1)] })
        var counts: [String: Int] = [:]
        for match in finishedResults {
            counts[normalizeTeamName(match.heim), default: 0] += 1
            counts[normalizeTeamName(match.gast), default: 0] += 1
        }
        let history = (historicalSeasons[seasonValue - 2] ?? []) + (historicalSeasons[seasonValue - 1] ?? [])
        return teamRatingService.fit(
            matches: history + finishedResults,
            promotedTeams: previousTeams.isEmpty ? [] : currentTeams.subtracting(previousTeams),
            currentSeasonMatchCounts: counts,
            referenceDate: upcomingMatches.compactMap { parseKickoffDate($0.datum) }.min()
        )
    }

    /// Expected goals per match: team ratings blended (in log space) with the bookmaker market,
    /// then small, confidence-weighted LLM news adjustments. Absence and rest factors only apply
    /// without market odds, because the market already prices them in.
    private func expectedGoalsByMatch() -> [String: MatchExpectedGoals] {
        let ratingModel = fittedRatingModel()
        let oddsByKey = ensembleService.remappedOdds(bettingOdds: bettingOdds, upcomingMatches: upcomingMatches)
        let overUnderByKey = Dictionary(overUnderOdds.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        }, uniquingKeysWith: { first, _ in first })
        let restDays = buildRestDaysByTeam()
        let absencesByTeam = Dictionary(grouping: playerAbsences) { normalizeTeamName($0.teamName) }
        let enrichmentByMatch = Dictionary(llmMatchEnrichments.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        }, uniquingKeysWith: { first, _ in first })

        return Dictionary(upcomingMatches.map { match in
            let matchKey = normalizedTeamKey(match.heim, match.gast)
            let rating = ratingModel?.expectedGoals(homeTeam: match.heim, awayTeam: match.gast) ?? (home: 1.6, away: 1.25)
            var homeXG = rating.home
            var awayXG = rating.away
            let enrichment = enrichmentByMatch[matchKey]
            let confidence = min(max(enrichment?.confidence ?? 0, 0), 1)
            let marketWeightHint = (enrichment?.marketWeightHint ?? 0) * confidence

            let overUnderTotal = overUnderByKey[matchKey].flatMap {
                MarketModel.totalGoals(line: $0.line, overQuote: $0.overQuote, underQuote: $0.underQuote)
            }
            if let odds = oddsByKey[matchKey], let market = MarketModel.expectedGoals(odds: odds, total: overUnderTotal) {
                let weight = min(max(learnedMarketWeight + marketWeightHint, 0.3), 0.95)
                (homeXG, awayXG) = ModelBacktestService.blend(rating: (homeXG, awayXG), market: market, marketWeight: weight)
            } else {
                let homeAbsenceImpact = absenceImpact(absencesByTeam[normalizeTeamName(match.heim)] ?? [])
                let awayAbsenceImpact = absenceImpact(absencesByTeam[normalizeTeamName(match.gast)] ?? [])
                homeXG *= (1 - homeAbsenceImpact.attack) * (1 + awayAbsenceImpact.defense) * restFactor(restDays[normalizeTeamName(match.heim)])
                awayXG *= (1 - awayAbsenceImpact.attack) * (1 + homeAbsenceImpact.defense) * restFactor(restDays[normalizeTeamName(match.gast)])
            }

            var drawCalibration = 0.0
            if let enrichment {
                let weight = learnedLLMSignalWeight() * confidence * 0.5
                homeXG *= 1 + (enrichment.homeAttackAdjustment + enrichment.awayDefenseAdjustment + enrichment.lineupImpact + enrichment.playerValueImpact) * weight
                awayXG *= 1 + (enrichment.awayAttackAdjustment + enrichment.homeDefenseAdjustment - enrichment.lineupImpact - enrichment.playerValueImpact) * weight
                if enrichment.totalGoalsAdjustment != 0 {
                    (homeXG, awayXG) = scaleTotal(homeXG: homeXG, awayXG: awayXG, targetTotal: max(0.8, homeXG + awayXG + enrichment.totalGoalsAdjustment * weight), weight: 1)
                }
                drawCalibration = enrichment.scorelineDrawCalibration * confidence
            }

            if learningState.sampleSize >= 30 {
                homeXG -= learningState.avgHomeGoalOverprediction * 0.2
                awayXG -= learningState.avgAwayGoalOverprediction * 0.2
            }

            return (
                matchKey,
                MatchExpectedGoals(
                    heim: match.heim,
                    gast: match.gast,
                    home: min(max(homeXG, 0.2), 4.5),
                    away: min(max(awayXG, 0.2), 4.5),
                    drawCalibration: drawCalibration,
                    marketWeightHint: marketWeightHint
                )
            )
        }, uniquingKeysWith: { first, _ in first })
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

    private func buildRestDaysByTeam() -> [String: Int] {
        func date(from raw: String) -> Date? {
            parseKickoffDate(raw)
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

    private static let consoleCharacterLimit = 200_000

    private func appendConsole(_ text: String) {
        consoleOutput += text
        if consoleOutput.count > Self.consoleCharacterLimit {
            consoleOutput = "[Console gekuerzt]\n" + consoleOutput.suffix(Self.consoleCharacterLimit / 2)
        }
        AppLogger.app.debug("\(text, privacy: .private)")
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
        timeout: TimeInterval = 15 * 60,
        userFacingAction: String,
        afterSuccess: @escaping (CodexCommandResult) throws -> Void = { _ in },
        onChunk: @escaping @MainActor (String) -> Void = { _ in }
    ) async {
        guard !isBusy else { return }
        isBusy = true
        codexCancelRequested = false
        errorMessage = nil
        defer { isBusy = false }

        do {
            let result = try await executeCodexCommand(arguments: arguments, standardInput: standardInput, timeout: timeout, onChunk: onChunk)
            try afterSuccess(result)
            if infoMessage?.isEmpty != false {
                infoMessage = userFacingAction
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        codexCancelRequested = false
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

    private func waitForKicktippPageToFinishLoading(urlContaining marker: String = "tippabgabe", timeoutNanoseconds: UInt64 = 15_000_000_000) async throws {
        let start = DispatchTime.now().uptimeNanoseconds

        // Phase 1: wait for loading to START (gives the navigation delegate time to fire)
        // This guards against a race where webView.url already reflects the new URL
        // but isPageLoading hasn't been set to true yet.
        while !kicktippAutomation.isPageLoading {
            if DispatchTime.now().uptimeNanoseconds - start > 2_000_000_000 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Phase 2: wait for loading to FINISH with the correct URL
        while kicktippAutomation.isPageLoading || kicktippAutomation.webView.url?.absoluteString.contains(marker) != true {
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
        // A past matchday page (?spieltagIndex=) is not the open tip form.
        if !currentURL.contains("/\(slug)/tippabgabe") || currentURL.contains("spieltagIndex=") {
            try kicktippAutomation.loadTippabgabe(for: slug)
        }

        try await waitForKicktippPageToFinishLoading()
    }

    /// `codex exec` always runs read-only: prompts embed untrusted third-party text (absences, LLM research).
    private static func codexExecArguments(outputFile: URL) -> [String] {
        ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--output-last-message", outputFile.path, "-"]
    }

    func cancelCodex() {
        codexCancelRequested = true
        activeCodexProcess?.terminate()
        infoMessage = "Codex wird abgebrochen..."
    }

    private func executeCodexCommand(
        arguments: [String],
        standardInput: String? = nil,
        timeout: TimeInterval = 15 * 60,
        onChunk: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> CodexCommandResult {
        guard !codexCancelRequested else { throw CodexCLIError.cancelled }
        appendConsole("\n$ \(codexPath) \(arguments.joined(separator: " "))\n")

        let handle = CodexProcessHandle()
        activeCodexProcess = handle
        defer { activeCodexProcess = nil }

        return try await codexCLIService.run(
            executablePath: codexPath,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout,
            handle: handle
        ) { chunk in
            Task { @MainActor in
                onChunk(chunk)
            }
        }
    }

    private func fetchLLMMatchEnrichments(seasonValue: Int) async -> [LLMMatchEnrichment] {
        guard !upcomingMatches.isEmpty else { return [] }

        let missingSignals = [
            "Shots-on-Goal und Verwertung",
            "Schiedsrichter-Statistiken",
            "Zusatzbelastung durch Europa/Pokal",
            "Sharp-Odds/Exchange-Check",
            "Lineup- und kurzfristige Teamnews",
            "Spielerwerte nach Minuten, Position, xG/xA, Defensive Actions und Keeper-Wert",
            "Closing-Line-Value oder closing-nahe Marktbewegung",
            "saisonuebergreifende historische Team- und Liga-Basisdaten",
            "Scoreline-Kalibrierung aus historischer Ergebnisverteilung",
            "dynamischer Gewichtungshinweis fuer Markt/Form/Lineup/Spielerimpact"
        ]
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
                arguments: Self.codexExecArguments(outputFile: outputFile),
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
                    arguments: Self.codexExecArguments(outputFile: outputFile),
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
            } catch CodexCLIError.cancelled {
                break
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
        let updatesByKey = Dictionary(updates.map {
            ("\($0.spieltag)|\(normalizedTeamKey($0.heim, $0.gast))", $0)
        }, uniquingKeysWith: { first, _ in first })
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
        var successfulRuns: [(tips: [SuggestedTip], rawResponse: String, runIndex: Int)] = []
        var failedRuns = 0

        for runIndex in 1...runCount {
            infoMessage = runCount == 1 ? "Codex analysiert..." : "Codex-Lauf \(runIndex)/\(runCount)..."
            let outputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("betbaconer-codex-last-message-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outputFile) }

            do {
                let arguments = Self.codexExecArguments(outputFile: outputFile)
                let result = try await executeCodexCommand(arguments: arguments, standardInput: generatedPrompt) { chunk in
                    self.appendConsole(self.stripANSI(chunk))
                }

                guard result.exitCode == 0 else {
                    throw CodexCLIError.executionFailed("Codex exec fehlgeschlagen. Siehe Console-Ausgabe.")
                }

                let output = try String(contentsOf: outputFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let tips = try tipWorkflowService.parseTips(from: output, upcomingMatches: upcomingMatches)
                successfulRuns.append((tips: tips, rawResponse: output, runIndex: runIndex))
                appendConsole("[Ensemble] Lauf \(runIndex)/\(runCount) erfolgreich geparst.\n")
            } catch CodexCLIError.cancelled {
                throw CodexCLIError.cancelled
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
        for run in successfulRuns {
            recordPredictionRun(
                tips: run.tips,
                rawPrompt: generatedPrompt,
                rawResponse: run.rawResponse,
                modelName: "codex-cli-run-\(run.runIndex)"
            )
        }
        appendConsole("[xG] " + expectedGoals.values
            .sorted { $0.heim < $1.heim }
            .map { String(format: "%@ %.2f : %.2f %@", $0.heim, $0.home, $0.away, $0.gast) }
            .joined(separator: " | ") + "\n")
        let aggregated = try ensembleService.aggregate(
            from: successfulRuns.map(\.tips),
            upcomingMatches: upcomingMatches,
            bettingOdds: bettingOdds,
            expectedGoals: expectedGoals
        )
        let probabilityModels = Dictionary(
            aggregated.map { (normalizedTeamKey($0.tip.heim, $0.tip.gast), $0.model) },
            uniquingKeysWith: { first, _ in first }
        )
        let stabilized = Self.stabilizeShortTermTips(
            aggregated.map(\.tip),
            previousRuns: predictionRuns,
            currentRuns: successfulRuns.map(\.tips),
            seasonIdentifier: season.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if stabilized.stabilizedCount > 0 {
            appendConsole("[Stabilitaet] \(stabilized.stabilizedCount) Tipp(s) aus vorherigem Kurzfrist-Run beibehalten; neuer Lauf ohne starken Konsens.\n")
        }
        importedResponse = tipWorkflowService.encodeTipsAsJSON(stabilized.tips)
        importTipsFromResponse(probabilityModels: probabilityModels)
        if failedRuns > 0 {
            appendConsole("[Ensemble] \(failedRuns) Lauf/Laeufe wurden verworfen.\n")
        }
        infoMessage = runCount == 1
            ? "Codex-Ausfuehrung abgeschlossen"
            : "Codex-Ensemble abgeschlossen (\(successfulRuns.count)/\(runCount) Laeufe)"
    }

    private func persistLearningStore() {
        guard !learningPersistenceDisabled else { return }
        do {
            try predictionStore.save(runs: predictionRuns, learningState: learningState, community: communityMatchdays, oddsArchive: oddsArchive)
        } catch {
            appendConsole("[Learning] Persistenz fehlgeschlagen: \(error.localizedDescription)\n")
        }
    }

    private func persistTipHistory() {
        guard !tipHistoryPersistenceDisabled else { return }
        do {
            try tipHistoryStore.save(tipHistory)
        } catch {
            appendConsole("[Verlauf] Persistenz fehlgeschlagen: \(error.localizedDescription)\n")
        }
    }

    private func syncManualKicktippTipsForLearning(from fields: [KicktippMatchField]) {
        let tips = Self.manualTips(from: fields, upcomingMatches: upcomingMatches)
        guard !tips.isEmpty, !hasPredictionRun(modelName: PredictionRun.manualModelName, tips: tips) else { return }

        recordPredictionRun(tips: tips, rawPrompt: "", rawResponse: "", modelName: PredictionRun.manualModelName)
        appendConsole("[Learning] \(tips.count) manuelle Kicktipp-Tipps fuer Self-Learning gespeichert.\n")
    }

    private func hasPredictionRun(modelName: String, tips: [SuggestedTip]) -> Bool {
        let expected = Dictionary(tips.map {
            (normalizedTeamKey($0.heim, $0.gast), "\($0.toreHeim):\($0.toreGast)")
        }, uniquingKeysWith: { first, _ in first })

        return predictionRuns.contains { run in
            guard run.modelName == modelName,
                  run.seasonIdentifier == season.trimmingCharacters(in: .whitespacesAndNewlines),
                  run.spieltag == tips.first?.spieltag,
                  run.matches.count == tips.count else {
                return false
            }

            let actual = Dictionary(run.matches.map {
                (normalizedTeamKey($0.heim, $0.gast), "\($0.predictedHomeGoals):\($0.predictedAwayGoals)")
            }, uniquingKeysWith: { first, _ in first })
            return actual == expected
        }
    }

    private func recordPredictionRun(
        tips: [SuggestedTip],
        rawPrompt: String,
        rawResponse: String,
        modelName: String = PredictionRun.ensembleModelName,
        probabilityModels: [String: EnsembleService.MatchProbabilityModel] = [:]
    ) {
        guard !tips.isEmpty else { return }

        let runId = UUID()
        let createdAt = Date()
        let trimmedSeason = season.trimmingCharacters(in: .whitespacesAndNewlines)
        let seasonIdentifier = trimmedSeason.isEmpty ? "unknown" : trimmedSeason
        let contexts = Dictionary(buildPredictionContexts().map { (normalizedTeamKey($0.upcomingMatch.heim, $0.upcomingMatch.gast), $0) }, uniquingKeysWith: { first, _ in first })
        let matches = tips.map { tip -> MatchPrediction in
            let context = contexts[normalizedTeamKey(tip.heim, tip.gast)]
            let model = probabilityModels[normalizedTeamKey(tip.heim, tip.gast)]
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
                probabilityHomeWin: model?.probabilityHomeWin,
                probabilityDraw: model?.probabilityDraw,
                probabilityAwayWin: model?.probabilityAwayWin,
                confidence: model?.confidence,
                topScorelines: model?.topScorelines,
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
                promptVersion: Self.promptVersion,
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
        let expectedGoalsByKey = Dictionary(matchExpectedGoals.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
        let enrichmentsByKey = Dictionary(llmMatchEnrichments.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
        let targetSpieltag = upcomingMatches.first?.spieltag
        let seasonValue = season.trimmingCharacters(in: .whitespacesAndNewlines)
        let historyForMatchday = tipHistory.filter {
            $0.spieltag == targetSpieltag && String(Self.currentBundesligaSeason(for: $0.timestamp)) == seasonValue
        }

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
