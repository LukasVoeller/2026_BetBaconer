import Foundation

/// Tip workflow: data loading, Codex ensemble, model selection and prediction records.
extension AppState {
    func runWorkflow() async {
        guard !isBusy else { return }

        isBusy = true
        codexRunner.resetCancellation()
        errorMessage = nil
        defer { isBusy = false }

        do {
            let seasonValue = try parsedSeason()

            infoMessage = "Lade Bundesliga-Daten..."
            let (finished, nextSpieltag, upcoming) = try await ligaService.fetchSeason(season: seasonValue)
            finishedResults = finished
            upcomingMatches = upcoming
            suggestedTips = []
            matchExpectedGoals = []
            importedResponse = ""
            self.nextSpieltag = nextSpieltag

            guard !upcoming.isEmpty else {
                throw ValidationError.noUpcomingMatches
            }
            await loadHistoricalSeasons(before: seasonValue, count: 2)

            infoMessage = "Lese Wettquoten..."
            bettingOdds = []
            overUnderOdds = []
            bttsOdds = []
            handicapOdds = []
            if !theOddsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let allMarketOdds = try await oddsAPIService.fetchAllMarketOdds()
                    bettingOdds = OddsRemapper.remapOddsToUpcomingMatches(allMarketOdds.h2h, upcomingMatches: upcoming)
                    overUnderOdds = OddsRemapper.remapOverUnderToUpcomingMatches(allMarketOdds.overUnder, upcomingMatches: upcoming)
                    bttsOdds = OddsRemapper.remapBTTSToUpcomingMatches(allMarketOdds.btts, upcomingMatches: upcoming)
                    handicapOdds = OddsRemapper.remapHandicapToUpcomingMatches(allMarketOdds.handicap, upcomingMatches: upcoming)
                    appendConsole("[Quoten] \(bettingOdds.count)/\(upcoming.count) Quoten aus The Odds API geladen.\n")
                } catch {
                    appendConsole("[Quoten] The Odds API fehlgeschlagen: \(error.localizedDescription)\n")
                }
            } else {
                appendConsole("[Quoten] The Odds API nicht konfiguriert, nutze Kicktipp-Fallback.\n")
            }

            if bettingOdds.count < upcoming.count {
                try await ensureKicktippMatchdayReadyForExtraction()
                let kicktippOddsResult = await kicktippAutomation.extractOdds(competitionSlug: kicktippCompetitionSlug)
                appendConsole(kicktippOddsResult.log)

                let remappedKicktippOdds = OddsRemapper.remapOddsToUpcomingMatches(kicktippOddsResult.odds, upcomingMatches: upcoming)
                let existingOddsByMatchKey = ensembleService.remappedOdds(bettingOdds: bettingOdds, upcomingMatches: upcoming)
                let kicktippOddsByMatchKey = ensembleService.remappedOdds(bettingOdds: remappedKicktippOdds, upcomingMatches: upcoming)

                bettingOdds = upcoming.compactMap { match in
                    let key = normalizedTeamKey(match.heim, match.gast)
                    return existingOddsByMatchKey[key] ?? kicktippOddsByMatchKey[key]
                }

                if let fields = try? await kicktippAutomation.extractMatchFields() {
                    kicktippMatchFields = fields
                    kicktippStatus = "\(fields.count) Kicktipp-Spiele erkannt"
                }
                appendConsole("[Quoten] Nach Fallback insgesamt \(bettingOdds.count)/\(upcoming.count) Quoten verfuegbar.\n")
            }

            validateWorkflowInputs(upcomingMatches: upcoming)
            archiveCurrentOdds(season: String(seasonValue))

            infoMessage = "Lade Team- und Stadiondaten..."
            do {
                teamMetadata = try await teamMetadataService.fetchBundesligaTeamMetadata()
                appendConsole("[TheSportsDB] \(teamMetadata.count) Team-Metadaten geladen.\n")
            } catch {
                appendConsole("[TheSportsDB] Fehler: \(error.localizedDescription)\n")
                teamMetadata = []
            }

            infoMessage = "Lade Verletzungen & Sperren..."
            do {
                let absences = try await sofaScoreService.fetchAbsences()
                playerAbsences = absences
                appendConsole("[SofaScore] \(absences.count) Abwesenheiten geladen.\n")
            } catch {
                appendConsole("[SofaScore] Fehler: \(error.localizedDescription)\n")
                playerAbsences = []
            }

            infoMessage = "Lade Wetterdaten..."
            do {
                matchWeather = try await weatherService.fetchWeather(for: upcomingMatches, teamMetadata: teamMetadata)
                appendConsole("[Open-Meteo] \(matchWeather.count) Wetter-Eintraege geladen.\n")
            } catch {
                appendConsole("[Open-Meteo] Fehler: \(error.localizedDescription)\n")
                matchWeather = []
            }

            if !kicktippCompetitionSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                infoMessage = "Lese Tipps und Quoten vergangener Spieltage..."
                await syncCommunityTips(seasonValue: seasonValue)
                await backfillKicktippOdds(seasonValue: seasonValue)
                do {
                    try await ensureKicktippMatchdayReadyForExtraction()
                } catch {
                    appendConsole("[Mitspieler] Zurueck zur Tippabgabe fehlgeschlagen: \(error.localizedDescription)\n")
                }
            }

            infoMessage = "Recherchiere fehlende Zusatzdaten..."
            llmMatchEnrichments = await fetchLLMMatchEnrichments(seasonValue: seasonValue)

            infoMessage = "Erzeuge Prompt..."
            generatedPrompt = tipWorkflowService.buildPrompt(
                season: seasonValue,
                finishedResults: finishedResults,
                upcomingMatches: upcomingMatches,
                bettingOdds: bettingOdds,
                overUnderOdds: overUnderOdds,
                bttsOdds: bttsOdds,
                handicapOdds: handicapOdds,
                playerAbsences: playerAbsences,
                teamMetadata: teamMetadata,
                matchWeather: matchWeather,
                llmMatchEnrichments: llmMatchEnrichments,
                tipHistory: tipHistory,
                learningState: learningState,
                communitySummary: communityService.promptSummary(
                    matchdays: currentSeasonCommunity,
                    rules: kicktippRules,
                    backtest: communityBacktest,
                    strategy: useRankingStrategy ? rankingStrategy : nil
                )
            )

            guard !generatedPrompt.isEmpty else { return }

            try await runPromptEnsembleWithCodex()
        } catch let e as KicktippAutomationError {
            errorMessage = e.localizedDescription
            if case let .noBettingFieldsFound(debugInfo) = e {
                appendConsole("\n[AUTO-LOG] Kicktipp DOM Debug:\n\(debugInfo)\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importTipsFromResponse() {
        importTipsFromResponse(probabilityModels: [:])
    }

    func importTipsFromResponse(probabilityModels: [String: EnsembleService.MatchProbabilityModel]) {
        errorMessage = nil
        do {
            let tips = try tipWorkflowService.parseTips(from: importedResponse, upcomingMatches: upcomingMatches)
            suggestedTips = tips
            if let spieltag = tips.first?.spieltag {
                let storedOdds = storedOddsSnapshot(for: tips)
                appendConsole("[Verlauf] \(tips.count) Tipps, \(storedOdds.count)/\(tips.count) Quoten gespeichert.\n")
                appendConsole("[Verlauf] Kicktipp-Namen: \(bettingOdds.map { "\($0.heim) vs \($0.gast)" }.joined(separator: ", "))\n")
                tipHistory.append(TipGenerationRecord(id: UUID(), timestamp: Date(), spieltag: spieltag, tips: tips, odds: storedOdds))
            }
            recordPredictionRun(tips: tips, rawPrompt: generatedPrompt, rawResponse: importedResponse, probabilityModels: probabilityModels)
            infoMessage = "Tipps importiert."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearTipHistory() {
        tipHistory = []
    }

    func fetchLLMMatchEnrichments(seasonValue: Int) async -> [LLMMatchEnrichment] {
        guard !upcomingMatches.isEmpty else { return [] }

        let missingSignals = [
            "Shots-on-Goal und Verwertung",
            "Schiedsrichter-Statistiken",
            "Zusatzbelastung durch Europa/Pokal",
            "Sharp-Odds/Exchange-Check",
            "Lineup- und kurzfristige Teamnews",
            "Spielerwerte nach Minuten, Position, xG/xA, Defensive Actions und Keeper-Wert",
            "Closing-Line-Value oder closing-nahe Marktbewegung",
            "saisonuebergreifende historische Team- und Liga-Basisdaten",
            "Scoreline-Kalibrierung aus historischer Ergebnisverteilung",
            "dynamischer Gewichtungshinweis fuer Markt/Form/Lineup/Spielerimpact"
        ]
        let prompt = tipWorkflowService.buildLLMEnrichmentPrompt(
            season: seasonValue,
            upcomingMatches: upcomingMatches,
            bettingOdds: bettingOdds,
            knownMissingSignals: missingSignals
        )
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("betbaconer-codex-enrichment-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputFile) }

        do {
            let result = try await executeCodexCommand(
                arguments: CodexRunner.execArguments(outputFile: outputFile),
                standardInput: prompt
            ) { chunk in
                self.appendConsole(self.stripANSI(chunk))
            }
            guard result.exitCode == 0 else {
                appendConsole("[LLM] Zusatzdaten fehlgeschlagen: Codex exit \(result.exitCode).\n")
                return []
            }
            let output = try String(contentsOf: outputFile, encoding: .utf8)
            let enrichments = try tipWorkflowService.parseLLMMatchEnrichments(from: output, upcomingMatches: upcomingMatches)
            appendConsole("[LLM] \(enrichments.count)/\(upcomingMatches.count) Zusatzdaten-Recherchen geladen.\n")
            return enrichments
        } catch {
            appendConsole("[LLM] Zusatzdaten fehlgeschlagen: \(error.localizedDescription)\n")
            return []
        }
    }

    func runPromptEnsembleWithCodex() async throws {
        let runCount = codexRunCount
        var successfulRuns: [(tips: [SuggestedTip], rawResponse: String, runIndex: Int)] = []
        var failedRuns = 0

        for runIndex in 1...runCount {
            infoMessage = runCount == 1 ? "Codex analysiert..." : "Codex-Lauf \(runIndex)/\(runCount)..."
            let outputFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("betbaconer-codex-last-message-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outputFile) }

            do {
                let arguments = CodexRunner.execArguments(outputFile: outputFile)
                let result = try await executeCodexCommand(arguments: arguments, standardInput: generatedPrompt) { chunk in
                    self.appendConsole(self.stripANSI(chunk))
                }

                guard result.exitCode == 0 else {
                    throw CodexCLIError.executionFailed("Codex exec fehlgeschlagen. Siehe Console-Ausgabe.")
                }

                let output = try String(contentsOf: outputFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let tips = try tipWorkflowService.parseTips(from: output, upcomingMatches: upcomingMatches)
                successfulRuns.append((tips: tips, rawResponse: output, runIndex: runIndex))
                appendConsole("[Ensemble] Lauf \(runIndex)/\(runCount) erfolgreich geparst.\n")
            } catch CodexCLIError.cancelled {
                throw CodexCLIError.cancelled
            } catch {
                failedRuns += 1
                appendConsole("[Ensemble] Lauf \(runIndex)/\(runCount) fehlgeschlagen: \(error.localizedDescription)\n")
            }
        }

        guard !successfulRuns.isEmpty else {
            throw CodexCLIError.executionFailed("Alle Codex-Laeufe sind fehlgeschlagen. Siehe Console-Ausgabe.")
        }

        let minimumSuccessfulRuns = requiredSuccessfulCodexRuns(for: runCount)
        guard successfulRuns.count >= minimumSuccessfulRuns else {
            throw CodexCLIError.executionFailed(
                "Zu wenige erfolgreiche Codex-Laeufe: \(successfulRuns.count)/\(runCount). Mindestens \(minimumSuccessfulRuns) erfolgreiche Laeufe sind erforderlich."
            )
        }

        let expectedGoals = expectedGoalsByMatch()
        matchExpectedGoals = expectedGoals.values.sorted { $0.heim < $1.heim }
        appendConsole("[Ensemble] Poisson-Scoreline ueber \(successfulRuns.count) Lauf/Laeufe berechnet.\n")
        for run in successfulRuns {
            recordPredictionRun(
                tips: run.tips,
                rawPrompt: generatedPrompt,
                rawResponse: run.rawResponse,
                modelName: "codex-cli-run-\(run.runIndex)"
            )
        }
        appendConsole("[xG] " + expectedGoals.values
            .sorted { $0.heim < $1.heim }
            .map { String(format: "%@ %.2f : %.2f %@", $0.heim, $0.home, $0.away, $0.gast) }
            .joined(separator: " | ") + "\n")
        let aggregated = try ensembleService.aggregate(
            from: successfulRuns.map(\.tips),
            upcomingMatches: upcomingMatches,
            bettingOdds: bettingOdds,
            expectedGoals: expectedGoals
        )
        let probabilityModels = Dictionary(
            aggregated.map { (normalizedTeamKey($0.tip.heim, $0.tip.gast), $0.model) },
            uniquingKeysWith: { first, _ in first }
        )
        let stabilized = Self.stabilizeShortTermTips(
            aggregated.map(\.tip),
            previousRuns: predictionRuns,
            currentRuns: successfulRuns.map(\.tips),
            seasonIdentifier: season.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if stabilized.stabilizedCount > 0 {
            appendConsole("[Stabilitaet] \(stabilized.stabilizedCount) Tipp(s) aus vorherigem Kurzfrist-Run beibehalten; neuer Lauf ohne starken Konsens.\n")
        }
        importedResponse = tipWorkflowService.encodeTipsAsJSON(stabilized.tips)
        importTipsFromResponse(probabilityModels: probabilityModels)
        if failedRuns > 0 {
            appendConsole("[Ensemble] \(failedRuns) Lauf/Laeufe wurden verworfen.\n")
        }
        infoMessage = runCount == 1
            ? "Codex-Ausfuehrung abgeschlossen"
            : "Codex-Ensemble abgeschlossen (\(successfulRuns.count)/\(runCount) Laeufe)"
    }

    func recordPredictionRun(
        tips: [SuggestedTip],
        rawPrompt: String,
        rawResponse: String,
        modelName: String = PredictionRun.ensembleModelName,
        probabilityModels: [String: EnsembleService.MatchProbabilityModel] = [:]
    ) {
        guard !tips.isEmpty else { return }

        let runId = UUID()
        let createdAt = Date()
        let trimmedSeason = season.trimmingCharacters(in: .whitespacesAndNewlines)
        let seasonIdentifier = trimmedSeason.isEmpty ? "unknown" : trimmedSeason
        let contexts = Dictionary(buildPredictionContexts().map { (normalizedTeamKey($0.upcomingMatch.heim, $0.upcomingMatch.gast), $0) }, uniquingKeysWith: { first, _ in first })
        let matches = tips.map { tip -> MatchPrediction in
            let context = contexts[normalizedTeamKey(tip.heim, tip.gast)]
            let model = probabilityModels[normalizedTeamKey(tip.heim, tip.gast)]
            return MatchPrediction(
                id: UUID(),
                runId: runId,
                spieltag: tip.spieltag,
                heim: tip.heim,
                gast: tip.gast,
                kickoffAt: context?.upcomingMatch.datum ?? "",
                predictedHomeGoals: tip.toreHeim,
                predictedAwayGoals: tip.toreGast,
                predictedOutcome: outcome(forHomeGoals: tip.toreHeim, awayGoals: tip.toreGast),
                rationale: tip.rationale,
                quoteHome: context?.quoteHome,
                quoteDraw: context?.quoteDraw,
                quoteAway: context?.quoteAway,
                homeFormLast5: context?.homeFormLast5,
                awayFormLast5: context?.awayFormLast5,
                homeGoalsPerGame: context?.homeGoalsPerGame,
                awayGoalsPerGame: context?.awayGoalsPerGame,
                homeConcededPerGame: context?.homeConcededPerGame,
                awayConcededPerGame: context?.awayConcededPerGame,
                injuriesHomeCount: context?.injuriesHomeCount,
                injuriesAwayCount: context?.injuriesAwayCount,
                keyAbsenceHome: context?.keyAbsenceHome,
                keyAbsenceAway: context?.keyAbsenceAway,
                consistencySignalSummary: context?.consistencySignalSummary,
                llmLineup: context?.llmLineup,
                llmPlayerValue: context?.llmPlayerValue,
                llmSharpOdds: context?.llmSharpOdds,
                llmClosingLine: context?.llmClosingLine,
                llmHistoricalBaseline: context?.llmHistoricalBaseline,
                llmScorelineCalibration: context?.llmScorelineCalibration,
                dataQuality: context?.dataQuality,
                expectedHomeGoals: context?.expectedHomeGoals,
                expectedAwayGoals: context?.expectedAwayGoals,
                marketWeightHint: context?.marketWeightHint,
                probabilityHomeWin: model?.probabilityHomeWin,
                probabilityDraw: model?.probabilityDraw,
                probabilityAwayWin: model?.probabilityAwayWin,
                confidence: model?.confidence,
                topScorelines: model?.topScorelines,
                actualHomeGoals: nil,
                actualAwayGoals: nil,
                actualOutcome: nil,
                exactHit: nil,
                tendencyHit: nil,
                goalDiffHit: nil,
                absErrorHomeGoals: nil,
                absErrorAwayGoals: nil,
                totalAbsGoalError: nil,
                evaluatedAt: nil
            )
        }

        predictionRuns.append(
            PredictionRun(
                id: runId,
                createdAt: createdAt,
                spieltag: tips.first?.spieltag ?? 0,
                modelName: modelName,
                promptVersion: Self.promptVersion,
                rawPrompt: rawPrompt,
                rawResponse: rawResponse,
                seasonIdentifier: seasonIdentifier,
                matches: matches
            )
        )
    }

    func buildPredictionContexts() -> [PredictionMatchContext] {
        let oddsByKey = ensembleService.remappedOdds(bettingOdds: bettingOdds, upcomingMatches: upcomingMatches)
        let groupedAbsences = Dictionary(grouping: playerAbsences) { normalizeTeamName($0.teamName) }
        let expectedGoalsByKey = Dictionary(matchExpectedGoals.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
        let enrichmentsByKey = Dictionary(llmMatchEnrichments.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
        let targetSpieltag = upcomingMatches.first?.spieltag
        let seasonValue = season.trimmingCharacters(in: .whitespacesAndNewlines)
        let historyForMatchday = tipHistory.filter {
            $0.spieltag == targetSpieltag && String(Self.currentBundesligaSeason(for: $0.timestamp)) == seasonValue
        }

        return upcomingMatches.map { match in
            let homeStats = teamPerformance(for: match.heim)
            let awayStats = teamPerformance(for: match.gast)
            let homeAbsences = groupedAbsences[normalizeTeamName(match.heim)] ?? []
            let awayAbsences = groupedAbsences[normalizeTeamName(match.gast)] ?? []
            let odds = oddsByKey[normalizedTeamKey(match.heim, match.gast)]
            let xg = expectedGoalsByKey[normalizedTeamKey(match.heim, match.gast)]
            let enrichment = enrichmentsByKey[normalizedTeamKey(match.heim, match.gast)]

            return PredictionMatchContext(
                upcomingMatch: match,
                quoteHome: parseQuote(odds?.quoteHeim),
                quoteDraw: parseQuote(odds?.quoteUnentschieden),
                quoteAway: parseQuote(odds?.quoteGast),
                homeFormLast5: homeStats.formLast5,
                awayFormLast5: awayStats.formLast5,
                homeGoalsPerGame: homeStats.goalsPerGame,
                awayGoalsPerGame: awayStats.goalsPerGame,
                homeConcededPerGame: homeStats.concededPerGame,
                awayConcededPerGame: awayStats.concededPerGame,
                injuriesHomeCount: homeAbsences.count,
                injuriesAwayCount: awayAbsences.count,
                keyAbsenceHome: homeAbsences.first.map { "\($0.playerName) (\($0.type))" },
                keyAbsenceAway: awayAbsences.first.map { "\($0.playerName) (\($0.type))" },
                consistencySignalSummary: consistencySignalSummary(for: match, history: historyForMatchday),
                llmLineup: enrichment?.structuredLineup,
                llmPlayerValue: enrichment?.playerValue,
                llmSharpOdds: enrichment?.sharpOdds,
                llmClosingLine: enrichment?.closingLine,
                llmHistoricalBaseline: enrichment?.historicalBaseline,
                llmScorelineCalibration: enrichment?.scorelineCalibration,
                dataQuality: enrichment?.dataQuality,
                expectedHomeGoals: xg?.home,
                expectedAwayGoals: xg?.away,
                marketWeightHint: xg?.marketWeightHint
            )
        }
    }

    func teamPerformance(for team: String) -> (formLast5: String, goalsPerGame: Double, concededPerGame: Double) {
        let matches = finishedResults
            .filter { $0.heim == team || $0.gast == team }
            .sorted { ($0.spieltag, $0.datum) > ($1.spieltag, $1.datum) }

        guard !matches.isEmpty else {
            return ("-", 0, 0)
        }

        let form = matches.prefix(5).map { match -> String in
            let homeGoals = match.heim == team ? match.toreHeim : match.toreGast
            let awayGoals = match.heim == team ? match.toreGast : match.toreHeim
            return homeGoals > awayGoals ? "S" : homeGoals == awayGoals ? "U" : "N"
        }.joined(separator: "-")

        let goals = matches.map { $0.heim == team ? $0.toreHeim : $0.toreGast }
        let conceded = matches.map { $0.heim == team ? $0.toreGast : $0.toreHeim }

        return (
            form.isEmpty ? "-" : form,
            Double(goals.reduce(0, +)) / Double(goals.count),
            Double(conceded.reduce(0, +)) / Double(conceded.count)
        )
    }

    func consistencySignalSummary(for match: UpcomingMatch, history: [TipGenerationRecord]) -> String? {
        let entries = history.compactMap { record in
            record.tips.first { normalizedTeamKey($0.heim, $0.gast) == normalizedTeamKey(match.heim, match.gast) }
        }
        guard !entries.isEmpty else { return nil }
        let grouped = Dictionary(grouping: entries) { "\($0.toreHeim):\($0.toreGast)" }
        let summary = grouped.sorted { $0.value.count > $1.value.count }
            .map { "\($0.value.count)x \($0.key)" }
            .joined(separator: ", ")
        return summary
    }

    func validateWorkflowInputs(upcomingMatches: [UpcomingMatch]) {
        if bettingOdds.count < upcomingMatches.count {
            appendConsole("[Quoten] Warnung: Nur \(bettingOdds.count)/\(upcomingMatches.count) Quoten verfuegbar – Workflow laeuft ohne vollstaendige Quotendaten.\n")
        }
    }

    func requiredSuccessfulCodexRuns(for configuredRuns: Int) -> Int {
        guard configuredRuns > 1 else { return 1 }
        return max(2, Int(ceil(Double(configuredRuns) * 0.6)))
    }

    func expectedGoalsByMatch() -> [String: MatchExpectedGoals] {
        ExpectedGoalsModel(ratingService: teamRatingService).expectedGoals(ExpectedGoalsInput(
            season: Int(season) ?? Self.currentBundesligaSeason(),
            finishedResults: finishedResults,
            historicalSeasons: historicalSeasons,
            upcomingMatches: upcomingMatches,
            bettingOdds: bettingOdds,
            overUnderOdds: overUnderOdds,
            playerAbsences: playerAbsences,
            llmMatchEnrichments: llmMatchEnrichments,
            marketWeight: learnedMarketWeight,
            llmSignalWeight: learnedLLMSignalWeight(),
            learningState: learningState
        ))
    }

    func learnedLLMSignalWeight() -> Double {
        decodedLearningWeights()?.llmSignalWeight ?? 0.55
    }

    func decodedLearningWeights() -> LearningCorrectionWeights? {
        try? JSONDecoder().decode(LearningCorrectionWeights.self, from: Data(learningState.weightsJSON.utf8))
    }

    func storedOddsSnapshot(for tips: [SuggestedTip]) -> [BettingOdds] {
        tips.compactMap { tip in
            guard let matchedOdds = bettingOdds.first(where: {
                teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast)
            }) else {
                return nil
            }

            return BettingOdds(
                heim: tip.heim,
                gast: tip.gast,
                quoteHeim: matchedOdds.quoteHeim,
                quoteUnentschieden: matchedOdds.quoteUnentschieden,
                quoteGast: matchedOdds.quoteGast
            )
        }
    }

    func parseQuote(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value.replacingOccurrences(of: ",", with: "."))
    }

    func syncManualKicktippTipsForLearning(from fields: [KicktippMatchField]) {
        let tips = Self.manualTips(from: fields, upcomingMatches: upcomingMatches)
        guard !tips.isEmpty, !hasPredictionRun(modelName: PredictionRun.manualModelName, tips: tips) else { return }

        recordPredictionRun(tips: tips, rawPrompt: "", rawResponse: "", modelName: PredictionRun.manualModelName)
        appendConsole("[Learning] \(tips.count) manuelle Kicktipp-Tipps fuer Self-Learning gespeichert.\n")
    }

    func hasPredictionRun(modelName: String, tips: [SuggestedTip]) -> Bool {
        let expected = Dictionary(tips.map {
            (normalizedTeamKey($0.heim, $0.gast), "\($0.toreHeim):\($0.toreGast)")
        }, uniquingKeysWith: { first, _ in first })

        return predictionRuns.contains { run in
            guard run.modelName == modelName,
                  run.seasonIdentifier == season.trimmingCharacters(in: .whitespacesAndNewlines),
                  run.spieltag == tips.first?.spieltag,
                  run.matches.count == tips.count else {
                return false
            }

            let actual = Dictionary(run.matches.map {
                (normalizedTeamKey($0.heim, $0.gast), "\($0.predictedHomeGoals):\($0.predictedAwayGoals)")
            }, uniquingKeysWith: { first, _ in first })
            return actual == expected
        }
    }
}
