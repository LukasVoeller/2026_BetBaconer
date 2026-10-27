import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @State var selectedTab: AppTab = .browser
    private let brandGlow = Color(red: 0.86, green: 0.92, blue: 0.21)
    let brandOrange = Color(red: 0.93, green: 0.43, blue: 0.09)
    private let brandEmber = Color(red: 0.74, green: 0.28, blue: 0.07)
    let actionGridColumns = [GridItem(.adaptive(minimum: 132), spacing: 8)]

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            VStack(spacing: 0) {
                statusStrip
                Divider()
                tabBar
                Divider()
                Group {
                    switch selectedTab {
                    case .settings: settingsTab
                    case .browser:  browserTab
                    case .codex:    codexTab
                    case .data:     dataTab
                    case .history:  historyTab
                    case .learning: learningTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1200, minHeight: 800)
        .tint(brandGlow)
        .task {
            await state.initializeKicktipp()
        }
        .task {
            await state.runKickoffRefreshLoop()
        }
        .confirmationDialog(
            "Vorhandene Kicktipp-Tipps ueberschreiben?",
            isPresented: Binding(
                get: { !state.pendingKicktippOverwrites.isEmpty },
                set: { if !$0 { state.pendingKicktippOverwrites = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Ueberschreiben", role: .destructive) {
                Task { await state.applyTipsToKicktipp(confirmOverwrite: true) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(state.pendingKicktippOverwrites.joined(separator: "\n"))
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabBarButton(tab: .browser,  label: "Kicktipp",      icon: "globe")
            tabBarButton(tab: .codex,    label: "Codex",        icon: "terminal")
            tabBarButton(tab: .data,     label: "Bundesliga",   icon: "sportscourt")
            tabBarButton(tab: .history,  label: "Verlauf",      icon: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            tabBarButton(tab: .learning, label: "Learning",     icon: "brain")
            tabBarButton(tab: .settings, label: "Einstellungen", icon: "gearshape")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func tabBarButton(tab: AppTab, label: String, icon: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                selectedTab == tab
                    ? brandOrange.opacity(0.18)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selectedTab == tab ? brandGlow.opacity(0.65) : Color.clear,
                        lineWidth: 1
                    )
            )
            .foregroundStyle(selectedTab == tab ? brandGlow : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sidebar

    // MARK: - Status Strip

    private var statusStrip: some View {
        VStack(spacing: 0) {
            if let error = state.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        state.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
                Divider()
            }
            HStack(spacing: 10) {
                if let info = state.infoMessage {
                    statusPill(text: info, color: .green)
                }
                Spacer()
                statusPill(text: state.codexStatus, color: .blue)
                statusPill(text: state.kicktippStatus, color: .orange)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func statusPill(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(2)
    }

    // MARK: - Tabs

    private var browserTab: some View {
        HStack(alignment: .top, spacing: 16) {
            KicktippWebView(webView: state.kicktippAutomation.webView)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
            browserSidePanel
        }
        .padding(16)
    }

    private var deviceAuthPanel: some View {
        card(title: "Device Login", icon: "person.badge.key") {
            VStack(alignment: .leading, spacing: 12) {
                if !state.codexDeviceAuthURL.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("URL").font(.caption).foregroundStyle(.secondary)
                        Text(state.codexDeviceAuthURL)
                            .textSelection(.enabled)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                    }
                }
                if !state.codexDeviceCode.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Code").font(.caption).foregroundStyle(.secondary)
                        Text(state.codexDeviceCode)
                            .textSelection(.enabled)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                    }
                }
                Button("URL im Browser öffnen") { state.openCodexDeviceAuthURL() }
                    .buttonStyle(.bordered)
                    .disabled(state.codexDeviceAuthURL.isEmpty)
                Button("Code kopieren") { state.copyCodexDeviceCode() }
                    .buttonStyle(.borderedProminent)
                    .tint(brandOrange)
                    .disabled(state.codexDeviceCode.isEmpty)
            }
        }
    }

    private var codexTab: some View {
        VStack(spacing: 16) {
            if !state.codexDeviceAuthURL.isEmpty || !state.codexDeviceCode.isEmpty {
                deviceAuthPanel
            }
            HStack(alignment: .top, spacing: 16) {
                card(title: "Generierter Prompt", icon: "text.alignleft") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $state.generatedPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxHeight: .infinity)
                            .scrollContentBackground(.hidden)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                        Button("Prompt kopieren") { state.copyPromptToClipboard() }
                            .buttonStyle(.bordered)
                            .disabled(state.generatedPrompt.isEmpty)
                    }
                }
                card(title: "Antwort / Import", icon: "square.and.arrow.down") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $state.importedResponse)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxHeight: .infinity)
                            .scrollContentBackground(.hidden)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                        Button("Tipps importieren") { state.importTipsFromResponse() }
                            .buttonStyle(.borderedProminent)
                            .tint(brandOrange)
                            .disabled(
                                state.importedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || state.upcomingMatches.isEmpty
                            )
                    }
                }
            }
            card(title: "Codex Console", icon: "terminal") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: .constant(state.consoleOutput))
                        .font(.system(.body, design: .monospaced))
                        .frame(maxHeight: .infinity)
                        .scrollContentBackground(.hidden)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                    Button("Console leeren") { state.clearConsole() }
                        .buttonStyle(.bordered)
                        .tint(brandEmber)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var browserSidePanel: some View {
        if !state.suggestedTips.isEmpty {
            card(title: "Importierte Tipps", icon: "lightbulb") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Alles kopieren") {
                            state.copySuggestedTipsAsText()
                        }
                        Button("Ergebnisse kopieren") {
                            state.copySuggestedResultsAsText()
                        }
                    }
                    .buttonStyle(.bordered)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(state.orderedSuggestedTips) { tip in
                                tipRow(tip)
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(width: 320)
        } else if !state.learning.tipHistory.isEmpty {
            card(title: "Verlauf", icon: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(state.latestTipHistory) { record in
                            historyRecordRow(record)
                            Divider()
                        }
                    }
                }
            }
            .frame(width: 320)
        } else {
            card(title: "Verlauf", icon: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                emptyState("Noch keine Generierungen aufgezeichnet.")
            }
            .frame(width: 320)
        }
    }

    // MARK: - Helpers

    func inputGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    func card<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func row(_ eyebrow: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(eyebrow).font(.caption).foregroundStyle(.secondary)
            Text(title).font(.body.weight(.medium))
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }

    func fullWidthButtonLabel(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    func signedPercentage(_ value: Double) -> String {
        String(format: "%+.0f%%", value * 100)
    }

    func emptyState(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

enum AppTab {
    case settings, browser, codex, data, history, learning
}
