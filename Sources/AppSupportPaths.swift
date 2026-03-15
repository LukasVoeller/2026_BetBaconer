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
}
