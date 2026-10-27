import Foundation

struct CodexCommandResult {
    let output: String
    let exitCode: Int32
}

enum CodexCLIError: LocalizedError, Equatable {
    case executableNotFound(String)
    case executionFailed(String)
    case timedOut(TimeInterval)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "Codex CLI nicht gefunden unter: \(path)"
        case let .executionFailed(message):
            return message
        case let .timedOut(seconds):
            return "Codex hat nicht innerhalb von \(Int(seconds / 60)) Minuten geantwortet und wurde beendet."
        case .cancelled:
            return "Codex-Ausfuehrung wurde abgebrochen."
        }
    }
}

/// Lets the UI terminate a running Codex process.
final class CodexProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var terminatedByUser = false

    var wasCancelled: Bool {
        lock.withLock { terminatedByUser }
    }

    func attach(_ process: Process) {
        let cancelledEarly = lock.withLock {
            self.process = process
            return terminatedByUser
        }
        if cancelledEarly { process.terminate() }
    }

    func terminate() {
        let running = lock.withLock {
            terminatedByUser = true
            return process
        }
        if running?.isRunning == true { running?.terminate() }
    }
}

/// Accumulates process output and decodes only complete UTF-8 sequences, so multi-byte
/// characters split across pipe reads are not dropped.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var pending: [ObjectIdentifier: Data] = [:]

    func append(_ data: Data, from handle: FileHandle) -> String {
        lock.withLock {
            let key = ObjectIdentifier(handle)
            var buffer = pending[key, default: Data()]
            buffer.append(data)
            var decoded = ""
            // A UTF-8 sequence is at most 4 bytes, so at most 3 trailing bytes can be incomplete.
            for trim in 0...min(3, buffer.count) {
                if let string = String(data: buffer.dropLast(trim), encoding: .utf8) {
                    decoded = string
                    buffer = Data(buffer.suffix(trim))
                    break
                }
            }
            pending[key] = buffer
            text += decoded
            return decoded
        }
    }

    func snapshot() -> String {
        lock.withLock { text }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() { lock.withLock { fired = true } }
    var didFire: Bool { lock.withLock { fired } }
}

struct CodexCLIService: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        standardInput: String? = nil,
        timeout: TimeInterval,
        handle: CodexProcessHandle = CodexProcessHandle(),
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CodexCommandResult {
        let expandedPath = NSString(string: executablePath).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: expandedPath) else {
            throw CodexCLIError.executableNotFound(expandedPath)
        }

        let timeoutFlag = TimeoutFlag()
        let result: CodexCommandResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                let stdin = Pipe()
                let collector = OutputCollector()

                let reader: @Sendable (FileHandle) -> Void = { fileHandle in
                    let data = fileHandle.availableData
                    guard !data.isEmpty else { return }
                    let text = collector.append(data, from: fileHandle)
                    if !text.isEmpty { onOutput(text) }
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
                    for pipe in [stdout, stderr] {
                        let readHandle = pipe.fileHandleForReading
                        readHandle.readabilityHandler = nil
                        let rest = readHandle.readDataToEndOfFile()
                        if !rest.isEmpty {
                            let text = collector.append(rest, from: readHandle)
                            if !text.isEmpty { onOutput(text) }
                        }
                    }
                    continuation.resume(returning: CodexCommandResult(output: collector.snapshot(), exitCode: process.terminationStatus))
                }

                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CodexCLIError.executionFailed(error.localizedDescription))
                    return
                }
                handle.attach(process)

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timeoutFlag.fire()
                    process.terminate()
                }

                // Writing a large prompt blocks until Codex reads it, so keep it off the cooperative pool.
                // If Codex exits early the write fails with EPIPE (SIGPIPE is ignored in AppDelegate).
                let input = standardInput.map { Data($0.utf8) }
                DispatchQueue.global().async {
                    let writer = stdin.fileHandleForWriting
                    if let input {
                        try? writer.write(contentsOf: input)
                    }
                    try? writer.close()
                }
            }
        } onCancel: {
            handle.terminate()
        }

        if handle.wasCancelled { throw CodexCLIError.cancelled }
        if timeoutFlag.didFire { throw CodexCLIError.timedOut(timeout) }
        return result
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
