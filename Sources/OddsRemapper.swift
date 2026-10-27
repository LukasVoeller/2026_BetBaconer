import Foundation

/// Aligns odds from external sources (different team spellings) to the OpenLigaDB fixtures.
/// Each source entry is used at most once, so two fixtures can never share one quote.
enum OddsRemapper {
    static func remapOverUnderToUpcomingMatches(_ source: [OverUnderOdds], upcomingMatches: [UpcomingMatch]) -> [OverUnderOdds] {
        var remaining = source
        return upcomingMatches.compactMap { match in
            guard let index = remaining.firstIndex(where: {
                teamNamesLikelyMatch($0.heim, match.heim) && teamNamesLikelyMatch($0.gast, match.gast)
            }) else { return nil }
            let odds = remaining.remove(at: index)
            return OverUnderOdds(heim: match.heim, gast: match.gast, line: odds.line, overQuote: odds.overQuote, underQuote: odds.underQuote)
        }
    }

    static func remapBTTSToUpcomingMatches(_ source: [BTTSOdds], upcomingMatches: [UpcomingMatch]) -> [BTTSOdds] {
        var remaining = source
        return upcomingMatches.compactMap { match in
            guard let index = remaining.firstIndex(where: {
                teamNamesLikelyMatch($0.heim, match.heim) && teamNamesLikelyMatch($0.gast, match.gast)
            }) else { return nil }
            let odds = remaining.remove(at: index)
            return BTTSOdds(heim: match.heim, gast: match.gast, yesQuote: odds.yesQuote, noQuote: odds.noQuote)
        }
    }

    static func remapHandicapToUpcomingMatches(_ source: [HandicapOdds], upcomingMatches: [UpcomingMatch]) -> [HandicapOdds] {
        var remaining = source
        return upcomingMatches.compactMap { match in
            guard let index = remaining.firstIndex(where: {
                teamNamesLikelyMatch($0.heim, match.heim) && teamNamesLikelyMatch($0.gast, match.gast)
            }) else { return nil }
            let odds = remaining.remove(at: index)
            return HandicapOdds(heim: match.heim, gast: match.gast, homeHandicap: odds.homeHandicap, homeQuote: odds.homeQuote, awayHandicap: odds.awayHandicap, awayQuote: odds.awayQuote)
        }
    }

    static func remapOddsToUpcomingMatches(_ sourceOdds: [BettingOdds], upcomingMatches: [UpcomingMatch]) -> [BettingOdds] {
        var remainingOdds = sourceOdds

        return upcomingMatches.compactMap { match in
            guard let index = remainingOdds.firstIndex(where: {
                teamNamesLikelyMatch($0.heim, match.heim) && teamNamesLikelyMatch($0.gast, match.gast)
            }) else {
                return nil
            }

            let odds = remainingOdds.remove(at: index)
            return BettingOdds(
                heim: match.heim,
                gast: match.gast,
                quoteHeim: odds.quoteHeim,
                quoteUnentschieden: odds.quoteUnentschieden,
                quoteGast: odds.quoteGast
            )
        }
    }
}
