import Foundation

enum TheOddsAPIError: LocalizedError {
    case missingKey
    case invalidResponse
    case apiError(statusCode: Int, code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Kein The-Odds-API-Key hinterlegt."
        case .invalidResponse:
            return "The Odds API hat eine unerwartete Antwort geliefert."
        case let .apiError(statusCode, code, message):
            if let code, !code.isEmpty {
                return "The Odds API Fehler \(statusCode) (\(code)): \(message)"
            }
            return "The Odds API Fehler \(statusCode): \(message)"
        }
    }
}

struct TheOddsAPIService {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = NetworkSessionFactory.makeDefaultSession()) {
        self.apiKey = apiKey
        self.session = session
    }

    func fetchAllMarketOdds() async throws -> (h2h: [BettingOdds], overUnder: [OverUnderOdds], btts: [BTTSOdds], handicap: [HandicapOdds]) {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TheOddsAPIError.missingKey
        }

        var components = URLComponents(string: "https://api.the-odds-api.com/v4/sports/soccer_germany_bundesliga/odds")!
        components.queryItems = [
            .init(name: "apiKey", value: apiKey),
            .init(name: "regions", value: "eu,uk"),
            .init(name: "markets", value: "h2h,totals,btts,asian_handicap"),
            .init(name: "oddsFormat", value: "decimal"),
        ]

        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TheOddsAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(OddsAPIErrorPayload.self, from: data)
            let message = apiError?.message ?? String(data: data, encoding: .utf8) ?? "Unbekannte Antwort"
            throw TheOddsAPIError.apiError(
                statusCode: httpResponse.statusCode,
                code: apiError?.errorCode,
                message: message
            )
        }

        let events = try JSONDecoder().decode([OddsEvent].self, from: data)

        let h2h: [BettingOdds] = events.compactMap { event in
            guard let marketOdds = aggregatedMarketOdds(for: event) else { return nil }
            return BettingOdds(
                heim: event.homeTeam,
                gast: event.awayTeam,
                quoteHeim: marketOdds.quoteHeim,
                quoteUnentschieden: marketOdds.quoteUnentschieden,
                quoteGast: marketOdds.quoteGast
            )
        }

        let overUnder: [OverUnderOdds] = events.compactMap { aggregatedOverUnder(for: $0) }
        let btts: [BTTSOdds] = events.compactMap { aggregatedBTTS(for: $0) }
        let handicap: [HandicapOdds] = events.compactMap { aggregatedHandicap(for: $0) }

        return (h2h: h2h, overUnder: overUnder, btts: btts, handicap: handicap)
    }

    private func aggregatedMarketOdds(for event: OddsEvent) -> MarketOdds? {
        var homePrices: [Double] = []
        var drawPrices: [Double] = []
        var awayPrices: [Double] = []

        for bookmaker in event.bookmakers {
            guard let market = bookmaker.markets.first(where: { $0.key == "h2h" }) else { continue }
            for outcome in market.outcomes {
                if teamNamesLikelyMatch(outcome.name, event.homeTeam) {
                    homePrices.append(outcome.price)
                } else if teamNamesLikelyMatch(outcome.name, event.awayTeam) {
                    awayPrices.append(outcome.price)
                } else if outcome.name.caseInsensitiveCompare("Draw") == .orderedSame {
                    drawPrices.append(outcome.price)
                }
            }
        }

        guard let home = median(homePrices),
              let draw = median(drawPrices),
              let away = median(awayPrices) else {
            return nil
        }

        return MarketOdds(
            quoteHeim: format(decimal: home),
            quoteUnentschieden: format(decimal: draw),
            quoteGast: format(decimal: away)
        )
    }

    private func aggregatedOverUnder(for event: OddsEvent) -> OverUnderOdds? {
        var overPrices: [Double] = []
        var underPrices: [Double] = []
        var linePrices: [Double] = []

        for bookmaker in event.bookmakers {
            guard let market = bookmaker.markets.first(where: { $0.key == "totals" }) else { continue }
            for outcome in market.outcomes {
                let point = outcome.point ?? 2.5
                linePrices.append(point)
                if outcome.name.lowercased() == "over" {
                    overPrices.append(outcome.price)
                } else if outcome.name.lowercased() == "under" {
                    underPrices.append(outcome.price)
                }
            }
        }

        guard let over = median(overPrices), let under = median(underPrices) else { return nil }
        let line = median(linePrices) ?? 2.5
        return OverUnderOdds(
            heim: event.homeTeam,
            gast: event.awayTeam,
            line: line,
            overQuote: format(decimal: over),
            underQuote: format(decimal: under)
        )
    }

    private func aggregatedBTTS(for event: OddsEvent) -> BTTSOdds? {
        var yesPrices: [Double] = []
        var noPrices: [Double] = []

        for bookmaker in event.bookmakers {
            guard let market = bookmaker.markets.first(where: { $0.key == "btts" }) else { continue }
            for outcome in market.outcomes {
                if outcome.name.lowercased() == "yes" {
                    yesPrices.append(outcome.price)
                } else if outcome.name.lowercased() == "no" {
                    noPrices.append(outcome.price)
                }
            }
        }

        guard let yes = median(yesPrices), let no = median(noPrices) else { return nil }
        return BTTSOdds(
            heim: event.homeTeam,
            gast: event.awayTeam,
            yesQuote: format(decimal: yes),
            noQuote: format(decimal: no)
        )
    }

    private func aggregatedHandicap(for event: OddsEvent) -> HandicapOdds? {
        var homePrices: [Double] = []
        var awayPrices: [Double] = []
        var homePoints: [Double] = []
        var awayPoints: [Double] = []

        for bookmaker in event.bookmakers {
            guard let market = bookmaker.markets.first(where: { $0.key == "asian_handicap" }) else { continue }
            for outcome in market.outcomes {
                if teamNamesLikelyMatch(outcome.name, event.homeTeam) {
                    homePrices.append(outcome.price)
                    if let point = outcome.point { homePoints.append(point) }
                } else if teamNamesLikelyMatch(outcome.name, event.awayTeam) {
                    awayPrices.append(outcome.price)
                    if let point = outcome.point { awayPoints.append(point) }
                }
            }
        }

        guard let homeQuote = median(homePrices), let awayQuote = median(awayPrices) else { return nil }
        let homeHandicap = median(homePoints) ?? 0
        let awayHandicap = median(awayPoints) ?? 0
        return HandicapOdds(
            heim: event.homeTeam,
            gast: event.awayTeam,
            homeHandicap: homeHandicap,
            homeQuote: format(decimal: homeQuote),
            awayHandicap: awayHandicap,
            awayQuote: format(decimal: awayQuote)
        )
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func format(decimal: Double) -> String {
        let rounded = (decimal * 100).rounded() / 100
        return String(format: "%.2f", rounded)
    }
}

private struct OddsEvent: Decodable {
    let homeTeam: String
    let awayTeam: String
    let bookmakers: [OddsBookmaker]

    private enum CodingKeys: String, CodingKey {
        case homeTeam = "home_team"
        case awayTeam = "away_team"
        case bookmakers
    }
}

private struct OddsBookmaker: Decodable {
    let markets: [OddsMarket]
}

private struct OddsMarket: Decodable {
    let key: String
    let outcomes: [OddsOutcome]
}

private struct OddsOutcome: Decodable {
    let name: String
    let price: Double
    let point: Double?
}

private struct MarketOdds {
    let quoteHeim: String
    let quoteUnentschieden: String
    let quoteGast: String
}

private struct OddsAPIErrorPayload: Decodable {
    let message: String?
    let errorCode: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case errorCode = "error_code"
    }
}
