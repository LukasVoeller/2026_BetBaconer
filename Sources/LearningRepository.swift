import Foundation
import Observation

/// Owns everything the app learns from: tip history, prediction runs, learning state, the group history
/// and the odds archive. Loads them once, saves on every change and never overwrites an unreadable file.
@MainActor
@Observable
final class LearningRepository {
    @ObservationIgnored private let predictionStore: PredictionStore
    @ObservationIgnored private let tipHistoryStore: TipHistoryStore
    /// Receives save failures (written to the console by AppState).
    @ObservationIgnored var onSaveError: (String) -> Void = { _ in }
    /// Load failures during init, shown as error banner.
    private(set) var loadErrors: [String] = []
    /// Set when a store could not be loaded nor backed up; saving would destroy the unreadable file.
    private var tipHistoryPersistenceDisabled = false
    private var learningPersistenceDisabled = false
    /// Suppresses saving while the initial load assigns the properties.
    private var isLoading = true

    var tipHistory: [TipGenerationRecord] = [] {
        didSet { saveTipHistory() }
    }
    var predictionRuns: [PredictionRun] = [] {
        didSet { saveLearningStore() }
    }
    var learningState: LearningState = .empty {
        didSet { saveLearningStore() }
    }
    /// Every odds snapshot the app has seen (latest per match), the basis for learning the market weight.
    var oddsArchive: [ArchivedOdds] = [] {
        didSet { saveLearningStore() }
    }
    /// Fellow players' tips of finished matchdays, read from the Kicktipp tip overview.
    var communityMatchdays: [CommunityMatchday] = [] {
        didSet { saveLearningStore() }
    }

    init(predictionStore: PredictionStore, tipHistoryStore: TipHistoryStore) {
        self.predictionStore = predictionStore
        self.tipHistoryStore = tipHistoryStore

        do {
            tipHistory = try tipHistoryStore.load()
        } catch {
            loadErrors.append(error.localizedDescription)
            if case .failedToLoad(backup: nil)? = error as? TipHistoryStoreError {
                tipHistoryPersistenceDisabled = true
            }
        }

        do {
            let loaded = try predictionStore.load()
            predictionRuns = loaded.runs
            learningState = loaded.learningState
            communityMatchdays = loaded.community
            oddsArchive = loaded.oddsArchive
        } catch {
            loadErrors.append(error.localizedDescription)
            if case .failedToLoad(backup: nil)? = error as? PredictionStoreError {
                learningPersistenceDisabled = true
            }
        }
        isLoading = false
    }

    private func saveLearningStore() {
        guard !isLoading, !learningPersistenceDisabled else { return }
        do {
            try predictionStore.save(runs: predictionRuns, learningState: learningState, community: communityMatchdays, oddsArchive: oddsArchive)
        } catch {
            onSaveError("[Learning] Persistenz fehlgeschlagen: \(error.localizedDescription)\n")
        }
    }

    private func saveTipHistory() {
        guard !isLoading, !tipHistoryPersistenceDisabled else { return }
        do {
            try tipHistoryStore.save(tipHistory)
        } catch {
            onSaveError("[Verlauf] Persistenz fehlgeschlagen: \(error.localizedDescription)\n")
        }
    }
}
