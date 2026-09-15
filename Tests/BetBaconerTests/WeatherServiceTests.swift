import Foundation
import Testing
@testable import BetBaconer

final class WeatherServiceTests {

    @Test
    func testFetchWeatherMatchesOpenMeteoLocalHour() async throws {
        MockURLProtocol.handler = { request in
            let url = request.url!
            let body: String
            if url.host == "geocoding-api.open-meteo.com" {
                body = #"{"results":[{"name":"Berlin","admin1":"Berlin","country":"Deutschland","latitude":52.52,"longitude":13.41}]}"#
            } else {
                XCTAssertTrue(url.absoluteString.contains("timezone=Europe/Berlin"))
                body = #"{"hourly":{"time":["2026-09-18T20:00"],"temperature_2m":[14.5],"precipitation":[0.2],"precipitation_probability":[30],"wind_speed_10m":[12.0],"weather_code":[3]}}"#
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let service = WeatherService(session: URLSession(configuration: configuration))

        let weather = try await service.fetchWeather(
            for: [
                UpcomingMatch(spieltag: 4, datum: "2026-09-18T20:30:00", heim: "Team A", gast: "Team B")
            ],
            teamMetadata: [
                TeamMetadata(teamName: "Team A", teamShortName: "", stadiumName: "", stadiumLocation: "Berlin", country: "Germany")
            ]
        )

        XCTAssertEqual(weather.count, 1)
        XCTAssertEqual(weather.first?.temperatureCelsius, 14.5)
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
