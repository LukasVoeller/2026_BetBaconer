import Foundation

/// Owns the running Codex process: sandboxed `exec` arguments, timeout and user cancellation.
@MainActor
final class CodexRunner {
    private let service = CodexCLIService()
    private var activeProcess: CodexProcessHandle?
    private(set) var cancelRequested = false

    /// `codex exec` always runs read-only: prompts embed untrusted third-party text (absences, LLM research).
    static func execArguments(outputFile: URL) -> [String] {
        ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--output-last-message", outputFile.path, "-"]
    }

    /// Called when a new user operation starts.
    func resetCancellation() {
        cancelRequested = false
    }

    /// Stops the running process; further runs of the same operation fail fast with `.cancelled`.
    func cancel() {
        cancelRequested = true
        activeProcess?.terminate()
    }

    func run(
        executablePath: String,
        arguments: [String],
        standardInput: String?,
        timeout: TimeInterval,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> CodexCommandResult {
        guard !cancelRequested else { throw CodexCLIError.cancelled }
        let handle = CodexProcessHandle()
        activeProcess = handle
        defer { activeProcess = nil }

        return try await service.run(
            executablePath: executablePath,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout,
            handle: handle
        ) { chunk in
            Task { @MainActor in onChunk(chunk) }
        }
    }
}
