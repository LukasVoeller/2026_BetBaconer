import Foundation
import Testing
@testable import BetBaconer

final class PredictionEvaluatorTests {

    @Test
    func testEvaluateRunsUsesOnlyLatestRunPerMatchdayForLearning() {
        let oldRun = predictionRun(createdAt: Date(timeIntervalSince1970: 1), homeGoals: 1, awayGoals: 0)
        let newRun = predictionRun(createdAt: Date(timeIntervalSince1970: 2), homeGoals: 2, awayGoals: 1)
        let finished = [
            FinishedMatch(spieltag: 1, datum: "2026-08-28T18:30:00Z", heim: "Team A", gast: "Team B", toreHeim: 2, toreGast: 1)
        ]

        let summary = PredictionEvaluator().evaluateRuns(
            [oldRun, newRun],
            using: ["2026": finished],
            previousState: .empty
        )

        XCTAssertEqual(summary.learningState.sampleSize, 1)
        XCTAssertEqual(summary.runs[0].matches.filter(\.isEvaluated).count, 0)
        XCTAssertEqual(summary.runs[1].matches.filter(\.isEvaluated).count, 1)
        XCTAssertEqual(summary.learningState.exactHitRate, 1)
    }

    private func predictionRun(createdAt: Date, homeGoals: Int, awayGoals: Int) -> PredictionRun {
        let runId = UUID()
        return PredictionRun(
            id: runId,
            createdAt: createdAt,
            spieltag: 1,
            modelName: "test",
            promptVersion: "v1",
            rawPrompt: "",
            rawResponse: "",
            seasonIdentifier: "2026",
            matches: [
                MatchPrediction(
                    id: UUID(),
                    runId: runId,
                    spieltag: 1,
                    heim: "Team A",
                    gast: "Team B",
                    kickoffAt: "2026-08-28T18:30:00Z",
                    predictedHomeGoals: homeGoals,
                    predictedAwayGoals: awayGoals,
                    predictedOutcome: outcome(forHomeGoals: homeGoals, awayGoals: awayGoals),
                    rationale: "",
                    quoteHome: nil,
                    quoteDraw: nil,
                    quoteAway: nil,
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
                    consistencySignalSummary: nil,
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
            ]
        )
    }
}
