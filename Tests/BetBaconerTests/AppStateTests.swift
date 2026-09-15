import Foundation
import Testing
@testable import BetBaconer

@MainActor
final class AppStateTests {

    @Test
    func testCurrentBundesligaSeasonUsesSummerSeasonStart() {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)

        components.year = 2026
        components.month = 8
        components.day = 26
        XCTAssertEqual(AppState.currentBundesligaSeason(for: components.date!), 2026)

        components.month = 5
        XCTAssertEqual(AppState.currentBundesligaSeason(for: components.date!), 2025)
    }

    @Test
    func testRestoresUpcomingMatchesFromLatestTipHistory() {
        let record = TipGenerationRecord(
            id: UUID(),
            timestamp: Date(),
            spieltag: 1,
            tips: [
                SuggestedTip(spieltag: 1, heim: "Team A", gast: "Team B", toreHeim: 2, toreGast: 1, rationale: "")
            ],
            odds: []
        )

        let matches = AppState.upcomingMatchesForLatestTips(record, predictionRuns: [])

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.heim, "Team A")
        XCTAssertEqual(matches.first?.gast, "Team B")
    }

    @Test
    func testRestoresUpcomingMatchesFromSameSeasonPredictionRun() {
        let record = tipRecord(timestamp: date(year: 2026, month: 9, day: 10), spieltag: 4)
        let oldRun = predictionRun(createdAt: Date(timeIntervalSince1970: 2), spieltag: 4, isEvaluated: false, seasonIdentifier: "2025")
        let currentRun = predictionRun(createdAt: Date(timeIntervalSince1970: 1), spieltag: 4, isEvaluated: false, seasonIdentifier: "2026")

        let matches = AppState.upcomingMatchesForLatestTips(record, predictionRuns: [oldRun, currentRun])

        XCTAssertEqual(matches.first?.datum, "2026")
    }

    @Test
    func testEvaluatedMatchdayRunsKeepsOnlyLatestEvaluatedRunPerMatchday() {
        let oldRun = predictionRun(createdAt: Date(timeIntervalSince1970: 1), isEvaluated: true)
        let newRun = predictionRun(createdAt: Date(timeIntervalSince1970: 2), isEvaluated: true)
        let openRun = predictionRun(createdAt: Date(timeIntervalSince1970: 3), spieltag: 2, isEvaluated: false)

        let runs = AppState.evaluatedMatchdayRuns(from: [oldRun, newRun, openRun])

        XCTAssertEqual(runs.map(\.id), [newRun.id])
    }

    @Test
    func testLatestTipHistoryKeepsOnlyNewestRecordPerMatchday() {
        let oldRecord = tipRecord(timestamp: Date(timeIntervalSince1970: 1), spieltag: 1)
        let newRecord = tipRecord(timestamp: Date(timeIntervalSince1970: 2), spieltag: 1)
        let otherRecord = tipRecord(timestamp: Date(timeIntervalSince1970: 3), spieltag: 2)

        let records = AppState.latestTipHistory(from: [oldRecord, newRecord, otherRecord])

        XCTAssertEqual(records.map(\.id), [otherRecord.id, newRecord.id])
    }

    @Test
    func testLatestTipHistorySortsCurrentSeasonBeforePreviousSeason() {
        let records = AppState.latestTipHistory(from: [
            tipRecord(timestamp: date(year: 2026, month: 5, day: 10), spieltag: 34),
            tipRecord(timestamp: date(year: 2026, month: 9, day: 10), spieltag: 4),
            tipRecord(timestamp: date(year: 2026, month: 8, day: 30), spieltag: 3),
            tipRecord(timestamp: date(year: 2026, month: 5, day: 1), spieltag: 33)
        ])

        XCTAssertEqual(records.map(\.spieltag), [4, 3, 34, 33])
    }

    @Test
    func testManualTipsUsesExistingKicktippFieldValues() {
        let tips = AppState.manualTips(
            from: [
                KicktippMatchField(
                    heim: "Team A",
                    gast: "Team B",
                    heimField: "home",
                    gastField: "away",
                    existingHeim: " 2 ",
                    existingGast: "1"
                )
            ],
            upcomingMatches: [
                UpcomingMatch(spieltag: 3, datum: "2026-09-12T13:30:00Z", heim: "Team A", gast: "Team B")
            ]
        )

        XCTAssertEqual(tips.count, 1)
        XCTAssertEqual(tips.first?.spieltag, 3)
        XCTAssertEqual(tips.first?.toreHeim, 2)
        XCTAssertEqual(tips.first?.toreGast, 1)
    }

    @Test
    func testShortTermStabilityKeepsPreviousTipWithoutConsensus() {
        let now = date(year: 2026, month: 9, day: 15)
        let previous = predictionRun(
            createdAt: now.addingTimeInterval(-30 * 60),
            spieltag: 4,
            modelName: "codex-cli-ensemble",
            score: (3, 0),
            isEvaluated: false
        )
        let current = [
            SuggestedTip(spieltag: 4, heim: "Team A", gast: "Team B", toreHeim: 2, toreGast: 1, rationale: "new")
        ]

        let result = AppState.stabilizeShortTermTips(
            current,
            previousRuns: [previous],
            currentRuns: [current],
            seasonIdentifier: "2026",
            now: now
        )

        XCTAssertEqual(result.stabilizedCount, 1)
        XCTAssertEqual(result.tips.first?.toreHeim, 3)
        XCTAssertEqual(result.tips.first?.toreGast, 0)
    }

    @Test
    func testShortTermStabilityAllowsStrongConsensus() {
        let now = date(year: 2026, month: 9, day: 15)
        let previous = predictionRun(
            createdAt: now.addingTimeInterval(-30 * 60),
            spieltag: 4,
            modelName: "codex-cli-ensemble",
            score: (3, 0),
            isEvaluated: false
        )
        let current = [
            SuggestedTip(spieltag: 4, heim: "Team A", gast: "Team B", toreHeim: 2, toreGast: 1, rationale: "new")
        ]

        let result = AppState.stabilizeShortTermTips(
            current,
            previousRuns: [previous],
            currentRuns: [current, current, current, current],
            seasonIdentifier: "2026",
            now: now
        )

        XCTAssertEqual(result.stabilizedCount, 0)
        XCTAssertEqual(result.tips.first?.toreHeim, 2)
        XCTAssertEqual(result.tips.first?.toreGast, 1)
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: day).date!
    }

    private func tipRecord(timestamp: Date, spieltag: Int) -> TipGenerationRecord {
        TipGenerationRecord(
            id: UUID(),
            timestamp: timestamp,
            spieltag: spieltag,
            tips: [
                SuggestedTip(spieltag: spieltag, heim: "Team A", gast: "Team B", toreHeim: 1, toreGast: 0, rationale: "")
            ],
            odds: []
        )
    }

    private func predictionRun(
        createdAt: Date,
        spieltag: Int = 1,
        modelName: String = "test",
        score: (home: Int, away: Int) = (1, 0),
        isEvaluated: Bool,
        seasonIdentifier: String = "2026"
    ) -> PredictionRun {
        let runId = UUID()
        return PredictionRun(
            id: runId,
            createdAt: createdAt,
            spieltag: spieltag,
            modelName: modelName,
            promptVersion: "v1",
            rawPrompt: "",
            rawResponse: "",
            seasonIdentifier: seasonIdentifier,
            matches: [
                MatchPrediction(
                    id: UUID(),
                    runId: runId,
                    spieltag: spieltag,
                    heim: "Team A",
                    gast: "Team B",
                    kickoffAt: seasonIdentifier,
                    predictedHomeGoals: score.home,
                    predictedAwayGoals: score.away,
                    predictedOutcome: outcome(forHomeGoals: score.home, awayGoals: score.away),
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
                    actualHomeGoals: isEvaluated ? 1 : nil,
                    actualAwayGoals: isEvaluated ? 0 : nil,
                    actualOutcome: isEvaluated ? .homeWin : nil,
                    exactHit: isEvaluated,
                    tendencyHit: isEvaluated,
                    goalDiffHit: isEvaluated,
                    absErrorHomeGoals: isEvaluated ? 0 : nil,
                    absErrorAwayGoals: isEvaluated ? 0 : nil,
                    totalAbsGoalError: isEvaluated ? 0 : nil,
                    evaluatedAt: isEvaluated ? Date() : nil
                )
            ]
        )
    }
}
