import Foundation
import Testing
@testable import BetBaconer

final class EnsembleServiceTests {

    @Test
    func testAggregateTipsUsesPoissonModalScoreline() throws {
        let service = EnsembleService()
        let upcomingMatches = [
            UpcomingMatch(spieltag: 26, datum: "2025-03-14T19:30:00Z", heim: "Team A", gast: "Team B")
        ]
        let runs = [
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 2, toreGast: 2, rationale: "A")],
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 2, toreGast: 2, rationale: "B")],
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 2, toreGast: 1, rationale: "C")],
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 1, toreGast: 2, rationale: "D")],
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 2, toreGast: 2, rationale: "E")]
        ]

        let aggregated = try service.aggregateTips(from: runs, upcomingMatches: upcomingMatches, bettingOdds: [])

        XCTAssertEqual(aggregated.first?.toreHeim, 1)
        XCTAssertEqual(aggregated.first?.toreGast, 1)
    }

    @Test
    func testAggregateTipsUsesProvidedExpectedGoals() throws {
        let service = EnsembleService()
        let upcomingMatches = [
            UpcomingMatch(spieltag: 26, datum: "2025-03-14T19:30:00Z", heim: "Team A", gast: "Team B")
        ]
        let runs = [
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 3, toreGast: 0, rationale: "A")],
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 3, toreGast: 0, rationale: "B")]
        ]
        let xg = MatchExpectedGoals(heim: "Team A", gast: "Team B", home: 1.4, away: 1.2)

        let aggregated = try service.aggregateTips(
            from: runs,
            upcomingMatches: upcomingMatches,
            bettingOdds: [],
            expectedGoals: [normalizedTeamKey("Team A", "Team B"): xg]
        )

        XCTAssertEqual(aggregated.first?.toreHeim, 1)
        XCTAssertEqual(aggregated.first?.toreGast, 1)
    }

    @Test
    func testRemappedOddsKeepsFirstDuplicateMatchInsteadOfCrashing() {
        let service = EnsembleService()
        let odds = [
            BettingOdds(heim: "Team A", gast: "Team B", quoteHeim: "1.80", quoteUnentschieden: "3.50", quoteGast: "4.00"),
            BettingOdds(heim: "Team A", gast: "Team B", quoteHeim: "1.90", quoteUnentschieden: "3.40", quoteGast: "3.90")
        ]

        let mapped = service.remappedOdds(
            bettingOdds: odds,
            upcomingMatches: [
                UpcomingMatch(spieltag: 1, datum: "2026-09-18T20:30:00", heim: "Team A", gast: "Team B")
            ]
        )

        XCTAssertEqual(mapped[normalizedTeamKey("Team A", "Team B")]?.quoteHeim, "1.80")
    }

    @Test
    func testAggregateTipsKeepsLowExpectedGoalsModalScoreline() throws {
        let service = EnsembleService()
        let upcomingMatches = [
            UpcomingMatch(spieltag: 26, datum: "2025-03-14T19:30:00Z", heim: "Team A", gast: "Team B")
        ]
        let runs = [
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 1, toreGast: 0, rationale: "A")]
        ]
        let xg = MatchExpectedGoals(heim: "Team A", gast: "Team B", home: 0.9, away: 0.9)

        let aggregated = try service.aggregateTips(
            from: runs,
            upcomingMatches: upcomingMatches,
            bettingOdds: [],
            expectedGoals: [normalizedTeamKey("Team A", "Team B"): xg]
        )

        XCTAssertEqual(aggregated.first?.toreHeim, 0)
        XCTAssertEqual(aggregated.first?.toreGast, 0)
    }

    @Test
    func testAggregateTipsDampensBlowoutWhenMarketIsClose() throws {
        let service = EnsembleService()
        let upcomingMatches = [
            UpcomingMatch(spieltag: 4, datum: "2026-09-19T13:30:00Z", heim: "Hamburger SV", gast: "1. FC Köln")
        ]
        let runs = [
            [SuggestedTip(spieltag: 4, heim: "Hamburger SV", gast: "1. FC Köln", toreHeim: 0, toreGast: 4, rationale: "A")]
        ]
        let odds = [
            BettingOdds(heim: "Hamburger SV", gast: "1. FC Köln", quoteHeim: "2.65", quoteUnentschieden: "3.60", quoteGast: "2.45")
        ]
        let xg = MatchExpectedGoals(heim: "Hamburger SV", gast: "1. FC Köln", home: 0.35, away: 3.8)

        let aggregated = try service.aggregateTips(
            from: runs,
            upcomingMatches: upcomingMatches,
            bettingOdds: odds,
            expectedGoals: [normalizedTeamKey("Hamburger SV", "1. FC Köln"): xg]
        )

        XCTAssertLessThanOrEqual(aggregated[0].toreGast - aggregated[0].toreHeim, 2)
        XCTAssertLessThanOrEqual(aggregated[0].toreHeim + aggregated[0].toreGast, 4)
    }

    @Test
    func testAggregateTipsCapsMatchdayDraws() throws {
        let service = EnsembleService()
        let upcomingMatches = (1...9).map {
            UpcomingMatch(spieltag: 4, datum: "2026-09-19T13:30:00Z", heim: "Home \($0)", gast: "Away \($0)")
        }
        let runs = [
            upcomingMatches.map {
                SuggestedTip(spieltag: 4, heim: $0.heim, gast: $0.gast, toreHeim: 1, toreGast: 1, rationale: "Remis")
            }
        ]
        let odds = upcomingMatches.enumerated().map { index, match in
            BettingOdds(
                heim: match.heim,
                gast: match.gast,
                quoteHeim: index < 4 ? "2.00" : "2.60",
                quoteUnentschieden: index < 4 ? "3.80" : "3.10",
                quoteGast: index < 4 ? "3.60" : "2.70"
            )
        }

        let aggregated = try service.aggregateTips(from: runs, upcomingMatches: upcomingMatches, bettingOdds: odds)
        let drawCount = aggregated.filter { $0.toreHeim == $0.toreGast }.count

        XCTAssertLessThanOrEqual(drawCount, 3)
    }
}
