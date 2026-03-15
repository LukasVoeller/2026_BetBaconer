#if canImport(XCTest)
import Foundation
import XCTest
@testable import BetBaconer

final class PredictionStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PredictionStore(
            fileURL: directory.appendingPathComponent("learning-store.json"),
            legacyHistoryURL: directory.appendingPathComponent("tip-history.json")
        )
        let run = PredictionRun(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            spieltag: 26,
            modelName: "test",
            promptVersion: "v1",
            rawPrompt: "prompt",
            rawResponse: "response",
            seasonIdentifier: "2025",
            matches: [
                MatchPrediction(
                    id: UUID(),
                    runId: UUID(),
                    spieltag: 26,
                    heim: "Team A",
                    gast: "Team B",
                    kickoffAt: "2025-03-14T19:30:00Z",
                    predictedHomeGoals: 2,
                    predictedAwayGoals: 1,
                    predictedOutcome: .homeWin,
                    rationale: "Form",
                    quoteHome: 1.8,
                    quoteDraw: 3.5,
                    quoteAway: 4.2,
                    homeFormLast5: "S-S-U-S-S",
                    awayFormLast5: "N-U-N-S-N",
                    homeGoalsPerGame: 2.0,
                    awayGoalsPerGame: 1.0,
                    homeConcededPerGame: 0.8,
                    awayConcededPerGame: 1.7,
                    injuriesHomeCount: 1,
                    injuriesAwayCount: 2,
                    keyAbsenceHome: "Player A",
                    keyAbsenceAway: "Player B",
                    consistencySignalSummary: "2x 2:1",
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

        try store.save(runs: [run], learningState: .empty)
        let loaded = try store.load()

        XCTAssertEqual(loaded.runs.count, 1)
        XCTAssertEqual(loaded.runs.first?.spieltag, 26)
        XCTAssertEqual(loaded.learningState.sampleSize, 0)
    }
}
#endif
