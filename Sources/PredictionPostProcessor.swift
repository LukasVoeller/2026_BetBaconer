import Foundation

public struct PredictionPostProcessor {
    public init() {}

    public func process(
        tips: [SuggestedTip],
        learningState: LearningState,
        oddsByMatch: [String: BettingOdds],
        isEnabled: Bool
    ) -> [SuggestedTip] {
        guard isEnabled, learningState.sampleSize >= 30 else { return tips }

        return tips.map { tip in
            var adjusted = tip
            let odds = oddsByMatch[normalizedTeamKey(tip.heim, tip.gast)]

            if learningState.avgHomeGoalOverprediction > 0.25, adjusted.toreHeim >= 4 {
                adjusted = SuggestedTip(
                    spieltag: adjusted.spieltag,
                    heim: adjusted.heim,
                    gast: adjusted.gast,
                    toreHeim: adjusted.toreHeim - 1,
                    toreGast: adjusted.toreGast,
                    rationale: adjusted.rationale
                )
            }

            if learningState.highScoreOverpredictionBias > 0.08, adjusted.toreHeim + adjusted.toreGast >= 5 {
                if adjusted.toreHeim >= adjusted.toreGast, adjusted.toreHeim > 0 {
                    adjusted = SuggestedTip(
                        spieltag: adjusted.spieltag,
                        heim: adjusted.heim,
                        gast: adjusted.gast,
                        toreHeim: adjusted.toreHeim - 1,
                        toreGast: adjusted.toreGast,
                        rationale: adjusted.rationale
                    )
                } else if adjusted.toreGast > 0 {
                    adjusted = SuggestedTip(
                        spieltag: adjusted.spieltag,
                        heim: adjusted.heim,
                        gast: adjusted.gast,
                        toreHeim: adjusted.toreHeim,
                        toreGast: adjusted.toreGast - 1,
                        rationale: adjusted.rationale
                    )
                }
            }

            if learningState.drawBias < -0.10,
               let odds,
               isTightOdds(odds),
               abs(adjusted.toreHeim - adjusted.toreGast) == 1,
               adjusted.toreHeim + adjusted.toreGast <= 3 {
                let drawGoals = min(adjusted.toreHeim, adjusted.toreGast) + (adjusted.toreHeim + adjusted.toreGast >= 2 ? 1 : 0)
                adjusted = SuggestedTip(
                    spieltag: adjusted.spieltag,
                    heim: adjusted.heim,
                    gast: adjusted.gast,
                    toreHeim: drawGoals,
                    toreGast: drawGoals,
                    rationale: adjusted.rationale
                )
            }

            return adjusted
        }
    }

    private func isTightOdds(_ odds: BettingOdds) -> Bool {
        guard let quoteHome = parseQuote(odds.quoteHeim),
              let quoteDraw = parseQuote(odds.quoteUnentschieden),
              let quoteAway = parseQuote(odds.quoteGast),
              quoteHome > 0, quoteDraw > 0, quoteAway > 0 else {
            return false
        }
        let probabilities = [1 / quoteHome, 1 / quoteDraw, 1 / quoteAway]
        guard let maxValue = probabilities.max(), let minValue = probabilities.min() else { return false }
        return (maxValue - minValue) < 0.10
    }

    private func parseQuote(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: "."))
    }
}
