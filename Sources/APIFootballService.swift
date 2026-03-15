import Foundation

enum APIFootballError: LocalizedError {
    case missingKey
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:    return "Kein API-Football Key hinterlegt."
        case .invalidResponse: return "API-Football hat eine unerwartete Antwort geliefert."
        }
    }
}

struct PlayerAbsence: Identifiable, Hashable {
    let playerName: String
    let teamName: String
    let type: String   // "Verletzung" | "Sperre" | "Sonstiges"
    let reason: String

    var id: String { "\(playerName)-\(teamName)" }
}

struct APIFootballService {
    private let apiKey: String
    private let session: URLSession
    private let bundesligaLeagueID = "78"

    init(apiKey: String, session: URLSession = NetworkSessionFactory.makeDefaultSession()) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Lädt Verletzungen & Sperren für den nächsten Spieltag.
    /// Schritt 1: nächste Fixtures holen → Schritt 2: Injuries pro Fixture abfragen.
    func fetchAbsences(season: Int) async throws -> [PlayerAbsence] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIFootballError.missingKey
        }

        // 1. Nächste Fixtures für Bundesliga (max. 9 = ein Spieltag)
        let fixtureIDs = try await fetchNextFixtureIDs(season: season, next: 9)
        guard !fixtureIDs.isEmpty else { return [] }

        // 2. Injuries pro Fixture, dedupliziert nach Spieler
        var seen = Set<String>()
        var absences: [PlayerAbsence] = []
        for fixtureID in fixtureIDs {
            let entries = try await fetchInjuriesForFixture(fixtureID: fixtureID)
            for entry in entries {
                let key = "\(entry.player.name)-\(entry.team.name)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)

                let type: String
                let lower = entry.type.lowercased()
                if lower.contains("suspension") || lower.contains("card") {
                    type = "Sperre"
                } else if lower.contains("missing") || lower.contains("injur") {
                    type = "Verletzung"
                } else {
                    type = "Sonstiges"
                }

                absences.append(PlayerAbsence(
                    playerName: entry.player.name,
                    teamName: entry.team.name,
                    type: type,
                    reason: entry.reason ?? ""
                ))
            }
        }
        return absences
    }

    func fetchOdds(season: Int, next: Int = 9) async throws -> [BettingOdds] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIFootballError.missingKey
        }

        let fixtures = try await fetchNextFixtures(season: season, next: next)
        guard !fixtures.isEmpty else { return [] }

        var odds: [BettingOdds] = []
        for fixture in fixtures {
            guard let market = try await fetchMatchWinnerOdds(fixtureID: fixture.fixture.id) else { continue }
            odds.append(
                BettingOdds(
                    heim: fixture.teams.home.name,
                    gast: fixture.teams.away.name,
                    quoteHeim: market.quoteHeim,
                    quoteUnentschieden: market.quoteUnentschieden,
                    quoteGast: market.quoteGast
                )
            )
        }

        return odds
    }

    // MARK: - Private helpers

    private func fetchNextFixtureIDs(season: Int, next: Int) async throws -> [Int] {
        let fixtures = try await fetchNextFixtures(season: season, next: next)
        return fixtures.map { $0.fixture.id }
    }

    private func fetchNextFixtures(season: Int, next: Int) async throws -> [FixtureWrapper] {
        var components = URLComponents(string: "https://v3.football.api-sports.io/fixtures")!
        components.queryItems = [
            .init(name: "league", value: bundesligaLeagueID),
            .init(name: "season", value: "\(season)"),
            .init(name: "next", value: "\(next)"),
        ]
        let data = try await get(components.url!)
        let decoded = try JSONDecoder().decode(FixturesResponse.self, from: data)
        return decoded.response
    }

    private func fetchInjuriesForFixture(fixtureID: Int) async throws -> [InjuryEntry] {
        var components = URLComponents(string: "https://v3.football.api-sports.io/injuries")!
        components.queryItems = [
            .init(name: "fixture", value: "\(fixtureID)"),
        ]
        let data = try await get(components.url!)
        let decoded = try JSONDecoder().decode(InjuriesResponse.self, from: data)
        return decoded.response
    }

    private func fetchMatchWinnerOdds(fixtureID: Int) async throws -> MatchWinnerOdds? {
        var components = URLComponents(string: "https://v3.football.api-sports.io/odds")!
        components.queryItems = [
            .init(name: "fixture", value: "\(fixtureID)")
        ]
        let data = try await get(components.url!)
        let decoded = try JSONDecoder().decode(OddsResponse.self, from: data)

        for marketResponse in decoded.response {
            for bookmaker in marketResponse.bookmakers {
                if let market = bookmaker.bets.first(where: isMatchWinnerMarket),
                   let matchWinnerOdds = parseMatchWinnerOdds(from: market.values) {
                    return matchWinnerOdds
                }
            }
        }

        return nil
    }

    private func isMatchWinnerMarket(_ bet: OddsBet) -> Bool {
        let name = bet.name.lowercased()
        return name.contains("match winner") || name == "1x2"
    }

    private func parseMatchWinnerOdds(from values: [OddsValue]) -> MatchWinnerOdds? {
        var home: String?
        var draw: String?
        var away: String?

        for value in values {
            let key = value.value.lowercased()
            if key == "home" || key == "1" {
                home = value.odd
            } else if key == "draw" || key == "x" {
                draw = value.odd
            } else if key == "away" || key == "2" {
                away = value.odd
            }
        }

        guard let home, let draw, let away else { return nil }
        return MatchWinnerOdds(
            quoteHeim: home.replacingOccurrences(of: ",", with: "."),
            quoteUnentschieden: draw.replacingOccurrences(of: ",", with: "."),
            quoteGast: away.replacingOccurrences(of: ",", with: ".")
        )
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-apisports-key")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIFootballError.invalidResponse
        }
        return data
    }
}

// MARK: - Decodable models

private struct FixturesResponse: Decodable {
    let response: [FixtureWrapper]
}

private struct FixtureWrapper: Decodable {
    let fixture: FixtureInfo
    let teams: FixtureTeams
}

private struct FixtureInfo: Decodable {
    let id: Int
}

private struct FixtureTeams: Decodable {
    let home: APITeam
    let away: APITeam
}

private struct InjuriesResponse: Decodable {
    let response: [InjuryEntry]
}

private struct InjuryEntry: Decodable {
    let player: APIPlayer
    let team: APITeam
    let type: String
    let reason: String?
}

private struct APIPlayer: Decodable {
    let name: String
}

private struct APITeam: Decodable {
    let name: String
}

private struct OddsResponse: Decodable {
    let response: [OddsFixtureResponse]
}

private struct OddsFixtureResponse: Decodable {
    let bookmakers: [OddsBookmaker]
}

private struct OddsBookmaker: Decodable {
    let bets: [OddsBet]
}

private struct OddsBet: Decodable {
    let name: String
    let values: [OddsValue]
}

private struct OddsValue: Decodable {
    let value: String
    let odd: String
}

private struct MatchWinnerOdds {
    let quoteHeim: String
    let quoteUnentschieden: String
    let quoteGast: String
}
