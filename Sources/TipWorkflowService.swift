import Foundation

enum TipWorkflowError: LocalizedError {
    case invalidModelOutput
    case fixtureMismatch

    var errorDescription: String? {
        switch self {
        case .invalidModelOutput:
            return "Die eingefuegte Antwort enthaelt kein valides JSON mit Tipps."
        case .fixtureMismatch:
            return "Die eingefuegte Antwort passt nicht zu den offenen Spielen."
        }
    }
}

struct TipWorkflowService {
    func buildPrompt(
        season: Int,
        finishedResults: [FinishedMatch],
        upcomingMatches: [UpcomingMatch],
        bettingOdds: [BettingOdds] = [],
        overUnderOdds: [OverUnderOdds] = [],
        bttsOdds: [BTTSOdds] = [],
        handicapOdds: [HandicapOdds] = [],
        playerAbsences: [PlayerAbsence] = [],
        teamMetadata: [TeamMetadata] = [],
        matchWeather: [MatchWeather] = [],
        matchReferees: [MatchReferee] = [],
        teamExtraFixtures: [TeamExtraFixture] = [],
        teamShotsStats: [TeamSeasonShots] = [],
        tipHistory: [TipGenerationRecord] = [],
        learningState: LearningState? = nil
    ) -> String {
        let standings = buildStandings(from: finishedResults)
        let restDaysByTeam = buildRestDaysByTeam(finishedResults: finishedResults, upcomingMatches: upcomingMatches)
        let formTableSection = recentFormTable(from: finishedResults)
        let metadataByTeam = Dictionary(uniqueKeysWithValues: teamMetadata.map { (normalizeTeamName($0.teamName), $0) })
        let weatherByMatch = Dictionary(uniqueKeysWithValues: matchWeather.map { ("\(normalizeTeamName($0.heim))|\(normalizeTeamName($0.gast))", $0) })

        // --- Lookup maps ---
        let normalizedOddsMap = Dictionary(
            uniqueKeysWithValues: bettingOdds.map {
                ("\(normalizeTeamName($0.heim))|\(normalizeTeamName($0.gast))", $0)
            }
        )
        let normalizedOUMap = Dictionary(
            uniqueKeysWithValues: overUnderOdds.map {
                ("\(normalizeTeamName($0.heim))|\(normalizeTeamName($0.gast))", $0)
            }
        )
        let normalizedBTTSMap = Dictionary(
            uniqueKeysWithValues: bttsOdds.map {
                ("\(normalizeTeamName($0.heim))|\(normalizeTeamName($0.gast))", $0)
            }
        )
        let normalizedHandicapMap = Dictionary(
            uniqueKeysWithValues: handicapOdds.map {
                ("\(normalizeTeamName($0.heim))|\(normalizeTeamName($0.gast))", $0)
            }
        )
        let normalizedRefereeMap = Dictionary(
            uniqueKeysWithValues: matchReferees.map {
                ("\(normalizeTeamName($0.heim))|\(normalizeTeamName($0.gast))", $0.referee)
            }
        )
        let extraFixturesByTeam = Dictionary(grouping: teamExtraFixtures) { normalizeTeamName($0.teamName) }
        let shotsByTeam = Dictionary(
            uniqueKeysWithValues: teamShotsStats.map { (normalizeTeamName($0.teamName), $0) }
        )

        // --- Kompakte Teamprofile (nur Teams im naechsten Spieltag) ---
        let teamsInFocus = Set(upcomingMatches.flatMap { [$0.heim, $0.gast] })
        let teamStatsSection = teamsInFocus.sorted()
            .map { teamProfile(team: $0, results: finishedResults, standings: standings, restDaysByTeam: restDaysByTeam, metadata: metadataByTeam[normalizeTeamName($0)], shotsStats: shotsByTeam[normalizeTeamName($0)]) }
            .joined(separator: "\n")

        // --- Spielplan mit Tabellenkontext, Resttagen, H2H und Quoten ---
        let upcomingLines = upcomingMatches.map { m -> String in
            var blocks = ["\(m.spieltag). Spieltag | \(m.heim) vs. \(m.gast) (\(m.datum))"]
            let homeStanding = standings[normalizeTeamName(m.heim)]
            let awayStanding = standings[normalizeTeamName(m.gast)]
            if let homeStanding, let awayStanding {
                blocks.append(
                    "  Tabelle: #\(homeStanding.rank) \(m.heim) (\(homeStanding.points) Pkt, \(signed(homeStanding.goalDifference)) TD) vs. #\(awayStanding.rank) \(m.gast) (\(awayStanding.points) Pkt, \(signed(awayStanding.goalDifference)) TD)"
                )
                blocks.append("  Motivation: \(motivationSummary(home: m.heim, away: m.gast, standings: standings))")
            }
            let homeRest = restDaysByTeam[normalizeTeamName(m.heim)]
            let awayRest = restDaysByTeam[normalizeTeamName(m.gast)]
            if homeRest != nil || awayRest != nil {
                blocks.append("  Resttage seit letztem Pflichtspiel: \(m.heim) \(formatRestDays(homeRest)) | \(m.gast) \(formatRestDays(awayRest))")
            }
            if let metadata = metadataByTeam[normalizeTeamName(m.heim)] {
                let venue = metadata.stadiumName.isEmpty ? metadata.stadiumLocation : "\(metadata.stadiumName), \(metadata.stadiumLocation)"
                if !venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append("  Stadion/Ort: \(venue)")
                }
            }
            if let weather = weatherByMatch["\(normalizeTeamName(m.heim))|\(normalizeTeamName(m.gast))"] {
                blocks.append("  Wetter: \(weatherSummary(weather))")
            }
            if let h2h = headToHeadSummary(homeTeam: m.heim, awayTeam: m.gast, results: finishedResults) {
                blocks.append("  H2H letzte Duelle (geringes Gewicht, max. 5-10%): \(h2h)")
            }
            if let o = normalizedOddsMap["\(normalizeTeamName(m.heim))|\(normalizeTeamName(m.gast))"] {
                var oddsBlock = "  Quoten: Sieg \(m.heim) \(o.quoteHeim) / Unentschieden \(o.quoteUnentschieden) / Sieg \(m.gast) \(o.quoteGast)"
                if let h = Double(o.quoteHeim.replacingOccurrences(of: ",", with: ".")),
                   let d = Double(o.quoteUnentschieden.replacingOccurrences(of: ",", with: ".")),
                   let a = Double(o.quoteGast.replacingOccurrences(of: ",", with: ".")),
                   h > 0, d > 0, a > 0 {
                    let inv = 1/h + 1/d + 1/a
                    let pH = (1/h) / inv * 100
                    let pD = (1/d) / inv * 100
                    let pA = (1/a) / inv * 100
                    oddsBlock += String(
                        format: "\n  Implizite Wahrscheinlichkeiten: %@ %.0f%% / Unentschieden %.0f%% / %@ %.0f%%",
                        m.heim, pH, pD, m.gast, pA
                    )
                }
                blocks.append(oddsBlock)
            }
            let matchKey = "\(normalizeTeamName(m.heim))|\(normalizeTeamName(m.gast))"
            // O/U and BTTS
            var tormarktLine = ""
            if let ou = normalizedOUMap[matchKey] {
                if let over = Double(ou.overQuote), let under = Double(ou.underQuote), over > 0, under > 0 {
                    let invOU = 1/over + 1/under
                    let pOver = (1/over) / invOU * 100
                    let pUnder = (1/under) / invOU * 100
                    tormarktLine = String(format: "  Tormarkt: O/U %.1f → Over %@ (%.0f%%) / Under %@ (%.0f%%)",
                        ou.line, ou.overQuote, pOver, ou.underQuote, pUnder)
                } else {
                    tormarktLine = "  Tormarkt: O/U \(ou.line) → Over \(ou.overQuote) / Under \(ou.underQuote)"
                }
                if let btts = normalizedBTTSMap[matchKey] {
                    var bttsAppend = " | BTTS Ja \(btts.yesQuote) / Nein \(btts.noQuote)"
                    if let yes = Double(btts.yesQuote), let no = Double(btts.noQuote), yes > 0, no > 0 {
                        let invBTTS = 1/yes + 1/no
                        let pYes = (1/yes) / invBTTS * 100
                        let pNo = (1/no) / invBTTS * 100
                        bttsAppend = String(format: " | BTTS Ja %@ (%.0f%%) / Nein %@ (%.0f%%)",
                            btts.yesQuote, pYes, btts.noQuote, pNo)
                    }
                    tormarktLine += bttsAppend
                }
                blocks.append(tormarktLine)
            } else if let btts = normalizedBTTSMap[matchKey] {
                var bttsLine = "  BTTS Ja \(btts.yesQuote) / Nein \(btts.noQuote)"
                if let yes = Double(btts.yesQuote), let no = Double(btts.noQuote), yes > 0, no > 0 {
                    let invBTTS = 1/yes + 1/no
                    let pYes = (1/yes) / invBTTS * 100
                    let pNo = (1/no) / invBTTS * 100
                    bttsLine = String(format: "  BTTS Ja %@ (%.0f%%) / Nein %@ (%.0f%%)",
                        btts.yesQuote, pYes, btts.noQuote, pNo)
                }
                blocks.append(bttsLine)
            }
            // Handicap
            if let hcp = normalizedHandicapMap[matchKey] {
                let homeSign = hcp.homeHandicap >= 0 ? "+" : ""
                let awaySign = hcp.awayHandicap >= 0 ? "+" : ""
                blocks.append("  Handicap: \(m.heim) (\(homeSign)\(hcp.homeHandicap)) \(hcp.homeQuote) / \(m.gast) (\(awaySign)\(hcp.awayHandicap)) \(hcp.awayQuote)")
            }
            // Schiedsrichter
            if let referee = normalizedRefereeMap[matchKey] {
                blocks.append("  Schiedsrichter: \(referee)")
            }
            // Europaeische/Pokal-Belastung
            let homeExtraKey = normalizeTeamName(m.heim)
            let awayExtraKey = normalizeTeamName(m.gast)
            let homeExtras = extraFixturesByTeam[homeExtraKey] ?? []
            let awayExtras = extraFixturesByTeam[awayExtraKey] ?? []
            if !homeExtras.isEmpty {
                for extra in homeExtras {
                    let homeAway = extra.isHome ? "Heim" : "Auswaerts"
                    blocks.append("  Zusatzbelastung \(m.heim): \(extra.competition) vs. \(extra.opponent) (\(homeAway))")
                }
            }
            if !awayExtras.isEmpty {
                for extra in awayExtras {
                    let homeAway = extra.isHome ? "Heim" : "Auswaerts"
                    blocks.append("  Zusatzbelastung \(m.gast): \(extra.competition) vs. \(extra.opponent) (\(homeAway))")
                }
            }
            return blocks.joined(separator: "\n")
        }.joined(separator: "\n\n")

        // --- Ausfälle ---
        let absenceLines = groupedAbsenceLines(playerAbsences: playerAbsences, teamsInFocus: teamsInFocus)
        let absenceSection = absenceLines.isEmpty ? "" : """


Verletzte und gesperrte Spieler:
\(absenceLines.joined(separator: "\n"))
Gewichte die Bedeutung: Torwart / Topscorer / zentrale Verteidigung = hoher Einfluss | Stammspieler = mittlerer Einfluss | Rotationsspieler = geringer Einfluss.
"""

        // --- Konsistenzsignal aus früheren Generierungen ---
        let targetSpieltag = upcomingMatches.first?.spieltag
        let relevantHistory = tipHistory.filter { $0.spieltag == targetSpieltag }
        let historySection: String
        if !relevantHistory.isEmpty {
            var predictions: [String: [String: Int]] = [:]
            for record in relevantHistory {
                for tip in record.tips {
                    let key = "\(tip.heim)|\(tip.gast)"
                    let score = "\(tip.toreHeim):\(tip.toreGast)"
                    predictions[key, default: [:]][score, default: 0] += 1
                }
            }
            let lines = upcomingMatches.compactMap { m -> String? in
                let key = "\(m.heim)|\(m.gast)"
                guard let scores = predictions[key] else { return nil }
                let total = scores.values.reduce(0, +)
                let summary = scores.sorted { $0.value > $1.value }
                    .map { "\($0.value)x \($0.key)" }
                    .joined(separator: ", ")
                return "- \(m.heim) vs. \(m.gast): \(summary) (aus \(total) Laeufen)"
            }
            historySection = lines.isEmpty ? "" : """


Bisherige KI-Vorhersagen fuer diesen Spieltag (\(relevantHistory.count) Laeufe) – Konsistenzsignal, Gewicht ~5–10%:
\(lines.joined(separator: "\n"))
"""
        } else {
            historySection = ""
        }

        let learningSection = learningState?.promptSummary(minSampleSize: 30) ?? ""

        return """
Du bist ein Fussball-Prognose-Modell. Analysiere die Bundesliga-Saison \(season) und prognostiziere die Ergebnisse des naechsten Spieltags. Arbeite intern Schritt fuer Schritt, gib nach aussen aber ausschliesslich das JSON-Objekt aus.

METHODIK (intern, nicht im Output):

1. TEAMSTAERKE BESTIMMEN
   Nutze die vorberechneten Teamprofile. Gewichte Form nach Aktualitaet:
   letzte 5 Spiele: 50%, Spiele 6–10: 30%, aeltere: 20%.
   Berechne pro Team:
   - Punkte/Spiel, Tore/Spiel, Gegentore/Spiel, Tor-Differenz/Spiel
   - Angriffsstärke = Ø Tore/Spiel (gew.) / Liga-Durchschnitt (~1.45 Tore/Spiel)
   - Defensivstaerke = Ø Gegentore/Spiel (gew.) / Liga-Durchschnitt
   - Heim-/Auswaertsform separat beruecksichtigen: Tore, Gegentore, Punkte pro Spiel
   - Tabellenkontext, Tor-Differenz und Resttage als Zusatzsignale einbeziehen
   - Bundesliga-Heimvorteil explizit einpreisen (Faktor ~1.25)
   - Formtabelle der letzten 6 Spieltage als kompaktes Normierungssignal nutzen
   Wenn Schussdaten verfuegbar: Angriffsstärke = Ø ShotsOnGoal × Verwertungsrate statt reiner Tore/Spiel.

2. VERLETZUNGEN & SPERREN
   Reduziere Angriffs- oder Defensivstaerke des betroffenen Teams entsprechend der Spielerbedeutung.
   Wenn die Spielerrolle nicht eindeutig erkennbar ist, konservativ statt extrem anpassen.
   Nutze die Team-Zusammenfassungen der Ausfaelle, nicht nur Einzelnamen.

3. WETTQUOTEN (Gewicht 30–40%)
   Die implizierten Wahrscheinlichkeiten aus den Quoten aggregieren Marktwissen inklusive Verletzungen und Formeinschaetzungen. Nutze sie als starkes Signal. Weiche nur ab, wenn deine Analyse klar dagegen spricht.

4. HEAD-TO-HEAD (max. 5–10%)
   Direkte Duelle nur schwach gewichten. Nutze sie nur als kleines Zusatzsignal, niemals als Hauptgrund.

5. TABELLENKONTEXT & MOTIVATION
   Beruecksichtige Abstiegskampf, Europaplaetze, Titelrennen und Punkteabstaende nur moderat als Kontextsignal.

6. REST & BELASTUNG
   Wenige Resttage koennen Pressing, Intensitaet und Torerwartung beeinflussen. Werte sehr kurze Regeneration als leicht negatives Signal.
   Europaeische/Pokal-Belastung unter der Woche (CL/EL/ECL/DFB-Pokal) ist ein deutlich staerkeres negatives Signal als reine Liga-Resttage.

7. WETTER & SPIELORT
   Beruecksichtige Wetter nur moderat: starker Regen, Wind oder winterliche Bedingungen koennen Tempo und Torerwartung senken.

8. TORERWARTUNG (Expected Goals, xG-Proxy)
   Berechne fuer jedes Team:
   xG_Heim = Angriff_Heim × Abwehr_Gast × Heimvorteil-Faktor
   xG_Gast = Angriff_Gast × Abwehr_Heim
   Pruefe Plausibilitaet gegen Quoten.

9. SIMULATION
   Simuliere jedes Spiel gedanklich 500-mal mit Poisson-verteilten Torerwartungen.
   Gib das wahrscheinlichste Endergebnis zurueck. Wenn mehrere Ergebnisse nah beieinander liegen, bevorzuge das marktnaehere und realistischere Resultat.

10. KONSISTENZ (Gewicht 5–10%)
   Bisherige KI-Vorhersagen fuer denselben Spieltag als leichtes Stabilitaetssignal.

REALISMUS-REGELN:
- Typische Bundesliga-Scorelines: 1:0, 2:1, 1:1, 2:0, 0:1, 1:2, 0:0, 3:1, 2:2, 3:0
- Ergebnisse mit >5 Toren Differenz vermeiden
- Unentschieden treten in ~25% aller Spiele auf – nicht zu selten waehlen
- Prognosen zur Liga-Norm hin kalibrieren, extreme Ausreisser vermeiden

\(formTableSection.isEmpty ? "" : """
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
\(formTableSection)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TEAMSTATISTIKEN (Saison \(season), gewichtet nach Aktualitaet):
\(teamStatsSection)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NAECHSTER SPIELTAG:
\(upcomingLines)\(absenceSection)\(historySection)\(learningSection)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
OUTPUT-ANFORDERUNGEN:
- Exakt ein JSON-Objekt mit dem Feld "tips", kein anderer Text, keine Markdown-Formatierung.
- In "tips" genau ein Objekt pro Spiel.
- Felder exakt: "spieltag", "heim", "gast", "tore_heim", "tore_gast", "rationale"
- "rationale" max. 25 Woerter: die 2–3 entscheidenden Faktoren (Form, Quoten, Verletzungen).
- Mannschaftsnamen exakt aus den Spieldaten uebernehmen.

{
  "tips": [
    {
      "spieltag": 26,
      "heim": "Team A",
      "gast": "Team B",
      "tore_heim": 2,
      "tore_gast": 1,
      "rationale": "Starke Heimform, Abwehr des Gastes durch Ausfaelle geschwaecht, Quoten bestaetigen Favorit."
    }
  ]
}
"""
    }

    /// Encodes tips back into the JSON format expected by the LLM response schema.
    func encodeTipsAsJSON(_ tips: [SuggestedTip]) -> String {
        struct ResponseEnvelope: Encodable { let tips: [TipOut] }
        struct TipOut: Encodable {
            let spieltag: Int; let heim: String; let gast: String
            let toreHeim: Int; let toreGast: Int; let rationale: String
            private enum CodingKeys: String, CodingKey {
                case spieltag, heim, gast
                case toreHeim = "tore_heim"; case toreGast = "tore_gast"; case rationale
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = ResponseEnvelope(tips: tips.map {
            TipOut(spieltag: $0.spieltag, heim: $0.heim, gast: $0.gast,
                   toreHeim: $0.toreHeim, toreGast: $0.toreGast, rationale: $0.rationale)
        })
        guard let data = try? encoder.encode(payload), let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    func parseTips(from content: String, upcomingMatches: [UpcomingMatch]) throws -> [SuggestedTip] {
        let data = Data(content.utf8)
        let decoder = JSONDecoder()

        let payload: [TipPayload]
        if let wrapped = try? decoder.decode(TipsEnvelope.self, from: data) {
            payload = wrapped.tips
        } else if let directArray = try? decoder.decode([TipPayload].self, from: data) {
            payload = directArray
        } else if let start = content.firstIndex(of: "["),
                  let end = content.lastIndex(of: "]"),
                  start <= end,
                  let directArray = try? decoder.decode([TipPayload].self, from: Data(String(content[start...end]).utf8)) {
            payload = directArray
        } else {
            throw TipWorkflowError.invalidModelOutput
        }

        let tips = payload.map {
            SuggestedTip(
                spieltag: $0.spieltag,
                heim: $0.heim,
                gast: $0.gast,
                toreHeim: $0.toreHeim,
                toreGast: $0.toreGast,
                rationale: $0.rationale
            )
        }

        let expected = Set(upcomingMatches.map { "\($0.heim)|\($0.gast)" })
        let actual = Set(tips.map { "\($0.heim)|\($0.gast)" })
        guard expected == actual else {
            throw TipWorkflowError.fixtureMismatch
        }

        return tips
    }

    // MARK: - Private helpers

    private func teamProfile(team: String, results: [FinishedMatch], standings: [String: TeamStanding], restDaysByTeam: [String: Int], metadata: TeamMetadata?, shotsStats: TeamSeasonShots? = nil) -> String {
        let all = results
            .filter { $0.heim == team || $0.gast == team }
            .sorted { $0.spieltag > $1.spieltag }

        guard !all.isEmpty else { return "\(team): Keine Daten verfuegbar" }

        func res(_ m: FinishedMatch) -> (gf: Int, ga: Int) {
            m.heim == team ? (m.toreHeim, m.toreGast) : (m.toreGast, m.toreHeim)
        }
        func pts(_ gf: Int, _ ga: Int) -> Double { gf > ga ? 3 : gf == ga ? 1 : 0 }

        // Gewichtete Gesamtstatistik
        var wGF = 0.0, wGA = 0.0, wPts = 0.0, wTotal = 0.0
        for (i, m) in all.enumerated() {
            let w: Double = i < 5 ? 0.5 : i < 10 ? 0.3 : 0.2
            let (gf, ga) = res(m)
            wGF   += Double(gf) * w
            wGA   += Double(ga) * w
            wPts  += pts(gf, ga) * w
            wTotal += w
        }
        let avgGF  = wTotal > 0 ? wGF  / wTotal : 0
        let avgGA  = wTotal > 0 ? wGA  / wTotal : 0
        let avgPts = wTotal > 0 ? wPts / wTotal : 0
        let avgGD  = avgGF - avgGA

        // Heim
        let home = all.filter { $0.heim == team }
        let hGF = home.isEmpty ? 0.0 : Double(home.map { $0.toreHeim }.reduce(0, +)) / Double(home.count)
        let hGA = home.isEmpty ? 0.0 : Double(home.map { $0.toreGast }.reduce(0, +)) / Double(home.count)
        let hPts = home.isEmpty ? 0.0 : Double(home.reduce(0) { partial, match in
            partial + (match.toreHeim > match.toreGast ? 3 : (match.toreHeim == match.toreGast ? 1 : 0))
        }) / Double(home.count)

        // Auswärts
        let away = all.filter { $0.gast == team }
        let aGF = away.isEmpty ? 0.0 : Double(away.map { $0.toreGast }.reduce(0, +)) / Double(away.count)
        let aGA = away.isEmpty ? 0.0 : Double(away.map { $0.toreHeim }.reduce(0, +)) / Double(away.count)
        let aPts = away.isEmpty ? 0.0 : Double(away.reduce(0) { partial, match in
            partial + (match.toreGast > match.toreHeim ? 3 : (match.toreGast == match.toreHeim ? 1 : 0))
        }) / Double(away.count)

        // Form letzte 5
        let form = all.prefix(5).map { m -> String in
            let (gf, ga) = res(m)
            return gf > ga ? "S" : gf == ga ? "U" : "N"
        }.joined(separator: "-")

        let homeForm = home.sorted { $0.spieltag > $1.spieltag }.prefix(5).map { match in
            match.toreHeim > match.toreGast ? "S" : match.toreHeim == match.toreGast ? "U" : "N"
        }.joined(separator: "-")
        let awayForm = away.sorted { $0.spieltag > $1.spieltag }.prefix(5).map { match in
            match.toreGast > match.toreHeim ? "S" : match.toreGast == match.toreHeim ? "U" : "N"
        }.joined(separator: "-")

        let f = { (v: Double) in String(format: "%.2f", v) }
        let standingText: String
        if let standing = standings[normalizeTeamName(team)] {
            standingText = "  Tabelle: Rang \(standing.rank) | Punkte \(standing.points) | Tore \(standing.goalsFor):\(standing.goalsAgainst) | TD \(signed(standing.goalDifference))"
        } else {
            standingText = "  Tabelle: Keine Daten verfuegbar"
        }

        let restText = "  Resttage: \(formatRestDays(restDaysByTeam[normalizeTeamName(team)]))"
        let venueText: String
        if let metadata {
            let venue = metadata.stadiumName.isEmpty ? metadata.stadiumLocation : "\(metadata.stadiumName), \(metadata.stadiumLocation)"
            venueText = venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "  Stadion: Keine Daten verfuegbar" : "  Stadion: \(venue)"
        } else {
            venueText = "  Stadion: Keine Daten verfuegbar"
        }
        return """
\(team) (\(all.count) Sp.):
\(standingText)
\(venueText)
  Form gesamt (letzte 5): \(form.isEmpty ? "–" : form)
  Gewichtete Kernwerte: Pkt/Sp \(f(avgPts)) | Tore/Sp \(f(avgGF)) | Gegentore/Sp \(f(avgGA)) | Tor-Diff/Sp \(f(avgGD))
  Heim (\(home.count) Sp.): Form \(homeForm.isEmpty ? "–" : homeForm) | Tore \(f(hGF)) | Gegentore \(f(hGA)) | Pkt/Sp \(f(hPts))
  Auswaerts (\(away.count) Sp.): Form \(awayForm.isEmpty ? "–" : awayForm) | Tore \(f(aGF)) | Gegentore \(f(aGA)) | Pkt/Sp \(f(aPts))
\(restText)\(shotsStats.map { s in
    "\n  Schuesse aufs Tor/Sp.: \(String(format: "%.1f", s.shotsOnGoalPerGameHome)) (Heim) | \(String(format: "%.1f", s.shotsOnGoalPerGameAway)) (Auswaerts) | Verwertung: \(String(format: "%.1f%%", s.shotsOnGoalConversionHome * 100)) (H) \(String(format: "%.1f%%", s.shotsOnGoalConversionAway * 100)) (A)"
} ?? "")
"""
    }

    private func headToHeadSummary(homeTeam: String, awayTeam: String, results: [FinishedMatch]) -> String? {
        let duels = results.filter {
            ($0.heim == homeTeam && $0.gast == awayTeam) || ($0.heim == awayTeam && $0.gast == homeTeam)
        }
        .sorted { ($0.spieltag, $0.datum) > ($1.spieltag, $1.datum) }
        .prefix(5)

        guard !duels.isEmpty else { return nil }

        let lines = duels.map { duel in
            "\(duel.heim) \(duel.toreHeim):\(duel.toreGast) \(duel.gast)"
        }
        return lines.joined(separator: " | ")
    }

    private func groupedAbsenceLines(playerAbsences: [PlayerAbsence], teamsInFocus: Set<String>) -> [String] {
        let normalizedTeamsInFocus = Set(teamsInFocus.map(normalizeTeamName))
        let relevant = playerAbsences.filter { normalizedTeamsInFocus.contains(normalizeTeamName($0.teamName)) }
        guard !relevant.isEmpty else { return [] }

        let grouped = Dictionary(grouping: relevant) { normalizeTeamName($0.teamName) }
        return grouped.keys.sorted().compactMap { team in
            guard let absences = grouped[team], !absences.isEmpty else { return nil }
            let suspensions = absences.filter { $0.type.lowercased().contains("sperre") }
            let injuries = absences.filter { !$0.type.lowercased().contains("sperre") }
            let highlighted = absences.prefix(4).map {
                "\($0.playerName) (\($0.type)\($0.reason.isEmpty ? "" : ": \($0.reason)"))"
            }.joined(separator: ", ")
            let displayTeam = absences.first?.teamName ?? team
            return "- \(displayTeam): \(absences.count) Ausfaelle, davon \(injuries.count) Verletzung(en), \(suspensions.count) Sperre(n). Wichtigste Eintraege: \(highlighted)"
        }
    }

    private func recentFormTable(from results: [FinishedMatch], lastN: Int = 6) -> String {
        guard !results.isEmpty else { return "" }

        let allSpieldags = Set(results.map { $0.spieltag }).sorted().suffix(lastN)
        guard allSpieldags.count >= 3 else { return "" }

        let relevantMatches = results.filter { allSpieldags.contains($0.spieltag) }

        var points: [String: Int] = [:]
        var goalsFor: [String: Int] = [:]
        var goalsAgainst: [String: Int] = [:]
        var displayNames: [String: String] = [:]

        for m in relevantMatches {
            let homeKey = normalizeTeamName(m.heim)
            let awayKey = normalizeTeamName(m.gast)
            displayNames[homeKey] = m.heim
            displayNames[awayKey] = m.gast

            goalsFor[homeKey, default: 0] += m.toreHeim
            goalsFor[awayKey, default: 0] += m.toreGast
            goalsAgainst[homeKey, default: 0] += m.toreGast
            goalsAgainst[awayKey, default: 0] += m.toreHeim

            if m.toreHeim > m.toreGast {
                points[homeKey, default: 0] += 3
            } else if m.toreHeim == m.toreGast {
                points[homeKey, default: 0] += 1
                points[awayKey, default: 0] += 1
            } else {
                points[awayKey, default: 0] += 3
            }
        }

        let sorted = displayNames.keys.sorted {
            let pA = points[$0, default: 0]; let pB = points[$1, default: 0]
            if pA != pB { return pA > pB }
            let gdA = (goalsFor[$0] ?? 0) - (goalsAgainst[$0] ?? 0)
            let gdB = (goalsFor[$1] ?? 0) - (goalsAgainst[$1] ?? 0)
            if gdA != gdB { return gdA > gdB }
            return $0 < $1
        }

        let lines = sorted.enumerated().map { (i, key) -> String in
            let name = displayNames[key] ?? key
            let pts = points[key, default: 0]
            let gf = goalsFor[key, default: 0]
            let ga = goalsAgainst[key, default: 0]
            let gd = gf - ga
            let gdStr = gd >= 0 ? "+\(gd)" : "\(gd)"
            return "\(i + 1). \(name) | \(pts) Pkt | \(gf):\(ga) | \(gdStr)"
        }

        return """
FORMTABELLE LETZTE \(allSpieldags.count) SPIELTAGE:
\(lines.joined(separator: "\n"))
"""
    }

    private func buildStandings(from results: [FinishedMatch]) -> [String: TeamStanding] {
        var table: [String: TeamStandingAccumulator] = [:]

        for result in results {
            let homeKey = normalizeTeamName(result.heim)
            let awayKey = normalizeTeamName(result.gast)

            table[homeKey, default: TeamStandingAccumulator(teamName: result.heim)].apply(
                goalsFor: result.toreHeim,
                goalsAgainst: result.toreGast
            )
            table[awayKey, default: TeamStandingAccumulator(teamName: result.gast)].apply(
                goalsFor: result.toreGast,
                goalsAgainst: result.toreHeim
            )
        }

        let sorted = table.values.sorted {
            if $0.points != $1.points { return $0.points > $1.points }
            if $0.goalDifference != $1.goalDifference { return $0.goalDifference > $1.goalDifference }
            if $0.goalsFor != $1.goalsFor { return $0.goalsFor > $1.goalsFor }
            return $0.teamName < $1.teamName
        }

        var standings: [String: TeamStanding] = [:]
        for (index, team) in sorted.enumerated() {
            standings[normalizeTeamName(team.teamName)] = TeamStanding(
                rank: index + 1,
                teamName: team.teamName,
                points: team.points,
                goalsFor: team.goalsFor,
                goalsAgainst: team.goalsAgainst
            )
        }
        return standings
    }

    private func buildRestDaysByTeam(finishedResults: [FinishedMatch], upcomingMatches: [UpcomingMatch]) -> [String: Int] {
        var lastPlayedAtByTeam: [String: String] = [:]
        for match in finishedResults.sorted(by: { $0.datum > $1.datum }) {
            let homeKey = normalizeTeamName(match.heim)
            let awayKey = normalizeTeamName(match.gast)
            if lastPlayedAtByTeam[homeKey] == nil {
                lastPlayedAtByTeam[homeKey] = match.datum
            }
            if lastPlayedAtByTeam[awayKey] == nil {
                lastPlayedAtByTeam[awayKey] = match.datum
            }
        }

        var restDays: [String: Int] = [:]
        for match in upcomingMatches {
            guard let kickoff = parseDate(match.datum) else { continue }
            let homeKey = normalizeTeamName(match.heim)
            let awayKey = normalizeTeamName(match.gast)

            if let lastHome = lastPlayedAtByTeam[homeKey], let lastHomeDate = parseDate(lastHome) {
                restDays[homeKey] = max(0, daysBetween(lastHomeDate, kickoff))
            }
            if let lastAway = lastPlayedAtByTeam[awayKey], let lastAwayDate = parseDate(lastAway) {
                restDays[awayKey] = max(0, daysBetween(lastAwayDate, kickoff))
            }
        }
        return restDays
    }

    private func motivationSummary(home: String, away: String, standings: [String: TeamStanding]) -> String {
        let homeStanding = standings[normalizeTeamName(home)]
        let awayStanding = standings[normalizeTeamName(away)]
        let homeSummary = homeStanding.map(describeMotivation) ?? "\(home): neutraler Tabellenkontext"
        let awaySummary = awayStanding.map(describeMotivation) ?? "\(away): neutraler Tabellenkontext"
        return "\(homeSummary) | \(awaySummary)"
    }

    private func describeMotivation(_ standing: TeamStanding) -> String {
        let context: String
        switch standing.rank {
        case 1...4:
            context = "Europaplaetze/Titelrennen"
        case 5...7:
            context = "Europa in Reichweite"
        case 8...13:
            context = "gesichertes Mittelfeld"
        case 14...16:
            context = "unterer Tabellenbereich"
        default:
            context = "Abstiegskampf"
        }
        return "\(standing.teamName): Rang \(standing.rank), \(standing.points) Pkt, \(context)"
    }

    private func parseDate(_ raw: String) -> Date? {
        iso8601WithFractional.date(from: raw) ?? iso8601.date(from: raw)
    }

    private func daysBetween(_ from: Date, _ to: Date) -> Int {
        Calendar(identifier: .gregorian).dateComponents([.day], from: from, to: to).day ?? 0
    }

    private func formatRestDays(_ days: Int?) -> String {
        guard let days else { return "unbekannt" }
        return "\(days) Tag(e)"
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private func weatherSummary(_ weather: MatchWeather) -> String {
        let temperature = weather.temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "unbekannt"
        let precipitation = weather.precipitationMillimeters.map { String(format: "%.1f mm", $0) } ?? "unbekannt"
        let precipitationProbability = weather.precipitationProbability.map { "\($0)%" } ?? "unbekannt"
        let wind = weather.windSpeedKmh.map { String(format: "%.1f km/h", $0) } ?? "unbekannt"
        let code = weather.weatherCode.map(String.init) ?? "n/a"
        return "\(weather.locationName) | Temp \(temperature) | Niederschlag \(precipitation) (\(precipitationProbability)) | Wind \(wind) | Code \(code)"
    }

    private let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct TeamStanding {
    let rank: Int
    let teamName: String
    let points: Int
    let goalsFor: Int
    let goalsAgainst: Int

    var goalDifference: Int { goalsFor - goalsAgainst }
}

private struct TeamStandingAccumulator {
    let teamName: String
    var points: Int = 0
    var goalsFor: Int = 0
    var goalsAgainst: Int = 0

    var goalDifference: Int { goalsFor - goalsAgainst }

    mutating func apply(goalsFor: Int, goalsAgainst: Int) {
        self.goalsFor += goalsFor
        self.goalsAgainst += goalsAgainst
        if goalsFor > goalsAgainst {
            points += 3
        } else if goalsFor == goalsAgainst {
            points += 1
        }
    }
}

private struct TipsEnvelope: Decodable {
    let tips: [TipPayload]
}

private struct TipPayload: Decodable {
    let spieltag: Int
    let heim: String
    let gast: String
    let toreHeim: Int
    let toreGast: Int
    let rationale: String

    private enum CodingKeys: String, CodingKey {
        case spieltag
        case heim
        case gast
        case toreHeim = "tore_heim"
        case toreGast = "tore_gast"
        case rationale
    }
}
