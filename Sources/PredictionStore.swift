import Foundation

enum PredictionStoreError: LocalizedError {
    case failedToLoad(backup: URL?)
    case failedToSave

    var errorDescription: String? {
        switch self {
        case let .failedToLoad(backup):
            return "Der Learning-Store konnte nicht geladen werden."
                + (backup.map { " Die Datei wurde nach \($0.lastPathComponent) gesichert, es wird neu begonnen." } ?? " Speichern ist deaktiviert, um Datenverlust zu vermeiden.")
        case .failedToSave:
            return "Der Learning-Store konnte nicht gespeichert werden."
        }
    }
}

struct PredictionStore {
    private let fileURL: URL
    private let legacyHistoryURL: URL

    init(fileURL: URL = PredictionStore.defaultFileURL, legacyHistoryURL: URL = PredictionStore.defaultLegacyHistoryURL) {
        self.fileURL = fileURL
        self.legacyHistoryURL = legacyHistoryURL
    }

    func load() throws -> (runs: [PredictionRun], learningState: LearningState, community: [CommunityMatchday], oddsArchive: [ArchivedOdds]) {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let raw = try decoder.singleValueContainer().decode(String.self)
                guard let date = Self.fractionalFormatter.date(from: raw) ?? Self.plainFormatter.date(from: raw) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Ungueltiges Datum: \(raw)"))
                }
                return date
            }
            do {
                let payload = try decoder.decode(LearningPersistencePayload.self, from: Data(contentsOf: fileURL))
                return (payload.predictionRuns, payload.learningState, payload.communityMatchdays ?? [], payload.oddsArchive ?? [])
            } catch {
                AppLogger.persistence.error("Learning store load failed: \(error.localizedDescription, privacy: .public)")
                throw PredictionStoreError.failedToLoad(backup: AppSupportPaths.quarantine(fileURL))
            }
        }

        let migratedRuns = migrateLegacyTipHistory()
        let state = LearningState.empty
        if !migratedRuns.isEmpty {
            try save(runs: migratedRuns, learningState: state)
        }
        return (migratedRuns, state, [], [])
    }

    func save(runs: [PredictionRun], learningState: LearningState, community: [CommunityMatchday] = [], oddsArchive: [ArchivedOdds] = []) throws {
        let encoder = JSONEncoder()
        // Fractional seconds keep ordering of runs created within the same second (single runs vs. ensemble).
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.fractionalFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let payload = LearningPersistencePayload(
            version: 1,
            predictionRuns: runs,
            learningState: learningState,
            communityMatchdays: community,
            oddsArchive: oddsArchive
        )

        guard let data = try? encoder.encode(payload) else {
            throw PredictionStoreError.failedToSave
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PredictionStoreError.failedToSave
        }
    }

    private func migrateLegacyTipHistory() -> [PredictionRun] {
        guard let data = try? Data(contentsOf: legacyHistoryURL),
              let records = try? JSONDecoder().decode([TipGenerationRecord].self, from: data) else {
            return []
        }

        return records.map { record in
            let seasonIdentifier = String(Self.bundesligaSeason(for: record.timestamp))
            let matches = record.tips.map { tip in
                let odds = record.odds.first { normalizedTeamKey($0.heim, $0.gast) == normalizedTeamKey(tip.heim, tip.gast) }
                return MatchPrediction(
                    id: UUID(),
                    runId: record.id,
                    spieltag: tip.spieltag,
                    heim: tip.heim,
                    gast: tip.gast,
                    kickoffAt: "",
                    predictedHomeGoals: tip.toreHeim,
                    predictedAwayGoals: tip.toreGast,
                    predictedOutcome: outcome(forHomeGoals: tip.toreHeim, awayGoals: tip.toreGast),
                    rationale: tip.rationale,
                    quoteHome: parseQuote(odds?.quoteHeim),
                    quoteDraw: parseQuote(odds?.quoteUnentschieden),
                    quoteAway: parseQuote(odds?.quoteGast),
                    homeFormLast5: nil,
                    awayFormLast5: nil,
                    homeGoalsPerGame: nil,
                    awayGoalsPerGame: nil,
                    homeConcededPerGame: nil,
                    awayConcededPerGame: nil,
                    injuriesHomeCount: nil,
                    injuriesAwayCount: nil,
                    keyAbsenceHome: nil,
                    keyAbsenceAway: nil,
                    consistencySignalSummary: "Migriert aus bisherigem Verlaufsdatensatz",
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

            return PredictionRun(
                id: record.id,
                createdAt: record.timestamp,
                spieltag: record.spieltag,
                modelName: "legacy-tip-history",
                promptVersion: "legacy",
                rawPrompt: "",
                rawResponse: "",
                seasonIdentifier: seasonIdentifier,
                matches: matches
            )
        }
    }

    private func parseQuote(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    private static func bundesligaSeason(for date: Date) -> Int {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return 0 }
        return month >= 7 ? year : year - 1
    }

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()

    private static var defaultFileURL: URL {
        let dir = AppSupportPaths.appDirectory()
        return dir.appendingPathComponent("learning-store.json")
    }

    private static var defaultLegacyHistoryURL: URL {
        let dir = AppSupportPaths.appDirectory()
        return dir.appendingPathComponent("tip-history.json")
    }
}

private struct LearningPersistencePayload: Codable {
    let version: Int
    let predictionRuns: [PredictionRun]
    let learningState: LearningState
    /// Fellow players' tips per finished matchday; optional so older stores still decode.
    let communityMatchdays: [CommunityMatchday]?
    let oddsArchive: [ArchivedOdds]?
}
