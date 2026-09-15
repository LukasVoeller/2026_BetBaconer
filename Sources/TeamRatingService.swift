import Foundation

struct TeamRatingModel {
    let attack: [String: Double]
    let defense: [String: Double]
    let homeAdvantage: Double

    func expectedGoals(homeTeam: String, awayTeam: String) -> (home: Double, away: Double)? {
        let homeKey = normalizeTeamName(homeTeam)
        let awayKey = normalizeTeamName(awayTeam)
        guard let homeAttack = attack[homeKey],
              let awayAttack = attack[awayKey],
              let homeDefense = defense[homeKey],
              let awayDefense = defense[awayKey] else {
            return nil
        }

        return (
            min(max(exp(homeAdvantage + homeAttack + awayDefense), 0.2), 4.5),
            min(max(exp(awayAttack + homeDefense), 0.2), 4.5)
        )
    }
}

struct TeamRatingService {
    private let halfLifeDays: Double = 180
    private let iterations = 700
    private let learningRate = 0.006

    func fit(finishedResults: [FinishedMatch]) -> TeamRatingModel? {
        let datedMatches = finishedResults.compactMap { match -> (match: FinishedMatch, date: Date)? in
            guard let date = Self.date(from: match.datum) else { return nil }
            return (match, date)
        }
        guard datedMatches.count >= 18, let latestDate = datedMatches.map(\.date).max() else { return nil }

        let teams = Set(finishedResults.flatMap { [normalizeTeamName($0.heim), normalizeTeamName($0.gast)] })
        var attack = Dictionary(uniqueKeysWithValues: teams.map { ($0, 0.0) })
        var defense = Dictionary(uniqueKeysWithValues: teams.map { ($0, 0.0) })
        var homeAdvantage = log(1.25)

        for _ in 0..<iterations {
            var attackGradient = Dictionary(uniqueKeysWithValues: teams.map { ($0, 0.0) })
            var defenseGradient = Dictionary(uniqueKeysWithValues: teams.map { ($0, 0.0) })
            var homeGradient = 0.0

            for entry in datedMatches {
                let match = entry.match
                let homeKey = normalizeTeamName(match.heim)
                let awayKey = normalizeTeamName(match.gast)
                let weight = pow(0.5, latestDate.timeIntervalSince(entry.date) / 86_400 / halfLifeDays)
                let homeLambda = exp(homeAdvantage + attack[homeKey, default: 0] + defense[awayKey, default: 0])
                let awayLambda = exp(attack[awayKey, default: 0] + defense[homeKey, default: 0])
                let homeError = weight * (Double(match.toreHeim) - homeLambda)
                let awayError = weight * (Double(match.toreGast) - awayLambda)

                attackGradient[homeKey, default: 0] += homeError
                defenseGradient[awayKey, default: 0] += homeError
                homeGradient += homeError
                attackGradient[awayKey, default: 0] += awayError
                defenseGradient[homeKey, default: 0] += awayError
            }

            for team in teams {
                attack[team, default: 0] += learningRate * attackGradient[team, default: 0]
                defense[team, default: 0] += learningRate * defenseGradient[team, default: 0]
            }
            homeAdvantage += learningRate * homeGradient

            let attackMean = attack.values.reduce(0, +) / Double(attack.count)
            let defenseMean = defense.values.reduce(0, +) / Double(defense.count)
            for team in teams {
                attack[team, default: 0] -= attackMean
                defense[team, default: 0] -= defenseMean
            }
        }

        return TeamRatingModel(attack: attack, defense: defense, homeAdvantage: min(max(homeAdvantage, log(1.05)), log(1.45)))
    }

    private static func date(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        return fractional.date(from: raw) ?? standard.date(from: raw)
    }
}
