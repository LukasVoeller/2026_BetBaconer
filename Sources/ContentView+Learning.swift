import AppKit
import SwiftUI

/// Learning tab: evaluation, backtest and app-vs-group comparison.
extension ContentView {
    var learningTab: some View {
        HStack(alignment: .top, spacing: 16) {
            card(title: "Lernstatus", icon: "chart.bar") {
                VStack(alignment: .leading, spacing: 10) {
                    metricRow("Bewertete Tipps", "\(state.learning.learningState.sampleSize)")
                    metricRow("Trefferquote Tendenz", percentage(state.learning.learningState.tendencyHitRate))
                    metricRow("Trefferquote exakt", percentage(state.learning.learningState.exactHitRate))
                    metricRow("Trefferquote Tordiff.", percentage(state.learning.learningState.goalDiffHitRate))
                    metricRow("Ø Torabweichung", String(format: "%.2f", state.learning.learningState.averageTotalAbsGoalError))
                    metricRow("Heim-Bias", signedPercentage(state.learning.learningState.homeBias))
                    metricRow("Remis-Bias", signedPercentage(state.learning.learningState.drawBias))
                    metricRow("Auswaerts-Bias", signedPercentage(state.learning.learningState.awayBias))
                }
            }
            card(title: "Learning Summary", icon: "text.quote") {
                if state.learning.learningState.correctionSummaryText.isEmpty {
                    emptyState("Noch keine bewerteten Vorhersagen vorhanden.")
                } else {
                    ScrollView {
                        Text(state.learning.learningState.correctionSummaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            card(title: "Modell-Backtest", icon: "chart.line.uptrend.xyaxis") {
                VStack(alignment: .leading, spacing: 8) {
                    metricRow("Marktgewicht", String(format: "%.0f%%", state.settings.learnedMarketWeight * 100))
                    metricRow("Archivierte Quoten", "\(state.learning.oddsArchive.count)")
                    HStack {
                        Button("Backtest ausfuehren") {
                            Task { await state.runModelBacktest() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(brandOrange)
                        Button("Quoten-CSV importieren") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.commaSeparatedText]
                            panel.allowsMultipleSelection = true
                            panel.message = "football-data.co.uk D1.csv-Dateien auswaehlen"
                            if panel.runModal() == .OK {
                                let urls = panel.urls
                                Task { await state.importHistoricalOdds(from: urls) }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(state.isBusy)
                    if state.backtestReport.isEmpty {
                        emptyState("Prueft das Modell Spieltag fuer Spieltag an den letzten Saisons und lernt das Marktgewicht aus dem Quoten-Archiv.")
                    } else {
                        ScrollView {
                            Text(state.backtestReport)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            card(title: "App vs. Tipprunde", icon: "person.3") {
                if state.communityBacktest.isEmpty {
                    emptyState("Noch keine Mitspieler-Tipps zu Spieltagen mit App-Tipps geladen.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(state.communityBacktest) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(row.spieltag). Spieltag: \(row.appPoints) Punkte")
                                        .font(.subheadline.weight(.semibold))
                                    Text(String(format: "Rang %d/%d | Runde Ø %.1f | Bester %d", row.appRank, row.playerCount, row.groupAverage, row.groupBest))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        }
                    }
                }
            }
            card(title: "Bewertete Spieltage", icon: "list.bullet.rectangle") {
                if state.evaluatedMatchdayRuns.isEmpty {
                    emptyState("Noch keine Spieltage bewertet.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(state.evaluatedMatchdayRuns) { run in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(run.spieltag). Spieltag")
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(run.matches.filter(\.isEvaluated).count)/\(run.matches.count) bewertet")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
    }
}
