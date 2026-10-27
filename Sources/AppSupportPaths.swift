import Foundation

enum AppSupportPaths {
    static func appDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("BetBaconer")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            AppLogger.persistence.error("Application Support directory creation failed: \(error.localizedDescription, privacy: .public)")
        }
        return dir
    }

    /// Moves an unreadable store file aside so the next save cannot overwrite the user's history.
    static func quarantine(_ url: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return backup
        } catch {
            AppLogger.persistence.error("Quarantine failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
