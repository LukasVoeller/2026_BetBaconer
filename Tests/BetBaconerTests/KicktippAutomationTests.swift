import Foundation
import Testing
import WebKit
@testable import BetBaconer

/// Runs the injected JavaScript against a Kicktipp-like DOM in a real WKWebView.
@MainActor
final class KicktippAutomationTests {
    private let html = """
    <html><body>
    <form id="tippabgabeForm">
      <table id="tippabgabeSpiele"><tbody>
        <tr class="datarow">
          <td class="col1">VfB Stuttgart</td><td class="col2">Borussia Mönchengladbach</td>
          <td><input id="s1_heimTipp" name="spieltippForms[1].heimTipp" value=""><input id="s1_gastTipp" name="spieltippForms[1].gastTipp" value=""></td>
          <td class="tippabgabe-quoten"><span class="quoteheim"><span class="quote-text">1,85</span></span><span class="quoteremis"><span class="quote-text">3,90</span></span><span class="quotegast"><span class="quote-text">4,10</span></span></td>
        </tr>
        <tr class="datarow">
          <td class="col1">RB Leipzig</td><td class="col2">SV 07 Elversberg</td>
          <td><input id="s2_heimTipp" name="spieltippForms[2].heimTipp" value="1"><input id="s2_gastTipp" name="spieltippForms[2].gastTipp" value="1"></td>
          <td class="tippabgabe-quoten"><span class="quoteheim"><span class="quote-text">1,30</span></span><span class="quoteremis"><span class="quote-text">5,75</span></span><span class="quotegast"><span class="quote-text">9,50</span></span></td>
        </tr>
      </tbody></table>
      <input type="submit" name="submitbutton" value="Tipps speichern">
    </form>
    <table id="overview"><thead><tr><th>Pos</th><th>Name</th><th>VFB BMG 2:3</th><th>RBL ELV 4:0</th><th>P</th><th>G</th></tr></thead>
      <tbody><tr><td>1.</td><td>Friederich</td><td>3:1</td><td>2:1<sub>2</sub></td><td>2</td><td>94</td></tr></tbody></table>
    </body></html>
    """

    private func loadedAutomation() async throws -> KicktippAutomation {
        let automation = KicktippAutomation()
        automation.webView.loadHTMLString(html, baseURL: URL(string: "https://www.kicktipp.de/runde/tippabgabe"))
        for _ in 0..<100 where automation.webView.isLoading || automation.webView.url == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        return automation
    }

    @Test
    func testExtractsFieldsAndAppliesTips() async throws {
        let automation = try await loadedAutomation()

        let fields = try await automation.extractMatchFields()
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields[0].heim, "VfB Stuttgart")
        XCTAssertEqual(fields[1].existingHeim, "1")

        let tips = [
            SuggestedTip(spieltag: 7, heim: "VfB Stuttgart", gast: "Borussia Mönchengladbach", toreHeim: 2, toreGast: 1, rationale: ""),
            SuggestedTip(spieltag: 7, heim: "RB Leipzig", gast: "SV 07 Elversberg", toreHeim: 3, toreGast: 0, rationale: ""),
        ]
        try await automation.applyTips(zip(fields, tips).map { (field: $0, tip: $1) })

        let readBack = try await automation.extractMatchFields()
        XCTAssertTrue(AppState.kicktippMismatches(expected: tips, fields: readBack).isEmpty)
    }

    @Test
    func testExtractsOddsFromTipPage() async throws {
        let automation = try await loadedAutomation()

        let odds = await automation.extractOddsFromPage().odds

        XCTAssertEqual(odds.count, 2)
        XCTAssertEqual(odds.first?.quoteHeim, "1.85")
    }

    @Test
    func testExtractsCommunityTable() async throws {
        let automation = try await loadedAutomation()

        let table = try await automation.extractCommunityTable().table

        XCTAssertTrue(table.header.first?.contains("VFB BMG 2:3") == true)
        XCTAssertEqual(table.rows.first?[3], "2:12")
    }
}
