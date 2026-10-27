import Foundation
import Testing
@testable import BetBaconer

/// Regression tests for the code review fixes (date parsing, matchday choice, parsing, persistence, Codex process).
final class ReviewRegressionTests {

    // MARK: - Dates & matchday

    @Test
    func testParsesLegacyOpenLigaLocalKickoffAndUTC() throws {
        let local = try XCTUnwrap(parseKickoffDate("2025-08-22T20:30:00"))
        let utc = try XCTUnwrap(parseKickoffDate("2025-08-22T18:30:00Z"))
        XCTAssertEqual(local, utc)
    }

    @Test
    func testTeamRatingFitsWithLocalKickoffStrings() {
        let teams = ["A", "B", "C", "D"]
        var results: [FinishedMatch] = []
        for round in 0..<6 {
            for (index, home) in teams.enumerated() {
                let away = teams[(index + round + 1) % teams.count]
                guard home != away else { continue }
                results.append(FinishedMatch(spieltag: round + 1, datum: "2025-09-\(10 + round)T15:30:00", heim: home, gast: away, toreHeim: index, toreGast: 1))
            }
        }

        XCTAssertTrue(TeamRatingService().fit(finishedResults: results) != nil)
    }

    @Test
    func testNextMatchdaySkipsPostponedEarlierMatch() {
        let finished = [FinishedMatch(spieltag: 25, datum: "2026-03-01T14:30:00Z", heim: "A", gast: "B", toreHeim: 1, toreGast: 0)]
        let upcoming = [
            UpcomingMatch(spieltag: 20, datum: "2026-03-04T19:30:00Z", heim: "C", gast: "D"),
            UpcomingMatch(spieltag: 26, datum: "2026-03-07T14:30:00Z", heim: "E", gast: "F"),
        ]

        XCTAssertEqual(OpenLigaDBService.nextMatchday(finished: finished, upcoming: upcoming), 26)
    }

    @Test
    func testNextMatchdayKeepsCurrentMatchdayWithOpenSundayGame() {
        let finished = [FinishedMatch(spieltag: 26, datum: "2026-03-07T14:30:00Z", heim: "A", gast: "B", toreHeim: 1, toreGast: 0)]
        let upcoming = [
            UpcomingMatch(spieltag: 26, datum: "2026-03-08T16:30:00Z", heim: "C", gast: "D"),
            UpcomingMatch(spieltag: 27, datum: "2026-03-14T14:30:00Z", heim: "E", gast: "F"),
        ]

        XCTAssertEqual(OpenLigaDBService.nextMatchday(finished: finished, upcoming: upcoming), 26)
    }

    // MARK: - Team names

    @Test
    func testKicktippAndOpenLigaNamesShareCanonicalKey() {
        XCTAssertEqual(normalizeTeamName("1. FC Heidenheim 1846"), normalizeTeamName("1. FC Heidenheim"))
        XCTAssertEqual(normalizeTeamName("Borussia Dortmund"), normalizeTeamName("Bor. Dortmund"))
        XCTAssertEqual(normalizeTeamName("RB Leipzig"), normalizeTeamName("RasenBallsport Leipzig"))
        XCTAssertEqual(normalizeTeamName("1. FC Köln"), normalizeTeamName("Köln"))
    }

    @Test
    func testLikelyMatchRejectsEmptyAndShortFragments() {
        XCTAssertTrue(!teamNamesLikelyMatch("", "FC Augsburg"))
        XCTAssertTrue(!teamNamesLikelyMatch("FC", "FC Augsburg"))
    }

    // MARK: - LLM output parsing

    @Test
    func testParseTipsRejectsDuplicateMatch() {
        let content = """
        {"tips": [
          {"spieltag": 26, "heim": "Team A", "gast": "Team B", "tore_heim": 1, "tore_gast": 0, "rationale": "x"},
          {"spieltag": 26, "heim": "Team A", "gast": "Team B", "tore_heim": 2, "tore_gast": 0, "rationale": "y"}
        ]}
        """
        let upcoming = [UpcomingMatch(spieltag: 26, datum: "", heim: "Team A", gast: "Team B")]

        XCTAssertThrowsError(try TipWorkflowService().parseTips(from: content, upcomingMatches: upcoming)) { error in
            XCTAssertTrue((error as? TipWorkflowError).map { if case .duplicateMatches = $0 { true } else { false } } == true)
        }
    }

    @Test
    func testParseTipsRejectsOutOfRangeScore() {
        let content = """
        {"tips": [{"spieltag": 26, "heim": "Team A", "gast": "Team B", "tore_heim": -1, "tore_gast": 0, "rationale": "x"}]}
        """
        let upcoming = [UpcomingMatch(spieltag: 26, datum: "", heim: "Team A", gast: "Team B")]

        XCTAssertThrowsError(try TipWorkflowService().parseTips(from: content, upcomingMatches: upcoming))
    }

    @Test
    func testParseTipsUsesCanonicalNamesAndMatchday() throws {
        let content = """
        {"tips": [{"spieltag": 99, "heim": "Heidenheim", "gast": "Bor. Dortmund", "tore_heim": 1, "tore_gast": 2, "rationale": "x"}]}
        """
        let upcoming = [UpcomingMatch(spieltag: 26, datum: "", heim: "1. FC Heidenheim 1846", gast: "Borussia Dortmund")]

        let tips = try TipWorkflowService().parseTips(from: content, upcomingMatches: upcoming)
        let tip = try XCTUnwrap(tips.first)

        XCTAssertEqual(tip.spieltag, 26)
        XCTAssertEqual(tip.heim, "1. FC Heidenheim 1846")
    }

    @Test
    func testParseEnrichmentsRejectsDuplicateMatch() {
        let entry = #"{"heim": "Team A", "gast": "Team B", "confidence": 0.5}"#
        let content = #"{"matches": [\#(entry), \#(entry)]}"#
        let upcoming = [UpcomingMatch(spieltag: 1, datum: "", heim: "Team A", gast: "Team B")]

        XCTAssertThrowsError(try TipWorkflowService().parseLLMMatchEnrichments(from: content, upcomingMatches: upcoming))
    }

    // MARK: - Kicktipp form checks

    @Test
    func testKicktippOverwritesAndMismatches() {
        let field = KicktippMatchField(heim: "Team A", gast: "Team B", heimField: "h", gastField: "g", existingHeim: "0", existingGast: "0")
        let tip = SuggestedTip(spieltag: 1, heim: "Team A", gast: "Team B", toreHeim: 2, toreGast: 1, rationale: "")
        let emptyField = KicktippMatchField(heim: "Team A", gast: "Team B", heimField: "h", gastField: "g", existingHeim: "", existingGast: "")

        XCTAssertEqual(AppState.kicktippOverwrites([(field: field, tip: tip)]).count, 1)
        XCTAssertEqual(AppState.kicktippOverwrites([(field: emptyField, tip: tip)]).count, 0)
        XCTAssertEqual(AppState.kicktippMismatches(expected: [tip], fields: [field]).count, 1)
    }

    // MARK: - Persistence

    @Test
    func testPredictionStoreKeepsSubSecondOrderAndQuarantinesCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("learning-store.json")
        let store = PredictionStore(fileURL: fileURL, legacyHistoryURL: directory.appendingPathComponent("tip-history.json"))

        let base = Date(timeIntervalSince1970: 1_700_000_000.1)
        let runs = [base, base.addingTimeInterval(0.4)].map {
            PredictionRun(id: UUID(), createdAt: $0, spieltag: 1, modelName: "test", promptVersion: "v", rawPrompt: "", rawResponse: "", seasonIdentifier: "2025", matches: [])
        }
        try store.save(runs: runs, learningState: .empty)
        let loaded = try store.load()
        XCTAssertTrue(loaded.runs[0].createdAt < loaded.runs[1].createdAt)

        try Data("{ kaputt".utf8).write(to: fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(!FileManager.default.fileExists(atPath: fileURL.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("corrupt") }
        XCTAssertEqual(backups.count, 1)
    }

    // MARK: - Codex process

    @Test
    func testCodexServicePassesStdinAndKeepsMultibyteCharacters() async throws {
        let result = try await CodexCLIService().run(
            executablePath: "/bin/cat",
            arguments: [],
            standardInput: String(repeating: "Müller-Ölstraße ", count: 20_000),
            timeout: 30
        ) { _ in }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.hasSuffix("Müller-Ölstraße "))
        XCTAssertEqual(result.output.count, "Müller-Ölstraße ".count * 20_000)
    }

    @Test
    func testCodexServiceTimesOut() async {
        do {
            _ = try await CodexCLIService().run(executablePath: "/bin/sleep", arguments: ["10"], timeout: 0.5) { _ in }
            #expect(Bool(false))
        } catch {
            XCTAssertEqual(error as? CodexCLIError, .timedOut(0.5))
        }
    }

    @Test
    func testCodexServiceCancelsViaHandle() async {
        let handle = CodexProcessHandle()
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            handle.terminate()
        }
        do {
            _ = try await CodexCLIService().run(executablePath: "/bin/sleep", arguments: ["10"], timeout: 30, handle: handle) { _ in }
            #expect(Bool(false))
        } catch {
            XCTAssertEqual(error as? CodexCLIError, .cancelled)
        }
    }
}

extension ReviewRegressionTests {
    @MainActor
    @Test
    func testCodexRunnerDeliversOutputInOrder() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("order-\(UUID().uuidString).sh")
        try "#!/bin/sh\nfor i in $(seq 1 200); do echo \"line $i\"; done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        var received = ""
        _ = try await CodexRunner().run(executablePath: script.path, arguments: [], standardInput: nil, timeout: 30) { received += $0 }

        let numbers = received.split(separator: "\n").compactMap { Int($0.split(separator: " ").last ?? "") }
        XCTAssertEqual(numbers, Array(1...200))
    }
}

extension ReviewRegressionTests {
    @Test
    func testOpenLigaAndFootballDataNamesOfFormerClubsMatch() {
        XCTAssertEqual(normalizeTeamName("SpVgg Greuther Fürth"), normalizeTeamName("Greuther Furth"))
        XCTAssertEqual(normalizeTeamName("DSC Arminia Bielefeld"), normalizeTeamName("Bielefeld"))
        XCTAssertEqual(normalizeTeamName("Hertha BSC"), normalizeTeamName("Hertha"))
        XCTAssertEqual(normalizeTeamName("SV Darmstadt 98"), normalizeTeamName("Darmstadt"))
    }
}

extension ReviewRegressionTests {
    @MainActor
    @Test
    func testLegacySettingsAreMigratedOnlyIntoEmptyDefaults() {
        let legacy = UserDefaults(suiteName: "BBT-legacy-\(UUID().uuidString)")!
        legacy.set("meine-runde", forKey: "kicktippCompetitionSlug")
        let fresh = UserDefaults(suiteName: "BBT-fresh-\(UUID().uuidString)")!
        AppState.migrateLegacySettings(from: legacy, to: fresh)
        XCTAssertEqual(fresh.string(forKey: "kicktippCompetitionSlug"), "meine-runde")

        let used = UserDefaults(suiteName: "BBT-used-\(UUID().uuidString)")!
        used.set("andere-runde", forKey: "kicktippCompetitionSlug")
        AppState.migrateLegacySettings(from: legacy, to: used)
        XCTAssertEqual(used.string(forKey: "kicktippCompetitionSlug"), "andere-runde")
    }
}
