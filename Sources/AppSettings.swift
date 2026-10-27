import Foundation
import Observation

/// Persisted user settings: UserDefaults for preferences, the keychain for the Odds API key.
@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let codexRunCount = "codexRunCount"
        static let kicktippCompetitionSlug = "kicktippCompetitionSlug"
        static let codexPath = "codexPath"
        static let kicktippRules = "kicktippRules"
        static let kicktippPlayerName = "kicktippPlayerName"
        static let useRankingStrategy = "useRankingStrategy"
        static let learnedMarketWeight = "learnedMarketWeight"
        static let autoRefreshBeforeKickoff = "autoRefreshBeforeKickoff"
        static let autoSubmitAfterRefresh = "autoSubmitAfterRefresh"
        static let all = [codexRunCount, kicktippCompetitionSlug, codexPath, kicktippRules, kicktippPlayerName,
                          useRankingStrategy, learnedMarketWeight, autoRefreshBeforeKickoff, autoSubmitAfterRefresh]
    }

    private enum SecretKeys {
        static let theOddsAPIKey = "theOddsAPIKey"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secretStore: KeychainSecretStore
    /// Receives keychain write failures (shown as error banner by AppState).
    @ObservationIgnored var onError: (String) -> Void = { _ in }
    /// Keychain read failure during init, if any.
    private(set) var loadError: String?

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
                onError(error.localizedDescription)
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
    /// Recompute tips about an hour before kickoff with the latest (most accurate) odds.
    var autoRefreshBeforeKickoff: Bool = false {
        didSet { defaults.set(autoRefreshBeforeKickoff, forKey: Keys.autoRefreshBeforeKickoff) }
    }
    var autoSubmitAfterRefresh: Bool = false {
        didSet { defaults.set(autoSubmitAfterRefresh, forKey: Keys.autoSubmitAfterRefresh) }
    }

    init(defaults: UserDefaults, secretStore: KeychainSecretStore, environment: [String: String], legacyDefaultsDomain: String?) {
        self.defaults = defaults
        self.secretStore = secretStore

        if let legacyDefaultsDomain, let legacy = UserDefaults(suiteName: legacyDefaultsDomain) {
            Self.migrateLegacySettings(from: legacy, to: defaults)
        }

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

        let environmentKey = environment["THE_ODDS_API_KEY"]
        do {
            theOddsAPIKey = try secretStore.loadSecret(account: SecretKeys.theOddsAPIKey) ?? environmentKey ?? ""
        } catch {
            theOddsAPIKey = environmentKey ?? ""
            loadError = error.localizedDescription
        }
    }

    /// Copies settings saved by the unbundled binary when the bundled app has none yet.
    static func migrateLegacySettings(from legacy: UserDefaults, to defaults: UserDefaults) {
        guard Keys.all.allSatisfy({ defaults.object(forKey: $0) == nil }) else { return }
        for key in Keys.all {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }
}
