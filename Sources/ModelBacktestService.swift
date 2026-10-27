import Foundation

struct ModelBacktestReport: Equatable {
    struct WeightResult: Equatable {
        let marketWeight: Double
        let pointsPerTip: Double
    }

    let ratingPointsPerTip: Double
    let favoritePointsPerTip: Double
    let ratingMatches: Int
    let marketResults: [WeightResult]
    let marketMatches: Int
    /// Only set when the odds archive holds enough matches for a reliable choice.
    let bestMarketWeight: Double?

    var summary: String {
        var lines = [
            String(format: "Statistik-Modell (Walk-forward, %d Spiele): %.3f Punkte/Tipp", ratingMatches, ratingPointsPerTip),
            String(format: "Faustregel Favorit 2:1/1:2: %.3f Punkte/Tipp", favoritePointsPerTip),
        ]
        if marketMatches > 0 {
            lines.append("Quoten-Archiv (\(marketMatches) Spiele), Punkte/Tipp je Marktgewicht:")
            lines += marketResults.map { String(format: "  Markt %.0f%%: %.3f", $0.marketWeight * 100, $0.pointsPerTip) }
        }
        if let bestMarketWeight {
            lines.append(String(format: "Gelerntes Marktgewicht: %.0f%%", bestMarketWeight * 100))
        } else {
            lines.append("Marktgewicht: Standard \(Int(ModelBacktestService.defaultMarketWeight * 100))% (ab \(ModelBacktestService.minimumMarketMatches) archivierten Spielen wird es gelernt)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Walk-forward backtests: every matchday is predicted only from matches played before it.
struct ModelBacktestService: Sendable {
    static let defaultMarketWeight = 0.8
    static let minimumMarketMatches = 45
    static let marketWeights = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }

    var rules: KicktippRules = .standard
    var ratingService = TeamRatingService()

    /// - Parameter seasons: finished matches per season start year (e.g. 2023 = 2023/24).
    func run(seasons: [Int: [FinishedMatch]], oddsArchive: [ArchivedOdds], evaluatedSeasons: ClosedRange<Int>) -> ModelBacktestReport {
        let ensemble = EnsembleService(rules: rules)
        var ratingPoints = 0.0, favoritePoints = 0.0, ratingCount = 0
        var marketPoints = [Double](repeating: 0, count: Self.marketWeights.count), marketCount = 0
        let archive = Dictionary(oddsArchive.map { ("\($0.season)|\($0.spieltag)|\(normalizedTeamKey($0.heim, $0.gast))", $0) }, uniquingKeysWith: { _, latest in latest })

        for season in evaluatedSeasons {
            guard let seasonMatches = seasons[season] else { continue }
            let previousTeams = Set((seasons[season - 1] ?? []).flatMap { [normalizeTeamName($0.heim), normalizeTeamName($0.gast)] })
            let currentTeams = Set(seasonMatches.flatMap { [normalizeTeamName($0.heim), normalizeTeamName($0.gast)] })
            let history = (seasons[season - 2] ?? []) + (seasons[season - 1] ?? [])

            for spieltag in 1...KicktippCommunityService.matchdaysPerSeason {
                let target = seasonMatches.filter { $0.spieltag == spieltag }
                guard let kickoff = target.compactMap({ parseKickoffDate($0.datum) }).min() else { continue }
                let played = seasonMatches.filter { parseKickoffDate($0.datum).map { $0 < kickoff } ?? false }
                var counts: [String: Int] = [:]
                for match in played {
                    counts[normalizeTeamName(match.heim), default: 0] += 1
                    counts[normalizeTeamName(match.gast), default: 0] += 1
                }
                guard let model = ratingService.fit(
                    matches: history + played,
                    promotedTeams: previousTeams.isEmpty ? [] : currentTeams.subtracting(previousTeams),
                    currentSeasonMatchCounts: counts,
                    referenceDate: kickoff
                ) else { continue }

                for match in target {
                    guard let rating = model.expectedGoals(homeTeam: match.heim, awayTeam: match.gast) else { continue }
                    let upcoming = UpcomingMatch(spieltag: spieltag, datum: match.datum, heim: match.heim, gast: match.gast)
                    let ratingModel = ensemble.probabilityModel(for: upcoming, homeExpectedGoals: rating.home, awayExpectedGoals: rating.away, drawCalibration: 0, odds: nil)
                    ratingPoints += points(ratingModel.selectedScoreline, match)
                    favoritePoints += points(ratingModel.probabilityHomeWin >= ratingModel.probabilityAwayWin ? (2, 1) : (1, 2), match)
                    ratingCount += 1

                    guard let odds = archive["\(season)|\(spieltag)|\(normalizedTeamKey(match.heim, match.gast))"],
                          let market = MarketModel.expectedGoals(odds: odds.bettingOdds, total: Self.overUnderTotal(odds)) else { continue }
                    for (index, weight) in Self.marketWeights.enumerated() {
                        let blended = Self.blend(rating: rating, market: market, marketWeight: weight)
                        let model = ensemble.probabilityModel(for: upcoming, homeExpectedGoals: blended.home, awayExpectedGoals: blended.away, drawCalibration: 0, odds: nil)
                        marketPoints[index] += points(model.selectedScoreline, match)
                    }
                    marketCount += 1
                }
            }
        }

        let marketResults = marketCount == 0 ? [] : zip(Self.marketWeights, marketPoints).map {
            ModelBacktestReport.WeightResult(marketWeight: $0, pointsPerTip: $1 / Double(marketCount))
        }
        let best = marketCount >= Self.minimumMarketMatches
            ? marketResults.max { ($0.pointsPerTip, $0.marketWeight) < ($1.pointsPerTip, $1.marketWeight) }?.marketWeight
            : nil
        return ModelBacktestReport(
            ratingPointsPerTip: ratingCount == 0 ? 0 : ratingPoints / Double(ratingCount),
            favoritePointsPerTip: ratingCount == 0 ? 0 : favoritePoints / Double(ratingCount),
            ratingMatches: ratingCount,
            marketResults: marketResults,
            marketMatches: marketCount,
            bestMarketWeight: best
        )
    }

    /// Geometric blend of expected goals (blending in log space keeps the ratio between the teams intact).
    static func blend(rating: (home: Double, away: Double), market: (home: Double, away: Double), marketWeight: Double) -> (home: Double, away: Double) {
        (
            exp(marketWeight * log(market.home) + (1 - marketWeight) * log(rating.home)),
            exp(marketWeight * log(market.away) + (1 - marketWeight) * log(rating.away))
        )
    }

    static func overUnderTotal(_ odds: ArchivedOdds) -> Double? {
        guard let line = odds.overUnderLine, let over = odds.overQuote, let under = odds.underQuote else { return nil }
        return MarketModel.totalGoals(line: line, overQuote: over, underQuote: under)
    }

    private func points(_ tip: (home: Int, away: Int), _ match: FinishedMatch) -> Double {
        rules.points(predictedHome: tip.home, predictedAway: tip.away, actualHome: match.toreHeim, actualAway: match.toreGast)
    }
}
