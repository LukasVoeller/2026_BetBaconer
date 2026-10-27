import Foundation

/// Builds the clipboard texts for suggested tips from a snapshot of the loaded match data.
struct TipTextFormatter {
    let bettingOdds: [BettingOdds]
    let overUnderOdds: [OverUnderOdds]
    let bttsOdds: [BTTSOdds]
    let handicapOdds: [HandicapOdds]
    let matchWeather: [MatchWeather]
    let llmMatchEnrichments: [LLMMatchEnrichment]
    let matchExpectedGoals: [MatchExpectedGoals]
    let finishedResults: [FinishedMatch]
    let playerAbsences: [PlayerAbsence]

    func detailedText(_ tip: SuggestedTip) -> String {
        let odds = bettingOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let overUnder = overUnderOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let btts = bttsOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let handicap = handicapOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let weather = matchWeather.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let enrichment = llmMatchEnrichments.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let expectedGoals = matchExpectedGoals.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let h2h = finishedResults
            .filter { ($0.heim == tip.heim && $0.gast == tip.gast) || ($0.heim == tip.gast && $0.gast == tip.heim) }
            .sorted { ($0.spieltag, $0.datum) > ($1.spieltag, $1.datum) }
            .prefix(5)
        let relevantAbsences = playerAbsences.filter { absence in
            teamNamesLikelyMatch(absence.teamName, tip.heim) || teamNamesLikelyMatch(absence.teamName, tip.gast)
        }
        let heimAbsences = relevantAbsences.filter { teamNamesLikelyMatch($0.teamName, tip.heim) }
        let gastAbsences = relevantAbsences.filter { teamNamesLikelyMatch($0.teamName, tip.gast) }

        var lines = [
            "\(tip.heim) vs. \(tip.gast)",
            "\(tip.toreHeim) : \(tip.toreGast)"
        ]

        if !tip.rationale.isEmpty {
            lines.append(tip.rationale)
        }

        lines.append("")
        lines.append("Faktoren")
        if let expectedGoals {
            lines.append("- Modell: xG \(tip.heim) \(String(format: "%.2f", expectedGoals.home)) | \(tip.gast) \(String(format: "%.2f", expectedGoals.away)); Dixon-Coles/Poisson")
        } else {
            lines.append("- Modell: Dixon-Coles/Poisson")
        }
        if let odds {
            lines.append("- Quoten: 1 \(odds.quoteHeim) | X \(odds.quoteUnentschieden) | 2 \(odds.quoteGast)")
        }
        if let overUnder {
            var market = "- Tormarkt: O/U \(String(format: "%.1f", overUnder.line)) Over \(overUnder.overQuote) | Under \(overUnder.underQuote)"
            if let btts {
                market += "; BTTS Ja \(btts.yesQuote) | Nein \(btts.noQuote)"
            }
            lines.append(market)
        } else if let btts {
            lines.append("- BTTS: Ja \(btts.yesQuote) | Nein \(btts.noQuote)")
        }
        if let handicap {
            let homeSign = handicap.homeHandicap >= 0 ? "+" : ""
            let awaySign = handicap.awayHandicap >= 0 ? "+" : ""
            lines.append("- Handicap: \(tip.heim) \(homeSign)\(handicap.homeHandicap) \(handicap.homeQuote) | \(tip.gast) \(awaySign)\(handicap.awayHandicap) \(handicap.awayQuote)")
        }
        if let weather {
            lines.append("- Wetter: \(formattedWeatherText(weather))")
        }
        if !h2h.isEmpty {
            lines.append("- H2H: " + h2h.map { "\($0.heim) \($0.toreHeim):\($0.toreGast) \($0.gast)" }.joined(separator: " | "))
        }
        if let enrichment {
            lines.append("- LLM Spielerimpact: \(enrichment.playerImpact)")
            lines.append("- LLM Spielerwert: \(enrichment.playerValue)")
            lines.append("- LLM Schiri/Spielstil: \(enrichment.refereeStats)")
            lines.append("- LLM Sharp-Odds: \(enrichment.sharpOdds)")
            lines.append("- LLM Closing/CLV: \(enrichment.closingLine)")
            lines.append("- LLM Lineup-News: \(enrichment.lineup)")
            lines.append("- LLM Lineup-Struktur: \(enrichment.structuredLineup)")
            lines.append("- LLM Historische Basis: \(enrichment.historicalBaseline)")
            lines.append("- LLM Scoreline-Kalibrierung: \(enrichment.scorelineCalibration)")
            lines.append("- LLM Gewichtung: \(enrichment.learnedWeightHint)")
            lines.append("- LLM Datenqualitaet: \(enrichment.dataQuality) | Confidence \(String(format: "%.0f%%", enrichment.confidence * 100))")
            lines.append(String(format: "- LLM xG-Anpassung: Angriff H %+.0f%% / A %+.0f%% | Defensive H %+.0f%% / A %+.0f%% | Total %+.2f | Lineup %+.0f%% | Spielerwert %+.0f%% | Sharp %+.0f%% | CLV %+.0f%% | Remis %+.0f%%",
                                enrichment.homeAttackAdjustment * 100,
                                enrichment.awayAttackAdjustment * 100,
                                enrichment.homeDefenseAdjustment * 100,
                                enrichment.awayDefenseAdjustment * 100,
                                enrichment.totalGoalsAdjustment,
                                enrichment.lineupImpact * 100,
                                enrichment.playerValueImpact * 100,
                                enrichment.sharpMarketDelta * 100,
                                enrichment.closingLineValue * 100,
                                enrichment.scorelineDrawCalibration * 100))
        }

        if !heimAbsences.isEmpty {
            lines.append("")
            lines.append(contentsOf: formattedAbsenceLines(team: tip.heim, absences: heimAbsences))
        }
        if !gastAbsences.isEmpty {
            if heimAbsences.isEmpty { lines.append("") }
            lines.append(contentsOf: formattedAbsenceLines(team: tip.gast, absences: gastAbsences))
        }

        return lines.joined(separator: "\n")
    }

    func resultText(_ tip: SuggestedTip) -> String {
        var lines = [
            "\(tip.heim) vs. \(tip.gast)",
            "\(tip.toreHeim) : \(tip.toreGast)"
        ]
        if !tip.rationale.isEmpty {
            lines.append(tip.rationale)
        }
        return lines.joined(separator: "\n")
    }

    private func formattedWeatherText(_ weather: MatchWeather) -> String {
        let temperature = weather.temperatureCelsius.map { String(format: "%.0f°C", $0) } ?? "Temp unbekannt"
        let precipitation = weather.precipitationMillimeters.map { String(format: "%.1f mm", $0) } ?? "Niederschlag unbekannt"
        let precipitationProbability = weather.precipitationProbability.map { "\($0)%" } ?? "n/a"
        let wind = weather.windSpeedKmh.map { String(format: "%.0f km/h", $0) } ?? "Wind unbekannt"
        return "\(weather.locationName) | \(temperature) | \(precipitation) (\(precipitationProbability)) | Wind \(wind)"
    }

    private func formattedAbsenceLines(team: String, absences: [PlayerAbsence]) -> [String] {
        [team] + absences.map { absence in
            "\(absenceEmoji(for: absence.type)) \(absence.playerName)\(absence.reason.isEmpty ? "" : " - \(absence.reason)")"
        }
    }
}
