import Foundation

enum WeatherServiceError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Open-Meteo hat eine unerwartete Antwort geliefert."
        }
    }
}

struct WeatherService: Sendable {
    private let session: URLSession

    init(session: URLSession = NetworkSessionFactory.makeDefaultSession()) {
        self.session = session
    }

    func fetchWeather(for upcomingMatches: [UpcomingMatch], teamMetadata: [TeamMetadata]) async throws -> [MatchWeather] {
        let metadataByTeam = Dictionary(uniqueKeysWithValues: teamMetadata.map { (normalizeTeamName($0.teamName), $0) })
        var weatherEntries: [MatchWeather] = []

        for match in upcomingMatches {
            guard let kickoff = parseDate(match.datum) else { continue }
            let normalizedHomeTeam = normalizeTeamName(match.heim)
            guard let metadata = metadataByTeam[normalizedHomeTeam] else { continue }

            let searchQuery = buildLocationQuery(for: metadata)
            guard let location = try await geocodeLocation(searchQuery) else { continue }
            guard let forecast = try await fetchForecast(latitude: location.latitude, longitude: location.longitude, at: kickoff) else { continue }

            weatherEntries.append(
                MatchWeather(
                    heim: match.heim,
                    gast: match.gast,
                    locationName: location.displayName,
                    kickoff: match.datum,
                    temperatureCelsius: forecast.temperatureCelsius,
                    precipitationMillimeters: forecast.precipitationMillimeters,
                    precipitationProbability: forecast.precipitationProbability,
                    windSpeedKmh: forecast.windSpeedKmh,
                    weatherCode: forecast.weatherCode
                )
            )
        }

        return weatherEntries
    }

    private func buildLocationQuery(for metadata: TeamMetadata) -> String {
        if !metadata.stadiumLocation.isEmpty {
            return metadata.stadiumLocation
        }
        if !metadata.stadiumName.isEmpty {
            return metadata.stadiumName
        }
        return metadata.teamName
    }

    private func geocodeLocation(_ query: String) async throws -> GeocodedLocation? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            .init(name: "name", value: query),
            .init(name: "count", value: "1"),
            .init(name: "language", value: "de"),
            .init(name: "countryCode", value: "DE"),
        ]

        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw WeatherServiceError.invalidResponse
        }

        let payload = try JSONDecoder().decode(GeocodingResponse.self, from: data)
        guard let result = payload.results?.first else { return nil }
        return GeocodedLocation(
            latitude: result.latitude,
            longitude: result.longitude,
            displayName: [result.name, result.admin1, result.country]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private func fetchForecast(latitude: Double, longitude: Double, at date: Date) async throws -> ForecastPoint? {
        let hourFormatter = ISO8601DateFormatter()
        hourFormatter.formatOptions = [.withInternetDateTime]

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let hourKey = String(hourFormatter.string(from: date).prefix(13)) + ":00"
        let dateKey = dateFormatter.string(from: date)

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "hourly", value: "temperature_2m,precipitation,precipitation_probability,wind_speed_10m,weather_code"),
            .init(name: "timezone", value: "Europe/Berlin"),
            .init(name: "start_date", value: dateKey),
            .init(name: "end_date", value: dateKey),
        ]

        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw WeatherServiceError.invalidResponse
        }

        let payload = try JSONDecoder().decode(ForecastResponse.self, from: data)
        guard let hourly = payload.hourly else { return nil }
        guard let index = hourly.time.firstIndex(of: hourKey) else { return nil }

        return ForecastPoint(
            temperatureCelsius: hourly.temperature2m[safe: index],
            precipitationMillimeters: hourly.precipitation[safe: index],
            precipitationProbability: hourly.precipitationProbability[safe: index],
            windSpeedKmh: hourly.windSpeed10m[safe: index],
            weatherCode: hourly.weatherCode[safe: index]
        )
    }

    private func parseDate(_ raw: String) -> Date? {
        Self.makeISO8601Formatter(withFractionalSeconds: true).date(from: raw)
            ?? Self.makeISO8601Formatter(withFractionalSeconds: false).date(from: raw)
    }

    private func normalizeTeamName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let lowered = folded.lowercased()
        let allowedScalars = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let compact = String(String.UnicodeScalarView(allowedScalars))
        let aliases: [String: String] = [
            "borussiamonchengladbach": "monchengladbach",
            "bormonchengladbach": "monchengladbach",
            "tsghoffenheim": "hoffenheim",
            "1899hoffenheim": "hoffenheim",
            "svwerderbremen": "werderbremen",
            "werderbremen": "werderbremen",
            "1fsvmainz05": "mainz05",
            "fsvmainz05": "mainz05",
            "1fcunionberlin": "unionberlin",
            "unionberlin": "unionberlin",
            "fcbayernmunchen": "bayernmunchen",
            "bayernmunchen": "bayernmunchen",
        ]
        return aliases[compact] ?? compact
    }

    private static func makeISO8601Formatter(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

private struct GeocodedLocation {
    let latitude: Double
    let longitude: Double
    let displayName: String
}

private struct ForecastPoint {
    let temperatureCelsius: Double?
    let precipitationMillimeters: Double?
    let precipitationProbability: Int?
    let windSpeedKmh: Double?
    let weatherCode: Int?
}

private struct GeocodingResponse: Decodable {
    let results: [GeocodingResult]?
}

private struct GeocodingResult: Decodable {
    let name: String?
    let admin1: String?
    let country: String?
    let latitude: Double
    let longitude: Double
}

private struct ForecastResponse: Decodable {
    let hourly: HourlyForecast?
}

private struct HourlyForecast: Decodable {
    let time: [String]
    let temperature2m: [Double]
    let precipitation: [Double]
    let precipitationProbability: [Int]
    let windSpeed10m: [Double]
    let weatherCode: [Int]

    private enum CodingKeys: String, CodingKey {
        case time
        case temperature2m = "temperature_2m"
        case precipitation
        case precipitationProbability = "precipitation_probability"
        case windSpeed10m = "wind_speed_10m"
        case weatherCode = "weather_code"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
