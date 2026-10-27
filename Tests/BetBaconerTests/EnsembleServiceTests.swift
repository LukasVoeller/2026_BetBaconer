import Foundation
import Testing
@testable import BetBaconer

final class EnsembleServiceTests {

    @Test
    func testStandardKicktippRulesGiveGoalDifferenceForWrongDrawScore() {
        var rules = KicktippRules.standard
        XCTAssertEqual(rules.points(predictedHome: 2, predictedAway: 1, actualHome: 2, actualAway: 1), 4)
        XCTAssertEqual(rules.points(predictedHome: 2, predictedAway: 1, actualHome: 3, actualAway: 2), 3)
        XCTAssertEqual(rules.points(predictedHome: 2, predictedAway: 1, actualHome: 4, actualAway: 0), 2)
        XCTAssertEqual(rules.points(predictedHome: 1, predictedAway: 1, actualHome: 2, actualAway: 2), 3)
        XCTAssertEqual(rules.points(predictedHome: 1, predictedAway: 0, actualHome: 0, actualAway: 1), 0)

        rules.drawCountsAsGoalDifference = false
        XCTAssertEqual(rules.points(predictedHome: 1, predictedAway: 1, actualHome: 2, actualAway: 2), 2)
    }

    @Test
    func testSymmetricMatchBreaksExpectedPointsTieTowardsHome() throws {
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
        let tip = try XCTUnwrap(aggregated.first)

        XCTAssertGreaterThan(tip.toreHeim, tip.toreGast)
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

        // Statistical xG dominates; the 3:0 runs only shift it by the LLM signal weight.
        XCTAssertEqual(aggregated.first?.toreHeim, 1)
        XCTAssertEqual(aggregated.first?.toreGast, 0)
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
            [SuggestedTip(spieltag: 26, heim: "Team A", gast: "Team B", toreHeim: 0, toreGast: 0, rationale: "A")]
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
    func testClearHomeFavoritesAreNotTippedAsDraws() throws {
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

        let expectedGoals = Dictionary(uniqueKeysWithValues: upcomingMatches.prefix(4).map {
            (normalizedTeamKey($0.heim, $0.gast), MatchExpectedGoals(heim: $0.heim, gast: $0.gast, home: 1.7, away: 1.0))
        })
        let aggregated = try service.aggregateTips(from: runs, upcomingMatches: upcomingMatches, bettingOdds: odds, expectedGoals: expectedGoals)

        for tip in aggregated.prefix(4) {
            XCTAssertGreaterThan(tip.toreHeim, tip.toreGast)
        }
    }

    @Test
    func testProbabilityModelStoresOutcomeProbabilitiesAndTopScorelines() {
        let service = EnsembleService()
        let match = UpcomingMatch(spieltag: 4, datum: "2026-09-19T13:30:00Z", heim: "Team A", gast: "Team B")

        let model = service.probabilityModel(
            for: match,
            homeExpectedGoals: 1.6,
            awayExpectedGoals: 1.1,
            drawCalibration: 0.05,
            odds: BettingOdds(heim: "Team A", gast: "Team B", quoteHeim: "1.90", quoteUnentschieden: "3.60", quoteGast: "4.20")
        )

        XCTAssertEqual(model.topScorelines.count, 3)
        XCTAssertEqual(model.probabilityHomeWin + model.probabilityDraw + model.probabilityAwayWin, 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(model.confidence, 0)
        XCTAssertLessThanOrEqual(model.confidence, 1)
    }
}
