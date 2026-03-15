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

        for run in runs {
            guard let finishedMatches = finishedMatchesBySeason[run.seasonIdentifier] else {
                updatedRuns.append(run)
                continue
            }

            let evaluatedMatches = evaluateMatches(run.matches, against: finishedMatches)
            if evaluatedMatches != run.matches {
                updatedRunCount += 1
                evaluatedMatchCount += zip(run.matches, evaluatedMatches).filter { !$0.0.isEvaluated && $0.1.isEvaluated }.count
            }

            updatedRuns.append(
                PredictionRun(
                    id: run.id,
                    createdAt: run.createdAt,
                    spieltag: run.spieltag,
                    modelName: run.modelName,
                    promptVersion: run.promptVersion,
                    rawPrompt: run.rawPrompt,
                    rawResponse: run.rawResponse,
                    seasonIdentifier: run.seasonIdentifier,
                    matches: evaluatedMatches
                )
            )
        }

        let allMatches = updatedRuns.flatMap(\.matches)
        let learningState = engine.buildLearningState(from: allMatches, previousState: previousState)
        return PredictionEvaluationSummary(
            evaluatedMatches: evaluatedMatchCount,
            updatedRuns: updatedRunCount,
            runs: updatedRuns,
            learningState: learningState
        )
    }

    public func evaluateMatches(_ predictions: [MatchPrediction], against finishedMatches: [FinishedMatch]) -> [MatchPrediction] {
        let index = Dictionary(uniqueKeysWithValues: finishedMatches.map { (finishedMatchKey($0), $0) })
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

        return MatchPrediction(
            id: prediction.id,
            runId: prediction.runId,
            spieltag: prediction.spieltag,
            heim: prediction.heim,
            gast: prediction.gast,
            kickoffAt: prediction.kickoffAt,
            predictedHomeGoals: prediction.predictedHomeGoals,
            predictedAwayGoals: prediction.predictedAwayGoals,
            predictedOutcome: prediction.predictedOutcome,
            rationale: prediction.rationale,
            quoteHome: prediction.quoteHome,
            quoteDraw: prediction.quoteDraw,
            quoteAway: prediction.quoteAway,
            homeFormLast5: prediction.homeFormLast5,
            awayFormLast5: prediction.awayFormLast5,
            homeGoalsPerGame: prediction.homeGoalsPerGame,
            awayGoalsPerGame: prediction.awayGoalsPerGame,
            homeConcededPerGame: prediction.homeConcededPerGame,
            awayConcededPerGame: prediction.awayConcededPerGame,
            injuriesHomeCount: prediction.injuriesHomeCount,
            injuriesAwayCount: prediction.injuriesAwayCount,
            keyAbsenceHome: prediction.keyAbsenceHome,
            keyAbsenceAway: prediction.keyAbsenceAway,
            consistencySignalSummary: prediction.consistencySignalSummary,
            actualHomeGoals: finishedMatch.toreHeim,
            actualAwayGoals: finishedMatch.toreGast,
            actualOutcome: actualOutcome,
            exactHit: exactHit,
            tendencyHit: tendencyHit,
            goalDiffHit: goalDiffHit,
            absErrorHomeGoals: absErrorHomeGoals,
            absErrorAwayGoals: absErrorAwayGoals,
            totalAbsGoalError: absErrorHomeGoals + absErrorAwayGoals,
            evaluatedAt: evaluatedAt
        )
    }

    private func finishedMatchKey(_ match: FinishedMatch) -> String {
        "\(match.spieltag)|\(normalizedTeamKey(match.heim, match.gast))"
    }

    private func predictionLookupKey(_ prediction: MatchPrediction) -> String {
        "\(prediction.spieltag)|\(normalizedTeamKey(prediction.heim, prediction.gast))"
    }
}
