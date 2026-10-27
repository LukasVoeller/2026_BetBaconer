import AppKit
import Foundation
import Observation

/// External collaborators of `AppState`; tests swap them for stubs and temporary locations.
struct AppDependencies {
    var defaults: UserDefaults = .standard
    var session: URLSession = NetworkSessionFactory.makeDefaultSession()
    var predictionStore = PredictionStore()
    var tipHistoryStore = TipHistoryStore()
    var secretStore = KeychainSecretStore()
    var environment: [String: String] = ProcessInfo.processInfo.environment
}

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
        static let autoRefreshBeforeKickoff     = "autoRefreshBeforeKickoff"
        static let autoSubmitAfterRefresh       = "autoSubmitAfterRefresh"
    }

    private enum SecretKeys {
        static let theOddsAPIKey = "theOddsAPIKey"
    }

    // MARK: - State

    var season: String = String(AppState.currentBundesligaSeason())
    // Persisted settings: loaded from `defaults` in init, written back on change.
    /// Number of Codex runs per analysis, always 1...9. (Re-assigning inside didSet recurses under @Observable.)
    var codexRunCount: Int {
        get { storedCodexRunCount }
        set {
            storedCodexRunCount = min(max(newValue, 1), 9)
            defaults.set(storedCodexRunCount, forKey: Keys.codexRunCount)
        }
    }
    private var storedCodexRunCount = 1
    var kicktippCompetitionSlug: String = "" {
        didSet { defaults.set(kicktippCompetitionSlug, forKey: Keys.kicktippCompetitionSlug) }
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
    var codexPath: String = "/opt/homebrew/bin/codex" {
        didSet { defaults.set(codexPath, forKey: Keys.codexPath) }
    }
    var kicktippRules: KicktippRules = .standard {
        didSet { defaults.set(try? JSONEncoder().encode(kicktippRules), forKey: Keys.kicktippRules) }
    }
    /// Own player name in the Kicktipp group, used to locate the ranking position.
    var kicktippPlayerName: String = "" {
        didSet { defaults.set(kicktippPlayerName, forKey: Keys.kicktippPlayerName) }
    }
    var useRankingStrategy: Bool = false {
        didSet { defaults.set(useRankingStrategy, forKey: Keys.useRankingStrategy) }
    }
    /// Share of the bookmaker market in expected goals; learned from the odds archive by the backtest.
    var learnedMarketWeight: Double = ModelBacktestService.defaultMarketWeight {
        didSet { defaults.set(learnedMarketWeight, forKey: Keys.learnedMarketWeight) }
    }
    var backtestReport = ""
    /// Recompute tips about an hour before kickoff with the latest (most accurate) odds.
    var autoRefreshBeforeKickoff: Bool = false {
        didSet { defaults.set(autoRefreshBeforeKickoff, forKey: Keys.autoRefreshBeforeKickoff) }
    }
    var autoSubmitAfterRefresh: Bool = false {
        didSet { defaults.set(autoSubmitAfterRefresh, forKey: Keys.autoSubmitAfterRefresh) }
    }
    var lastKickoffRefresh: [String: Date] = [:]
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
    var historicalSeasons: [Int: [FinishedMatch]] = [:]
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
    /// Set when a store could not be loaded nor backed up; saving would destroy the unreadable file.
    var tipHistoryPersistenceDisabled = false
    var learningPersistenceDisabled = false
    var errorMessage: String?
    var infoMessage: String?

    let kicktippAutomation: KicktippAutomation

    // MARK: - Services

    let defaults: UserDefaults
    let session: URLSession
    let ligaService: OpenLigaDBService
    let tipWorkflowService = TipWorkflowService()
    let sofaScoreService: SofaScoreService
    let teamMetadataService: TheSportsDBService
    let weatherService: WeatherService
    let teamRatingService = TeamRatingService()
    let predictionStore: PredictionStore
    let predictionEvaluator = PredictionEvaluator()
    let communityService = KicktippCommunityService()
    var ensembleService: EnsembleService {
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
    let codexRunner = CodexRunner()
    let secretStore: KeychainSecretStore
    let tipHistoryStore: TipHistoryStore

    var oddsAPIService: TheOddsAPIService {
        TheOddsAPIService(apiKey: theOddsAPIKey, session: session)
    }

    // MARK: - Init

    /// Bump whenever tip selection changes, so backtesting stays separated per model version.
    static let promptVersion = "rating-market-ev-kicktipp-v7"

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

    init(dependencies: AppDependencies = AppDependencies(), kicktippAutomation: KicktippAutomation = KicktippAutomation()) {
        defaults = dependencies.defaults
        session = dependencies.session
        ligaService = OpenLigaDBService(session: dependencies.session)
        sofaScoreService = SofaScoreService(session: dependencies.session)
        teamMetadataService = TheSportsDBService(session: dependencies.session)
        weatherService = WeatherService(session: dependencies.session)
        predictionStore = dependencies.predictionStore
        tipHistoryStore = dependencies.tipHistoryStore
        secretStore = dependencies.secretStore
        self.kicktippAutomation = kicktippAutomation

        let storedRunCount = defaults.integer(forKey: Keys.codexRunCount)
        storedCodexRunCount = min(max(storedRunCount == 0 ? 1 : storedRunCount, 1), 9)
        kicktippCompetitionSlug = defaults.string(forKey: Keys.kicktippCompetitionSlug) ?? ""
        codexPath = defaults.string(forKey: Keys.codexPath) ?? "/opt/homebrew/bin/codex"
        kicktippRules = defaults.data(forKey: Keys.kicktippRules)
            .flatMap { try? JSONDecoder().decode(KicktippRules.self, from: $0) } ?? .standard
        kicktippPlayerName = defaults.string(forKey: Keys.kicktippPlayerName) ?? ""
        useRankingStrategy = defaults.bool(forKey: Keys.useRankingStrategy)
        learnedMarketWeight = (defaults.object(forKey: Keys.learnedMarketWeight) as? Double) ?? ModelBacktestService.defaultMarketWeight
        autoRefreshBeforeKickoff = defaults.bool(forKey: Keys.autoRefreshBeforeKickoff)
        autoSubmitAfterRefresh = defaults.bool(forKey: Keys.autoSubmitAfterRefresh)

        let environmentKey = dependencies.environment["THE_ODDS_API_KEY"]
        do {
            theOddsAPIKey = try secretStore.loadSecret(account: SecretKeys.theOddsAPIKey) ?? environmentKey ?? ""
        } catch {
            theOddsAPIKey = environmentKey ?? ""
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

    // MARK: - Shared helpers

    func restoreUpcomingMatchesFromLatestTips() {
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

    func parsedSeason() throws -> Int {
        guard let seasonValue = Int(season) else {
            throw ValidationError.invalidSeason
        }
        return seasonValue
    }

    private static let consoleCharacterLimit = 200_000

    func appendConsole(_ text: String) {
        consoleOutput += text
        if consoleOutput.count > Self.consoleCharacterLimit {
            consoleOutput = "[Console gekuerzt]\n" + consoleOutput.suffix(Self.consoleCharacterLimit / 2)
        }
        AppLogger.app.debug("\(text, privacy: .private)")
    }

    func perform(_ operation: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        codexRunner.resetCancellation()
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

    func persistLearningStore() {
        guard !learningPersistenceDisabled else { return }
        do {
            try predictionStore.save(runs: predictionRuns, learningState: learningState, community: communityMatchdays, oddsArchive: oddsArchive)
        } catch {
            appendConsole("[Learning] Persistenz fehlgeschlagen: \(error.localizedDescription)\n")
        }
    }

    func persistTipHistory() {
        guard !tipHistoryPersistenceDisabled else { return }
        do {
            try tipHistoryStore.save(tipHistory)
        } catch {
            appendConsole("[Verlauf] Persistenz fehlgeschlagen: \(error.localizedDescription)\n")
        }
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
