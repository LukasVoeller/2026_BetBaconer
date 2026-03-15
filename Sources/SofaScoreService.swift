import Foundation

struct SofaScoreService {
    private let session: URLSession

    init(session: URLSession = NetworkSessionFactory.makeDefaultSession()) {
        self.session = session
    }

    func fetchAbsences() async throws -> [PlayerAbsence] {
        // 1. Aktuelle Saison-ID holen
        let seasonId = try await fetchCurrentSeasonId()

        // 2. Nächste Spieltag-Events holen
        let events = try await fetchNextEvents(seasonId: seasonId)
        guard !events.isEmpty else { return [] }

        // 3. Pro Event fehlende Spieler aus Lineups holen
        var seen = Set<String>()
        var absences: [PlayerAbsence] = []

        for event in events {
            let entries = (try? await fetchMissingPlayers(for: event)) ?? []
            for (playerName, teamName, type, reason) in entries {
                let key = "\(playerName)-\(teamName)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                absences.append(PlayerAbsence(playerName: playerName, teamName: teamName, type: type, reason: reason))
            }
        }
        return absences
    }

    // MARK: - Private

    private func fetchCurrentSeasonId() async throws -> Int {
        let data = try await get("https://api.sofascore.com/api/v1/unique-tournament/35/seasons")
        let decoded = try JSONDecoder().decode(SeasonsResponse.self, from: data)
        guard let first = decoded.seasons.first else {
            throw URLError(.badServerResponse)
        }
        return first.id
    }

    private func fetchNextEvents(seasonId: Int) async throws -> [SofaEvent] {
        let data = try await get("https://api.sofascore.com/api/v1/unique-tournament/35/season/\(seasonId)/events/next/0")
        let decoded = try JSONDecoder().decode(EventsResponse.self, from: data)
        return decoded.events
    }

    private func fetchMissingPlayers(for event: SofaEvent) async throws -> [(String, String, String, String)] {
        let data = try await get("https://api.sofascore.com/api/v1/event/\(event.id)/lineups")
        let decoded = try JSONDecoder().decode(LineupsResponse.self, from: data)

        var result: [(playerName: String, teamName: String, type: String, reason: String)] = []

        for (side, teamName) in [(decoded.home, event.homeTeam.name), (decoded.away, event.awayTeam.name)] {
            for entry in side.missingPlayers {
                let descLower = (entry.description ?? "").lowercased()
                let type: String
                if descLower.contains("red") {
                    type = "Sperre (Rote Karte)"
                } else if entry.reason == 11 || descLower.contains("yellow") || descLower.contains("card") || descLower.contains("suspension") {
                    type = "Sperre (Gelbe Karte)"
                } else {
                    type = "Verletzung"
                }
                let reasonText = entry.description ?? ""
                result.append((entry.player.name, teamName, type, reasonText))
            }
        }
        return result
    }

    private func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.sofascore.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Decodable models

private struct SeasonsResponse: Decodable {
    let seasons: [SofaSeason]
}
private struct SofaSeason: Decodable {
    let id: Int
    let name: String
}

private struct EventsResponse: Decodable {
    let events: [SofaEvent]
}
struct SofaEvent: Decodable {
    let id: Int
    let homeTeam: SofaTeam
    let awayTeam: SofaTeam
}
struct SofaTeam: Decodable {
    let name: String
}

private struct LineupsResponse: Decodable {
    let home: LineupSide
    let away: LineupSide
}
private struct LineupSide: Decodable {
    let missingPlayers: [MissingPlayer]

    private enum CodingKeys: String, CodingKey { case missingPlayers }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        missingPlayers = (try? container.decode([MissingPlayer].self, forKey: .missingPlayers)) ?? []
    }
}
private struct MissingPlayer: Decodable {
    let player: SofaPlayer
    let type: String
    let reason: Int
    let description: String?
}
private struct SofaPlayer: Decodable {
    let name: String
}
