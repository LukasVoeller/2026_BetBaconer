import Foundation

/// Kicktipp point rules of the betting group. Groups can configure them, so they are user settings.
struct KicktippRules: Codable, Equatable, Sendable {
    var exactScorePoints: Double = 4
    var goalDifferencePoints: Double = 3
    var tendencyPoints: Double = 2
    /// Kicktipp standard: a wrong draw score (1:1 vs. 2:2) still has the right goal difference (0) and earns its points.
    var drawCountsAsGoalDifference: Bool = true

    static let standard = KicktippRules()

    func points(predictedHome: Int, predictedAway: Int, actualHome: Int, actualAway: Int) -> Double {
        if predictedHome == actualHome && predictedAway == actualAway {
            return exactScorePoints
        }
        let predictedDiff = predictedHome - predictedAway
        let actualDiff = actualHome - actualAway
        if predictedDiff == actualDiff && (predictedDiff != 0 || drawCountsAsGoalDifference) {
            return goalDifferencePoints
        }
        return predictedDiff.signum() == actualDiff.signum() ? tendencyPoints : 0
    }
}

/// Aggregates tips from multiple Codex ensemble runs into a single consensus prediction.
struct EnsembleService {
    struct MatchProbabilityModel {
        let selectedScoreline: (home: Int, away: Int)
        let expectedHomeGoals: Double
        let expectedAwayGoals: Double
        let probabilityHomeWin: Double
        let probabilityDraw: Double
        let probabilityAwayWin: Double
        /// Heuristic score from outcome margin and top scoreline mass; not a calibrated probability.
        let confidence: Double
        let topScorelines: [ScorelineProbability]
    }

    struct AggregatedTip {
        let tip: SuggestedTip
        let model: MatchProbabilityModel
    }

    /// Share of the Codex runs' mean scoreline blended into the statistical xG.
    static let llmSignalWeight = 0.2

    var rules: KicktippRules = .standard
    /// Optional ranking strategy; nil keeps pure expected-points maximisation.
    var strategy: RankingStrategy?
    /// The group's typical tips when the home or away side is favoured (proxy for the hidden crowd tips).
    var crowdTipHomeFavorite = (home: 2, away: 1)
    var crowdTipAwayFavorite = (home: 1, away: 2)

    // MARK: - Public

    /// Aggregates tips by estimating goals, then selecting the scoreline with the highest
    /// expected Kicktipp points under a Dixon-Coles adjusted Poisson model.
    func aggregateTips(
        from runs: [[SuggestedTip]],
        upcomingMatches: [UpcomingMatch],
        bettingOdds: [BettingOdds],
        expectedGoals: [String: MatchExpectedGoals] = [:]
    ) throws -> [SuggestedTip] {
        try aggregate(from: runs, upcomingMatches: upcomingMatches, bettingOdds: bettingOdds, expectedGoals: expectedGoals).map(\.tip)
    }

    func aggregate(
        from runs: [[SuggestedTip]],
        upcomingMatches: [UpcomingMatch],
        bettingOdds: [BettingOdds],
        expectedGoals: [String: MatchExpectedGoals] = [:]
    ) throws -> [AggregatedTip] {
        guard !runs.isEmpty else {
            throw TipWorkflowError.invalidModelOutput
        }

        let oddsByKey = remappedOdds(bettingOdds: bettingOdds, upcomingMatches: upcomingMatches)

        return try upcomingMatches.map { match in
            let key = normalizedTeamKey(match.heim, match.gast)
            let candidates = runs.compactMap { run in
                run.first { normalizedTeamKey($0.heim, $0.gast) == key }
            }

            guard !candidates.isEmpty else {
                throw TipWorkflowError.fixtureMismatch
            }

            let odds = oddsByKey[key]
            let goals: (home: Double, away: Double)
            if let statistical = expectedGoals[key] {
                let llmHome = candidates.map { Double($0.toreHeim) }.average
                let llmAway = candidates.map { Double($0.toreGast) }.average
                let weight = Self.llmSignalWeight
                goals = (
                    clampedExpectedGoals(statistical.home * (1 - weight) + llmHome * weight),
                    clampedExpectedGoals(statistical.away * (1 - weight) + llmAway * weight)
                )
            } else {
                goals = marketAdjustedExpectedGoals(from: candidates, odds: odds)
            }
            let model = probabilityModel(
                for: match,
                homeExpectedGoals: goals.home,
                awayExpectedGoals: goals.away,
                drawCalibration: expectedGoals[key]?.drawCalibration ?? 0,
                odds: odds
            )
            let scoreline = model.selectedScoreline
            let chosen = rationaleSource(for: scoreline, candidates: candidates, oddsByKey: oddsByKey)

            return AggregatedTip(
                tip: SuggestedTip(
                    spieltag: match.spieltag,
                    heim: match.heim,
                    gast: match.gast,
                    toreHeim: scoreline.home,
                    toreGast: scoreline.away,
                    rationale: chosen.rationale
                ),
                model: model
            )
        }
    }

    func probabilityModel(
        for match: UpcomingMatch,
        homeExpectedGoals: Double,
        awayExpectedGoals: Double,
        drawCalibration: Double,
        odds: BettingOdds?
    ) -> MatchProbabilityModel {
        let probabilities = scorelineProbabilities(
            homeExpectedGoals: homeExpectedGoals,
            awayExpectedGoals: awayExpectedGoals,
            drawCalibration: drawCalibration,
            odds: odds
        )
        let pHome = probabilities.filter { $0.homeGoals > $0.awayGoals }.map(\.probability).reduce(0, +)
        let pDraw = probabilities.filter { $0.homeGoals == $0.awayGoals }.map(\.probability).reduce(0, +)
        let pAway = probabilities.filter { $0.homeGoals < $0.awayGoals }.map(\.probability).reduce(0, +)
        let crowdTip = pHome >= pAway ? crowdTipHomeFavorite : crowdTipAwayFavorite
        let selected = bestKicktippScoreline(from: probabilities, crowdTip: crowdTip)
        let sortedOutcomes = [pHome, pDraw, pAway].sorted(by: >)
        let confidence = min(max((sortedOutcomes[0] - sortedOutcomes[1]) * 1.8 + (probabilities.first?.probability ?? 0) * 2.0, 0), 1)

        return MatchProbabilityModel(
            selectedScoreline: (selected.homeGoals, selected.awayGoals),
            expectedHomeGoals: homeExpectedGoals,
            expectedAwayGoals: awayExpectedGoals,
            probabilityHomeWin: pHome,
            probabilityDraw: pDraw,
            probabilityAwayWin: pAway,
            confidence: confidence,
            topScorelines: Array(probabilities.prefix(3))
        )
    }

    /// Returns betting odds keyed by normalized match key, aligned to upcoming matches.
    func remappedOdds(bettingOdds: [BettingOdds], upcomingMatches: [UpcomingMatch]) -> [String: BettingOdds] {
        let oddsNormMap = Dictionary(bettingOdds.map {
            (normalizedTeamKey($0.heim, $0.gast), $0)
        }, uniquingKeysWith: { first, _ in first })
        return Dictionary(upcomingMatches.compactMap { match in
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
        }, uniquingKeysWith: { first, _ in first })
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

    private func scorelineProbabilities(homeExpectedGoals: Double, awayExpectedGoals: Double, drawCalibration: Double, odds: BettingOdds?) -> [ScorelineProbability] {
        var matrix: [ScorelineProbability] = []
        let market = marketShape(from: odds)

        for homeGoals in 0...6 {
            for awayGoals in 0...6 {
                let probability = poissonProbability(goals: homeGoals, lambda: homeExpectedGoals)
                    * poissonProbability(goals: awayGoals, lambda: awayExpectedGoals)
                    * dixonColesAdjustment(homeGoals: homeGoals, awayGoals: awayGoals, homeExpectedGoals: homeExpectedGoals, awayExpectedGoals: awayExpectedGoals)
                    * realismAdjustment(homeGoals: homeGoals, awayGoals: awayGoals, market: market)
                    * drawCalibrationAdjustment(homeGoals: homeGoals, awayGoals: awayGoals, drawCalibration: drawCalibration)
                matrix.append(ScorelineProbability(homeGoals: homeGoals, awayGoals: awayGoals, probability: probability))
            }
        }

        let total = matrix.map(\.probability).reduce(0, +)
        guard total > 0 else { return matrix }
        return matrix
            .map { ScorelineProbability(homeGoals: $0.homeGoals, awayGoals: $0.awayGoals, probability: $0.probability / total) }
            .sorted { lhs, rhs in
                if lhs.probability != rhs.probability { return lhs.probability > rhs.probability }
                return abs(lhs.homeGoals - lhs.awayGoals) < abs(rhs.homeGoals - rhs.awayGoals)
            }
    }

    /// Highest expected Kicktipp points; exact ties (symmetric matches) go to the more home-leaning scoreline.
    private func bestKicktippScoreline(from probabilities: [ScorelineProbability], crowdTip: (home: Int, away: Int)) -> ScorelineProbability {
        let scored = probabilities.map { ($0, expectedKicktippPoints(for: $0, actualProbabilities: probabilities)) }
        let byValue: ((ScorelineProbability, Double), (ScorelineProbability, Double)) -> Bool = { lhs, rhs in
            if abs(lhs.1 - rhs.1) > 1e-9 { return lhs.1 < rhs.1 }
            return (lhs.0.homeGoals - lhs.0.awayGoals) < (rhs.0.homeGoals - rhs.0.awayGoals)
        }
        guard let best = scored.max(by: byValue) else {
            return ScorelineProbability(homeGoals: 1, awayGoals: 1, probability: 0)
        }
        guard let strategy, strategy.tolerance > 0 else { return best.0 }

        let affordable = scored.filter { best.1 - $0.1 <= strategy.tolerance }
        let isCrowd: (ScorelineProbability) -> Bool = { $0.homeGoals == crowdTip.home && $0.awayGoals == crowdTip.away }
        switch strategy.mode {
        case .followCrowd:
            return affordable.first { isCrowd($0.0) }?.0 ?? best.0
        case .differentiate:
            guard isCrowd(best.0) else { return best.0 }
            return affordable.filter { !isCrowd($0.0) }.max(by: byValue)?.0 ?? best.0
        }
    }

    private func expectedKicktippPoints(for predicted: ScorelineProbability, actualProbabilities: [ScorelineProbability]) -> Double {
        actualProbabilities.reduce(0) { sum, actual in
            sum + actual.probability * rules.points(
                predictedHome: predicted.homeGoals,
                predictedAway: predicted.awayGoals,
                actualHome: actual.homeGoals,
                actualAway: actual.awayGoals
            )
        }
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
