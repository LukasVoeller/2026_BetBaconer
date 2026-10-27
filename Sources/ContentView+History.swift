import AppKit
import SwiftUI

/// History tab: earlier tips with results.
extension ContentView {
    var historyTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.tipHistory.isEmpty {
                emptyState("Noch keine Generierungen aufgezeichnet.")
            } else {
                Text("\(state.latestTipHistory.count) Spieltag(e) gespeichert")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(state.latestTipHistory) { record in
                            let orderedTips = state.orderedTips(record.tips)
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Label("\(record.spieltag). Spieltag", systemImage: "calendar")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.regularMaterial)
                                Divider()
                                historyHeaderRow()
                                ForEach(orderedTips) { tip in
                                    let oddsMap = historyOddsMap(for: record)
                                    let actualResult = actualResultText(for: tip, in: record)
                                    HStack(spacing: 0) {
                                        Text("\(tip.heim) vs. \(tip.gast)")
                                            .font(.body)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, 16)
                                        if let o = oddsMap[normalizedTeamKey(tip.heim, tip.gast)] {
                                            Text("\(o.quoteHeim) / \(o.quoteUnentschieden) / \(o.quoteGast)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                                .frame(width: 130, alignment: .center)
                                        } else {
                                            Text("keine Quoten")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .frame(width: 130, alignment: .center)
                                        }
                                        Text("\(tip.toreHeim) : \(tip.toreGast)")
                                            .font(.body.weight(.bold))
                                            .monospacedDigit()
                                            .frame(width: 60, alignment: .center)
                                        Text(actualResult)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(actualResult == "-" ? .tertiary : .primary)
                                            .monospacedDigit()
                                            .frame(width: 60, alignment: .center)
                                        if !tip.rationale.isEmpty {
                                            Text(tip.rationale)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.trailing, 16)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func historyRecordRow(_ record: TipGenerationRecord) -> some View {
        let oddsMap = historyOddsMap(for: record)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(record.spieltag). Spieltag – \(record.timestamp.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(state.orderedTips(record.tips)) { tip in
                let actualResult = actualResultText(for: tip, in: record)
                HStack {
                    Text("\(tip.heim) vs. \(tip.gast)")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    if let o = oddsMap[normalizedTeamKey(tip.heim, tip.gast)] {
                        Text("\(o.quoteHeim) / \(o.quoteUnentschieden) / \(o.quoteGast)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("keine Quoten")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(tip.toreHeim):\(tip.toreGast)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                    Text(actualResult)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(actualResult == "-" ? .tertiary : .primary)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }

    func historyHeaderRow() -> some View {
        HStack(spacing: 0) {
            Text("")
                .frame(maxWidth: .infinity)
                .padding(.leading, 16)
            Text("")
                .frame(width: 130)
            Text("Soll")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .center)
            Text("Ist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .center)
            Text("")
                .frame(maxWidth: .infinity)
                .padding(.trailing, 16)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    func actualResultText(for tip: SuggestedTip, in record: TipGenerationRecord) -> String {
        let recordSeason = String(AppState.currentBundesligaSeason(for: record.timestamp))
        if let prediction = state.predictionRuns
            .reversed()
            .first(where: { run in
                run.seasonIdentifier == recordSeason
                && run.spieltag == tip.spieltag
                && run.matches.contains { prediction in
                    normalizedTeamKey(prediction.heim, prediction.gast) == normalizedTeamKey(tip.heim, tip.gast)
                    && prediction.actualHomeGoals != nil
                    && prediction.actualAwayGoals != nil
                }
            })?
            .matches
            .first(where: { prediction in
                normalizedTeamKey(prediction.heim, prediction.gast) == normalizedTeamKey(tip.heim, tip.gast)
                && prediction.actualHomeGoals != nil
                && prediction.actualAwayGoals != nil
            }),
           let homeGoals = prediction.actualHomeGoals,
           let awayGoals = prediction.actualAwayGoals {
            return "\(homeGoals):\(awayGoals)"
        }

        guard state.season.trimmingCharacters(in: .whitespacesAndNewlines) == recordSeason else { return "-" }
        if let result = state.finishedResults.first(where: {
            $0.spieltag == tip.spieltag
            && normalizedTeamKey($0.heim, $0.gast) == normalizedTeamKey(tip.heim, tip.gast)
        }) {
            return "\(result.toreHeim):\(result.toreGast)"
        }

        return "-"
    }

    func historyOddsMap(for record: TipGenerationRecord) -> [String: BettingOdds] {
        Dictionary(record.odds.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
    }
}
