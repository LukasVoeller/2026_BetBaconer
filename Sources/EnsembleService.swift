import Foundation

/// Aggregates tips from multiple Codex ensemble runs into a single consensus prediction.
struct EnsembleService {

    // MARK: - Public

    /// Aggregates tips from multiple runs using majority voting.
    /// Tiebreaker order: market alignment → lower goal difference → fewer total goals.
    func aggregateTips(
        from runs: [[SuggestedTip]],
        upcomingMatches: [UpcomingMatch],
        bettingOdds: [BettingOdds]
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

            let grouped = Dictionary(grouping: candidates) { "\($0.toreHeim):\($0.toreGast)" }
            let chosenGroup = grouped.values.sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }

                let lhsAlignment = marketAlignmentScore(for: lhs[0], oddsByKey: oddsByKey)
                let rhsAlignment = marketAlignmentScore(for: rhs[0], oddsByKey: oddsByKey)
                if lhsAlignment != rhsAlignment { return lhsAlignment > rhsAlignment }

                let lhsGoalDiff = abs(lhs[0].toreHeim - lhs[0].toreGast)
                let rhsGoalDiff = abs(rhs[0].toreHeim - rhs[0].toreGast)
                if lhsGoalDiff != rhsGoalDiff { return lhsGoalDiff < rhsGoalDiff }

                return (lhs[0].toreHeim + lhs[0].toreGast) < (rhs[0].toreHeim + rhs[0].toreGast)
            }.first

            guard let chosen = chosenGroup?.first else {
                throw TipWorkflowError.invalidModelOutput
            }

            aggregated.append(SuggestedTip(
                spieltag: chosen.spieltag,
                heim: match.heim,
                gast: match.gast,
                toreHeim: chosen.toreHeim,
                toreGast: chosen.toreGast,
                rationale: chosen.rationale
            ))
        }

        return aggregated
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
}
