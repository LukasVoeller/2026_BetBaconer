import Foundation
import Testing
import WebKit
@testable import BetBaconer

/// Serves canned API responses: OpenLigaDB fixtures, everything else 404.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var openLigaSeason = 2026
    nonisolated(unsafe) static var openLigaJSON = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let isSeason = url.host == "api.openligadb.de" && url.path.hasSuffix("/bl1/\(Self.openLigaSeason)")
        let isOtherSeason = url.host == "api.openligadb.de"
        let body = isSeason ? Self.openLigaJSON : (isOtherSeason ? Data("[]".utf8) : Data())
        let status = isOtherSeason ? 200 : 404
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Kicktipp look-alike served through a custom URL scheme inside a real WKWebView.
@MainActor
final class KicktippTestServer: NSObject, WKURLSchemeHandler {
    private(set) var requests: [(method: String, url: String)] = []

    static let tipForm = """
    <html><body><form id="tippabgabeForm" method="post" action="kicktipp-test://kicktipp/runde/tippabgabe">
    <table id="tippabgabeSpiele"><tbody>
      <tr class="datarow"><td class="col1">Borussia Mönchengladbach</td><td class="col2">RB Leipzig</td>
        <td><input id="a_heimTipp" name="spieltippForms[1].heimTipp" value=""><input id="a_gastTipp" name="spieltippForms[1].gastTipp" value=""></td>
        <td class="tippabgabe-quoten"><span class="quoteheim"><span class="quote-text">2,60</span></span><span class="quoteremis"><span class="quote-text">3,50</span></span><span class="quotegast"><span class="quote-text">2,50</span></span></td></tr>
      <tr class="datarow"><td class="col1">SV 07 Elversberg</td><td class="col2">VfB Stuttgart</td>
        <td><input id="b_heimTipp" name="spieltippForms[2].heimTipp" value=""><input id="b_gastTipp" name="spieltippForms[2].gastTipp" value=""></td>
        <td class="tippabgabe-quoten"><span class="quoteheim"><span class="quote-text">4,20</span></span><span class="quoteremis"><span class="quote-text">3,90</span></span><span class="quotegast"><span class="quote-text">1,75</span></span></td></tr>
    </tbody></table><input type="submit" name="submitbutton" value="Tipps speichern"></form></body></html>
    """

    static let pastTipPage = """
    <html><body><table id="tippabgabeSpiele"><tbody>
      <tr class="datarow"><td class="col1">VfB Stuttgart</td><td class="col2">Borussia Mönchengladbach</td>
        <td class="tippabgabe-quoten"><span class="quoteheim"><span class="quote-text">1,90</span></span><span class="quoteremis"><span class="quote-text">3,80</span></span><span class="quotegast"><span class="quote-text">3,70</span></span></td></tr>
      <tr class="datarow"><td class="col1">RB Leipzig</td><td class="col2">SV 07 Elversberg</td>
        <td class="tippabgabe-quoten"><span class="quoteheim"><span class="quote-text">1,25</span></span><span class="quoteremis"><span class="quote-text">6,50</span></span><span class="quotegast"><span class="quote-text">11,00</span></span></td></tr>
    </tbody></table></body></html>
    """

    static let overview = """
    <html><body><table><thead><tr><th>Pos</th><th>Name</th><th>VFB BMG 2:3</th><th>RBL ELV 4:0</th><th>P</th><th>G</th></tr></thead><tbody>
      <tr><td>1.</td><td>Friederich</td><td>1:2<sub>3</sub></td><td>3:0<sub>3</sub></td><td>6</td><td>6</td></tr>
      <tr><td>2.</td><td>Lukas</td><td>2:1</td><td>4:0<sub>4</sub></td><td>4</td><td>4</td></tr>
    </tbody></table></body></html>
    """

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        requests.append((urlSchemeTask.request.httpMethod ?? "GET", url.absoluteString))
        let query = url.query ?? ""
        let html: String
        if url.path.hasSuffix("tippuebersicht") {
            html = Self.overview
        } else if url.path.hasSuffix("tippabgabe") && query.contains("spieltagIndex=1") {
            html = Self.pastTipPage
        } else {
            html = Self.tipForm
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(Data(html.utf8))
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
@Suite(.serialized)
final class WorkflowEndToEndTests {
    private static func match(_ day: Int, _ date: String, _ home: String, _ away: String, _ result: (Int, Int)?) -> String {
        let results = result.map { #"[{"resultTypeID":2,"pointsTeam1":\#($0.0),"pointsTeam2":\#($0.1)}]"# } ?? "[]"
        return #"{"matchIsFinished":\#(result != nil),"matchDateTimeUTC":"\#(date)","group":{"groupOrderID":\#(day)},"team1":{"teamName":"\#(home)"},"team2":{"teamName":"\#(away)"},"matchResults":\#(results)}"#
    }

    private static let fakeCodex = """
    #!/bin/sh
    out=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--output-last-message" ]; then out="$2"; shift; fi
      shift
    done
    cat > /dev/null
    printf '%s' '{"tips":[{"spieltag":2,"heim":"Borussia Mönchengladbach","gast":"RB Leipzig","tore_heim":1,"tore_gast":2,"rationale":"Leipzig staerker"},{"spieltag":2,"heim":"SV 07 Elversberg","gast":"VfB Stuttgart","tore_heim":0,"tore_gast":2,"rationale":"Stuttgart Favorit"}]}' > "$out"
    echo "fake codex done"
    """

    @Test
    func testFullWorkflowGeneratesEntersAndSubmitsTips() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("betbaconer-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let codex = directory.appendingPathComponent("codex")
        try Self.fakeCodex.write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        StubURLProtocol.openLigaSeason = 2026
        StubURLProtocol.openLigaJSON = Data(("[" + [
            Self.match(1, "2026-08-21T18:30:00Z", "VfB Stuttgart", "Borussia Mönchengladbach", (2, 3)),
            Self.match(1, "2026-08-22T13:30:00Z", "RB Leipzig", "SV 07 Elversberg", (4, 0)),
            Self.match(2, "2027-01-16T14:30:00Z", "Borussia Mönchengladbach", "RB Leipzig", nil),
            Self.match(2, "2027-01-16T17:30:00Z", "SV 07 Elversberg", "VfB Stuttgart", nil),
        ].joined(separator: ",") + "]").utf8)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]

        let server = KicktippTestServer()
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.setURLSchemeHandler(server, forURLScheme: "kicktipp-test")
        let automation = KicktippAutomation(baseURL: URL(string: "kicktipp-test://kicktipp")!, configuration: webConfiguration)

        let defaults = UserDefaults(suiteName: "BetBaconerTests-\(UUID().uuidString)")!
        let state = AppState(
            dependencies: AppDependencies(
                defaults: defaults,
                session: URLSession(configuration: sessionConfiguration),
                predictionStore: PredictionStore(fileURL: directory.appendingPathComponent("learning-store.json"), legacyHistoryURL: directory.appendingPathComponent("none.json")),
                tipHistoryStore: TipHistoryStore(fileURL: directory.appendingPathComponent("tip-history.json")),
                secretStore: KeychainSecretStore(service: "BetBaconerTests.\(UUID().uuidString)", migrateFrom: nil),
                environment: [:],
                legacyDefaultsDomain: nil
            ),
            kicktippAutomation: automation
        )
        state.season = "2026"
        state.codexRunCount = 12
        XCTAssertEqual(state.codexRunCount, 9)
        XCTAssertEqual(defaults.integer(forKey: "codexRunCount"), 9)
        state.codexRunCount = 1
        state.codexPath = codex.path
        state.kicktippCompetitionSlug = "runde"

        // 1. Generate: OpenLigaDB -> Kicktipp odds -> group history -> Codex -> model -> tips.
        await state.runWorkflow()
        #expect(state.errorMessage == nil, "\(state.errorMessage ?? "") \n\(state.consoleOutput)")
        XCTAssertEqual(state.suggestedTips.count, 2)
        XCTAssertTrue(state.suggestedTips.allSatisfy { $0.spieltag == 2 })
        XCTAssertEqual(state.currentSeasonCommunity.count, 1)
        XCTAssertEqual(state.oddsArchive.filter { $0.spieltag == 1 }.count, 2)
        XCTAssertEqual(state.oddsArchive.filter { $0.spieltag == 2 }.count, 2)
        let ensemble = try XCTUnwrap(state.predictionRuns.last { $0.modelName == PredictionRun.ensembleModelName })
        XCTAssertTrue(ensemble.matches.allSatisfy { $0.probabilityHomeWin != nil })
        // The market makes Stuttgart (1.75) the clear favourite.
        let stuttgart = try XCTUnwrap(state.suggestedTips.first { $0.gast == "VfB Stuttgart" })
        XCTAssertGreaterThan(stuttgart.toreGast, stuttgart.toreHeim)

        // 2. Enter the tips into the form and verify them.
        await state.applyTipsToKicktipp()
        #expect(state.errorMessage == nil, "\(state.errorMessage ?? "")")
        XCTAssertTrue(state.pendingKicktippOverwrites.isEmpty)
        let fields = try await automation.extractMatchFields()
        XCTAssertTrue(AppState.kicktippMismatches(expected: state.suggestedTips, fields: fields).isEmpty)

        // 3. Submit.
        await state.submitKicktippTips()
        #expect(state.errorMessage == nil, "\(state.errorMessage ?? "")")
        for _ in 0..<40 where !server.requests.contains(where: { $0.method == "POST" }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(server.requests.contains { $0.method == "POST" && $0.url.hasSuffix("/runde/tippabgabe") })
    }
}
