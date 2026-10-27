import Foundation
import Testing
@testable import BetBaconer

@MainActor
final class AppSettingsAndRepositoryTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bb-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSettings(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(defaults: defaults, secretStore: KeychainSecretStore(service: "BBT.\(UUID().uuidString)", migrateFrom: nil),
                    environment: ["THE_ODDS_API_KEY": "env-key"], legacyDefaultsDomain: nil)
    }

    @Test
    func testSettingsPersistAndReloadWithClamping() {
        let defaults = UserDefaults(suiteName: "BBT-settings-\(UUID().uuidString)")!
        let settings = makeSettings(defaults)
        XCTAssertEqual(settings.theOddsAPIKey, "env-key")

        settings.codexRunCount = 0
        settings.kicktippRules.drawCountsAsGoalDifference = false
        settings.kicktippCompetitionSlug = "runde"

        let reloaded = makeSettings(defaults)
        XCTAssertEqual(reloaded.codexRunCount, 1)
        XCTAssertTrue(!reloaded.kicktippRules.drawCountsAsGoalDifference)
        XCTAssertEqual(reloaded.kicktippCompetitionSlug, "runde")
    }

    @Test
    func testRepositorySavesChangesAndReloadsThem() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func makeRepository() -> LearningRepository {
            LearningRepository(
                predictionStore: PredictionStore(fileURL: directory.appendingPathComponent("learning.json"), legacyHistoryURL: directory.appendingPathComponent("none.json")),
                tipHistoryStore: TipHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
            )
        }

        let repository = makeRepository()
        XCTAssertTrue(repository.loadErrors.isEmpty)
        repository.oddsArchive = [ArchivedOdds(season: "2026", spieltag: 1, heim: "A", gast: "B", quoteHeim: "2.0", quoteUnentschieden: "3.4",
                                               quoteGast: "3.6", overUnderLine: nil, overQuote: nil, underQuote: nil, capturedAt: Date())]
        repository.tipHistory = [TipGenerationRecord(id: UUID(), timestamp: Date(), spieltag: 1, tips: [], odds: [])]

        let reloaded = makeRepository()
        XCTAssertEqual(reloaded.oddsArchive.count, 1)
        XCTAssertEqual(reloaded.tipHistory.count, 1)
    }

    @Test
    func testRepositoryNeverOverwritesUnreadableStoreWhenBackupFails() throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("learning.json")
        try Data("{ kaputt".utf8).write(to: file)
        // A read-only directory makes the quarantine move fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let repository = LearningRepository(
            predictionStore: PredictionStore(fileURL: file, legacyHistoryURL: directory.appendingPathComponent("none.json")),
            tipHistoryStore: TipHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        )
        repository.oddsArchive = []

        XCTAssertTrue(!repository.loadErrors.isEmpty)
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(content, "{ kaputt")
    }
}
