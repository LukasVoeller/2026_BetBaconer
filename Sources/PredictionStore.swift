import Foundation

enum PredictionStoreError: LocalizedError {
    case failedToLoad
    case failedToSave

    var errorDescription: String? {
        switch self {
        case .failedToLoad:
            return "Der Learning-Store konnte nicht geladen werden."
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

    func load() throws -> (runs: [PredictionRun], learningState: LearningState) {
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let payload = try? decoder.decode(LearningPersistencePayload.self, from: data) else {
                throw PredictionStoreError.failedToLoad
            }
            return (payload.predictionRuns, payload.learningState)
        }

        let migratedRuns = migrateLegacyTipHistory()
        let state = LearningState.empty
        if !migratedRuns.isEmpty {
            try save(runs: migratedRuns, learningState: state)
        }
        return (migratedRuns, state)
    }

    func save(runs: [PredictionRun], learningState: LearningState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let payload = LearningPersistencePayload(
            version: 1,
            predictionRuns: runs,
            learningState: learningState
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
            let seasonIdentifier = String(Calendar(identifier: .gregorian).component(.year, from: record.timestamp))
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
}
