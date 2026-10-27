import Foundation

public struct PredictionEvaluator {
    private let engine: LearningEngine

    public init(engine: LearningEngine = LearningEngine()) {
        self.engine = engine
    }

    public func evaluateRuns(
        _ runs: [PredictionRun],
        using finishedMatchesBySeason: [String: [FinishedMatch]],
        previousState: LearningState
    ) -> PredictionEvaluationSummary {
        var updatedRuns: [PredictionRun] = []
        var updatedRunCount = 0
        var evaluatedMatchCount = 0
        let learningRunIDs = latestRunIDsByMatchday(from: runs)

        // Every run is evaluated (so single Codex runs stay comparable), but only one run per matchday feeds learning.
        for run in runs {
            guard let finishedMatches = finishedMatchesBySeason[run.seasonIdentifier] else {
                updatedRuns.append(run)
                continue
            }

            let evaluatedMatches = evaluateMatches(run.matches, against: finishedMatches)
            if evaluatedMatches != run.matches {
                updatedRunCount += 1
            }
            if learningRunIDs.contains(run.id) {
                evaluatedMatchCount += zip(run.matches, evaluatedMatches).filter { !$0.0.isEvaluated && $0.1.isEvaluated }.count
            }

            updatedRuns.append(run.replacingMatches(evaluatedMatches))
        }

        let allMatches = updatedRuns
            .filter { learningRunIDs.contains($0.id) }
            .flatMap(\.matches)
        var learningState = engine.buildLearningState(from: allMatches, previousState: previousState)
        let versionSummary = modelVersionSummary(from: updatedRuns.filter { learningRunIDs.contains($0.id) })
        if !versionSummary.isEmpty {
            learningState.correctionSummaryText += "\n" + versionSummary
        }
        return PredictionEvaluationSummary(
            evaluatedMatches: evaluatedMatchCount,
            updatedRuns: updatedRunCount,
            runs: updatedRuns,
            learningState: learningState
        )
    }

    public func evaluateMatches(_ predictions: [MatchPrediction], against finishedMatches: [FinishedMatch]) -> [MatchPrediction] {
        let index = Dictionary(finishedMatches.map { (finishedMatchKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        return predictions.map { prediction in
            guard !prediction.isEvaluated,
                  let finishedMatch = index[predictionLookupKey(prediction)] else {
                return prediction
            }
            return evaluatedPrediction(prediction, with: finishedMatch)
        }
    }

    public func evaluatedPrediction(_ prediction: MatchPrediction, with finishedMatch: FinishedMatch, evaluatedAt: Date = Date()) -> MatchPrediction {
        let actualOutcome = outcome(forHomeGoals: finishedMatch.toreHeim, awayGoals: finishedMatch.toreGast)
        let exactHit = prediction.predictedHomeGoals == finishedMatch.toreHeim && prediction.predictedAwayGoals == finishedMatch.toreGast
        let tendencyHit = prediction.predictedOutcome == actualOutcome
        let predictedDiff = prediction.predictedHomeGoals - prediction.predictedAwayGoals
        let actualDiff = finishedMatch.toreHeim - finishedMatch.toreGast
        let goalDiffHit = predictedDiff == actualDiff
        let absErrorHomeGoals = abs(prediction.predictedHomeGoals - finishedMatch.toreHeim)
        let absErrorAwayGoals = abs(prediction.predictedAwayGoals - finishedMatch.toreGast)

        var evaluated = prediction
        evaluated.actualHomeGoals = finishedMatch.toreHeim
        evaluated.actualAwayGoals = finishedMatch.toreGast
        evaluated.actualOutcome = actualOutcome
        evaluated.exactHit = exactHit
        evaluated.tendencyHit = tendencyHit
        evaluated.goalDiffHit = goalDiffHit
        evaluated.absErrorHomeGoals = absErrorHomeGoals
        evaluated.absErrorAwayGoals = absErrorAwayGoals
        evaluated.totalAbsGoalError = absErrorHomeGoals + absErrorAwayGoals
        evaluated.evaluatedAt = evaluatedAt
        return evaluated
    }

    private func finishedMatchKey(_ match: FinishedMatch) -> String {
        "\(match.spieltag)|\(normalizedTeamKey(match.heim, match.gast))"
    }

    private func predictionLookupKey(_ prediction: MatchPrediction) -> String {
        "\(prediction.spieltag)|\(normalizedTeamKey(prediction.heim, prediction.gast))"
    }

    /// Learns from what was actually tipped: the Kicktipp form state beats the ensemble, which beats single Codex runs.
    /// Within the same source the newest run wins.
    private func latestRunIDsByMatchday(from runs: [PredictionRun]) -> Set<UUID> {
        let latest = Dictionary(grouping: runs) { "\($0.seasonIdentifier)|\($0.spieltag)" }
            .compactMap { _, runs in runs.max(by: PredictionRun.learningOrder)?.id }
        return Set(latest)
    }

    private func modelVersionSummary(from runs: [PredictionRun]) -> String {
        let rows = Dictionary(grouping: runs, by: \.promptVersion)
            .compactMap { version, runs -> String? in
                let matches = runs.flatMap(\.matches).filter(\.isEvaluated)
                guard matches.count >= 5 else { return nil }
                let tendency = Double(matches.filter { $0.tendencyHit == true }.count) / Double(matches.count)
                let exact = Double(matches.filter { $0.exactHit == true }.count) / Double(matches.count)
                let errors = matches.compactMap(\.totalAbsGoalError).map(Double.init)
                let error = errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count)
                return String(format: "- Modell %@: %d bewertete Tipps, Tendenz %.0f%%, exakt %.0f%%, Ø Fehler %.2f",
                              version, matches.count, tendency * 100, exact * 100, error)
            }
            .sorted()
        guard !rows.isEmpty else { return "" }
        return "Backtesting je Modellversion:\n" + rows.joined(separator: "\n")
    }
}

private extension PredictionRun {
    func replacingMatches(_ matches: [MatchPrediction]) -> PredictionRun {
        PredictionRun(
            id: id,
            createdAt: createdAt,
            spieltag: spieltag,
            modelName: modelName,
            promptVersion: promptVersion,
            rawPrompt: rawPrompt,
            rawResponse: rawResponse,
            seasonIdentifier: seasonIdentifier,
            matches: matches
        )
    }
}

