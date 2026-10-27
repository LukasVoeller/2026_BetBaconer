import Foundation
import Testing
@testable import BetBaconer

final class ModelBacktestServiceTests {

    /// Fair (margin-free) 1X2 odds of independent Poisson goals.
    private func fairOdds(home: Double, away: Double) -> BettingOdds {
        func poisson(_ k: Int, _ lambda: Double) -> Double { pow(lambda, Double(k)) * exp(-lambda) / Double((1...max(k, 1)).reduce(1, *)) }
        var pHome = 0.0, pDraw = 0.0, pAway = 0.0
        for h in 0...10 { for a in 0...10 {
            let p = poisson(h, home) * poisson(a, away)
            if h > a { pHome += p } else if h == a { pDraw += p } else { pAway += p }
        } }
        return BettingOdds(heim: "A", gast: "B", quoteHeim: String(format: "%.4f", 1 / pHome), quoteUnentschieden: String(format: "%.4f", 1 / pDraw), quoteGast: String(format: "%.4f", 1 / pAway))
    }

    @Test
    func testMarketModelRecoversExpectedGoalsFromOneXTwoOdds() throws {
        let goals = try XCTUnwrap(MarketModel.expectedGoals(odds: fairOdds(home: 1.9, away: 1.1), total: nil))

        XCTAssertEqual(goals.home, 1.9, accuracy: 0.08)
        XCTAssertEqual(goals.away, 1.1, accuracy: 0.08)
    }

    @Test
    func testMarketModelUsesOverUnderTotal() throws {
        let total = try XCTUnwrap(MarketModel.totalGoals(line: 2.5, overQuote: "1.80", underQuote: "2.00"))
        let goals = try XCTUnwrap(MarketModel.expectedGoals(odds: fairOdds(home: 1.9, away: 1.1), total: total))

        XCTAssertGreaterThan(total, 2.5)
        XCTAssertEqual(goals.home + goals.away, total, accuracy: 0.01)
    }

    @Test
    func testBlendIsGeometricAndBounded() {
        let blended = ModelBacktestService.blend(rating: (1.0, 1.0), market: (4.0, 1.0), marketWeight: 0.5)

        XCTAssertEqual(blended.home, 2.0, accuracy: 0.0001)
        XCTAssertEqual(blended.away, 1.0, accuracy: 0.0001)
    }

    @Test
    func testRatingModelPenalisesPromotedTeamAndCalibratesGoals() throws {
        let teams = ["A", "B", "C", "D"]
        var matches: [FinishedMatch] = []
        for round in 0..<8 {
            for (index, home) in teams.enumerated() {
                let away = teams[(index + 1 + round % 3) % teams.count]
                guard home != away else { continue }
                matches.append(FinishedMatch(spieltag: round + 1, datum: "2025-0\(1 + round % 9)-1\(index)T15:30:00Z", heim: home, gast: away, toreHeim: 2, toreGast: 1))
            }
        }
        let service = TeamRatingService()
        let plain = try XCTUnwrap(service.fit(matches: matches, promotedTeams: [], currentSeasonMatchCounts: [:], referenceDate: nil))
        let promoted = try XCTUnwrap(service.fit(matches: matches, promotedTeams: ["a"], currentSeasonMatchCounts: [:], referenceDate: nil))

        let plainGoals = try XCTUnwrap(plain.expectedGoals(homeTeam: "A", awayTeam: "B"))
        let promotedGoals = try XCTUnwrap(promoted.expectedGoals(homeTeam: "A", awayTeam: "B"))
        XCTAssertGreaterThan(plainGoals.home, promotedGoals.home)
        XCTAssertGreaterThan(promotedGoals.away, plainGoals.away)
        // 3 goals per game in the data; the scale keeps the regularised model on that level on average.
        let predicted = matches.compactMap { plain.expectedGoals(homeTeam: $0.heim, awayTeam: $0.gast) }.map { $0.home + $0.away }
        XCTAssertEqual(predicted.reduce(0, +) / Double(predicted.count), 3.0, accuracy: 0.1)
    }

    @Test
    func testBacktestLearnsMarketWeightFromArchive() {
        // Synthetic season: the market always knows the winner, the rating model has no history for it.
        var current: [FinishedMatch] = []
        var archive: [ArchivedOdds] = []
        let teams = (1...10).map { "Team \($0)" }
        for spieltag in 1...9 {
            for index in stride(from: 0, to: teams.count, by: 2) {
                let home = teams[(index + spieltag) % teams.count], away = teams[(index + spieltag + 1) % teams.count]
                let date = String(format: "2025-%02d-%02dT15:30:00Z", 8 + spieltag / 4, 1 + (spieltag * 3) % 27)
                current.append(FinishedMatch(spieltag: spieltag, datum: date, heim: home, gast: away, toreHeim: 2, toreGast: 0))
                archive.append(ArchivedOdds(season: "2025", spieltag: spieltag, heim: home, gast: away,
                                            quoteHeim: "1.30", quoteUnentschieden: "5.50", quoteGast: "11.00",
                                            overUnderLine: nil, overQuote: nil, underQuote: nil, capturedAt: Date()))
            }
        }
        let history = (1...4).flatMap { round in
            stride(from: 0, to: teams.count, by: 2).map { index in
                FinishedMatch(spieltag: round, datum: String(format: "2024-09-%02dT15:30:00Z", round * 5 + index / 2), heim: teams[(index + round) % teams.count], gast: teams[(index + round + 1) % teams.count], toreHeim: 1, toreGast: 1)
            }
        }

        let report = ModelBacktestService().run(seasons: [2024: history, 2025: current], oddsArchive: archive, evaluatedSeasons: 2025...2025)

        XCTAssertEqual(report.marketMatches, 45)
        XCTAssertGreaterThan(report.bestMarketWeight ?? 0, 0.5)
    }
}
