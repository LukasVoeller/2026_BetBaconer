import Foundation

struct CodexCommandResult {
    let output: String
    let exitCode: Int32
}

enum CodexCLIError: LocalizedError {
    case executableNotFound(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "Codex CLI nicht gefunden unter: \(path)"
        case let .executionFailed(message):
            return message
        }
    }
}

private final class SynchronizedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func append(_ text: String) {
        lock.lock()
        value += text
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct CodexCLIService: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        standardInput: String? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CodexCommandResult {
        let expandedPath = NSString(string: executablePath).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: expandedPath) else {
            throw CodexCLIError.executableNotFound(expandedPath)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            let buffer = SynchronizedBuffer()

            let append: @Sendable (String) -> Void = { text in
                guard !text.isEmpty else { return }
                buffer.append(text)
                onOutput(text)
            }

            let reader: @Sendable (FileHandle) -> Void = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                append(text)
            }

            stdout.fileHandleForReading.readabilityHandler = reader
            stderr.fileHandleForReading.readabilityHandler = reader

            let launch = Self.buildLaunchConfiguration(for: expandedPath, arguments: arguments)
            process.executableURL = URL(fileURLWithPath: launch.executable)
            process.arguments = launch.arguments
            process.environment = Self.buildEnvironment(extraPATHEntries: launch.pathEntries)
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                let remainingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: remainingStdout, encoding: .utf8), !text.isEmpty {
                    append(text)
                }

                let remainingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: remainingStderr, encoding: .utf8), !text.isEmpty {
                    append(text)
                }

                continuation.resume(returning: CodexCommandResult(output: buffer.snapshot(), exitCode: process.terminationStatus))
            }

            do {
                try process.run()
                if let standardInput {
                    if let data = standardInput.data(using: .utf8) {
                        stdin.fileHandleForWriting.write(data)
                    }
                    try? stdin.fileHandleForWriting.close()
                }
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: CodexCLIError.executionFailed(error.localizedDescription))
            }
        }
    }

    private static func buildLaunchConfiguration(for executablePath: String, arguments: [String]) -> (executable: String, arguments: [String], pathEntries: [String]) {
        let standardPATHEntries = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        if shouldLaunchViaNode(scriptPath: executablePath), let nodePath = firstExistingExecutable(in: ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]) {
            return (nodePath, [executablePath] + arguments, standardPATHEntries)
        }

        let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        return (executablePath, arguments, [executableDirectory] + standardPATHEntries)
    }

    private static func buildEnvironment(extraPATHEntries: [String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPATH = environment["PATH"] ?? ""
        let combined = (extraPATHEntries + existingPATH.split(separator: ":").map(String.init))
        var deduplicated: [String] = []
        for entry in combined where !entry.isEmpty {
            if !deduplicated.contains(entry) {
                deduplicated.append(entry)
            }
        }
        environment["PATH"] = deduplicated.joined(separator: ":")
        return environment
    }

    private static func shouldLaunchViaNode(scriptPath: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: scriptPath) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 128)
        guard let header = String(data: data, encoding: .utf8) else { return false }
        return header.contains("#!/usr/bin/env node")
    }

    private static func firstExistingExecutable(in candidates: [String]) -> String? {
        candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
