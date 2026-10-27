import Foundation
import Testing
import WebKit
@testable import BetBaconer

/// Runs extraction and parsing against a reduced copy of a real Kicktipp tip overview.
@MainActor
final class RealKicktippPageTests {
    /// OpenLigaDB results of Bundesliga 2026/27, matchday 7 (as listed in the page header).
    private let results = [
        ("VfB Stuttgart", "Borussia Mönchengladbach", 2, 3), ("SC Paderborn 07", "Hamburger SV", 1, 0),
        ("1. FSV Mainz 05", "SV Werder Bremen", 2, 3), ("RB Leipzig", "SV 07 Elversberg", 4, 0),
        ("FC Augsburg", "1. FC Union Berlin", 1, 1), ("1. FC Köln", "FC Schalke 04", 0, 0),
        ("Borussia Dortmund", "Eintracht Frankfurt", 1, 0), ("TSG Hoffenheim", "Bayer 04 Leverkusen", 3, 0),
        ("SC Freiburg", "FC Bayern München", 1, 3),
    ].map { FinishedMatch(spieltag: 7, datum: "2026-10-17T13:30:00Z", heim: $0.0, gast: $0.1, toreHeim: $0.2, toreGast: $0.3) }

    @Test
    func testParsesRealKicktippOverview() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "kicktipp-tippuebersicht-st7", withExtension: "html", subdirectory: "Fixtures"))
        let automation = KicktippAutomation()
        automation.webView.loadHTMLString(try String(contentsOf: url, encoding: .utf8), baseURL: nil)
        for _ in 0..<100 where automation.webView.isLoading {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let table = try await automation.extractCommunityTable().table
        // The ranking table (most scores) wins over the fixture table, and header boxes stay separated.
        XCTAssertTrue(table.header.first?.contains("VFB BMG 2:3") == true)

        let day = try KicktippCommunityService().parse(table: table, season: "2026", spieltag: 7, finishedMatches: results)
        XCTAssertEqual(day.results.count, 9)
        XCTAssertEqual(day.players.count, 6)
        XCTAssertEqual(day.players.first?.name, "Spieler 1")
        XCTAssertTrue(day.players.allSatisfy { $0.totalPoints != nil && $0.tips.count == 9 })
    }

    @Test
    func testRuleInferenceRefusesVaryingOddsPoints() {
        let tips = [10, 6, 3, 9, 4, 7].map { CommunityTip(heim: "VfB Stuttgart", gast: "Borussia Mönchengladbach", home: 2, away: 3, points: $0) }
        let day = CommunityMatchday(season: "2026", spieltag: 7, results: Array(results.prefix(1)),
                                    players: [CommunityPlayer(name: "Spieler", tips: tips, matchdayPoints: nil, totalPoints: nil)])

        XCTAssertTrue(KicktippCommunityService().inferRules(from: [day]) == nil)
    }

    @Test
    func testHeaderParserAcceptsGluedCodes() {
        let parsed = KicktippCommunityService.parseHeaderMatch("VFBBMG2:3")
        XCTAssertEqual(parsed?.home, "VFB")
        XCTAssertEqual(parsed?.away, "BMG")
        XCTAssertEqual(parsed?.result?.0, 2)
    }
}
