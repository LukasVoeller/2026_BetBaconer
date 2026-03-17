import Foundation

public struct LearningEngine {
    public init() {}

    public func buildLearningState(from predictions: [MatchPrediction], previousState: LearningState = .empty, updatedAt: Date = Date()) -> LearningState {
        let evaluated = predictions.filter(\.isEvaluated)
        guard !evaluated.isEmpty else {
            var empty = previousState
            empty.updatedAt = updatedAt
            empty.sampleSize = 0
            empty.correctionSummaryText = ""
            empty.weightsJSON = "{}"
            empty.tendencyHitRate = 0
            empty.exactHitRate = 0
            empty.goalDiffHitRate = 0
            empty.averageTotalAbsGoalError = 0
            empty.homeBias = 0
            empty.drawBias = 0
            empty.awayBias = 0
            empty.avgHomeGoalOverprediction = 0
            empty.avgAwayGoalOverprediction = 0
            empty.marketAlignmentScore = 0
            empty.highScoreOverpredictionBias = 0
            empty.predictedHomeWinRate = 0
            empty.predictedDrawRate = 0
            empty.predictedAwayWinRate = 0
            empty.actualHomeWinRate = 0
            empty.actualDrawRate = 0
            empty.actualAwayWinRate = 0
            empty.brierScore = 0
            empty.marketBrierScore = 0
            return empty
        }

        let sampleSize = Double(evaluated.count)
        let tendencyHitRate = rate(of: evaluated.compactMap(\.tendencyHit))
        let exactHitRate = rate(of: evaluated.compactMap(\.exactHit))
        let goalDiffHitRate = rate(of: evaluated.compactMap(\.goalDiffHit))
        let averageTotalAbsGoalError = evaluated.compactMap(\.totalAbsGoalError).map(Double.init).average
        let avgHomeGoalOverprediction = zip(evaluated.compactMap(\.actualHomeGoals), evaluated.map(\.predictedHomeGoals))
            .map { Double($1 - $0) }
            .average
        let avgAwayGoalOverprediction = zip(evaluated.compactMap(\.actualAwayGoals), evaluated.map(\.predictedAwayGoals))
            .map { Double($1 - $0) }
            .average

        let predictedOutcomes = evaluated.map(\.predictedOutcome)
        let actualOutcomes = evaluated.compactMap(\.actualOutcome)

        let predictedHomeWinRate = share(of: .homeWin, in: predictedOutcomes)
        let predictedDrawRate = share(of: .draw, in: predictedOutcomes)
        let predictedAwayWinRate = share(of: .awayWin, in: predictedOutcomes)
        let actualHomeWinRate = share(of: .homeWin, in: actualOutcomes)
        let actualDrawRate = share(of: .draw, in: actualOutcomes)
        let actualAwayWinRate = share(of: .awayWin, in: actualOutcomes)

        let homeBias = predictedHomeWinRate - actualHomeWinRate
        let drawBias = predictedDrawRate - actualDrawRate
        let awayBias = predictedAwayWinRate - actualAwayWinRate

        let marketAlignedMatches = evaluated.filter { prediction in
            guard let quoteHome = prediction.quoteHome,
                  let quoteDraw = prediction.quoteDraw,
                  let quoteAway = prediction.quoteAway else {
                return false
            }
            let marketFavorite = favoriteOutcome(quoteHome: quoteHome, quoteDraw: quoteDraw, quoteAway: quoteAway)
            return prediction.predictedOutcome == marketFavorite
        }
        let marketAlignmentScore = evaluated.isEmpty ? 0 : Double(marketAlignedMatches.count) / sampleSize

        let predictedHighScores = evaluated.filter { $0.predictedHomeGoals + $0.predictedAwayGoals >= 5 }.count
        let actualHighScores = evaluated.filter {
            guard let actualHomeGoals = $0.actualHomeGoals, let actualAwayGoals = $0.actualAwayGoals else { return false }
            return actualHomeGoals + actualAwayGoals >= 5
        }.count
        let highScoreOverpredictionBias = (Double(predictedHighScores) / sampleSize) - (Double(actualHighScores) / sampleSize)

        // Brier Scores (nur fuer Matches mit Markt-Quoten)
        let brierMatches = evaluated.filter { $0.quoteHome != nil && $0.quoteDraw != nil && $0.quoteAway != nil }
        let brierScore: Double
        if brierMatches.isEmpty {
            brierScore = 0
        } else {
            let sum = brierMatches.map { m -> Double in
                guard let actualOutcome = m.actualOutcome else { return 0 }
                let oH = actualOutcome == .homeWin ? 1.0 : 0.0
                let oD = actualOutcome == .draw    ? 1.0 : 0.0
                let oA = actualOutcome == .awayWin ? 1.0 : 0.0
                let pH = m.predictedOutcome == .homeWin ? 1.0 : 0.0
                let pD = m.predictedOutcome == .draw    ? 1.0 : 0.0
                let pA = m.predictedOutcome == .awayWin ? 1.0 : 0.0
                return pow(pH - oH, 2) + pow(pD - oD, 2) + pow(pA - oA, 2)
            }.reduce(0, +)
            brierScore = sum / Double(brierMatches.count)
        }

        let marketBrierScore: Double
        if brierMatches.isEmpty {
            marketBrierScore = 0
        } else {
            let validMatches = brierMatches.compactMap { m -> Double? in
                guard let qH = m.quoteHome, let qD = m.quoteDraw, let qA = m.quoteAway,
                      qH > 0, qD > 0, qA > 0,
                      let actualOutcome = m.actualOutcome else { return nil }
                let inv = 1/qH + 1/qD + 1/qA
                let pH = (1/qH) / inv
                let pD = (1/qD) / inv
                let pA = (1/qA) / inv
                let oH = actualOutcome == .homeWin ? 1.0 : 0.0
                let oD = actualOutcome == .draw    ? 1.0 : 0.0
                let oA = actualOutcome == .awayWin ? 1.0 : 0.0
                return pow(pH - oH, 2) + pow(pD - oD, 2) + pow(pA - oA, 2)
            }
            marketBrierScore = validMatches.isEmpty ? 0 : validMatches.reduce(0, +) / Double(validMatches.count)
        }

        let weights = LearningCorrectionWeights(
            drawBoost: max(0, -drawBias),
            homeGoalReductionBias: max(0, avgHomeGoalOverprediction),
            highScoreDampening: max(0, highScoreOverpredictionBias)
        )
        let weightsJSON = encodeWeights(weights)
        let summary = correctionSummary(
            sampleSize: evaluated.count,
            homeBias: homeBias,
            drawBias: drawBias,
            awayBias: awayBias,
            avgHomeGoalOverprediction: avgHomeGoalOverprediction,
            avgAwayGoalOverprediction: avgAwayGoalOverprediction,
            marketAlignmentScore: marketAlignmentScore,
            highScoreOverpredictionBias: highScoreOverpredictionBias
        )

        return LearningState(
            id: previousState.id,
            updatedAt: updatedAt,
            sampleSize: evaluated.count,
            homeBias: homeBias,
            drawBias: drawBias,
            awayBias: awayBias,
            avgHomeGoalOverprediction: avgHomeGoalOverprediction,
            avgAwayGoalOverprediction: avgAwayGoalOverprediction,
            marketAlignmentScore: marketAlignmentScore,
            highScoreOverpredictionBias: highScoreOverpredictionBias,
            correctionSummaryText: summary,
            weightsJSON: weightsJSON,
            tendencyHitRate: tendencyHitRate,
            exactHitRate: exactHitRate,
            goalDiffHitRate: goalDiffHitRate,
            averageTotalAbsGoalError: averageTotalAbsGoalError,
            predictedHomeWinRate: predictedHomeWinRate,
            predictedDrawRate: predictedDrawRate,
            predictedAwayWinRate: predictedAwayWinRate,
            actualHomeWinRate: actualHomeWinRate,
            actualDrawRate: actualDrawRate,
            actualAwayWinRate: actualAwayWinRate,
            brierScore: brierScore,
            marketBrierScore: marketBrierScore
        )
    }

    public func correctionSummary(
        sampleSize: Int,
        homeBias: Double,
        drawBias: Double,
        awayBias: Double,
        avgHomeGoalOverprediction: Double,
        avgAwayGoalOverprediction: Double,
        marketAlignmentScore: Double,
        highScoreOverpredictionBias: Double
    ) -> String {
        var lines = ["Selbstlernende Korrekturen aus \(sampleSize) vergangenen Tipps:"]

        if drawBias < -0.05 {
            lines.append("- Unentschieden wurden bislang zu selten prognostiziert.")
        } else if drawBias > 0.05 {
            lines.append("- Unentschieden wurden bislang zu oft prognostiziert.")
        }

        if homeBias > 0.05 {
            lines.append("- Heimteams wurden leicht überschätzt.")
        } else if awayBias > 0.05 {
            lines.append("- Auswärtsteams wurden leicht überschätzt.")
        }

        if avgHomeGoalOverprediction > 0.15 {
            lines.append("- Hohe Heimtorzahlen wurden im Schnitt um \(formatted(avgHomeGoalOverprediction)) Tore überschätzt.")
        } else if avgHomeGoalOverprediction < -0.15 {
            lines.append("- Heimtorzahlen wurden im Schnitt um \(formatted(abs(avgHomeGoalOverprediction))) Tore unterschätzt.")
        }

        if avgAwayGoalOverprediction > 0.15 {
            lines.append("- Auswärtstore wurden im Schnitt um \(formatted(avgAwayGoalOverprediction)) Tore überschätzt.")
        } else if avgAwayGoalOverprediction < -0.15 {
            lines.append("- Auswärtstore wurden im Schnitt um \(formatted(abs(avgAwayGoalOverprediction))) Tore unterschätzt.")
        }

        if highScoreOverpredictionBias > 0.08 {
            lines.append("- Sehr torreiche Ergebnisse wurden zu häufig prognostiziert.")
        }

        if marketAlignmentScore > 0.72 {
            lines.append("- Bei engen Quoten wurden Favoriten zu oft bevorzugt.")
        } else if marketAlignmentScore < 0.35 {
            lines.append("- Marktquoten wurden bislang eher zu schwach berücksichtigt.")
        }

        if lines.count == 1 {
            lines.append("- Bisher zeigen sich keine starken systematischen Verzerrungen.")
        }

        return lines.joined(separator: "\n")
    }

    public func favoriteOutcome(quoteHome: Double, quoteDraw: Double, quoteAway: Double) -> MatchOutcome {
        if quoteHome <= quoteDraw && quoteHome <= quoteAway {
            return .homeWin
        }
        if quoteAway <= quoteHome && quoteAway <= quoteDraw {
            return .awayWin
        }
        return .draw
    }

    private func encodeWeights(_ weights: LearningCorrectionWeights) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(weights),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func rate(of flags: [Bool]) -> Double {
        guard !flags.isEmpty else { return 0 }
        return Double(flags.filter { $0 }.count) / Double(flags.count)
    }

    private func share(of outcome: MatchOutcome, in outcomes: [MatchOutcome]) -> Double {
        guard !outcomes.isEmpty else { return 0 }
        return Double(outcomes.filter { $0 == outcome }.count) / Double(outcomes.count)
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
