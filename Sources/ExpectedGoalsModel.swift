import Foundation

/// Everything the expected-goals model needs, captured from the app state.
struct ExpectedGoalsInput {
    var season: Int
    var finishedResults: [FinishedMatch]
    /// Finished matches of earlier seasons (start year -> matches).
    var historicalSeasons: [Int: [FinishedMatch]] = [:]
    var upcomingMatches: [UpcomingMatch]
    var bettingOdds: [BettingOdds] = []
    var overUnderOdds: [OverUnderOdds] = []
    var playerAbsences: [PlayerAbsence] = []
    var llmMatchEnrichments: [LLMMatchEnrichment] = []
    var marketWeight: Double = ModelBacktestService.defaultMarketWeight
    var llmSignalWeight: Double = 0.55
    var learningState: LearningState = .empty
}

/// Expected goals per match: team ratings blended (in log space) with the bookmaker market,
/// then small, confidence-weighted LLM news adjustments. Absence and rest factors only apply
/// without market odds, because the market already prices them in.
struct ExpectedGoalsModel {
    var ratingService = TeamRatingService()

    func expectedGoals(_ input: ExpectedGoalsInput) -> [String: MatchExpectedGoals] {
        let ratingModel = ratingModel(input)
        let oddsByKey = EnsembleService().remappedOdds(bettingOdds: input.bettingOdds, upcomingMatches: input.upcomingMatches)
        let overUnderByKey = Dictionary(input.overUnderOdds.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
        let restDays = restDaysByTeam(input)
        let absencesByTeam = Dictionary(grouping: input.playerAbsences) { normalizeTeamName($0.teamName) }
        let enrichmentByMatch = Dictionary(input.llmMatchEnrichments.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })

        return Dictionary(input.upcomingMatches.map { match in
            let matchKey = normalizedTeamKey(match.heim, match.gast)
            let rating = ratingModel?.expectedGoals(homeTeam: match.heim, awayTeam: match.gast) ?? (home: 1.6, away: 1.25)
            var homeXG = rating.home
            var awayXG = rating.away
            let enrichment = enrichmentByMatch[matchKey]
            let confidence = min(max(enrichment?.confidence ?? 0, 0), 1)
            let marketWeightHint = (enrichment?.marketWeightHint ?? 0) * confidence

            let overUnderTotal = overUnderByKey[matchKey].flatMap {
                MarketModel.totalGoals(line: $0.line, overQuote: $0.overQuote, underQuote: $0.underQuote)
            }
            if let odds = oddsByKey[matchKey], let market = MarketModel.expectedGoals(odds: odds, total: overUnderTotal) {
                let weight = min(max(input.marketWeight + marketWeightHint, 0.3), 0.95)
                (homeXG, awayXG) = ModelBacktestService.blend(rating: (homeXG, awayXG), market: market, marketWeight: weight)
            } else {
                let homeAbsence = absenceImpact(absencesByTeam[normalizeTeamName(match.heim)] ?? [])
                let awayAbsence = absenceImpact(absencesByTeam[normalizeTeamName(match.gast)] ?? [])
                homeXG *= (1 - homeAbsence.attack) * (1 + awayAbsence.defense) * restFactor(restDays[normalizeTeamName(match.heim)])
                awayXG *= (1 - awayAbsence.attack) * (1 + homeAbsence.defense) * restFactor(restDays[normalizeTeamName(match.gast)])
            }

            var drawCalibration = 0.0
            if let enrichment {
                let weight = input.llmSignalWeight * confidence * 0.5
                homeXG *= 1 + (enrichment.homeAttackAdjustment + enrichment.awayDefenseAdjustment + enrichment.lineupImpact + enrichment.playerValueImpact) * weight
                awayXG *= 1 + (enrichment.awayAttackAdjustment + enrichment.homeDefenseAdjustment - enrichment.lineupImpact - enrichment.playerValueImpact) * weight
                if enrichment.totalGoalsAdjustment != 0 {
                    let current = max(0.1, homeXG + awayXG)
                    let factor = max(0.8, current + enrichment.totalGoalsAdjustment * weight) / current
                    homeXG *= factor
                    awayXG *= factor
                }
                drawCalibration = enrichment.scorelineDrawCalibration * confidence
            }

            if input.learningState.sampleSize >= 30 {
                homeXG -= input.learningState.avgHomeGoalOverprediction * 0.2
                awayXG -= input.learningState.avgAwayGoalOverprediction * 0.2
            }

            return (
                matchKey,
                MatchExpectedGoals(
                    heim: match.heim,
                    gast: match.gast,
                    home: min(max(homeXG, 0.2), 4.5),
                    away: min(max(awayXG, 0.2), 4.5),
                    drawCalibration: drawCalibration,
                    marketWeightHint: marketWeightHint
                )
            )
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Rating model over the current and two previous seasons (parameters from the walk-forward grid search).
    func ratingModel(_ input: ExpectedGoalsInput) -> TeamRatingModel? {
        let previousTeams = Set((input.historicalSeasons[input.season - 1] ?? []).flatMap { [normalizeTeamName($0.heim), normalizeTeamName($0.gast)] })
        let currentTeams = Set((input.finishedResults.map { ($0.heim, $0.gast) } + input.upcomingMatches.map { ($0.heim, $0.gast) })
            .flatMap { [normalizeTeamName($0.0), normalizeTeamName($0.1)] })
        var counts: [String: Int] = [:]
        for match in input.finishedResults {
            counts[normalizeTeamName(match.heim), default: 0] += 1
            counts[normalizeTeamName(match.gast), default: 0] += 1
        }
        let history = (input.historicalSeasons[input.season - 2] ?? []) + (input.historicalSeasons[input.season - 1] ?? [])
        return ratingService.fit(
            matches: history + input.finishedResults,
            promotedTeams: previousTeams.isEmpty ? [] : currentTeams.subtracting(previousTeams),
            currentSeasonMatchCounts: counts,
            referenceDate: input.upcomingMatches.compactMap { parseKickoffDate($0.datum) }.min()
        )
    }

    private func absenceImpact(_ absences: [PlayerAbsence]) -> (attack: Double, defense: Double) {
        let raw = min(0.20, Double(absences.count) * 0.025)
        let attackReasons = ["forward", "wing", "striker", "thigh", "muscle", "illness"]
        let defenseReasons = ["defender", "centre-back", "knee", "ankle", "calf", "surgery"]
        let text = absences.map { "\($0.playerName) \($0.reason)" }.joined(separator: " ").lowercased()
        let attack = raw * (attackReasons.contains { text.contains($0) } ? 1.1 : 0.8)
        let defense = raw * (defenseReasons.contains { text.contains($0) } ? 1.1 : 0.8)
        return (min(0.25, attack), min(0.25, defense))
    }

    private func restFactor(_ days: Int?) -> Double {
        guard let days else { return 1 }
        if days < 4 { return 0.92 }
        if days > 8 { return 1.03 }
        return 1
    }

    private func restDaysByTeam(_ input: ExpectedGoalsInput) -> [String: Int] {
        var result: [String: Int] = [:]
        for match in input.upcomingMatches {
            guard let kickoff = parseKickoffDate(match.datum) else { continue }
            for team in [match.heim, match.gast] {
                let last = input.finishedResults
                    .filter { $0.heim == team || $0.gast == team }
                    .compactMap { parseKickoffDate($0.datum) }
                    .filter { $0 < kickoff }
                    .max()
                if let last {
                    result[normalizeTeamName(team)] = max(0, Calendar.current.dateComponents([.day], from: last, to: kickoff).day ?? 0)
                }
            }
        }
        return result
    }
}
