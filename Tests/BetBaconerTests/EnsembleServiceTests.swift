#if canImport(XCTest)
import XCTest
@testable import BetBaconer

final class EnsembleServiceTests: XCTestCase {
    func testAggregateTipsUsesMarketAlignmentAsTiebreaker() throws {
        let service = EnsembleService()
        let upcomingMatches = [
            UpcomingMatch(spieltag: 26, datum: "2025-03-14T19:30:00Z", heim: "Team A", gast: "Team B")
        ]
        let runs = [
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 1, toreGast: 0, rationale: "A")],
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 0, toreGast: 1, rationale: "B")]
        ]
        let odds = [
            BettingOdds(heim: "Team A", gast: "Team B", quoteHeim: "1.80", quoteUnentschieden: "3.50", quoteGast: "4.20")
        ]

        let aggregated = try service.aggregateTips(from: runs, upcomingMatches: upcomingMatches, bettingOdds: odds)

        XCTAssertEqual(aggregated.first?.toreHeim, 1)
        XCTAssertEqual(aggregated.first?.toreGast, 0)
    }
}
#endif
