import Foundation

struct TeamRatingModel {
    let attack: [String: Double]
    let defense: [String: Double]
    let homeAdvantage: Double
    /// Corrects the systematic goal underestimate caused by regularisation (Jensen: shrunk ratings lower mean exp()).
    let goalScale: Double
    /// Promoted teams start below average until they have played enough matches.
    let promotedTeams: Set<String>
    let currentSeasonMatchCounts: [String: Int]
    let promotedPenalty: Double

    func expectedGoals(homeTeam: String, awayTeam: String) -> (home: Double, away: Double)? {
        let home = normalizeTeamName(homeTeam)
        let away = normalizeTeamName(awayTeam)
        guard attack[home] != nil || promotedTeams.contains(home),
              attack[away] != nil || promotedTeams.contains(away) else {
            return nil
        }
        let (homeAttack, homeDefense) = rating(home)
        let (awayAttack, awayDefense) = rating(away)
        return (
            min(max(exp(homeAdvantage + homeAttack + awayDefense) * goalScale, 0.2), 4.5),
            min(max(exp(awayAttack + homeDefense) * goalScale, 0.2), 4.5)
        )
    }

    private func rating(_ team: String) -> (attack: Double, defense: Double) {
        var attackValue = attack[team] ?? 0
        var defenseValue = defense[team] ?? 0
        if promotedTeams.contains(team) {
            let shrink = max(0, 1 - Double(currentSeasonMatchCounts[team] ?? 0) / 10)
            attackValue -= promotedPenalty * shrink
            defenseValue += promotedPenalty * shrink
        }
        return (attackValue, defenseValue)
    }
}

/// Time-weighted Poisson attack/defence ratings with L2 regularisation.
/// Defaults come from a walk-forward grid search over the Bundesliga seasons 2020-2025
/// (training on up to two previous seasons, half-life 365 days, L2 6, promoted penalty 0.2).
struct TeamRatingService: Sendable {
    var halfLifeDays: Double = 365
    var l2: Double = 6
    var promotedPenalty: Double = 0.2
    var iterations = 40

    /// Convenience for a single season without promoted-team information.
    func fit(finishedResults: [FinishedMatch]) -> TeamRatingModel? {
        fit(matches: finishedResults, promotedTeams: [], currentSeasonMatchCounts: [:], referenceDate: nil)
    }

    func fit(
        matches: [FinishedMatch],
        promotedTeams: Set<String>,
        currentSeasonMatchCounts: [String: Int],
        referenceDate: Date?
    ) -> TeamRatingModel? {
        let dated = matches.compactMap { match -> (FinishedMatch, Date)? in
            parseKickoffDate(match.datum).map { (match, $0) }
        }
        guard dated.count >= 18, let latest = dated.map(\.1).max() else { return nil }
        let reference = referenceDate ?? latest

        var index: [String: Int] = [:]
        for (match, _) in dated {
            for team in [normalizeTeamName(match.heim), normalizeTeamName(match.gast)] where index[team] == nil {
                index[team] = index.count
            }
        }
        let samples = dated.map { match, date in
            (
                home: index[normalizeTeamName(match.heim)]!,
                away: index[normalizeTeamName(match.gast)]!,
                homeGoals: Double(match.toreHeim),
                awayGoals: Double(match.toreGast),
                weight: pow(0.5, max(0, reference.timeIntervalSince(date)) / 86_400 / halfLifeDays)
            )
        }

        let count = index.count
        var attack = [Double](repeating: 0, count: count)
        var defense = [Double](repeating: 0, count: count)
        var homeAdvantage = log(1.25)

        // Newton steps per parameter (Poisson log-likelihood is concave), converge in a few dozen iterations.
        for _ in 0..<iterations {
            var attackGradient = [Double](repeating: 0, count: count), attackCurvature = attackGradient
            var defenseGradient = attackGradient, defenseCurvature = attackGradient
            var homeGradient = 0.0, homeCurvature = 0.0
            for sample in samples {
                let homeLambda = exp(homeAdvantage + attack[sample.home] + defense[sample.away])
                let awayLambda = exp(attack[sample.away] + defense[sample.home])
                let homeError = sample.weight * (sample.homeGoals - homeLambda)
                let awayError = sample.weight * (sample.awayGoals - awayLambda)
                attackGradient[sample.home] += homeError
                attackCurvature[sample.home] += sample.weight * homeLambda
                defenseGradient[sample.away] += homeError
                defenseCurvature[sample.away] += sample.weight * homeLambda
                homeGradient += homeError
                homeCurvature += sample.weight * homeLambda
                attackGradient[sample.away] += awayError
                attackCurvature[sample.away] += sample.weight * awayLambda
                defenseGradient[sample.home] += awayError
                defenseCurvature[sample.home] += sample.weight * awayLambda
            }
            for team in 0..<count {
                attack[team] += (attackGradient[team] - l2 * attack[team]) / (attackCurvature[team] + l2)
                defense[team] += (defenseGradient[team] - l2 * defense[team]) / (defenseCurvature[team] + l2)
            }
            homeAdvantage += homeGradient / max(homeCurvature, 1)
            let attackMean = attack.reduce(0, +) / Double(count)
            let defenseMean = defense.reduce(0, +) / Double(count)
            for team in 0..<count {
                attack[team] -= attackMean
                defense[team] -= defenseMean
            }
        }

        homeAdvantage = min(max(homeAdvantage, log(1.05)), log(1.45))
        // Scale with the clamped home advantage the model actually predicts with.
        var actualGoals = 0.0, predictedGoals = 0.0
        for sample in samples {
            actualGoals += sample.weight * (sample.homeGoals + sample.awayGoals)
            predictedGoals += sample.weight * (exp(homeAdvantage + attack[sample.home] + defense[sample.away]) + exp(attack[sample.away] + defense[sample.home]))
        }

        return TeamRatingModel(
            attack: index.mapValues { attack[$0] },
            defense: index.mapValues { defense[$0] },
            homeAdvantage: homeAdvantage,
            goalScale: predictedGoals > 0 ? min(max(actualGoals / predictedGoals, 0.8), 1.25) : 1,
            promotedTeams: promotedTeams,
            currentSeasonMatchCounts: currentSeasonMatchCounts,
            promotedPenalty: promotedPenalty
        )
    }
}

/// Converts bookmaker odds into expected goals: the 1X2 market fixes supremacy (and, via the draw price,
/// the goal total); an Over/Under market, if available, fixes the total directly.
enum MarketModel {
    static func outcomeProbabilities(_ odds: BettingOdds) -> (home: Double, draw: Double, away: Double)? {
        guard let home = parseDecimal(odds.quoteHeim), let draw = parseDecimal(odds.quoteUnentschieden), let away = parseDecimal(odds.quoteGast),
              home > 1, draw > 1, away > 1 else { return nil }
        let inverse = 1 / home + 1 / draw + 1 / away
        return ((1 / home) / inverse, (1 / draw) / inverse, (1 / away) / inverse)
    }

    /// Goal total T so that P(Poisson(T) > line) matches the de-vigged over price.
    static func totalGoals(line: Double, overQuote: String, underQuote: String) -> Double? {
        guard let over = parseDecimal(overQuote), let under = parseDecimal(underQuote), over > 1, under > 1 else { return nil }
        let overProbability = (1 / over) / (1 / over + 1 / under)
        let threshold = Int(floor(line))
        var best: (total: Double, error: Double) = (2.8, .infinity)
        for step in 0...400 {
            let total = 1.0 + Double(step) * 0.01
            let error = abs((1 - poissonCDF(threshold, total)) - overProbability)
            if error < best.error { best = (total, error) }
        }
        return best.total
    }

    static func expectedGoals(odds: BettingOdds, total: Double?) -> (home: Double, away: Double)? {
        guard let probabilities = outcomeProbabilities(odds) else { return nil }
        let targetSupremacy = probabilities.home - probabilities.away

        func fitted(total: Double) -> (home: Double, away: Double, draw: Double) {
            var low = -total + 0.1, high = total - 0.1
            for _ in 0..<30 {
                let mid = (low + high) / 2
                let outcome = outcomes(home: (total + mid) / 2, away: (total - mid) / 2)
                if outcome.home - outcome.away < targetSupremacy { low = mid } else { high = mid }
            }
            let supremacy = (low + high) / 2
            let home = (total + supremacy) / 2, away = (total - supremacy) / 2
            return (home, away, outcomes(home: home, away: away).draw)
        }

        if let total {
            let result = fitted(total: total)
            return (result.home, result.away)
        }
        // Without Over/Under: the draw price pins down the total (draw probability falls as the total rises).
        var low = 1.2, high = 5.0
        for _ in 0..<25 {
            let mid = (low + high) / 2
            if fitted(total: mid).draw > probabilities.draw { low = mid } else { high = mid }
        }
        let result = fitted(total: (low + high) / 2)
        return (result.home, result.away)
    }

    private static func outcomes(home: Double, away: Double) -> (home: Double, draw: Double, away: Double) {
        let homeDistribution = (0...10).map { poisson($0, home) }
        let awayDistribution = (0...10).map { poisson($0, away) }
        var result = (home: 0.0, draw: 0.0, away: 0.0)
        for h in 0...10 {
            for a in 0...10 {
                let p = homeDistribution[h] * awayDistribution[a]
                if h > a { result.home += p } else if h == a { result.draw += p } else { result.away += p }
            }
        }
        return result
    }

    private static func poisson(_ goals: Int, _ lambda: Double) -> Double {
        var value = exp(-lambda)
        if goals > 0 { for k in 1...goals { value *= lambda / Double(k) } }
        return value
    }

    private static func poissonCDF(_ goals: Int, _ lambda: Double) -> Double {
        (0...max(goals, 0)).reduce(0) { $0 + poisson($1, lambda) }
    }

    private static func parseDecimal(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: "."))
    }
}
