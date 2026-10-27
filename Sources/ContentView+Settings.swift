import AppKit
import SwiftUI

/// Settings tab: paths, Kicktipp group, points rules and strategies.
extension ContentView {
    var settingsTab: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                settingsCard
                codexCard
            }
            card(title: "Hinweise", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hier werden die globalen Analyse- und Codex-Einstellungen verwaltet.")
                        .foregroundStyle(.secondary)
                    Text("Aenderungen wirken direkt auf den naechsten Workflow-Lauf.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(16)
    }

    private var settingsCard: some View {
        card(title: "Einstellungen", icon: "gearshape") {
            VStack(alignment: .leading, spacing: 10) {
                inputGroup(title: "Codex Pfad") {
                    TextField("/opt/homebrew/bin/codex", text: Bindable(state.settings).codexPath)
                        .textFieldStyle(.roundedBorder)
                }
                inputGroup(title: "Competition Slug") {
                    TextField("z. B. meine-tipprunde", text: Bindable(state.settings).kicktippCompetitionSlug)
                        .textFieldStyle(.roundedBorder)
                }
                inputGroup(title: "The Odds API Key") {
                    SecureField("The Odds API Key", text: Bindable(state.settings).theOddsAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                inputGroup(title: "Codex-Laeufe") {
                    Stepper(value: Bindable(state.settings).codexRunCount, in: 1...9) {
                        Text("\(state.settings.codexRunCount) Lauf/Laeufe pro Analyse")
                    }
                }
                inputGroup(title: "Kicktipp-Punkteregel der Tipprunde") {
                    Stepper(value: Bindable(state.settings).kicktippRules.exactScorePoints, in: 0...10) {
                        Text("Ergebnis: \(Int(state.settings.kicktippRules.exactScorePoints)) Punkte")
                    }
                    Stepper(value: Bindable(state.settings).kicktippRules.goalDifferencePoints, in: 0...10) {
                        Text("Tordifferenz: \(Int(state.settings.kicktippRules.goalDifferencePoints)) Punkte")
                    }
                    Stepper(value: Bindable(state.settings).kicktippRules.tendencyPoints, in: 0...10) {
                        Text("Tendenz: \(Int(state.settings.kicktippRules.tendencyPoints)) Punkte")
                    }
                    Toggle("Tordifferenz-Punkte auch bei Remis", isOn: Bindable(state.settings).kicktippRules.drawCountsAsGoalDifference)
                    if let inferred = state.inferredKicktippRules {
                        let rules = inferred.rules
                        Text(String(format: "Aus %d Mitspieler-Tipps erkannt: %.0f/%.0f/%.0f, Remis-Tordifferenz %@",
                                    inferred.sampleCount, rules.exactScorePoints, rules.goalDifferencePoints, rules.tendencyPoints,
                                    rules.drawCountsAsGoalDifference ? "ja" : "nein"))
                            .font(.caption)
                            .foregroundStyle(rules == state.settings.kicktippRules ? Color.secondary : Color.orange)
                        if rules != state.settings.kicktippRules {
                            Button("Erkannte Regel uebernehmen") { state.adoptInferredKicktippRules() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                inputGroup(title: "Kurz vor Anstoss") {
                    Toggle("Tipps 60 Min. vor Anstoss mit aktuellen Quoten neu berechnen", isOn: Bindable(state.settings).autoRefreshBeforeKickoff)
                    Toggle("Geaenderte Tipps automatisch eintragen und absenden", isOn: Bindable(state.settings).autoSubmitAfterRefresh)
                        .disabled(!state.settings.autoRefreshBeforeKickoff)
                    Text("Quoten direkt vor Anstoss enthalten Aufstellungen und Kurzfrist-News und sind die genaueste Prognose. Die App muss dafuer geoeffnet sein.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                inputGroup(title: "Ranglisten-Strategie") {
                    TextField("Mein Name in der Tipprunde", text: Bindable(state.settings).kicktippPlayerName)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Tipps an Ranglage anpassen", isOn: Bindable(state.settings).useRankingStrategy)
                    Text(state.rankingStrategy.map { String(format: "%@ Max. %.2f erwartete Punkte Verzicht je Spiel.", $0.summary, $0.tolerance) }
                         ?? "Kostet bewusst bis zu 0,25 erwartete Punkte je Spiel, um die Siegchance zu erhoehen. Braucht Name und geladene Mitspieler-Tipps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
