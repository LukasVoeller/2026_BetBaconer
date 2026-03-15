import Foundation

enum OpenLigaDBError: LocalizedError {
    case invalidResponse
    case noOpenMatchday

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenLigaDB hat eine unerwartete Antwort geliefert."
        case .noOpenMatchday:
            return "Kein offener Spieltag gefunden."
        }
    }
}

struct OpenLigaDBService {
    private let session: URLSession

    init(session: URLSession = NetworkSessionFactory.makeDefaultSession()) {
        self.session = session
    }

    func fetchSeason(season: Int) async throws -> ([FinishedMatch], Int, [UpcomingMatch]) {
        let url = URL(string: "https://api.openligadb.de/getmatchdata/bl1/\(season)")!
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw OpenLigaDBError.invalidResponse
        }

        let matches = try decodeMatches(from: data)
        let finishedResults = finishedMatches(from: matches)
        let upcomingMatches = upcomingMatches(from: matches)

        guard let nextSpieltag = upcomingMatches.map(\.spieltag).min() else {
            throw OpenLigaDBError.noOpenMatchday
        }

        let currentMatchdayUpcoming = upcomingMatches
            .filter { $0.spieltag == nextSpieltag }
            .sorted { ($0.datum, $0.heim) < ($1.datum, $1.heim) }

        return (finishedResults, nextSpieltag, currentMatchdayUpcoming)
    }

    func fetchFinishedMatches(season: Int) async throws -> [FinishedMatch] {
        let url = URL(string: "https://api.openligadb.de/getmatchdata/bl1/\(season)")!
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw OpenLigaDBError.invalidResponse
        }

        let matches = try decodeMatches(from: data)
        return finishedMatches(from: matches)
    }

    private func decodeMatches(from data: Data) throws -> [OpenLigaMatch] {
        try JSONDecoder().decode([OpenLigaMatch].self, from: data)
    }

    private func finishedMatches(from matches: [OpenLigaMatch]) -> [FinishedMatch] {
        matches.compactMap { match -> FinishedMatch? in
            guard match.matchIsFinished,
                  let result = match.matchResults.first(where: { $0.resultTypeID == 2 }) else {
                return nil
            }

            return FinishedMatch(
                spieltag: match.group.groupOrderID,
                datum: match.matchDateTime,
                heim: match.team1.teamName,
                gast: match.team2.teamName,
                toreHeim: result.pointsTeam1,
                toreGast: result.pointsTeam2
            )
        }
        .sorted { lhs, rhs in
            (lhs.spieltag, lhs.datum, lhs.heim) < (rhs.spieltag, rhs.datum, rhs.heim)
        }
    }

    private func upcomingMatches(from matches: [OpenLigaMatch]) -> [UpcomingMatch] {
        matches.compactMap { match -> UpcomingMatch? in
            guard !match.matchIsFinished else { return nil }
            return UpcomingMatch(
                spieltag: match.group.groupOrderID,
                datum: match.matchDateTime,
                heim: match.team1.teamName,
                gast: match.team2.teamName
            )
        }
    }
}

private struct OpenLigaMatch: Decodable {
    let matchIsFinished: Bool
    let matchDateTime: String
    let group: MatchGroup
    let team1: Team
    let team2: Team
    let matchResults: [MatchResult]
}

private struct MatchGroup: Decodable {
    let groupOrderID: Int
}

private struct Team: Decodable {
    let teamName: String
}

private struct MatchResult: Decodable {
    let resultTypeID: Int
    let pointsTeam1: Int
    let pointsTeam2: Int
}
