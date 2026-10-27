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
    /// Settings domain of the unbundled `swift run` binary; copied once into the app bundle's defaults.
    var legacyDefaultsDomain: String? = Bundle.main.bundleIdentifier == nil ? nil : "BetBaconer"
}

@MainActor
@Observable
final class AppState {

    // MARK: - State

    var season: String = String(AppState.currentBundesligaSeason())
    var backtestReport = ""
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
    var latestTipHistory: [TipGenerationRecord] {
        Self.latestTipHistory(from: learning.tipHistory)
    }
    var evaluatedMatchdayRuns: [PredictionRun] {
        Self.evaluatedMatchdayRuns(from: learning.predictionRuns)
    }
    /// Finished matches of earlier seasons (start year -> matches) for the rating model and backtests.
    var historicalSeasons: [Int: [FinishedMatch]] = [:]
    var currentSeasonCommunity: [CommunityMatchday] {
        learning.communityMatchdays.filter { $0.season == season.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    var inferredKicktippRules: InferredKicktippRules? {
        communityService.inferRules(from: currentSeasonCommunity)
    }
    var communityBacktest: [CommunityBacktestRow] {
        communityService.backtest(runs: learning.predictionRuns, matchdays: currentSeasonCommunity, rules: settings.kicktippRules)
    }
    var rankingStrategy: RankingStrategy? {
        let name = settings.kicktippPlayerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let nextSpieltag else { return nil }
        return communityService.rankingStrategy(playerName: name, matchdays: currentSeasonCommunity, nextSpieltag: nextSpieltag)
    }
    var isBusy = false
    /// Kicktipp fields that already hold a different tip and would be overwritten; non-empty asks the UI for confirmation.
    var pendingKicktippOverwrites: [String] = []
    /// Set when a store could not be loaded nor backed up; saving would destroy the unreadable file.
    var errorMessage: String?
    var infoMessage: String?

    let kicktippAutomation: KicktippAutomation
    /// Persisted user settings (UserDefaults + keychain).
    let settings: AppSettings
    /// Persisted learning data: tip history, prediction runs, group history, odds archive.
    let learning: LearningRepository

    // MARK: - Services

    let session: URLSession
    let ligaService: OpenLigaDBService
    let tipWorkflowService = TipWorkflowService()
    let sofaScoreService: SofaScoreService
    let teamMetadataService: TheSportsDBService
    let weatherService: WeatherService
    let teamRatingService = TeamRatingService()
    let predictionEvaluator = PredictionEvaluator()
    let communityService = KicktippCommunityService()
    var ensembleService: EnsembleService {
        var service = EnsembleService(rules: settings.kicktippRules)
        let community = currentSeasonCommunity
        if !community.isEmpty {
            service.crowdTipHomeFavorite = communityService.typicalCrowdTip(homeFavored: true, matchdays: community)
            service.crowdTipAwayFavorite = communityService.typicalCrowdTip(homeFavored: false, matchdays: community)
        }
        if settings.useRankingStrategy {
            service.strategy = rankingStrategy
        }
        return service
    }
    let codexRunner = CodexRunner()

    var oddsAPIService: TheOddsAPIService {
        TheOddsAPIService(apiKey: settings.theOddsAPIKey, session: session)
    }

    // MARK: - Init

    /// Bump whenever tip selection changes, so backtesting stays separated per model version.
    static let promptVersion = "market-ev-kicktipp-v8"

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
        session = dependencies.session
        ligaService = OpenLigaDBService(session: dependencies.session)
        sofaScoreService = SofaScoreService(session: dependencies.session)
        teamMetadataService = TheSportsDBService(session: dependencies.session)
        weatherService = WeatherService(session: dependencies.session)
        learning = LearningRepository(predictionStore: dependencies.predictionStore, tipHistoryStore: dependencies.tipHistoryStore)
        self.kicktippAutomation = kicktippAutomation
        settings = AppSettings(
            defaults: dependencies.defaults,
            secretStore: dependencies.secretStore,
            environment: dependencies.environment,
            legacyDefaultsDomain: dependencies.legacyDefaultsDomain
        )
        errorMessage = settings.loadError

        if let latestTips = learning.tipHistory.last {
            suggestedTips = latestTips.tips
            bettingOdds = latestTips.odds
        }
        if !suggestedTips.isEmpty {
            importedResponse = tipWorkflowService.encodeTipsAsJSON(suggestedTips)
        }
        restoreUpcomingMatchesFromLatestTips()
        if let loadError = learning.loadErrors.last {
            errorMessage = loadError
        }
        learning.onSaveError = { [weak self] message in self?.appendConsole(message) }
        settings.onError = { [weak self] message in self?.errorMessage = message }
    }

    // MARK: - Shared helpers


    private func restoreUpcomingMatchesFromLatestTips() {
        guard upcomingMatches.isEmpty, let latestTips = learning.tipHistory.last else { return }
        upcomingMatches = Self.upcomingMatchesForLatestTips(latestTips, predictionRuns: learning.predictionRuns)
        nextSpieltag = upcomingMatches.map(\.spieltag).min()
    }

    /// Model probabilities of the newest ensemble run for this match (manual and single Codex runs carry none).
    func latestEnsemblePrediction(for tip: SuggestedTip) -> MatchPrediction? {
        let key = normalizedTeamKey(tip.heim, tip.gast)
        return learning.predictionRuns
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
