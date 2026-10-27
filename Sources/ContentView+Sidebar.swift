import AppKit
import SwiftUI

/// Sidebar cards with the main actions.
extension ContentView {
    var sidebar: some View {
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

    var sidebarHeader: some View {
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

    var kicktippCard: some View {
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

    var workflowCard: some View {
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

    var learningCard: some View {
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

    var codexCard: some View {
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
}
