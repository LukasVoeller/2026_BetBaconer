import Foundation
import Testing
@testable import BetBaconer

@Suite(.serialized)
struct TheOddsAPIServiceTests {
    @Test
    func testOverUnderKeepsQuotesOnSelectedLine() async throws {
        OddsAPIURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("apiKey=test-key") == true)
            return Self.response("""
            [
              {
                "home_team": "Team A",
                "away_team": "Team B",
                "bookmakers": [
                  { "markets": [
                    { "key": "totals", "outcomes": [
                      { "name": "Over", "price": 1.70, "point": 2.5 },
                      { "name": "Under", "price": 2.10, "point": 2.5 },
                      { "name": "Over", "price": 2.80, "point": 3.5 },
                      { "name": "Under", "price": 1.40, "point": 3.5 }
                    ] }
                  ] },
                  { "markets": [
                    { "key": "totals", "outcomes": [
                      { "name": "Over", "price": 1.90, "point": 2.5 },
                      { "name": "Under", "price": 1.95, "point": 2.5 }
                    ] }
                  ] }
                ]
              }
            ]
            """)
        }
        defer { OddsAPIURLProtocol.handler = nil }

        let service = TheOddsAPIService(apiKey: "test-key", session: Self.session())
        let odds = try await service.fetchAllMarketOdds().overUnder

        XCTAssertEqual(odds.count, 1)
        let odd = try XCTUnwrap(odds.first)
        XCTAssertEqual(odd.line, 2.5)
        XCTAssertEqual(odd.overQuote, "1.80")
        XCTAssertEqual(odd.underQuote, "2.03")
    }

    @Test
    func testHandicapKeepsHomeAndAwayOnSameLine() async throws {
        OddsAPIURLProtocol.handler = { _ in
            Self.response("""
            [
              {
                "home_team": "Team A",
                "away_team": "Team B",
                "bookmakers": [
                  { "markets": [
                    { "key": "asian_handicap", "outcomes": [
                      { "name": "Team A", "price": 1.91, "point": -0.5 },
                      { "name": "Team B", "price": 1.91, "point": 0.5 },
                      { "name": "Team A", "price": 2.25, "point": -1.5 },
                      { "name": "Team B", "price": 1.65, "point": 1.5 }
                    ] }
                  ] },
                  { "markets": [
                    { "key": "asian_handicap", "outcomes": [
                      { "name": "Team A", "price": 1.85, "point": -0.5 },
                      { "name": "Team B", "price": 1.98, "point": 0.5 }
                    ] }
                  ] }
                ]
              }
            ]
            """)
        }
        defer { OddsAPIURLProtocol.handler = nil }

        let service = TheOddsAPIService(apiKey: "test-key", session: Self.session())
        let odds = try await service.fetchAllMarketOdds().handicap

        XCTAssertEqual(odds.count, 1)
        let odd = try XCTUnwrap(odds.first)
        XCTAssertEqual(odd.homeHandicap, -0.5)
        XCTAssertEqual(odd.homeQuote, "1.88")
        XCTAssertEqual(odd.awayHandicap, 0.5)
        XCTAssertEqual(odd.awayQuote, "1.94")
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OddsAPIURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(_ body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: URL(string: "https://api.the-odds-api.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }
}

private final class OddsAPIURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
