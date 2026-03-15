import Foundation

enum TheSportsDBError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "TheSportsDB hat eine unerwartete Antwort geliefert."
        }
    }
}

struct TheSportsDBService: Sendable {
    private let session: URLSession

    init(session: URLSession = NetworkSessionFactory.makeDefaultSession()) {
        self.session = session
    }

    func fetchBundesligaTeamMetadata() async throws -> [TeamMetadata] {
        var components = URLComponents(string: "https://www.thesportsdb.com/api/v1/json/123/search_all_teams.php")!
        components.queryItems = [
            .init(name: "l", value: "German Bundesliga")
        ]

        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw TheSportsDBError.invalidResponse
        }

        let payload = try JSONDecoder().decode(TeamSearchResponse.self, from: data)
        return (payload.teams ?? []).map {
            TeamMetadata(
                teamName: $0.teamName ?? "",
                teamShortName: $0.teamShortName ?? "",
                stadiumName: $0.stadiumName ?? "",
                stadiumLocation: $0.stadiumLocation ?? "",
                country: $0.country ?? ""
            )
        }
        .filter { !$0.teamName.isEmpty }
    }
}

private struct TeamSearchResponse: Decodable {
    let teams: [TeamSearchItem]?
}

private struct TeamSearchItem: Decodable {
    let teamName: String?
    let teamShortName: String?
    let stadiumName: String?
    let stadiumLocation: String?
    let country: String?

    private enum CodingKeys: String, CodingKey {
        case teamName = "strTeam"
        case teamShortName = "strTeamShort"
        case stadiumName = "strStadium"
        case stadiumLocation = "strStadiumLocation"
        case country = "strCountry"
    }
}
