#if canImport(XCTest)
import XCTest
@testable import BetBaconer

final class TeamRatingServiceTests: XCTestCase {
    func testFitRatesStrongerAttackHigher() throws {
        let matches = [
            FinishedMatch(spieltag: 1, datum: "2026-08-01T15:30:00Z", heim: "Team A", gast: "Team B", toreHeim: 4, toreGast: 0),
            FinishedMatch(spieltag: 2, datum: "2026-08-08T15:30:00Z", heim: "Team A", gast: "Team C", toreHeim: 3, toreGast: 0),
            FinishedMatch(spieltag: 3, datum: "2026-08-15T15:30:00Z", heim: "Team B", gast: "Team A", toreHeim: 0, toreGast: 2),
            FinishedMatch(spieltag: 4, datum: "2026-08-22T15:30:00Z", heim: "Team C", gast: "Team A", toreHeim: 1, toreGast: 3),
            FinishedMatch(spieltag: 5, datum: "2026-08-29T15:30:00Z", heim: "Team B", gast: "Team C", toreHeim: 1, toreGast: 1),
            FinishedMatch(spieltag: 6, datum: "2026-09-05T15:30:00Z", heim: "Team C", gast: "Team B", toreHeim: 1, toreGast: 0),
            FinishedMatch(spieltag: 7, datum: "2026-09-12T15:30:00Z", heim: "Team A", gast: "Team B", toreHeim: 5, toreGast: 1),
            FinishedMatch(spieltag: 8, datum: "2026-09-19T15:30:00Z", heim: "Team C", gast: "Team A", toreHeim: 0, toreGast: 4),
            FinishedMatch(spieltag: 9, datum: "2026-09-26T15:30:00Z", heim: "Team B", gast: "Team A", toreHeim: 0, toreGast: 3),
            FinishedMatch(spieltag: 10, datum: "2026-10-03T15:30:00Z", heim: "Team A", gast: "Team C", toreHeim: 4, toreGast: 1),
            FinishedMatch(spieltag: 11, datum: "2026-10-10T15:30:00Z", heim: "Team B", gast: "Team C", toreHeim: 1, toreGast: 2),
            FinishedMatch(spieltag: 12, datum: "2026-10-17T15:30:00Z", heim: "Team C", gast: "Team B", toreHeim: 2, toreGast: 1),
            FinishedMatch(spieltag: 13, datum: "2026-10-24T15:30:00Z", heim: "Team A", gast: "Team B", toreHeim: 3, toreGast: 0),
            FinishedMatch(spieltag: 14, datum: "2026-10-31T15:30:00Z", heim: "Team A", gast: "Team C", toreHeim: 3, toreGast: 1),
            FinishedMatch(spieltag: 15, datum: "2026-11-07T15:30:00Z", heim: "Team B", gast: "Team A", toreHeim: 1, toreGast: 4),
            FinishedMatch(spieltag: 16, datum: "2026-11-14T15:30:00Z", heim: "Team C", gast: "Team A", toreHeim: 0, toreGast: 2),
            FinishedMatch(spieltag: 17, datum: "2026-11-21T15:30:00Z", heim: "Team B", gast: "Team C", toreHeim: 0, toreGast: 1),
            FinishedMatch(spieltag: 18, datum: "2026-11-28T15:30:00Z", heim: "Team C", gast: "Team B", toreHeim: 1, toreGast: 1)
        ]

        let model = try XCTUnwrap(TeamRatingService().fit(finishedResults: matches))
        let strong = try XCTUnwrap(model.expectedGoals(homeTeam: "Team A", awayTeam: "Team B"))
        let weak = try XCTUnwrap(model.expectedGoals(homeTeam: "Team B", awayTeam: "Team A"))

        XCTAssertGreaterThan(strong.home, weak.home)
        XCTAssertGreaterThan(strong.home, strong.away)
    }
}
#endif
