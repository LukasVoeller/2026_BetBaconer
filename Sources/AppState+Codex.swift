import AppKit
import Foundation

/// Codex CLI login, command execution and clipboard actions.
extension AppState {
    func checkCodexLoginStatus() async {
        await runCodexCommand(arguments: ["login", "status"], timeout: 60, userFacingAction: "Codex-Status geprueft") { result in
            self.codexStatus = result.exitCode == 0 ? "Angemeldet" : "Nicht angemeldet"
        } onChunk: { chunk in
            self.appendConsole(self.stripANSI(chunk))
        }
    }

    func startCodexLogin() async {
        codexDeviceAuthURL = ""
        codexDeviceCode = ""

        await runCodexCommand(arguments: ["login", "--device-auth"], userFacingAction: "Codex-Login gestartet") { result in
            let cleanOutput = self.stripANSI(result.output)
            self.updateDeviceAuthData(from: cleanOutput)
            self.codexStatus = result.exitCode == 0 ? "Angemeldet" : "Login im Browser abschliessen"
            if !self.codexDeviceAuthURL.isEmpty {
                self.infoMessage = "Device-Auth-URL und Code wurden ausgelesen."
            }
        } onChunk: { chunk in
            let cleanChunk = self.stripANSI(chunk)
            self.appendConsole(cleanChunk)
            self.updateDeviceAuthData(from: self.consoleOutput)
        }
    }

    func openCodexDeviceAuthURL() {
        guard let url = URL(string: codexDeviceAuthURL), !codexDeviceAuthURL.isEmpty else {
            errorMessage = "Keine Device-Auth-URL vorhanden."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copyCodexDeviceCode() {
        guard !codexDeviceCode.isEmpty else {
            errorMessage = "Kein Device-Code vorhanden."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(codexDeviceCode, forType: .string)
        infoMessage = "Device-Code in die Zwischenablage kopiert."
    }

    func stripANSI(_ text: String) -> String {
        let withoutEscapes = text.replacingOccurrences(of: #"\u{001B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        return withoutEscapes.replacingOccurrences(of: #"\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    }

    private func updateDeviceAuthData(from text: String) {
        if codexDeviceAuthURL.isEmpty {
            codexDeviceAuthURL = firstMatch(in: text, pattern: #"https://auth\.openai\.com/codex/device"#) ?? ""
            if !codexDeviceAuthURL.isEmpty {
                openCodexDeviceAuthURL()
            }
        }
        if codexDeviceCode.isEmpty {
            codexDeviceCode = firstMatch(in: text, pattern: #"\b[A-Z0-9]{4}-[A-Z0-9]{5}\b"#) ?? ""
        }
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private func runCodexCommand(
        arguments: [String],
        standardInput: String? = nil,
        timeout: TimeInterval = 15 * 60,
        userFacingAction: String,
        afterSuccess: @escaping (CodexCommandResult) throws -> Void = { _ in },
        onChunk: @escaping @MainActor (String) -> Void = { _ in }
    ) async {
        guard !isBusy else { return }
        isBusy = true
        codexRunner.resetCancellation()
        errorMessage = nil
        defer { isBusy = false }

        do {
            let result = try await executeCodexCommand(arguments: arguments, standardInput: standardInput, timeout: timeout, onChunk: onChunk)
            try afterSuccess(result)
            if infoMessage?.isEmpty != false {
                infoMessage = userFacingAction
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelCodex() {
        codexRunner.cancel()
        infoMessage = "Codex wird abgebrochen..."
    }

    func executeCodexCommand(
        arguments: [String],
        standardInput: String? = nil,
        timeout: TimeInterval = 15 * 60,
        onChunk: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> CodexCommandResult {
        appendConsole("\n$ \(settings.codexPath) \(arguments.joined(separator: " "))\n")
        return try await codexRunner.run(
            executablePath: settings.codexPath,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout,
            onChunk: onChunk
        )
    }

    func copyPromptToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(generatedPrompt, forType: .string)
    }

    private var tipTextFormatter: TipTextFormatter {
        TipTextFormatter(
            bettingOdds: bettingOdds, overUnderOdds: overUnderOdds, bttsOdds: bttsOdds, handicapOdds: handicapOdds,
            matchWeather: matchWeather, llmMatchEnrichments: llmMatchEnrichments, matchExpectedGoals: matchExpectedGoals,
            finishedResults: finishedResults, playerAbsences: playerAbsences
        )
    }

    func copySuggestedTipsAsText() {
        copySuggestedTips(formatter: tipTextFormatter.detailedText, message: "Alle Tippdetails in die Zwischenablage kopiert.")
    }

    func copySuggestedResultsAsText() {
        copySuggestedTips(formatter: tipTextFormatter.resultText, message: "Tipp-Ergebnisse in die Zwischenablage kopiert.")
    }

    private func copySuggestedTips(formatter: (SuggestedTip) -> String, message: String) {
        guard !suggestedTips.isEmpty else {
            errorMessage = "Keine importierten Tipps zum Kopieren vorhanden."
            return
        }

        let text = orderedSuggestedTips
            .map(formatter)
            .joined(separator: "\n\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        infoMessage = message
    }

    func clearConsole() {
        consoleOutput = ""
    }
}
