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

        for run in runs {
            guard learningRunIDs.contains(run.id) else {
                let matches = run.matches.map { $0.clearingEvaluation() }
                if matches != run.matches { updatedRunCount += 1 }
                updatedRuns.append(run.replacingMatches(matches))
                continue
            }

            guard let finishedMatches = finishedMatchesBySeason[run.seasonIdentifier] else {
                updatedRuns.append(run)
                continue
            }

            let evaluatedMatches = evaluateMatches(run.matches, against: finishedMatches)
            if evaluatedMatches != run.matches {
                updatedRunCount += 1
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
            llmLineup: prediction.llmLineup,
            llmPlayerValue: prediction.llmPlayerValue,
            llmSharpOdds: prediction.llmSharpOdds,
            llmClosingLine: prediction.llmClosingLine,
            llmHistoricalBaseline: prediction.llmHistoricalBaseline,
            llmScorelineCalibration: prediction.llmScorelineCalibration,
            dataQuality: prediction.dataQuality,
            expectedHomeGoals: prediction.expectedHomeGoals,
            expectedAwayGoals: prediction.expectedAwayGoals,
            marketWeightHint: prediction.marketWeightHint,
            evaluatedClosingLineValue: prediction.evaluatedClosingLineValue,
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

    private func latestRunIDsByMatchday(from runs: [PredictionRun]) -> Set<UUID> {
        let latest = Dictionary(grouping: runs) { "\($0.seasonIdentifier)|\($0.spieltag)" }
            .compactMap { _, runs in runs.max { $0.createdAt < $1.createdAt }?.id }
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

private extension MatchPrediction {
    func clearingEvaluation() -> MatchPrediction {
        var prediction = self
        prediction.actualHomeGoals = nil
        prediction.actualAwayGoals = nil
        prediction.actualOutcome = nil
        prediction.exactHit = nil
        prediction.tendencyHit = nil
        prediction.goalDiffHit = nil
        prediction.absErrorHomeGoals = nil
        prediction.absErrorAwayGoals = nil
        prediction.totalAbsGoalError = nil
        prediction.evaluatedAt = nil
        return prediction
    }
}
