import Foundation

enum TipHistoryStoreError: LocalizedError {
    case failedToLoad
    case failedToSave

    var errorDescription: String? {
        switch self {
        case .failedToLoad:
            return "Der Tipp-Verlauf konnte nicht geladen werden."
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
            throw TipHistoryStoreError.failedToLoad
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
