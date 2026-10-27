import Foundation

/// Kicktipp browser automation: tip form, submission and reading the group history.
extension AppState {
    func initializeKicktipp() async {
        let loggedIn = await kicktippAutomation.isLoggedIn()
        if loggedIn && !kicktippCompetitionSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await loadKicktippMatchday()
        } else {
            openKicktippLogin()
        }
    }

    func openKicktippLogin() {
        kicktippAutomation.openLogin()
        kicktippStatus = "Login-Seite geladen"
        infoMessage = "Bitte im eingebetteten Kicktipp-Browser anmelden."
    }

    func loadKicktippMatchday() async {
        await perform {
            try self.kicktippAutomation.loadTippabgabe(for: self.kicktippCompetitionSlug)
            try await self.waitForKicktippPageToFinishLoading()
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            self.syncManualKicktippTipsForLearning(from: fields)
            self.kicktippStatus = "\(fields.count) Kicktipp-Spiele erkannt"
            self.infoMessage = "Kicktipp-Tippabgabe fuer die Runde wurde geladen."
        }
    }

    private func readKicktippMatches() async {
        await perform {
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            self.syncManualKicktippTipsForLearning(from: fields)
            self.kicktippStatus = "\(fields.count) Kicktipp-Spiele erkannt"
            self.infoMessage = "Kicktipp-Spiele aus der Seite gelesen."
        }
    }

    func applyTipsToKicktipp(confirmOverwrite: Bool = false) async {
        pendingKicktippOverwrites = []
        await perform {
            guard !self.suggestedTips.isEmpty else {
                throw KicktippAutomationError.javaScriptError("Bitte zuerst Tipps importieren oder per Codex erzeugen.")
            }
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            let updates = try self.buildKicktippUpdates(from: fields)

            let overwrites = Self.kicktippOverwrites(updates)
            if !overwrites.isEmpty && !confirmOverwrite {
                self.pendingKicktippOverwrites = overwrites
                return
            }

            try await self.kicktippAutomation.applyTips(updates)

            let readBack = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = readBack
            let mismatches = Self.kicktippMismatches(expected: updates.map(\.tip), fields: readBack)
            guard mismatches.isEmpty else {
                throw KicktippAutomationError.javaScriptError("Kicktipp-Felder enthalten nach dem Eintragen abweichende Werte: \(mismatches.joined(separator: ", "))")
            }
            self.kicktippStatus = "Tipps in Formular eingetragen"
            self.infoMessage = "\(updates.count) Tipps eingetragen und geprueft. Zum Absenden 'Tipps absenden' nutzen."
        }
    }

    /// Fields that already hold a different, non-empty tip.
    nonisolated static func kicktippOverwrites(_ updates: [(field: KicktippMatchField, tip: SuggestedTip)]) -> [String] {
        updates.compactMap { update in
            let home = update.field.existingHeim.trimmingCharacters(in: .whitespaces)
            let away = update.field.existingGast.trimmingCharacters(in: .whitespaces)
            guard !home.isEmpty || !away.isEmpty,
                  home != String(update.tip.toreHeim) || away != String(update.tip.toreGast) else {
                return nil
            }
            return "\(update.tip.heim) vs. \(update.tip.gast): \(home):\(away) -> \(update.tip.toreHeim):\(update.tip.toreGast)"
        }
    }

    /// Tips whose Kicktipp field values differ from the expected score.
    nonisolated static func kicktippMismatches(expected tips: [SuggestedTip], fields: [KicktippMatchField]) -> [String] {
        tips.compactMap { tip in
            guard let field = fields.first(where: { matchesLikelyEqual($0.heim, $0.gast, tip.heim, tip.gast) }) else {
                return "\(tip.heim) vs. \(tip.gast) fehlt"
            }
            let value = "\(field.existingHeim.trimmingCharacters(in: .whitespaces)):\(field.existingGast.trimmingCharacters(in: .whitespaces))"
            return value == "\(tip.toreHeim):\(tip.toreGast)" ? nil : "\(tip.heim) vs. \(tip.gast) (\(value))"
        }
    }

    func submitKicktippTips() async {
        await perform {
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            let deviations = Self.kicktippMismatches(expected: self.suggestedTips, fields: fields)
            if !deviations.isEmpty {
                self.appendConsole("[Kicktipp] Formular weicht von importierten Tipps ab: \(deviations.joined(separator: ", "))\n")
            }
            self.syncManualKicktippTipsForLearning(from: fields)
            try await self.kicktippAutomation.submitTips()
            self.kicktippStatus = "Tipps abgesendet"
            self.infoMessage = "Die Kicktipp-Tipps wurden abgesendet."
        }
    }

    func applySeasonQuestionTipsToKicktipp() async {
        await perform {
            let seasonValue = try self.parsedSeason()
            try await self.ensureKicktippMatchdayReadyForExtraction()
            let fields = try await self.kicktippAutomation.extractMatchFields()
            self.kicktippMatchFields = fields
            let teams = Set(fields.flatMap { [$0.heim, $0.gast] } + self.upcomingMatches.flatMap { [$0.heim, $0.gast] })
            let prompt = self.tipWorkflowService.buildSeasonQuestionPrompt(season: seasonValue, teams: teams.sorted())
            let outputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("betbaconer-season-questions-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outputFile) }

            let arguments = CodexRunner.execArguments(outputFile: outputFile)
            let result = try await self.executeCodexCommand(arguments: arguments, standardInput: prompt) { chunk in
                self.appendConsole(self.stripANSI(chunk))
            }
            guard result.exitCode == 0 else {
                throw CodexCLIError.executionFailed("Codex exec fuer Saisonfragen fehlgeschlagen. Siehe Console-Ausgabe.")
            }

            let output = try String(contentsOf: outputFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.seasonQuestionTips = try self.tipWorkflowService.parseSeasonQuestionTips(from: output)
            try await self.kicktippAutomation.applySeasonQuestionTips(self.seasonQuestionTips)
            self.kicktippStatus = "Saisonfragen eingetragen"
            self.infoMessage = "Die Saisonfragen wurden in Kicktipp eingetragen."
        }
    }

    func buildKicktippUpdates(from fields: [KicktippMatchField], requireAll: Bool = true) throws -> [(field: KicktippMatchField, tip: SuggestedTip)] {
        let tipMatchdays = Set(suggestedTips.map(\.spieltag))
        guard tipMatchdays.count == 1, let tipMatchday = tipMatchdays.first else {
            throw KicktippAutomationError.javaScriptError("Die importierten Tipps gehoeren zu mehreren Spieltagen.")
        }
        if let nextSpieltag, nextSpieltag != tipMatchday {
            throw KicktippAutomationError.javaScriptError("Die Tipps gehoeren zu Spieltag \(tipMatchday), offen ist Spieltag \(nextSpieltag). Bitte neu generieren.")
        }

        var updates: [(field: KicktippMatchField, tip: SuggestedTip)] = []
        var matchedTipIDs = Set<SuggestedTip.ID>()

        for field in fields {
            let fieldKey = normalizedTeamKey(field.heim, field.gast)
            guard let tip = suggestedTips.first(where: { normalizedTeamKey($0.heim, $0.gast) == fieldKey })
                ?? suggestedTips.first(where: { matchesLikelyEqual($0.heim, $0.gast, field.heim, field.gast) }),
                  !matchedTipIDs.contains(tip.id) else {
                continue
            }
            updates.append((field: field, tip: tip))
            matchedTipIDs.insert(tip.id)
        }

        if updates.isEmpty {
            throw KicktippAutomationError.javaScriptError("Keine Kicktipp-Spiele konnten mit den importierten Tipps gematcht werden.")
        }

        let unmatchedTips = suggestedTips.filter { !matchedTipIDs.contains($0.id) }
        if requireAll && !unmatchedTips.isEmpty {
            let summary = unmatchedTips
                .map { "\($0.heim) vs. \($0.gast)" }
                .joined(separator: ", ")
            throw KicktippAutomationError.javaScriptError("Nicht alle Tipps konnten Kicktipp-Spielen zugeordnet werden: \(summary)")
        }

        return updates
    }

    func waitForKicktippPageToFinishLoading(urlContaining marker: String = "tippabgabe", timeoutNanoseconds: UInt64 = 15_000_000_000) async throws {
        let start = DispatchTime.now().uptimeNanoseconds

        // Phase 1: wait for loading to START (gives the navigation delegate time to fire)
        // This guards against a race where webView.url already reflects the new URL
        // but isPageLoading hasn't been set to true yet.
        while !kicktippAutomation.isPageLoading {
            if DispatchTime.now().uptimeNanoseconds - start > 2_000_000_000 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Phase 2: wait for loading to FINISH with the correct URL
        while kicktippAutomation.isPageLoading || kicktippAutomation.webView.url?.absoluteString.contains(marker) != true {
            if !kicktippAutomation.isPageLoading, kicktippAutomation.webView.url?.path.contains("/login") == true {
                throw KicktippAutomationError.javaScriptError("Nicht bei Kicktipp angemeldet. Bitte im Kicktipp-Tab einloggen und erneut versuchen.")
            }
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                throw KicktippAutomationError.javaScriptError("Kicktipp-Tippabgabe konnte nicht rechtzeitig geladen werden.")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func ensureKicktippMatchdayReadyForExtraction() async throws {
        let slug = kicktippCompetitionSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else {
            throw KicktippAutomationError.invalidCompetitionSlug
        }

        let currentURL = kicktippAutomation.webView.url?.absoluteString ?? ""
        // A past matchday page (?spieltagIndex=) is not the open tip form.
        if !currentURL.contains("/\(slug)/tippabgabe") || currentURL.contains("spieltagIndex=") {
            try kicktippAutomation.loadTippabgabe(for: slug)
        }

        try await waitForKicktippPageToFinishLoading()
    }

    func loadCommunityTips() async {
        await perform {
            let seasonValue = try self.parsedSeason()
            if self.finishedResults.isEmpty {
                self.finishedResults = try await self.ligaService.fetchFinishedMatches(season: seasonValue)
            }
            await self.syncCommunityTips(seasonValue: seasonValue)
            await self.backfillKicktippOdds(seasonValue: seasonValue)
            try await self.ensureKicktippMatchdayReadyForExtraction()
            self.infoMessage = "\(self.currentSeasonCommunity.count) Spieltage mit Mitspieler-Tipps, \(self.oddsArchive.count) archivierte Quoten."
        }
    }

    /// Reads the tip overview of every finished matchday that is missing, plus the latest one (totals change).
    /// Failures are logged and never abort the tip workflow.
    func syncCommunityTips(seasonValue: Int) async {
        let seasonKey = String(seasonValue)
        let slug = kicktippCompetitionSlug
        let finishedMatchdays = Set(finishedResults.map(\.spieltag)).filter { matchday in
            nextSpieltag.map { matchday < $0 } ?? true
        }
        let stored = Set(communityMatchdays.filter { $0.season == seasonKey }.map(\.spieltag))
        let latest = finishedMatchdays.max()
        let toLoad = finishedMatchdays.filter { !stored.contains($0) || $0 == latest }.sorted()
        guard !toLoad.isEmpty else { return }

        var loaded: [CommunityMatchday] = []
        for spieltag in toLoad {
            do {
                try kicktippAutomation.loadCommunityOverview(for: slug, spieltag: spieltag)
                try await waitForKicktippPageToFinishLoading(urlContaining: "spieltagIndex=\(spieltag)")
                let extracted = try await kicktippAutomation.extractCommunityTable()
                do {
                    loaded.append(try communityService.parse(table: extracted.table, season: seasonKey, spieltag: spieltag, finishedMatches: finishedResults))
                } catch {
                    appendConsole("\n[AUTO-LOG] Kicktipp-Tippuebersicht Spieltag \(spieltag):\n\(extracted.raw.prefix(3000))\n")
                    throw error
                }
            } catch {
                appendConsole("[Mitspieler] Spieltag \(spieltag) nicht gelesen: \(error.localizedDescription)\n")
                break
            }
        }
        guard !loaded.isEmpty else { return }

        let replaced = Set(loaded.map(\.spieltag))
        communityMatchdays = communityMatchdays.filter { $0.season != seasonKey || !replaced.contains($0.spieltag) } + loaded
        appendConsole("[Mitspieler] \(loaded.count) Spieltag(e) gelesen, \(currentSeasonCommunity.count) gespeichert.\n")

        if let inferred = inferredKicktippRules, inferred.rules != kicktippRules {
            let rules = inferred.rules
            appendConsole(String(
                format: "[Mitspieler] Erkannte Punkteregel %.0f/%.0f/%.0f, Remis-Tordifferenz %@ (aus %d Tipps) weicht von den Einstellungen ab.\n",
                rules.exactScorePoints, rules.goalDifferencePoints, rules.tendencyPoints,
                rules.drawCountsAsGoalDifference ? "ja" : "nein", inferred.sampleCount
            ))
            infoMessage = "Punkteregel der Tipprunde weicht von den Einstellungen ab, siehe Einstellungen."
        }
    }

    /// Reads the odds Kicktipp shows on the tip page of finished matchdays that are not archived yet.
    func backfillKicktippOdds(seasonValue: Int) async {
        let seasonKey = String(seasonValue)
        let archived = Set(oddsArchive.filter { $0.season == seasonKey }.map(\.spieltag))
        let missing = Set(finishedResults.map(\.spieltag))
            .filter { matchday in !archived.contains(matchday) && (nextSpieltag.map { matchday < $0 } ?? true) }
            .sorted()
        var stored = 0
        for spieltag in missing {
            do {
                try kicktippAutomation.loadTippabgabe(for: kicktippCompetitionSlug, spieltag: spieltag)
                try await waitForKicktippPageToFinishLoading(urlContaining: "spieltagIndex=\(spieltag)")
            } catch {
                appendConsole("[Quoten-Archiv] Spieltag \(spieltag) nicht geladen: \(error.localizedDescription)\n")
                break
            }
            let extracted = await kicktippAutomation.extractOddsFromPage()
            let results = finishedResults.filter { $0.spieltag == spieltag }
            let snapshots = extracted.odds.compactMap { odds -> ArchivedOdds? in
                guard let match = results.first(where: { matchesLikelyEqual($0.heim, $0.gast, odds.heim, odds.gast) }) else { return nil }
                return ArchivedOdds(
                    season: seasonKey, spieltag: spieltag, heim: match.heim, gast: match.gast,
                    quoteHeim: odds.quoteHeim, quoteUnentschieden: odds.quoteUnentschieden, quoteGast: odds.quoteGast,
                    overUnderLine: nil, overQuote: nil, underQuote: nil,
                    capturedAt: parseKickoffDate(match.datum) ?? Date()
                )
            }
            if snapshots.isEmpty {
                appendConsole("[Quoten-Archiv] Kicktipp zeigt fuer Spieltag \(spieltag) keine Quoten; Nachladen beendet.\n\(extracted.log)")
                break
            }
            mergeIntoOddsArchive(snapshots)
            stored += snapshots.count
        }
        if stored > 0 {
            appendConsole("[Quoten-Archiv] \(stored) historische Quoten aus Kicktipp gespeichert (gesamt \(oddsArchive.count)).\n")
        }
    }

    func adoptInferredKicktippRules() {
        guard let inferred = inferredKicktippRules else { return }
        kicktippRules = inferred.rules
        infoMessage = "Punkteregel aus den Mitspieler-Tipps uebernommen."
    }
}
