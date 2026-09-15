#if canImport(XCTest)
import XCTest
@testable import BetBaconer

final class TipWorkflowServiceTests: XCTestCase {
    func testBuildPromptAsksCodexToVerifyOddsViaWebResearch() {
        let prompt = TipWorkflowService().buildPrompt(
            season: 2026,
            finishedResults: [],
            upcomingMatches: [
                UpcomingMatch(spieltag: 1, datum: "2026-08-14T18:30:00Z", heim: "Team A", gast: "Team B")
            ],
            bettingOdds: [
                BettingOdds(heim: "Team A", gast: "Team B", quoteHeim: "1.10", quoteUnentschieden: "12.0", quoteGast: "18.5")
            ]
        )

        XCTAssertTrue(prompt.contains("Web-Recherche"))
        XCTAssertTrue(prompt.contains("gelieferten Quoten unplausibel"))
    }

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

    func testParseSeasonQuestionTipsAcceptsWrappedJSON() throws {
        let service = TipWorkflowService()
        let content = """
        {
          "season_questions": [
            {
              "question": "Wer wird Deutscher Meister?",
              "answers": ["Bayer 04 Leverkusen"]
            }
          ]
        }
        """

        let tips = try service.parseSeasonQuestionTips(from: content)

        XCTAssertEqual(tips.count, 1)
        XCTAssertEqual(tips.first?.answers, ["Bayer 04 Leverkusen"])
    }

    func testParseLLMMatchEnrichmentsClampsAdjustments() throws {
        let service = TipWorkflowService()
        let matches = [
            UpcomingMatch(spieltag: 4, datum: "2026-09-18T18:30:00Z", heim: "Team A", gast: "Team B")
        ]
        let content = """
        {
          "matches": [
            {
              "heim": "Team A",
              "gast": "Team B",
              "player_impact": "Team B ohne Stammkeeper",
              "referee_stats": "hohe Kartenrate",
              "sharp_odds": "keine belastbaren Zusatzdaten",
              "lineup": "keine bestaetigten Lineups",
              "data_quality": "mittel",
              "structured_lineup": "Team A mit Stammelf",
              "player_value": "Team B ohne Topscorer",
              "closing_line": "Quote bewegt sich leicht zu Team A",
              "historical_baseline": "vergleichbare Spiele 2.6 Tore",
              "scoreline_calibration": "Remis leicht untergewichten",
              "learned_weight_hint": "Markt staerker gewichten",
              "home_attack_adjustment": 0.9,
              "away_attack_adjustment": -0.9,
              "home_defense_adjustment": 0.1,
              "away_defense_adjustment": -0.1,
              "total_goals_adjustment": 2.0,
              "lineup_impact": 0.5,
              "player_value_impact": -0.5,
              "sharp_market_delta": 0.3,
              "closing_line_value": -0.3,
              "historical_goal_baseline": 9.0,
              "scoreline_draw_calibration": 0.5,
              "market_weight_hint": -0.5,
              "confidence": 2,
              "sources": ["https://example.com"]
            }
          ]
        }
        """

        let enrichments = try service.parseLLMMatchEnrichments(from: content, upcomingMatches: matches)

        XCTAssertEqual(enrichments.count, 1)
        XCTAssertEqual(enrichments[0].homeAttackAdjustment, 0.25)
        XCTAssertEqual(enrichments[0].awayAttackAdjustment, -0.25)
        XCTAssertEqual(enrichments[0].totalGoalsAdjustment, 0.40)
        XCTAssertEqual(enrichments[0].lineupImpact, 0.25)
        XCTAssertEqual(enrichments[0].playerValueImpact, -0.25)
        XCTAssertEqual(enrichments[0].historicalGoalBaseline, 4)
        XCTAssertEqual(enrichments[0].scorelineDrawCalibration, 0.25)
        XCTAssertEqual(enrichments[0].marketWeightHint, -0.25)
        XCTAssertEqual(enrichments[0].confidence, 1)
        XCTAssertEqual(enrichments[0].structuredLineup, "Team A mit Stammelf")
    }

    func testParseClosingLineUpdatesClampsCLV() throws {
        let content = """
        {
          "closing_lines": [
            {
              "spieltag": 4,
              "heim": "Team A",
              "gast": "Team B",
              "closing_line": "Closing 1 1.90 / X 3.50 / 2 4.00",
              "closing_line_value": 0.9,
              "sources": ["https://example.com"]
            }
          ]
        }
        """

        let updates = try TipWorkflowService().parseClosingLineUpdates(from: content)

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].closingLineValue, 0.25)
        XCTAssertEqual(updates[0].closingLine, "Closing 1 1.90 / X 3.50 / 2 4.00")
    }
}
#endif
