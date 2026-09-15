import Foundation

/// Aggregates tips from multiple Codex ensemble runs into a single consensus prediction.
struct EnsembleService {

    // MARK: - Public

    /// Aggregates tips by estimating goals, then selecting the most likely exact
    /// scoreline under a Dixon-Coles adjusted Poisson model.
    func aggregateTips(
        from runs: [[SuggestedTip]],
        upcomingMatches: [UpcomingMatch],
        bettingOdds: [BettingOdds],
        expectedGoals: [String: MatchExpectedGoals] = [:]
    ) throws -> [SuggestedTip] {
        guard !runs.isEmpty else {
            throw TipWorkflowError.invalidModelOutput
        }

        let oddsByKey = remappedOdds(bettingOdds: bettingOdds, upcomingMatches: upcomingMatches)
        var aggregated: [SuggestedTip] = []

        for match in upcomingMatches {
            let candidates = runs.compactMap { run in
                run.first { normalizedTeamKey($0.heim, $0.gast) == normalizedTeamKey(match.heim, match.gast) }
            }

            guard !candidates.isEmpty else {
                throw TipWorkflowError.fixtureMismatch
            }

            let odds = oddsByKey[normalizedTeamKey(match.heim, match.gast)]
            let fallbackExpectedGoals = marketAdjustedExpectedGoals(from: candidates, odds: odds)
            let matchExpectedGoals = expectedGoals[normalizedTeamKey(match.heim, match.gast)]
            let scoreline = mostLikelyScoreline(
                homeExpectedGoals: matchExpectedGoals?.home ?? fallbackExpectedGoals.home,
                awayExpectedGoals: matchExpectedGoals?.away ?? fallbackExpectedGoals.away,
                drawCalibration: matchExpectedGoals?.drawCalibration ?? 0,
                odds: odds
            )
            let chosen = rationaleSource(for: scoreline, candidates: candidates, oddsByKey: oddsByKey)

            aggregated.append(SuggestedTip(
                spieltag: chosen.spieltag,
                heim: match.heim,
                gast: match.gast,
                toreHeim: scoreline.home,
                toreGast: scoreline.away,
                rationale: chosen.rationale
            ))
        }

        return calibrateMatchdayDrawRate(aggregated, oddsByKey: oddsByKey, expectedGoals: expectedGoals)
    }

    /// Returns betting odds keyed by normalized match key, aligned to upcoming matches.
    func remappedOdds(bettingOdds: [BettingOdds], upcomingMatches: [UpcomingMatch]) -> [String: BettingOdds] {
        let oddsNormMap = Dictionary(uniqueKeysWithValues: bettingOdds.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        })
        return Dictionary(uniqueKeysWithValues: upcomingMatches.compactMap { match in
            guard let odds = oddsNormMap[normalizedTeamKey(match.heim, match.gast)] else { return nil }
            return (
                normalizedTeamKey(match.heim, match.gast),
                BettingOdds(
                    heim: match.heim,
                    gast: match.gast,
                    quoteHeim: odds.quoteHeim,
                    quoteUnentschieden: odds.quoteUnentschieden,
                    quoteGast: odds.quoteGast
                )
            )
        })
    }

    // MARK: - Private

    private func marketAdjustedExpectedGoals(from candidates: [SuggestedTip], odds: BettingOdds?) -> (home: Double, away: Double) {
        let homeMean = candidates.map { Double($0.toreHeim) }.average
        let awayMean = candidates.map { Double($0.toreGast) }.average
        guard let odds,
              let homeQuote = parseQuote(odds.quoteHeim),
              let drawQuote = parseQuote(odds.quoteUnentschieden),
              let awayQuote = parseQuote(odds.quoteGast),
              homeQuote > 0, drawQuote > 0, awayQuote > 0 else {
            return (clampedExpectedGoals(homeMean), clampedExpectedGoals(awayMean))
        }

        let inv = 1 / homeQuote + 1 / drawQuote + 1 / awayQuote
        let marketHome = (1 / homeQuote) / inv
        let marketDraw = (1 / drawQuote) / inv
        let marketAway = (1 / awayQuote) / inv
        let totalGoals = max(1.6, homeMean + awayMean)
        let marketHomeGoals = totalGoals * (marketHome + marketDraw / 2)
        let marketAwayGoals = totalGoals * (marketAway + marketDraw / 2)

        return (
            clampedExpectedGoals(homeMean * 0.7 + marketHomeGoals * 0.3),
            clampedExpectedGoals(awayMean * 0.7 + marketAwayGoals * 0.3)
        )
    }

    private func calibrateMatchdayDrawRate(
        _ tips: [SuggestedTip],
        oddsByKey: [String: BettingOdds],
        expectedGoals: [String: MatchExpectedGoals]
    ) -> [SuggestedTip] {
        let drawIndexes = tips.indices.filter { tips[$0].toreHeim == tips[$0].toreGast }
        let maxDraws = max(1, min(3, Int((Double(tips.count) * 0.28).rounded(.toNearestOrAwayFromZero))))
        guard drawIndexes.count > maxDraws else { return tips }

        let indexesToFlip = drawIndexes
            .sorted {
                drawKeepScore(for: tips[$0], oddsByKey: oddsByKey, expectedGoals: expectedGoals) <
                drawKeepScore(for: tips[$1], oddsByKey: oddsByKey, expectedGoals: expectedGoals)
            }
            .prefix(drawIndexes.count - maxDraws)

        var calibrated = tips
        for index in indexesToFlip {
            calibrated[index] = nonDrawAlternative(for: tips[index], oddsByKey: oddsByKey, expectedGoals: expectedGoals)
        }
        return calibrated
    }

    private func drawKeepScore(
        for tip: SuggestedTip,
        oddsByKey: [String: BettingOdds],
        expectedGoals: [String: MatchExpectedGoals]
    ) -> Double {
        let key = normalizedTeamKey(tip.heim, tip.gast)
        let xgCloseness = expectedGoals[key].map { max(0, 1 - abs($0.home - $0.away)) } ?? 0.5
        guard let odds = oddsByKey[key],
              let homeQuote = parseQuote(odds.quoteHeim),
              let drawQuote = parseQuote(odds.quoteUnentschieden),
              let awayQuote = parseQuote(odds.quoteGast),
              homeQuote > 0, drawQuote > 0, awayQuote > 0 else {
            return xgCloseness
        }

        let inv = 1 / homeQuote + 1 / drawQuote + 1 / awayQuote
        return ((1 / drawQuote) / inv) * 2 + xgCloseness
    }

    private func nonDrawAlternative(
        for tip: SuggestedTip,
        oddsByKey: [String: BettingOdds],
        expectedGoals: [String: MatchExpectedGoals]
    ) -> SuggestedTip {
        let homeFavored = nonDrawHomeFavored(for: tip, oddsByKey: oddsByKey, expectedGoals: expectedGoals)
        let goals = max(1, tip.toreHeim)
        let score = homeFavored ? (home: goals + 1, away: goals) : (home: goals, away: goals + 1)
        return SuggestedTip(
            spieltag: tip.spieltag,
            heim: tip.heim,
            gast: tip.gast,
            toreHeim: score.home,
            toreGast: score.away,
            rationale: "Spieltagskalibrierung: Markt und xG sprechen knapp gegen ein ueberhoehtes Remisfeld."
        )
    }

    private func nonDrawHomeFavored(
        for tip: SuggestedTip,
        oddsByKey: [String: BettingOdds],
        expectedGoals: [String: MatchExpectedGoals]
    ) -> Bool {
        let key = normalizedTeamKey(tip.heim, tip.gast)
        if let odds = oddsByKey[key],
           let homeQuote = parseQuote(odds.quoteHeim),
           let awayQuote = parseQuote(odds.quoteGast),
           homeQuote != awayQuote {
            return homeQuote < awayQuote
        }
        if let xg = expectedGoals[key], xg.home != xg.away {
            return xg.home > xg.away
        }
        return true
    }

    private func mostLikelyScoreline(homeExpectedGoals: Double, awayExpectedGoals: Double, drawCalibration: Double, odds: BettingOdds?) -> (home: Int, away: Int) {
        var best = (home: 0, away: 0, probability: -1.0)
        let market = marketShape(from: odds)

        for homeGoals in 0...6 {
            for awayGoals in 0...6 {
                let probability = poissonProbability(goals: homeGoals, lambda: homeExpectedGoals)
                    * poissonProbability(goals: awayGoals, lambda: awayExpectedGoals)
                    * dixonColesAdjustment(homeGoals: homeGoals, awayGoals: awayGoals, homeExpectedGoals: homeExpectedGoals, awayExpectedGoals: awayExpectedGoals)
                    * realismAdjustment(homeGoals: homeGoals, awayGoals: awayGoals, market: market)
                    * drawCalibrationAdjustment(homeGoals: homeGoals, awayGoals: awayGoals, drawCalibration: drawCalibration)
                if probability > best.probability {
                    best = (homeGoals, awayGoals, probability)
                }
            }
        }

        return (best.home, best.away)
    }

    private func rationaleSource(
        for scoreline: (home: Int, away: Int),
        candidates: [SuggestedTip],
        oddsByKey: [String: BettingOdds]
    ) -> SuggestedTip {
        candidates.sorted { lhs, rhs in
            let lhsExactDistance = abs(lhs.toreHeim - scoreline.home) + abs(lhs.toreGast - scoreline.away)
            let rhsExactDistance = abs(rhs.toreHeim - scoreline.home) + abs(rhs.toreGast - scoreline.away)
            if lhsExactDistance != rhsExactDistance { return lhsExactDistance < rhsExactDistance }

            let lhsAlignment = marketAlignmentScore(for: lhs, oddsByKey: oddsByKey)
            let rhsAlignment = marketAlignmentScore(for: rhs, oddsByKey: oddsByKey)
            return lhsAlignment > rhsAlignment
        }.first ?? candidates[0]
    }

    private func clampedExpectedGoals(_ value: Double) -> Double {
        min(max(value, 0.2), 4.5)
    }

    private func poissonProbability(goals: Int, lambda: Double) -> Double {
        pow(lambda, Double(goals)) * exp(-lambda) / Double(factorial(goals))
    }

    private func dixonColesAdjustment(homeGoals: Int, awayGoals: Int, homeExpectedGoals: Double, awayExpectedGoals: Double) -> Double {
        let rho = -0.07
        switch (homeGoals, awayGoals) {
        case (0, 0):
            return 1 - homeExpectedGoals * awayExpectedGoals * rho
        case (0, 1):
            return 1 + homeExpectedGoals * rho
        case (1, 0):
            return 1 + awayExpectedGoals * rho
        case (1, 1):
            return 1 - rho
        default:
            return 1
        }
    }

    private func realismAdjustment(homeGoals: Int, awayGoals: Int, market: MarketShape?) -> Double {
        guard let market else { return 1 }
        let total = homeGoals + awayGoals
        let margin = abs(homeGoals - awayGoals)
        var factor = 1.0

        if market.favoriteWinProbability < 0.45 {
            if margin >= 3 { factor *= 0.12 }
            if total >= 5 { factor *= 0.20 }
        } else if market.favoriteWinProbability < 0.60 {
            if margin >= 4 { factor *= 0.20 }
            if total >= 6 { factor *= 0.35 }
        }

        return factor
    }

    private func drawCalibrationAdjustment(homeGoals: Int, awayGoals: Int, drawCalibration: Double) -> Double {
        guard homeGoals == awayGoals else { return 1 }
        return min(max(1 + drawCalibration, 0.80), 1.20)
    }

    private func marketShape(from odds: BettingOdds?) -> MarketShape? {
        guard let odds,
              let homeQuote = parseQuote(odds.quoteHeim),
              let drawQuote = parseQuote(odds.quoteUnentschieden),
              let awayQuote = parseQuote(odds.quoteGast),
              homeQuote > 0, drawQuote > 0, awayQuote > 0 else {
            return nil
        }

        let inv = 1 / homeQuote + 1 / drawQuote + 1 / awayQuote
        return MarketShape(favoriteWinProbability: max((1 / homeQuote) / inv, (1 / awayQuote) / inv))
    }

    private func factorial(_ value: Int) -> Int {
        value < 2 ? 1 : (2...value).reduce(1, *)
    }

    /// Returns 1 if the tip's predicted outcome matches the market favourite, 0 otherwise.
    private func marketAlignmentScore(for tip: SuggestedTip, oddsByKey: [String: BettingOdds]) -> Int {
        guard let odds = oddsByKey[normalizedTeamKey(tip.heim, tip.gast)] else { return 0 }

        let heim = Double(odds.quoteHeim.replacingOccurrences(of: ",", with: ".")) ?? .greatestFiniteMagnitude
        let draw = Double(odds.quoteUnentschieden.replacingOccurrences(of: ",", with: ".")) ?? .greatestFiniteMagnitude
        let gast = Double(odds.quoteGast.replacingOccurrences(of: ",", with: ".")) ?? .greatestFiniteMagnitude

        let favoriteOutcome: Int
        if heim <= draw && heim <= gast {
            favoriteOutcome = 1
        } else if gast <= heim && gast <= draw {
            favoriteOutcome = -1
        } else {
            favoriteOutcome = 0
        }

        let tipOutcome = tip.toreHeim == tip.toreGast ? 0 : (tip.toreHeim > tip.toreGast ? 1 : -1)
        return tipOutcome == favoriteOutcome ? 1 : 0
    }

    private func parseQuote(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: "."))
    }
}

private struct MarketShape {
    let favoriteWinProbability: Double
}

private extension Array where Element == Double {
    var average: Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }
}
