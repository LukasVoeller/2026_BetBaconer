import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @State private var selectedTab: AppTab = .browser
    private let brandGlow = Color(red: 0.86, green: 0.92, blue: 0.21)
    private let brandOrange = Color(red: 0.93, green: 0.43, blue: 0.09)
    private let brandEmber = Color(red: 0.74, green: 0.28, blue: 0.07)
    private let actionGridColumns = [GridItem(.adaptive(minimum: 132), spacing: 8)]

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

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sidebarHeader
                kicktippCard
                workflowCard
                learningCard
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarHeader: some View {
        VStack(alignment: .center, spacing: 2) {
            if let url = Bundle.module.url(forResource: "logo", withExtension: "png"),
               let logo = NSImage(contentsOf: url) {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 360, height: 360)
                    .padding(.top, -64)
                    .padding(.bottom, -58)
            }
            VStack(alignment: .center, spacing: 2) {
                Text("BetBaconer")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("v0.9.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private var settingsCard: some View {
        card(title: "Einstellungen", icon: "gearshape") {
            VStack(alignment: .leading, spacing: 10) {
                inputGroup(title: "Codex Pfad") {
                    TextField("/opt/homebrew/bin/codex", text: $state.codexPath)
                        .textFieldStyle(.roundedBorder)
                }
                inputGroup(title: "Competition Slug") {
                    TextField("z. B. meine-tipprunde", text: $state.kicktippCompetitionSlug)
                        .textFieldStyle(.roundedBorder)
                }
                inputGroup(title: "The Odds API Key") {
                    SecureField("The Odds API Key", text: $state.theOddsAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                inputGroup(title: "Codex-Laeufe") {
                    Stepper(value: $state.codexRunCount, in: 1...9) {
                        Text("\(state.codexRunCount) Lauf/Laeufe pro Analyse")
                    }
                }
                inputGroup(title: "Kicktipp-Punkteregel der Tipprunde") {
                    Stepper(value: $state.kicktippRules.exactScorePoints, in: 0...10) {
                        Text("Ergebnis: \(Int(state.kicktippRules.exactScorePoints)) Punkte")
                    }
                    Stepper(value: $state.kicktippRules.goalDifferencePoints, in: 0...10) {
                        Text("Tordifferenz: \(Int(state.kicktippRules.goalDifferencePoints)) Punkte")
                    }
                    Stepper(value: $state.kicktippRules.tendencyPoints, in: 0...10) {
                        Text("Tendenz: \(Int(state.kicktippRules.tendencyPoints)) Punkte")
                    }
                    Toggle("Tordifferenz-Punkte auch bei Remis", isOn: $state.kicktippRules.drawCountsAsGoalDifference)
                    if let inferred = state.inferredKicktippRules {
                        let rules = inferred.rules
                        Text(String(format: "Aus %d Mitspieler-Tipps erkannt: %.0f/%.0f/%.0f, Remis-Tordifferenz %@",
                                    inferred.sampleCount, rules.exactScorePoints, rules.goalDifferencePoints, rules.tendencyPoints,
                                    rules.drawCountsAsGoalDifference ? "ja" : "nein"))
                            .font(.caption)
                            .foregroundStyle(rules == state.kicktippRules ? Color.secondary : Color.orange)
                        if rules != state.kicktippRules {
                            Button("Erkannte Regel uebernehmen") { state.adoptInferredKicktippRules() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                inputGroup(title: "Kurz vor Anstoss") {
                    Toggle("Tipps 60 Min. vor Anstoss mit aktuellen Quoten neu berechnen", isOn: $state.autoRefreshBeforeKickoff)
                    Toggle("Geaenderte Tipps automatisch eintragen und absenden", isOn: $state.autoSubmitAfterRefresh)
                        .disabled(!state.autoRefreshBeforeKickoff)
                    Text("Quoten direkt vor Anstoss enthalten Aufstellungen und Kurzfrist-News und sind die genaueste Prognose. Die App muss dafuer geoeffnet sein.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                inputGroup(title: "Ranglisten-Strategie") {
                    TextField("Mein Name in der Tipprunde", text: $state.kicktippPlayerName)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Tipps an Ranglage anpassen", isOn: $state.useRankingStrategy)
                    Text(state.rankingStrategy.map { String(format: "%@ Max. %.2f erwartete Punkte Verzicht je Spiel.", $0.summary, $0.tolerance) }
                         ?? "Kostet bewusst bis zu 0,25 erwartete Punkte je Spiel, um die Siegchance zu erhoehen. Braucht Name und geladene Mitspieler-Tipps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var settingsTab: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                settingsCard
                codexCard
            }
            card(title: "Hinweise", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hier werden die globalen Analyse- und Codex-Einstellungen verwaltet.")
                        .foregroundStyle(.secondary)
                    Text("Aenderungen wirken direkt auf den naechsten Workflow-Lauf.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(16)
    }

    private var codexCard: some View {
        card(title: "Codex", icon: "terminal") {
            LazyVGrid(columns: actionGridColumns, alignment: .leading, spacing: 8) {
                Button {
                    Task {
                        await state.checkCodexLoginStatus()
                        selectedTab = .codex
                    }
                } label: {
                    fullWidthButtonLabel("Status prüfen")
                }
                .buttonStyle(.bordered)
                .disabled(state.isBusy)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task {
                        await state.startCodexLogin()
                        selectedTab = .codex
                    }
                } label: {
                    fullWidthButtonLabel("Mit Codex anmelden")
                }
                .buttonStyle(.borderedProminent)
                .tint(brandOrange)
                .disabled(state.isBusy)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var kicktippCard: some View {
        card(title: "Kicktipp", icon: "soccer.field") {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: actionGridColumns, alignment: .leading, spacing: 8) {
                    Button {
                        state.openKicktippLogin()
                        selectedTab = .browser
                    } label: {
                        fullWidthButtonLabel("Login öffnen")
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        Task {
                            await state.loadKicktippMatchday()
                            selectedTab = .browser
                        }
                    } label: {
                        fullWidthButtonLabel("Tippabgabe laden")
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy)
                    .frame(maxWidth: .infinity, alignment: .leading)

                }

                Divider()

                LazyVGrid(columns: actionGridColumns, alignment: .leading, spacing: 8) {
                    Button {
                        Task {
                            await state.applyTipsToKicktipp()
                            selectedTab = .browser
                        }
                    } label: {
                        fullWidthButtonLabel("Tipps eintragen")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(brandOrange)
                    .disabled(state.suggestedTips.isEmpty || state.kicktippAutomation.isPageLoading || state.isBusy)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        Task {
                            await state.submitKicktippTips()
                            selectedTab = .browser
                        }
                    } label: {
                        fullWidthButtonLabel("Tipps absenden")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(brandOrange)
                    .disabled(state.kicktippMatchFields.isEmpty || state.kicktippAutomation.isPageLoading || state.isBusy)
                    .frame(maxWidth: .infinity, alignment: .leading)

                }

                if state.kicktippAutomation.isPageLoading {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Seite lädt…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var workflowCard: some View {
        card(title: "Bundesliga", icon: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: actionGridColumns, alignment: .leading, spacing: 8) {
                    Button {
                        Task {
                            await state.runWorkflow()
                        }
                    } label: {
                        fullWidthButtonLabel("Tipps generieren")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(brandOrange)
                    .disabled(state.isBusy)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        Task {
                            await state.applySeasonQuestionTipsToKicktipp()
                            selectedTab = .browser
                        }
                    } label: {
                        fullWidthButtonLabel("Saisonfragen eintragen")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(brandOrange)
                    .disabled(state.kicktippAutomation.isPageLoading || state.isBusy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if state.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Läuft...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Codex abbrechen") { state.cancelCodex() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var learningCard: some View {
        card(title: "Self-Learning", icon: "brain.head.profile") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(state.learningState.sampleSize) bewertete Tipps")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: actionGridColumns, alignment: .leading, spacing: 8) {
                    Button {
                        Task {
                            await state.evaluateLearningData()
                            selectedTab = .learning
                        }
                    } label: {
                        fullWidthButtonLabel("Offene Tipps auswerten")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(brandOrange)
                    .disabled(state.isBusy)

                    Button {
                        Task {
                            await state.loadCommunityTips()
                            selectedTab = .learning
                        }
                    } label: {
                        fullWidthButtonLabel("Kicktipp-Historie laden")
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy || state.kicktippCompetitionSlug.isEmpty)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

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

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.tipHistory.isEmpty {
                emptyState("Noch keine Generierungen aufgezeichnet.")
            } else {
                Text("\(state.latestTipHistory.count) Spieltag(e) gespeichert")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(state.latestTipHistory) { record in
                            let orderedTips = state.orderedTips(record.tips)
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Label("\(record.spieltag). Spieltag", systemImage: "calendar")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.regularMaterial)
                                Divider()
                                historyHeaderRow()
                                ForEach(orderedTips) { tip in
                                    let oddsMap = historyOddsMap(for: record)
                                    let actualResult = actualResultText(for: tip, in: record)
                                    HStack(spacing: 0) {
                                        Text("\(tip.heim) vs. \(tip.gast)")
                                            .font(.body)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.leading, 16)
                                        if let o = oddsMap[normalizedTeamKey(tip.heim, tip.gast)] {
                                            Text("\(o.quoteHeim) / \(o.quoteUnentschieden) / \(o.quoteGast)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .monospacedDigit()
                                                .frame(width: 130, alignment: .center)
                                        } else {
                                            Text("keine Quoten")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .frame(width: 130, alignment: .center)
                                        }
                                        Text("\(tip.toreHeim) : \(tip.toreGast)")
                                            .font(.body.weight(.bold))
                                            .monospacedDigit()
                                            .frame(width: 60, alignment: .center)
                                        Text(actualResult)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(actualResult == "-" ? .tertiary : .primary)
                                            .monospacedDigit()
                                            .frame(width: 60, alignment: .center)
                                        if !tip.rationale.isEmpty {
                                            Text(tip.rationale)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.trailing, 16)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        } else if !state.tipHistory.isEmpty {
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

    private var dataTab: some View {
        HStack(alignment: .top, spacing: 16) {
            card(title: "Bisherige Ergebnisse", icon: "checkmark.circle") {
                if state.finishedResults.isEmpty {
                    emptyState("Noch keine Daten geladen.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(state.finishedResults) { r in
                                row("\(r.spieltag). Spieltag", "\(r.heim)  \(r.toreHeim):\(r.toreGast)  \(r.gast)", formattedKickoff(r.datum))
                            }
                        }
                    }
                }
            }
            card(title: "Offene Spiele", icon: "calendar") {
                if state.upcomingMatches.isEmpty {
                    emptyState("Noch keine offenen Spiele geladen.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(state.upcomingMatches) { m in
                                row("\(m.spieltag). Spieltag", "\(m.heim) vs. \(m.gast)", formattedKickoff(m.datum))
                            }
                        }
                    }
                }
            }
            card(title: "Importierte Tipps", icon: "lightbulb") {
                if state.suggestedTips.isEmpty {
                    emptyState("Noch keine Tipps importiert.")
                } else {
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
            }
        }
        .padding(16)
    }

    private var learningTab: some View {
        HStack(alignment: .top, spacing: 16) {
            card(title: "Lernstatus", icon: "chart.bar") {
                VStack(alignment: .leading, spacing: 10) {
                    metricRow("Bewertete Tipps", "\(state.learningState.sampleSize)")
                    metricRow("Trefferquote Tendenz", percentage(state.learningState.tendencyHitRate))
                    metricRow("Trefferquote exakt", percentage(state.learningState.exactHitRate))
                    metricRow("Trefferquote Tordiff.", percentage(state.learningState.goalDiffHitRate))
                    metricRow("Ø Torabweichung", String(format: "%.2f", state.learningState.averageTotalAbsGoalError))
                    metricRow("Heim-Bias", signedPercentage(state.learningState.homeBias))
                    metricRow("Remis-Bias", signedPercentage(state.learningState.drawBias))
                    metricRow("Auswaerts-Bias", signedPercentage(state.learningState.awayBias))
                }
            }
            card(title: "Learning Summary", icon: "text.quote") {
                if state.learningState.correctionSummaryText.isEmpty {
                    emptyState("Noch keine bewerteten Vorhersagen vorhanden.")
                } else {
                    ScrollView {
                        Text(state.learningState.correctionSummaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            card(title: "Modell-Backtest", icon: "chart.line.uptrend.xyaxis") {
                VStack(alignment: .leading, spacing: 8) {
                    metricRow("Marktgewicht", String(format: "%.0f%%", state.learnedMarketWeight * 100))
                    metricRow("Archivierte Quoten", "\(state.oddsArchive.count)")
                    HStack {
                        Button("Backtest ausfuehren") {
                            Task { await state.runModelBacktest() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(brandOrange)
                        Button("Quoten-CSV importieren") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.commaSeparatedText]
                            panel.allowsMultipleSelection = true
                            panel.message = "football-data.co.uk D1.csv-Dateien auswaehlen"
                            if panel.runModal() == .OK {
                                let urls = panel.urls
                                Task { await state.importHistoricalOdds(from: urls) }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(state.isBusy)
                    if state.backtestReport.isEmpty {
                        emptyState("Prueft das Modell Spieltag fuer Spieltag an den letzten Saisons und lernt das Marktgewicht aus dem Quoten-Archiv.")
                    } else {
                        ScrollView {
                            Text(state.backtestReport)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            card(title: "App vs. Tipprunde", icon: "person.3") {
                if state.communityBacktest.isEmpty {
                    emptyState("Noch keine Mitspieler-Tipps zu Spieltagen mit App-Tipps geladen.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(state.communityBacktest) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(row.spieltag). Spieltag: \(row.appPoints) Punkte")
                                        .font(.subheadline.weight(.semibold))
                                    Text(String(format: "Rang %d/%d | Runde Ø %.1f | Bester %d", row.appRank, row.playerCount, row.groupAverage, row.groupBest))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        }
                    }
                }
            }
            card(title: "Bewertete Spieltage", icon: "list.bullet.rectangle") {
                if state.evaluatedMatchdayRuns.isEmpty {
                    emptyState("Noch keine Spieltage bewertet.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(state.evaluatedMatchdayRuns) { run in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(run.spieltag). Spieltag")
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(run.matches.filter(\.isEvaluated).count)/\(run.matches.count) bewertet")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func inputGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func card<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ eyebrow: String, _ title: String, _ detail: String) -> some View {
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

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }

    private func fullWidthButtonLabel(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private func signedPercentage(_ value: Double) -> String {
        String(format: "%+.0f%%", value * 100)
    }

    private func tipRow(_ tip: SuggestedTip) -> some View {
        // Lookups
        let odds    = state.bettingOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let ou      = state.overUnderOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let btts    = state.bttsOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let hcp     = state.handicapOdds.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let weather = state.matchWeather.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let enrichment = state.llmMatchEnrichments.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let expectedGoals = state.matchExpectedGoals.first { teamNamesLikelyMatch($0.heim, tip.heim) && teamNamesLikelyMatch($0.gast, tip.gast) }
        let modelPrediction = state.latestEnsemblePrediction(for: tip)
        let h2h     = state.finishedResults
            .filter { ($0.heim == tip.heim && $0.gast == tip.gast) || ($0.heim == tip.gast && $0.gast == tip.heim) }
            .sorted { ($0.spieltag, $0.datum) > ($1.spieltag, $1.datum) }
            .prefix(5)
        let absences   = state.playerAbsences.filter { teamNamesLikelyMatch($0.teamName, tip.heim) || teamNamesLikelyMatch($0.teamName, tip.gast) }
        let heimAbsences = absences.filter { teamNamesLikelyMatch($0.teamName, tip.heim) }
        let gastAbsences = absences.filter { teamNamesLikelyMatch($0.teamName, tip.gast) }

        // Vorausberechnungen die @ViewBuilder-Probleme vermeiden
        let tormarktEntry: (label: String, value: String)? = {
            if let ou {
                var s = "O/U \(String(format: "%.1f", ou.line)): Over \(ou.overQuote) / Under \(ou.underQuote)"
                if let btts { s += "  |  BTTS Ja \(btts.yesQuote) / Nein \(btts.noQuote)" }
                return ("Tormarkt", s)
            } else if let btts {
                return ("BTTS", "Ja \(btts.yesQuote) / Nein \(btts.noQuote)")
            }
            return nil
        }()
        let h2hText: String? = h2h.isEmpty ? nil :
            h2h.map { "\($0.heim) \($0.toreHeim):\($0.toreGast) \($0.gast)" }.joined(separator: "  |  ")
        let hasMarketFactors = odds != nil || tormarktEntry != nil || hcp != nil
        let hasContextFactors = weather != nil || h2hText != nil
        let enrichmentRows: [(String, String)] = enrichment.map { e in
            [
                ("Spielerimpact", e.playerImpact),
                ("Spielerwert", e.playerValue),
                ("Schiri/Spielstil", e.refereeStats),
                ("Sharp-Odds", e.sharpOdds),
                ("Closing/CLV", e.closingLine),
                ("Lineup-News", e.lineup),
                ("Lineup-Struktur", e.structuredLineup),
                ("Historische Basis", e.historicalBaseline),
                ("Scoreline-Kalib.", e.scorelineCalibration),
                ("Gewichtung", e.learnedWeightHint),
                ("Datenqualitaet", "\(e.dataQuality) | Confidence \(String(format: "%.0f%%", e.confidence * 100))"),
                ("xG-Anpassung", String(format: "Angriff H %+.0f%% / A %+.0f%% | Defensive H %+.0f%% / A %+.0f%% | Total %+.2f | Lineup %+.0f%% | Spielerwert %+.0f%% | Sharp %+.0f%% | CLV %+.0f%% | Remis %+.0f%%",
                                         e.homeAttackAdjustment * 100,
                                         e.awayAttackAdjustment * 100,
                                         e.homeDefenseAdjustment * 100,
                                         e.awayDefenseAdjustment * 100,
                                         e.totalGoalsAdjustment,
                                         e.lineupImpact * 100,
                                         e.playerValueImpact * 100,
                                         e.sharpMarketDelta * 100,
                                         e.closingLineValue * 100,
                                         e.scorelineDrawCalibration * 100))
            ]
        } ?? []

        return VStack(alignment: .leading, spacing: 4) {
            // Header
            Text("\(tip.heim) vs. \(tip.gast)")
                .font(.system(size: 15, weight: .semibold))
            Text("\(tip.toreHeim) : \(tip.toreGast)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            if !tip.rationale.isEmpty {
                Text(tip.rationale)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            factorSection("Modell") {
                if let expectedGoals {
                    tipMetricRow("xG", String(format: "%@ %.2f | %@ %.2f", tip.heim, expectedGoals.home, tip.gast, expectedGoals.away))
                }
                if let modelPrediction,
                   let home = modelPrediction.probabilityHomeWin,
                   let draw = modelPrediction.probabilityDraw,
                   let away = modelPrediction.probabilityAwayWin {
                    tipMetricRow("Wahrscheinlichkeiten", String(format: "1 %.0f%% | X %.0f%% | 2 %.0f%%", home * 100, draw * 100, away * 100))
                }
                if let confidence = modelPrediction?.confidence {
                    tipMetricRow("Modell-Sicherheit", String(format: "%.0f/100 (heuristisch)", confidence * 100))
                }
                if let topScorelines = modelPrediction?.topScorelines, !topScorelines.isEmpty {
                    tipMetricRow(
                        "Top-3",
                        topScorelines.map { String(format: "%d:%d %.0f%%", $0.homeGoals, $0.awayGoals, $0.probability * 100) }.joined(separator: "  |  ")
                    )
                }
                tipMetricRow("Finale Auswahl", "Maximale erwartete Kicktipp-Punkte (Punkteregel aus den Einstellungen) aus der Poisson-Scoreline-Matrix")
            }

            if hasMarketFactors {
                factorSection("Markt") {
                    if let o = odds {
                        tipMetricRow("Quoten", "1: \(o.quoteHeim)  X: \(o.quoteUnentschieden)  2: \(o.quoteGast)")
                    }
                    if let tormarktEntry {
                        tipMetricRow(tormarktEntry.label, tormarktEntry.value)
                    }
                    if let hcp {
                        let hSign = hcp.homeHandicap >= 0 ? "+" : ""
                        let aSign = hcp.awayHandicap >= 0 ? "+" : ""
                        tipMetricRow("Handicap", "\(tip.heim) (\(hSign)\(hcp.homeHandicap)) \(hcp.homeQuote)  /  \(tip.gast) (\(aSign)\(hcp.awayHandicap)) \(hcp.awayQuote)")
                    }
                }
            }

            if hasContextFactors {
                factorSection("Kontext") {
                    if let weather {
                        tipMetricRow("Wetter", tipWeatherText(weather))
                    }
                    if let h2hText {
                        tipMetricRow("H2H", h2hText)
                    }
                }
            }

            if !enrichmentRows.isEmpty {
                factorSection("LLM-Zusatzrecherche") {
                    ForEach(enrichmentRows, id: \.0) { row in
                        tipMetricRow(row.0, row.1)
                    }
                }
            }

            // Ausfälle
            if !heimAbsences.isEmpty || !gastAbsences.isEmpty {
                factorSection("Ausfaelle") {
                    if !heimAbsences.isEmpty { absenceGroup(team: tip.heim, absences: heimAbsences) }
                    if !gastAbsences.isEmpty { absenceGroup(team: tip.gast, absences: gastAbsences) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func factorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 3) {
                content()
            }
        }
        .padding(.top, 8)
    }

    private func tipMetricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tipWeatherText(_ w: MatchWeather) -> String {
        var parts: [String] = []
        if let t = w.temperatureCelsius { parts.append(String(format: "%.0f°C", t)) }
        if let mm = w.precipitationMillimeters, mm > 0.5 { parts.append(String(format: "%.1f mm", mm)) }
        if let prob = w.precipitationProbability, prob > 10 { parts.append("Regen \(prob)%") }
        if let wind = w.windSpeedKmh, wind > 20 { parts.append(String(format: "Wind %.0f km/h", wind)) }
        let detail = parts.isEmpty ? "keine Besonderheiten" : parts.joined(separator: ", ")
        return "\(w.locationName) – \(detail)"
    }

    private func absenceGroup(team: String, absences: [PlayerAbsence]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(team)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(absences) { absence in
                HStack(spacing: 4) {
                    Text(absenceEmoji(for: absence.type))
                        .font(.system(size: 11))
                    Text("\(absence.playerName)\(absence.reason.isEmpty ? "" : " – \(absence.reason)")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func historyRecordRow(_ record: TipGenerationRecord) -> some View {
        let oddsMap = historyOddsMap(for: record)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(record.spieltag). Spieltag – \(record.timestamp.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(state.orderedTips(record.tips)) { tip in
                let actualResult = actualResultText(for: tip, in: record)
                HStack {
                    Text("\(tip.heim) vs. \(tip.gast)")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    if let o = oddsMap[normalizedTeamKey(tip.heim, tip.gast)] {
                        Text("\(o.quoteHeim) / \(o.quoteUnentschieden) / \(o.quoteGast)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("keine Quoten")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(tip.toreHeim):\(tip.toreGast)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                    Text(actualResult)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(actualResult == "-" ? .tertiary : .primary)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func historyHeaderRow() -> some View {
        HStack(spacing: 0) {
            Text("")
                .frame(maxWidth: .infinity)
                .padding(.leading, 16)
            Text("")
                .frame(width: 130)
            Text("Soll")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .center)
            Text("Ist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .center)
            Text("")
                .frame(maxWidth: .infinity)
                .padding(.trailing, 16)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func actualResultText(for tip: SuggestedTip, in record: TipGenerationRecord) -> String {
        let recordSeason = String(AppState.currentBundesligaSeason(for: record.timestamp))
        if let prediction = state.predictionRuns
            .reversed()
            .first(where: { run in
                run.seasonIdentifier == recordSeason
                && run.spieltag == tip.spieltag
                && run.matches.contains { prediction in
                    normalizedTeamKey(prediction.heim, prediction.gast) == normalizedTeamKey(tip.heim, tip.gast)
                    && prediction.actualHomeGoals != nil
                    && prediction.actualAwayGoals != nil
                }
            })?
            .matches
            .first(where: { prediction in
                normalizedTeamKey(prediction.heim, prediction.gast) == normalizedTeamKey(tip.heim, tip.gast)
                && prediction.actualHomeGoals != nil
                && prediction.actualAwayGoals != nil
            }),
           let homeGoals = prediction.actualHomeGoals,
           let awayGoals = prediction.actualAwayGoals {
            return "\(homeGoals):\(awayGoals)"
        }

        guard state.season.trimmingCharacters(in: .whitespacesAndNewlines) == recordSeason else { return "-" }
        if let result = state.finishedResults.first(where: {
            $0.spieltag == tip.spieltag
            && normalizedTeamKey($0.heim, $0.gast) == normalizedTeamKey(tip.heim, tip.gast)
        }) {
            return "\(result.toreHeim):\(result.toreGast)"
        }

        return "-"
    }

    private func historyOddsMap(for record: TipGenerationRecord) -> [String: BettingOdds] {
        Dictionary(record.odds.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

enum AppTab {
    case settings, browser, codex, data, history, learning
}
