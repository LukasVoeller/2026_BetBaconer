#if canImport(XCTest)
import XCTest
@testable import BetBaconer

final class TipWorkflowServiceTests: XCTestCase {
    func testParseTipsAcceptsWrappedJSON() throws {
        let service = TipWorkflowService()
        let upcomingMatches = [
            UpcomingMatch(spieltag: 26, datum: "2025-03-14T19:30:00Z", heim: "Team A", gast: "Team B")
        ]
        let content = """
        {
          "tips": [
            {
              "spieltag": 26,
              "heim": "Team A",
              "gast": "Team B",
              "tore_heim": 2,
              "tore_gast": 1,
              "rationale": "Form und Quoten sprechen fuer Heim."
            }
          ]
        }
        """

        let tips = try service.parseTips(from: content, upcomingMatches: upcomingMatches)

        XCTAssertEqual(tips.count, 1)
        XCTAssertEqual(tips.first?.toreHeim, 2)
        XCTAssertEqual(tips.first?.toreGast, 1)
    }

    func testParseTipsRejectsFixtureMismatch() {
        let service = TipWorkflowService()
        let upcomingMatches = [
            UpcomingMatch(spieltag: 26, datum: "2025-03-14T19:30:00Z", heim: "Team A", gast: "Team B")
        ]
        let content = """
        [
          {
            "spieltag": 26,
            "heim": "Team A",
            "gast": "Team C",
            "tore_heim": 1,
            "tore_gast": 1,
            "rationale": "Mismatch"
          }
        ]
        """

        XCTAssertThrowsError(try service.parseTips(from: content, upcomingMatches: upcomingMatches)) { error in
            XCTAssertTrue(error is TipWorkflowError)
        }
    }
}
#endif
