import Foundation

/// Self-learning: evaluation, odds archive, backtest and the refresh shortly before kickoff.
extension AppState {
    func evaluateLearningData() async {
        await perform {
            if let fields = try? await self.kicktippAutomation.extractMatchFields() {
                self.kicktippMatchFields = fields
            }
            self.syncManualKicktippTipsForLearning(from: self.kicktippMatchFields)

            let seasons = Set(self.predictionRuns.compactMap { Int($0.seasonIdentifier) })
            guard !seasons.isEmpty else {
                self.infoMessage = "Keine auswertbaren Prediction-Runs vorhanden."
                return
            }

            var finishedBySeason: [String: [FinishedMatch]] = [:]
            for season in seasons.sorted() {
                finishedBySeason[String(season)] = try await self.ligaService.fetchFinishedMatches(season: season)
            }

            let summary = self.predictionEvaluator.evaluateRuns(
                self.predictionRuns,
                using: finishedBySeason,
                previousState: self.learningState
            )
            let runsWithClosingLines = await self.enrichEvaluatedRunsWithClosingLines(summary.runs)
            let finalSummary = self.predictionEvaluator.evaluateRuns(
                runsWithClosingLines,
                using: finishedBySeason,
                previousState: summary.learningState
            )
            self.predictionRuns = finalSummary.runs
            self.learningState = finalSummary.learningState
            self.infoMessage = summary.evaluatedMatches == 0
                ? "Keine neuen abgeschlossenen Spiele zum Bewerten gefunden."
                : "\(summary.evaluatedMatches) Vorhersage(n) wurden bewertet."
        }
    }

    private func resetLearningData() {
        predictionRuns = []
        learningState = .empty
        infoMessage = "Learning-Daten wurden zurueckgesetzt."
    }

    /// Walk-forward backtest over the last seasons; learns the market weight once the odds archive is large enough.
    func runModelBacktest() async {
        await perform {
            let seasonValue = try self.parsedSeason()
            self.infoMessage = "Lade Saisons fuer den Backtest..."
            let oldestArchived = self.oddsArchive.compactMap { Int($0.season) }.min() ?? seasonValue
            let firstEvaluated = min(seasonValue - 4, oldestArchived)
            await self.loadHistoricalSeasons(before: seasonValue, count: seasonValue - firstEvaluated + 2)
            var seasons = self.historicalSeasons
            seasons[seasonValue] = self.finishedResults.isEmpty
                ? try await self.ligaService.fetchFinishedMatches(season: seasonValue)
                : self.finishedResults
            let backtest = ModelBacktestService(rules: self.kicktippRules)
            let archive = self.oddsArchive
            self.infoMessage = "Backtest laeuft..."
            let report = await Task.detached(priority: .userInitiated) {
                backtest.run(seasons: seasons, oddsArchive: archive, evaluatedSeasons: firstEvaluated...seasonValue)
            }.value
            if let best = report.bestMarketWeight {
                self.learnedMarketWeight = best
            }
            self.backtestReport = report.summary
            self.appendConsole("[Backtest]\n\(report.summary)\n")
            self.infoMessage = "Backtest abgeschlossen."
        }
    }

    /// Imports football-data.co.uk CSV files (one per season) into the odds archive.
    func importHistoricalOdds(from urls: [URL]) async {
        await perform {
            let seasonValue = try self.parsedSeason()
            await self.loadHistoricalSeasons(before: seasonValue, count: 10)
            var seasons = self.historicalSeasons
            if !self.finishedResults.isEmpty { seasons[seasonValue] = self.finishedResults }
            var imported: [ArchivedOdds] = []
            var unmatched = 0
            for url in urls {
                let text = try String(contentsOf: url, encoding: .utf8)
                let result = HistoricalOddsImporter().importCSV(text, seasons: seasons)
                imported += result.odds
                unmatched += result.unmatched
                self.appendConsole("[Quoten-Import] \(url.lastPathComponent): \(result.odds.count) Spiele, \(result.unmatched) nicht zugeordnet.\n")
            }
            self.mergeIntoOddsArchive(imported)
            self.infoMessage = "\(imported.count) historische Quoten importiert (\(unmatched) nicht zugeordnet). Jetzt 'Backtest ausfuehren'."
        }
    }

    /// Matches kicking off in 5-75 minutes that were not refreshed within the last 40 minutes.
    nonisolated static func matchesDueForKickoffRefresh(_ matches: [UpcomingMatch], lastRefresh: [String: Date], now: Date) -> [UpcomingMatch] {
        matches.filter { match in
            guard let kickoff = parseKickoffDate(match.datum) else { return false }
            let minutes = kickoff.timeIntervalSince(now) / 60
            let last = lastRefresh[normalizedTeamKey(match.heim, match.gast)]
            return minutes > 5 && minutes <= 75 && (last.map { now.timeIntervalSince($0) > 40 * 60 } ?? true)
        }
    }

    /// Runs while the window is open; checks every 10 minutes whether a kickoff is close.
    func runKickoffRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard autoRefreshBeforeKickoff, !isBusy, !suggestedTips.isEmpty else { continue }
            let due = Self.matchesDueForKickoffRefresh(upcomingMatches, lastRefresh: lastKickoffRefresh, now: Date())
            guard !due.isEmpty else { continue }
            await perform { try await self.refreshTipsBeforeKickoff(due) }
        }
    }

    /// Fetches the latest odds, recomputes the due matches and (optionally) enters and submits them.
    /// No new Codex run: the market already prices in late news, and Codex would take too long.
    private func refreshTipsBeforeKickoff(_ due: [UpcomingMatch]) async throws {
        let seasonKey = season.trimmingCharacters(in: .whitespacesAndNewlines)
        appendConsole("[Anstoss] Aktualisiere \(due.map { "\($0.heim)-\($0.gast)" }.joined(separator: ", ")) mit aktuellen Quoten.\n")
        var freshOdds: [BettingOdds] = []
        if !theOddsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let market = try await oddsAPIService.fetchAllMarketOdds()
            freshOdds = OddsRemapper.remapOddsToUpcomingMatches(market.h2h, upcomingMatches: upcomingMatches)
            let freshOverUnder = OddsRemapper.remapOverUnderToUpcomingMatches(market.overUnder, upcomingMatches: upcomingMatches)
            let freshKeys = Set(freshOverUnder.map { normalizedTeamKey($0.heim, $0.gast) })
            overUnderOdds = overUnderOdds.filter { !freshKeys.contains(normalizedTeamKey($0.heim, $0.gast)) } + freshOverUnder
        } else {
            try kicktippAutomation.loadTippabgabe(for: kicktippCompetitionSlug)
            try await waitForKicktippPageToFinishLoading()
            freshOdds = OddsRemapper.remapOddsToUpcomingMatches(await kicktippAutomation.extractOddsFromPage().odds, upcomingMatches: upcomingMatches)
        }
        let freshKeys = Set(freshOdds.map { normalizedTeamKey($0.heim, $0.gast) })
        bettingOdds = bettingOdds.filter { !freshKeys.contains(normalizedTeamKey($0.heim, $0.gast)) } + freshOdds
        archiveCurrentOdds(season: seasonKey)

        let expectedGoals = expectedGoalsByMatch()
        matchExpectedGoals = expectedGoals.values.sorted { $0.heim < $1.heim }
        let aggregated = try ensembleService.aggregate(from: [suggestedTips], upcomingMatches: upcomingMatches, bettingOdds: bettingOdds, expectedGoals: expectedGoals)
        let freshByKey = Dictionary(aggregated.map { (normalizedTeamKey($0.tip.heim, $0.tip.gast), $0) }, uniquingKeysWith: { first, _ in first })
        let dueKeys = Set(due.map { normalizedTeamKey($0.heim, $0.gast) })
        for key in dueKeys { lastKickoffRefresh[key] = Date() }

        var changed: [SuggestedTip] = []
        let refreshed = suggestedTips.map { tip -> SuggestedTip in
            let key = normalizedTeamKey(tip.heim, tip.gast)
            guard dueKeys.contains(key), let fresh = freshByKey[key]?.tip,
                  fresh.toreHeim != tip.toreHeim || fresh.toreGast != tip.toreGast else { return tip }
            let updated = SuggestedTip(spieltag: tip.spieltag, heim: tip.heim, gast: tip.gast, toreHeim: fresh.toreHeim, toreGast: fresh.toreGast,
                                       rationale: tip.rationale + " | Kurz vor Anstoss mit aktuellen Quoten neu berechnet.")
            changed.append(updated)
            return updated
        }
        guard !changed.isEmpty else {
            appendConsole("[Anstoss] Keine Tippaenderung noetig.\n")
            return
        }
        appendConsole("[Anstoss] Geaendert: \(changed.map { "\($0.heim)-\($0.gast) \($0.toreHeim):\($0.toreGast)" }.joined(separator: ", "))\n")
        importedResponse = tipWorkflowService.encodeTipsAsJSON(refreshed)
        importTipsFromResponse(probabilityModels: freshByKey.mapValues(\.model))

        guard autoSubmitAfterRefresh else { return }
        try await ensureKicktippMatchdayReadyForExtraction()
        let fields = try await kicktippAutomation.extractMatchFields()
        let updates = try buildKicktippUpdates(from: fields, requireAll: false)
            .filter { dueKeys.contains(normalizedTeamKey($0.tip.heim, $0.tip.gast)) }
        guard !updates.isEmpty else { return }
        try await kicktippAutomation.applyTips(updates)
        let mismatches = Self.kicktippMismatches(expected: updates.map(\.tip), fields: try await kicktippAutomation.extractMatchFields())
        guard mismatches.isEmpty else {
            throw KicktippAutomationError.javaScriptError("Aktualisierte Tipps nicht korrekt eingetragen: \(mismatches.joined(separator: ", "))")
        }
        try await kicktippAutomation.submitTips()
        kicktippStatus = "Tipps kurz vor Anstoss aktualisiert"
        appendConsole("[Anstoss] \(updates.count) Tipp(s) eingetragen und abgesendet.\n")
    }

    func loadHistoricalSeasons(before seasonValue: Int, count: Int) async {
        for year in (seasonValue - count)..<seasonValue where historicalSeasons[year] == nil {
            do {
                historicalSeasons[year] = try await ligaService.fetchFinishedMatches(season: year)
            } catch {
                appendConsole("[OpenLigaDB] Saison \(year) nicht geladen: \(error.localizedDescription)\n")
            }
        }
    }

    /// Keeps the latest odds per match; the snapshot closest to kickoff wins.
    func archiveCurrentOdds(season: String) {
        let overUnderByKey = Dictionary(overUnderOdds.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
        let snapshots = upcomingMatches.compactMap { match -> ArchivedOdds? in
            let key = normalizedTeamKey(match.heim, match.gast)
            guard let odds = bettingOdds.first(where: { normalizedTeamKey($0.heim, $0.gast) == key }) else { return nil }
            let overUnder = overUnderByKey[key]
            return ArchivedOdds(
                season: season, spieltag: match.spieltag, heim: match.heim, gast: match.gast,
                quoteHeim: odds.quoteHeim, quoteUnentschieden: odds.quoteUnentschieden, quoteGast: odds.quoteGast,
                overUnderLine: overUnder?.line, overQuote: overUnder?.overQuote, underQuote: overUnder?.underQuote,
                capturedAt: Date()
            )
        }
        mergeIntoOddsArchive(snapshots)
    }

    func mergeIntoOddsArchive(_ snapshots: [ArchivedOdds]) {
        guard !snapshots.isEmpty else { return }
        let replaced = Set(snapshots.map { "\($0.season)|\($0.spieltag)|\(normalizedTeamKey($0.heim, $0.gast))" })
        oddsArchive = oddsArchive.filter { !replaced.contains("\($0.season)|\($0.spieltag)|\(normalizedTeamKey($0.heim, $0.gast))") } + snapshots
    }

    private func enrichEvaluatedRunsWithClosingLines(_ runs: [PredictionRun]) async -> [PredictionRun] {
        let missing = runs
            .flatMap(\.matches)
            .filter { $0.isEvaluated && self.needsClosingLineUpdate($0) }
        guard !missing.isEmpty else { return runs }

        var updates: [LLMClosingLineUpdate] = []
        let batchSize = 12

        for start in stride(from: missing.startIndex, to: missing.endIndex, by: batchSize) {
            let end = missing.index(start, offsetBy: batchSize, limitedBy: missing.endIndex) ?? missing.endIndex
            let batch = Array(missing[start..<end])
            let prompt = tipWorkflowService.buildClosingLinePrompt(predictions: batch)
            let outputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("betbaconer-codex-closing-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outputFile) }

            do {
                let result = try await executeCodexCommand(
                    arguments: CodexRunner.execArguments(outputFile: outputFile),
                    standardInput: prompt
                ) { chunk in
                    self.appendConsole(self.stripANSI(chunk))
                }
                guard result.exitCode == 0 else {
                    appendConsole("[CLV] Closing-Line-Recherche fehlgeschlagen: Codex exit \(result.exitCode).\n")
                    continue
                }
                let output = try String(contentsOf: outputFile, encoding: .utf8)
                updates.append(contentsOf: try tipWorkflowService.parseClosingLineUpdates(from: output))
            } catch CodexCLIError.cancelled {
                break
            } catch {
                appendConsole("[CLV] Closing-Line-Recherche fehlgeschlagen: \(error.localizedDescription)\n")
            }
        }

        appendConsole("[CLV] \(updates.count) Closing-Line-Updates geladen.\n")
        return applyClosingLineUpdates(updates, to: runs)
    }

    private func needsClosingLineUpdate(_ prediction: MatchPrediction) -> Bool {
        guard prediction.evaluatedClosingLineValue == nil else { return false }
        let text = prediction.llmClosingLine?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return text.isEmpty || text.contains("keine") || text.contains("unbekannt") || text.contains("n/a")
    }

    private func applyClosingLineUpdates(_ updates: [LLMClosingLineUpdate], to runs: [PredictionRun]) -> [PredictionRun] {
        let updatesByKey = Dictionary(updates.map {
            ("\($0.spieltag)|\(normalizedTeamKey($0.heim, $0.gast))", $0)
        }, uniquingKeysWith: { first, _ in first })
        return runs.map { run in
            var copy = run
            copy.matches = run.matches.map { match in
                guard let update = updatesByKey["\(match.spieltag)|\(normalizedTeamKey(match.heim, match.gast))"] else {
                    return match
                }
                var updated = match
                updated.llmClosingLine = update.closingLine
                updated.evaluatedClosingLineValue = update.closingLineValue
                return updated
            }
            return copy
        }
    }
}
