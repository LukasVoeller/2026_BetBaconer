import Foundation
import Testing
@testable import BetBaconer

final class ExpectedGoalsModelTests {
    private let upcoming = [UpcomingMatch(spieltag: 8, datum: "2026-10-24T13:30:00Z", heim: "Team A", gast: "Team B")]
    private let key = normalizedTeamKey("Team A", "Team B")

    /// Team A and Team B are equally strong in the results.
    private var history: [FinishedMatch] {
        (0..<20).map { index in
            FinishedMatch(spieltag: index + 1, datum: String(format: "2026-0%d-%02dT13:30:00Z", 8 + index / 10, 1 + index % 10 * 2),
                          heim: index.isMultiple(of: 2) ? "Team A" : "Team B", gast: index.isMultiple(of: 2) ? "Team B" : "Team A",
                          toreHeim: 1, toreGast: 1)
        }
    }

    @Test
    func testMarketMovesExpectedGoalsTowardsTheFavourite() throws {
        let base = ExpectedGoalsInput(season: 2026, finishedResults: history, upcomingMatches: upcoming)
        var withMarket = base
        withMarket.bettingOdds = [BettingOdds(heim: "Team A", gast: "Team B", quoteHeim: "1.40", quoteUnentschieden: "4.80", quoteGast: "7.50")]

        let neutral = try XCTUnwrap(ExpectedGoalsModel().expectedGoals(base)[key])
        let market = try XCTUnwrap(ExpectedGoalsModel().expectedGoals(withMarket)[key])

        XCTAssertGreaterThan(market.home - market.away, neutral.home - neutral.away + 0.8)
    }

    @Test
    func testAbsencesOnlyApplyWithoutMarketOdds() throws {
        let absences = (1...6).map { PlayerAbsence(playerName: "Stuermer \($0)", teamName: "Team A", type: "Verletzung", reason: "striker muscle") }
        var input = ExpectedGoalsInput(season: 2026, finishedResults: history, upcomingMatches: upcoming)
        let healthy = try XCTUnwrap(ExpectedGoalsModel().expectedGoals(input)[key])
        input.playerAbsences = absences
        let injured = try XCTUnwrap(ExpectedGoalsModel().expectedGoals(input)[key])
        XCTAssertGreaterThan(healthy.home, injured.home)

        input.bettingOdds = [BettingOdds(heim: "Team A", gast: "Team B", quoteHeim: "2.40", quoteUnentschieden: "3.40", quoteGast: "2.90")]
        let priced = try XCTUnwrap(ExpectedGoalsModel().expectedGoals(input)[key])
        input.playerAbsences = []
        let pricedHealthy = try XCTUnwrap(ExpectedGoalsModel().expectedGoals(input)[key])
        XCTAssertEqual(priced.home, pricedHealthy.home, accuracy: 0.0001)
    }
}
