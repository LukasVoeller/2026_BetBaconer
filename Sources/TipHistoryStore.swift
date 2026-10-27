import Foundation

enum TipHistoryStoreError: LocalizedError {
    case failedToLoad(backup: URL?)
    case failedToSave

    var errorDescription: String? {
        switch self {
        case let .failedToLoad(backup):
            return "Der Tipp-Verlauf konnte nicht geladen werden."
                + (backup.map { " Die Datei wurde nach \($0.lastPathComponent) gesichert, es wird neu begonnen." } ?? " Speichern ist deaktiviert, um Datenverlust zu vermeiden.")
        case .failedToSave:
            return "Der Tipp-Verlauf konnte nicht gespeichert werden."
        }
    }
}

struct TipHistoryStore {
    private let fileURL: URL

    init(fileURL: URL = TipHistoryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> [TipGenerationRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            return try decoder.decode([TipGenerationRecord].self, from: data)
        } catch {
            AppLogger.persistence.error("Tip history load failed: \(error.localizedDescription, privacy: .public)")
            throw TipHistoryStoreError.failedToLoad(backup: AppSupportPaths.quarantine(fileURL))
        }
    }

    func save(_ records: [TipGenerationRecord]) throws {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.persistence.error("Tip history save failed: \(error.localizedDescription, privacy: .public)")
            throw TipHistoryStoreError.failedToSave
        }
    }

    static var defaultFileURL: URL {
        let dir = AppSupportPaths.appDirectory()
        return dir.appendingPathComponent("tip-history.json")
    }
}
