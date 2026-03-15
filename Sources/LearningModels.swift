import Foundation

public enum MatchOutcome: String, Codable {
    case homeWin
    case draw
    case awayWin

    var displayLabel: String {
        switch self {
        case .homeWin: return "1"
        case .draw: return "X"
        case .awayWin: return "2"
        }
    }
}

public struct PredictionRun: Codable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let spieltag: Int
    public let modelName: String
    public let promptVersion: String
    public let rawPrompt: String
    public let rawResponse: String
    public let seasonIdentifier: String
    public var matches: [MatchPrediction]
}

public struct MatchPrediction: Codable, Identifiable, Hashable {
    public let id: UUID
    public let runId: UUID
    public let spieltag: Int
    public let heim: String
    public let gast: String
    public let kickoffAt: String
    public let predictedHomeGoals: Int
    public let predictedAwayGoals: Int
    public let predictedOutcome: MatchOutcome
    public let rationale: String

    public let quoteHome: Double?
    public let quoteDraw: Double?
    public let quoteAway: Double?
    public let homeFormLast5: String?
    public let awayFormLast5: String?
    public let homeGoalsPerGame: Double?
    public let awayGoalsPerGame: Double?
    public let homeConcededPerGame: Double?
    public let awayConcededPerGame: Double?
    public let injuriesHomeCount: Int?
    public let injuriesAwayCount: Int?
    public let keyAbsenceHome: String?
    public let keyAbsenceAway: String?
    public let consistencySignalSummary: String?

    public var actualHomeGoals: Int?
    public var actualAwayGoals: Int?
    public var actualOutcome: MatchOutcome?
    public var exactHit: Bool?
    public var tendencyHit: Bool?
    public var goalDiffHit: Bool?
    public var absErrorHomeGoals: Int?
    public var absErrorAwayGoals: Int?
    public var totalAbsGoalError: Int?
    public var evaluatedAt: Date?

    public init(
        id: UUID,
        runId: UUID,
        spieltag: Int,
        heim: String,
        gast: String,
        kickoffAt: String,
        predictedHomeGoals: Int,
        predictedAwayGoals: Int,
        predictedOutcome: MatchOutcome,
        rationale: String,
        quoteHome: Double?,
        quoteDraw: Double?,
        quoteAway: Double?,
        homeFormLast5: String?,
        awayFormLast5: String?,
        homeGoalsPerGame: Double?,
        awayGoalsPerGame: Double?,
        homeConcededPerGame: Double?,
        awayConcededPerGame: Double?,
        injuriesHomeCount: Int?,
        injuriesAwayCount: Int?,
        keyAbsenceHome: String?,
        keyAbsenceAway: String?,
        consistencySignalSummary: String?,
        actualHomeGoals: Int?,
        actualAwayGoals: Int?,
        actualOutcome: MatchOutcome?,
        exactHit: Bool?,
        tendencyHit: Bool?,
        goalDiffHit: Bool?,
        absErrorHomeGoals: Int?,
        absErrorAwayGoals: Int?,
        totalAbsGoalError: Int?,
        evaluatedAt: Date?
    ) {
        self.id = id
        self.runId = runId
        self.spieltag = spieltag
        self.heim = heim
        self.gast = gast
        self.kickoffAt = kickoffAt
        self.predictedHomeGoals = predictedHomeGoals
        self.predictedAwayGoals = predictedAwayGoals
        self.predictedOutcome = predictedOutcome
        self.rationale = rationale
        self.quoteHome = quoteHome
        self.quoteDraw = quoteDraw
        self.quoteAway = quoteAway
        self.homeFormLast5 = homeFormLast5
        self.awayFormLast5 = awayFormLast5
        self.homeGoalsPerGame = homeGoalsPerGame
        self.awayGoalsPerGame = awayGoalsPerGame
        self.homeConcededPerGame = homeConcededPerGame
        self.awayConcededPerGame = awayConcededPerGame
        self.injuriesHomeCount = injuriesHomeCount
        self.injuriesAwayCount = injuriesAwayCount
        self.keyAbsenceHome = keyAbsenceHome
        self.keyAbsenceAway = keyAbsenceAway
        self.consistencySignalSummary = consistencySignalSummary
        self.actualHomeGoals = actualHomeGoals
        self.actualAwayGoals = actualAwayGoals
        self.actualOutcome = actualOutcome
        self.exactHit = exactHit
        self.tendencyHit = tendencyHit
        self.goalDiffHit = goalDiffHit
        self.absErrorHomeGoals = absErrorHomeGoals
        self.absErrorAwayGoals = absErrorAwayGoals
        self.totalAbsGoalError = totalAbsGoalError
        self.evaluatedAt = evaluatedAt
    }

    var isEvaluated: Bool {
        actualHomeGoals != nil && actualAwayGoals != nil && evaluatedAt != nil
    }
}

public struct LearningState: Codable, Identifiable, Sendable {
    public let id: UUID
    public var updatedAt: Date
    public var sampleSize: Int
    public var homeBias: Double
    public var drawBias: Double
    public var awayBias: Double
    public var avgHomeGoalOverprediction: Double
    public var avgAwayGoalOverprediction: Double
    public var marketAlignmentScore: Double
    public var highScoreOverpredictionBias: Double
    public var correctionSummaryText: String
    public var weightsJSON: String
    public var tendencyHitRate: Double
    public var exactHitRate: Double
    public var goalDiffHitRate: Double
    public var averageTotalAbsGoalError: Double
    public var predictedHomeWinRate: Double
    public var predictedDrawRate: Double
    public var predictedAwayWinRate: Double
    public var actualHomeWinRate: Double
    public var actualDrawRate: Double
    public var actualAwayWinRate: Double

    public static let empty = LearningState(
        id: UUID(),
        updatedAt: .distantPast,
        sampleSize: 0,
        homeBias: 0,
        drawBias: 0,
        awayBias: 0,
        avgHomeGoalOverprediction: 0,
        avgAwayGoalOverprediction: 0,
        marketAlignmentScore: 0,
        highScoreOverpredictionBias: 0,
        correctionSummaryText: "",
        weightsJSON: "{}",
        tendencyHitRate: 0,
        exactHitRate: 0,
        goalDiffHitRate: 0,
        averageTotalAbsGoalError: 0,
        predictedHomeWinRate: 0,
        predictedDrawRate: 0,
        predictedAwayWinRate: 0,
        actualHomeWinRate: 0,
        actualDrawRate: 0,
        actualAwayWinRate: 0
    )

    public init(
        id: UUID,
        updatedAt: Date,
        sampleSize: Int,
        homeBias: Double,
        drawBias: Double,
        awayBias: Double,
        avgHomeGoalOverprediction: Double,
        avgAwayGoalOverprediction: Double,
        marketAlignmentScore: Double,
        highScoreOverpredictionBias: Double,
        correctionSummaryText: String,
        weightsJSON: String,
        tendencyHitRate: Double,
        exactHitRate: Double,
        goalDiffHitRate: Double,
        averageTotalAbsGoalError: Double,
        predictedHomeWinRate: Double,
        predictedDrawRate: Double,
        predictedAwayWinRate: Double,
        actualHomeWinRate: Double,
        actualDrawRate: Double,
        actualAwayWinRate: Double
    ) {
        self.id = id
        self.updatedAt = updatedAt
        self.sampleSize = sampleSize
        self.homeBias = homeBias
        self.drawBias = drawBias
        self.awayBias = awayBias
        self.avgHomeGoalOverprediction = avgHomeGoalOverprediction
        self.avgAwayGoalOverprediction = avgAwayGoalOverprediction
        self.marketAlignmentScore = marketAlignmentScore
        self.highScoreOverpredictionBias = highScoreOverpredictionBias
        self.correctionSummaryText = correctionSummaryText
        self.weightsJSON = weightsJSON
        self.tendencyHitRate = tendencyHitRate
        self.exactHitRate = exactHitRate
        self.goalDiffHitRate = goalDiffHitRate
        self.averageTotalAbsGoalError = averageTotalAbsGoalError
        self.predictedHomeWinRate = predictedHomeWinRate
        self.predictedDrawRate = predictedDrawRate
        self.predictedAwayWinRate = predictedAwayWinRate
        self.actualHomeWinRate = actualHomeWinRate
        self.actualDrawRate = actualDrawRate
        self.actualAwayWinRate = actualAwayWinRate
    }

    public func promptSummary(minSampleSize: Int) -> String? {
        guard sampleSize >= minSampleSize, !correctionSummaryText.isEmpty else { return nil }
        return """


Selbstlernende Korrekturen aus bisherigen Vorhersagen:
\(correctionSummaryText)
Korrigiere diese Verzerrungen in der aktuellen Analyse.
"""
    }
}

public struct LearningCorrectionWeights: Codable {
    var drawBoost: Double
    var homeGoalReductionBias: Double
    var highScoreDampening: Double
}

public struct PredictionEvaluationSummary {
    public let evaluatedMatches: Int
    public let updatedRuns: Int
    public let runs: [PredictionRun]
    public let learningState: LearningState
}

struct PredictionMatchContext {
    let upcomingMatch: UpcomingMatch
    let quoteHome: Double?
    let quoteDraw: Double?
    let quoteAway: Double?
    let homeFormLast5: String
    let awayFormLast5: String
    let homeGoalsPerGame: Double
    let awayGoalsPerGame: Double
    let homeConcededPerGame: Double
    let awayConcededPerGame: Double
    let injuriesHomeCount: Int
    let injuriesAwayCount: Int
    let keyAbsenceHome: String?
    let keyAbsenceAway: String?
    let consistencySignalSummary: String?
}
