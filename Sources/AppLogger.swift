import Foundation
import OSLog

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "BetBaconer"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let automation = Logger(subsystem: subsystem, category: "automation")
}
