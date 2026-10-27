import AppKit
import SwiftUI

/// Bundesliga tab: fixtures, results and the detailed tip rows.
extension ContentView {
    var dataTab: some View {
        HStack(alignment: .top, spacing: 16) {
            card(title: "Bisherige Ergebnisse", icon: "checkmark.circle") {
                if state.finishedResults.isEmpty {
                    emptyState("Noch keine Daten geladen.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(state.finishedResults) { r in
                                row("\(r.spieltag). Spieltag", "\(r.heim)  \(r.toreHeim):\(r.toreGast)  \(r.gast)", formattedKickoff(r.datum))
                            }
                        }
                    }
                }
            }
            card(title: "Offene Spiele", icon: "calendar") {
                if state.upcomingMatches.isEmpty {
                    emptyState("Noch keine offenen Spiele geladen.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(state.upcomingMatches) { m in
                                row("\(m.spieltag). Spieltag", "\(m.heim) vs. \(m.gast)", formattedKickoff(m.datum))
                            }
                        }
                    }
                }
            }
            card(title: "Importierte Tipps", icon: "lightbulb") {
                if state.suggestedTips.isEmpty {
                    emptyState("Noch keine Tipps importiert.")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button("Alles kopieren") {
                                state.copySuggestedTipsAsText()
                            }
                            Button("Ergebnisse kopieren") {
                                state.copySuggestedResultsAsText()
                            }
                        }
                        .buttonStyle(.bordered)

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(state.orderedSuggestedTips) { tip in
                                    tipRow(tip)
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    func tipRow(_ tip: SuggestedTip) -> some View {
        // Lookups
        let odds    = state.bettingOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let ou      = state.overUnderOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let btts    = state.bttsOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let hcp     = state.handicapOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let weather = state.matchWeather.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let enrichment = state.llmMatchEnrichments.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let expectedGoals = state.matchExpectedGoals.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let modelPrediction = state.latestEnsemblePrediction(for: tip)
        let h2h     = state.finishedResults
            .filter { ($0.heim == tip.heim && $0.gast == tip.gast) || ($0.heim == tip.gast && $0.gast == tip.heim) }
            .sorted { ($0.spieltag, $0.datum) > ($1.spieltag, $1.datum) }
            .prefix(5)
        let absences   = state.playerAbsences.filter { teamNamesLikelyMatch($0.teamName, tip.heim) || teamNamesLikelyMatch($0.teamName, tip.gast) }
        let heimAbsences = absences.filter { teamNamesLikelyMatch($0.teamName, tip.heim) }
        let gastAbsences = absences.filter { teamNamesLikelyMatch($0.teamName, tip.gast) }

        // Vorausberechnungen die @ViewBuilder-Probleme vermeiden
        let tormarktEntry: (label: String, value: String)? = {
            if let ou {
                var s = "O/U \(String(format: "%.1f", ou.line)): Over \(ou.overQuote) / Under \(ou.underQuote)"
                if let btts { s += "  |  BTTS Ja \(btts.yesQuote) / Nein \(btts.noQuote)" }
                return ("Tormarkt", s)
            } else if let btts {
                return ("BTTS", "Ja \(btts.yesQuote) / Nein \(btts.noQuote)")
            }
            return nil
        }()
        let h2hText: String? = h2h.isEmpty ? nil :
            h2h.map { "\($0.heim) \($0.toreHeim):\($0.toreGast) \($0.gast)" }.joined(separator: "  |  ")
        let hasMarketFactors = odds != nil || tormarktEntry != nil || hcp != nil
        let hasContextFactors = weather != nil || h2hText != nil
        let enrichmentRows: [(String, String)] = enrichment.map { e in
            [
                ("Spielerimpact", e.playerImpact),
                ("Spielerwert", e.playerValue),
                ("Schiri/Spielstil", e.refereeStats),
                ("Sharp-Odds", e.sharpOdds),
                ("Closing/CLV", e.closingLine),
                ("Lineup-News", e.lineup),
                ("Lineup-Struktur", e.structuredLineup),
                ("Historische Basis", e.historicalBaseline),
                ("Scoreline-Kalib.", e.scorelineCalibration),
                ("Gewichtung", e.learnedWeightHint),
                ("Datenqualitaet", "\(e.dataQuality) | Confidence \(String(format: "%.0f%%", e.confidence * 100))"),
                ("xG-Anpassung", String(format: "Angriff H %+.0f%% / A %+.0f%% | Defensive H %+.0f%% / A %+.0f%% | Total %+.2f | Lineup %+.0f%% | Spielerwert %+.0f%% | Sharp %+.0f%% | CLV %+.0f%% | Remis %+.0f%%",
                                         e.homeAttackAdjustment * 100,
                                         e.awayAttackAdjustment * 100,
                                         e.homeDefenseAdjustment * 100,
                                         e.awayDefenseAdjustment * 100,
                                         e.totalGoalsAdjustment,
                                         e.lineupImpact * 100,
                                         e.playerValueImpact * 100,
                                         e.sharpMarketDelta * 100,
                                         e.closingLineValue * 100,
                                         e.scorelineDrawCalibration * 100))
            ]
        } ?? []

        return VStack(alignment: .leading, spacing: 4) {
            // Header
            Text("\(tip.heim) vs. \(tip.gast)")
                .font(.system(size: 15, weight: .semibold))
            Text("\(tip.toreHeim) : \(tip.toreGast)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            if !tip.rationale.isEmpty {
                Text(tip.rationale)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            factorSection("Modell") {
                if let expectedGoals {
                    tipMetricRow("xG", String(format: "%@ %.2f | %@ %.2f", tip.heim, expectedGoals.home, tip.gast, expectedGoals.away))
                }
                if let modelPrediction,
                   let home = modelPrediction.probabilityHomeWin,
                   let draw = modelPrediction.probabilityDraw,
                   let away = modelPrediction.probabilityAwayWin {
                    tipMetricRow("Wahrscheinlichkeiten", String(format: "1 %.0f%% | X %.0f%% | 2 %.0f%%", home * 100, draw * 100, away * 100))
                }
                if let confidence = modelPrediction?.confidence {
                    tipMetricRow("Modell-Sicherheit", String(format: "%.0f/100 (heuristisch)", confidence * 100))
                }
                if let topScorelines = modelPrediction?.topScorelines, !topScorelines.isEmpty {
                    tipMetricRow(
                        "Top-3",
                        topScorelines.map { String(format: "%d:%d %.0f%%", $0.homeGoals, $0.awayGoals, $0.probability * 100) }.joined(separator: "  |  ")
                    )
                }
                tipMetricRow("Finale Auswahl", "Maximale erwartete Kicktipp-Punkte (Punkteregel aus den Einstellungen) aus der Poisson-Scoreline-Matrix")
            }

            if hasMarketFactors {
                factorSection("Markt") {
                    if let o = odds {
                        tipMetricRow("Quoten", "1: \(o.quoteHeim)  X: \(o.quoteUnentschieden)  2: \(o.quoteGast)")
                    }
                    if let tormarktEntry {
                        tipMetricRow(tormarktEntry.label, tormarktEntry.value)
                    }
                    if let hcp {
                        let hSign = hcp.homeHandicap >= 0 ? "+" : ""
                        let aSign = hcp.awayHandicap >= 0 ? "+" : ""
                        tipMetricRow("Handicap", "\(tip.heim) (\(hSign)\(hcp.homeHandicap)) \(hcp.homeQuote)  /  \(tip.gast) (\(aSign)\(hcp.awayHandicap)) \(hcp.awayQuote)")
                    }
                }
            }

            if hasContextFactors {
                factorSection("Kontext") {
                    if let weather {
                        tipMetricRow("Wetter", tipWeatherText(weather))
                    }
                    if let h2hText {
                        tipMetricRow("H2H", h2hText)
                    }
                }
            }

            if !enrichmentRows.isEmpty {
                factorSection("LLM-Zusatzrecherche") {
                    ForEach(enrichmentRows, id: \.0) { row in
                        tipMetricRow(row.0, row.1)
                    }
                }
            }

            // Ausfälle
            if !heimAbsences.isEmpty || !gastAbsences.isEmpty {
                factorSection("Ausfaelle") {
                    if !heimAbsences.isEmpty { absenceGroup(team: tip.heim, absences: heimAbsences) }
                    if !gastAbsences.isEmpty { absenceGroup(team: tip.gast, absences: gastAbsences) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func factorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 3) {
                content()
            }
        }
        .padding(.top, 8)
    }

    private func tipMetricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tipWeatherText(_ w: MatchWeather) -> String {
        var parts: [String] = []
        if let t = w.temperatureCelsius { parts.append(String(format: "%.0f°C", t)) }
        if let mm = w.precipitationMillimeters, mm > 0.5 { parts.append(String(format: "%.1f mm", mm)) }
        if let prob = w.precipitationProbability, prob > 10 { parts.append("Regen \(prob)%") }
        if let wind = w.windSpeedKmh, wind > 20 { parts.append(String(format: "Wind %.0f km/h", wind)) }
        let detail = parts.isEmpty ? "keine Besonderheiten" : parts.joined(separator: ", ")
        return "\(w.locationName) – \(detail)"
    }

    private func absenceGroup(team: String, absences: [PlayerAbsence]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(team)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(absences) { absence in
                HStack(spacing: 4) {
                    Text(absenceEmoji(for: absence.type))
                        .font(.system(size: 11))
                    Text("\(absence.playerName)\(absence.reason.isEmpty ? "" : " – \(absence.reason)")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
