import Foundation

public struct FinishedMatch: Codable, Identifiable, Hashable {
    public let spieltag: Int
    public let datum: String
    public let heim: String
    public let gast: String
    public let toreHeim: Int
    public let toreGast: Int

    public init(spieltag: Int, datum: String, heim: String, gast: String, toreHeim: Int, toreGast: Int) {
        self.spieltag = spieltag
        self.datum = datum
        self.heim = heim
        self.gast = gast
        self.toreHeim = toreHeim
        self.toreGast = toreGast
    }

    public var id: String { "\(spieltag)-\(datum)-\(heim)-\(gast)" }
}

struct UpcomingMatch: Codable, Identifiable, Hashable {
    let spieltag: Int
    let datum: String
    let heim: String
    let gast: String

    var id: String { "\(spieltag)-\(datum)-\(heim)-\(gast)" }
}

public struct SuggestedTip: Codable, Identifiable, Hashable {
    public let spieltag: Int
    public let heim: String
    public let gast: String
    public let toreHeim: Int
    public let toreGast: Int
    public let rationale: String

    public init(spieltag: Int, heim: String, gast: String, toreHeim: Int, toreGast: Int, rationale: String) {
        self.spieltag = spieltag
        self.heim = heim
        self.gast = gast
        self.toreHeim = toreHeim
        self.toreGast = toreGast
        self.rationale = rationale
    }

    public var id: String { "\(spieltag)-\(heim)-\(gast)" }
}

struct SeasonQuestionTip: Codable, Identifiable, Hashable {
    let question: String
    let answers: [String]

    var id: String { question }
}

public struct BettingOdds: Codable, Identifiable, Hashable {
    public let heim: String
    public let gast: String
    public let quoteHeim: String
    public let quoteUnentschieden: String
    public let quoteGast: String

    public init(heim: String, gast: String, quoteHeim: String, quoteUnentschieden: String, quoteGast: String) {
        self.heim = heim
        self.gast = gast
        self.quoteHeim = quoteHeim
        self.quoteUnentschieden = quoteUnentschieden
        self.quoteGast = quoteGast
    }

    public var id: String { "\(heim)-\(gast)" }
}

struct TeamMetadata: Codable, Identifiable, Hashable {
    let teamName: String
    let teamShortName: String
    let stadiumName: String
    let stadiumLocation: String
    let country: String

    var id: String { teamName }
}

struct MatchWeather: Codable, Identifiable, Hashable {
    let heim: String
    let gast: String
    let locationName: String
    let kickoff: String
    let temperatureCelsius: Double?
    let precipitationMillimeters: Double?
    let precipitationProbability: Int?
    let windSpeedKmh: Double?
    let weatherCode: Int?

    var id: String { "\(heim)-\(gast)-\(kickoff)" }
}

struct KicktippMatchField: Codable, Identifiable, Hashable {
    let heim: String
    let gast: String
    let heimField: String
    let gastField: String
    let existingHeim: String
    let existingGast: String

    var id: String { "\(heim)-\(gast)-\(heimField)-\(gastField)" }
}

struct OverUnderOdds: Codable, Identifiable, Hashable {
    let heim: String
    let gast: String
    let line: Double          // typisch 2.5
    let overQuote: String
    let underQuote: String
    var id: String { "\(heim)-\(gast)" }
}

struct BTTSOdds: Codable, Identifiable, Hashable {
    let heim: String
    let gast: String
    let yesQuote: String
    let noQuote: String
    var id: String { "\(heim)-\(gast)" }
}

struct HandicapOdds: Codable, Identifiable, Hashable {
    let heim: String
    let gast: String
    let homeHandicap: Double  // z. B. -0.5
    let homeQuote: String
    let awayHandicap: Double  // z. B. +0.5
    let awayQuote: String
    var id: String { "\(heim)-\(gast)" }
}

struct MatchExpectedGoals: Hashable {
    let heim: String
    let gast: String
    let home: Double
    let away: Double
    let drawCalibration: Double
    let marketWeightHint: Double

    init(heim: String, gast: String, home: Double, away: Double, drawCalibration: Double = 0, marketWeightHint: Double = 0) {
        self.heim = heim
        self.gast = gast
        self.home = home
        self.away = away
        self.drawCalibration = drawCalibration
        self.marketWeightHint = marketWeightHint
    }
}

struct LLMMatchEnrichment: Codable, Identifiable, Hashable {
    let heim: String
    let gast: String
    let playerImpact: String
    let refereeStats: String
    let sharpOdds: String
    let lineup: String
    let dataQuality: String
    let structuredLineup: String
    let playerValue: String
    let closingLine: String
    let historicalBaseline: String
    let scorelineCalibration: String
    let learnedWeightHint: String
    let homeAttackAdjustment: Double
    let awayAttackAdjustment: Double
    let homeDefenseAdjustment: Double
    let awayDefenseAdjustment: Double
    let totalGoalsAdjustment: Double
    let lineupImpact: Double
    let playerValueImpact: Double
    let sharpMarketDelta: Double
    let closingLineValue: Double
    let historicalGoalBaseline: Double
    let scorelineDrawCalibration: Double
    let marketWeightHint: Double
    let confidence: Double
    let sources: [String]

    var id: String { "\(heim)-\(gast)" }

    init(
        heim: String,
        gast: String,
        playerImpact: String,
        refereeStats: String,
        sharpOdds: String,
        lineup: String,
        dataQuality: String,
        structuredLineup: String = "keine belastbaren Zusatzdaten",
        playerValue: String = "keine belastbaren Zusatzdaten",
        closingLine: String = "keine belastbaren Zusatzdaten",
        historicalBaseline: String = "keine belastbaren Zusatzdaten",
        scorelineCalibration: String = "keine belastbaren Zusatzdaten",
        learnedWeightHint: String = "keine belastbaren Zusatzdaten",
        homeAttackAdjustment: Double,
        awayAttackAdjustment: Double,
        homeDefenseAdjustment: Double,
        awayDefenseAdjustment: Double,
        totalGoalsAdjustment: Double,
        lineupImpact: Double = 0,
        playerValueImpact: Double = 0,
        sharpMarketDelta: Double = 0,
        closingLineValue: Double = 0,
        historicalGoalBaseline: Double = 0,
        scorelineDrawCalibration: Double = 0,
        marketWeightHint: Double = 0,
        confidence: Double,
        sources: [String]
    ) {
        self.heim = heim
        self.gast = gast
        self.playerImpact = playerImpact
        self.refereeStats = refereeStats
        self.sharpOdds = sharpOdds
        self.lineup = lineup
        self.dataQuality = dataQuality
        self.structuredLineup = structuredLineup
        self.playerValue = playerValue
        self.closingLine = closingLine
        self.historicalBaseline = historicalBaseline
        self.scorelineCalibration = scorelineCalibration
        self.learnedWeightHint = learnedWeightHint
        self.homeAttackAdjustment = homeAttackAdjustment
        self.awayAttackAdjustment = awayAttackAdjustment
        self.homeDefenseAdjustment = homeDefenseAdjustment
        self.awayDefenseAdjustment = awayDefenseAdjustment
        self.totalGoalsAdjustment = totalGoalsAdjustment
        self.lineupImpact = lineupImpact
        self.playerValueImpact = playerValueImpact
        self.sharpMarketDelta = sharpMarketDelta
        self.closingLineValue = closingLineValue
        self.historicalGoalBaseline = historicalGoalBaseline
        self.scorelineDrawCalibration = scorelineDrawCalibration
        self.marketWeightHint = marketWeightHint
        self.confidence = confidence
        self.sources = sources
    }

    private enum CodingKeys: String, CodingKey {
        case heim, gast, sources
        case playerImpact = "player_impact"
        case refereeStats = "referee_stats"
        case sharpOdds = "sharp_odds"
        case lineup
        case dataQuality = "data_quality"
        case structuredLineup = "structured_lineup"
        case playerValue = "player_value"
        case closingLine = "closing_line"
        case historicalBaseline = "historical_baseline"
        case scorelineCalibration = "scoreline_calibration"
        case learnedWeightHint = "learned_weight_hint"
        case homeAttackAdjustment = "home_attack_adjustment"
        case awayAttackAdjustment = "away_attack_adjustment"
        case homeDefenseAdjustment = "home_defense_adjustment"
        case awayDefenseAdjustment = "away_defense_adjustment"
        case totalGoalsAdjustment = "total_goals_adjustment"
        case lineupImpact = "lineup_impact"
        case playerValueImpact = "player_value_impact"
        case sharpMarketDelta = "sharp_market_delta"
        case closingLineValue = "closing_line_value"
        case historicalGoalBaseline = "historical_goal_baseline"
        case scorelineDrawCalibration = "scoreline_draw_calibration"
        case marketWeightHint = "market_weight_hint"
        case confidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            heim: try c.decode(String.self, forKey: .heim),
            gast: try c.decode(String.self, forKey: .gast),
            playerImpact: (try? c.decode(String.self, forKey: .playerImpact)) ?? "keine belastbaren Zusatzdaten",
            refereeStats: (try? c.decode(String.self, forKey: .refereeStats)) ?? "keine belastbaren Zusatzdaten",
            sharpOdds: (try? c.decode(String.self, forKey: .sharpOdds)) ?? "keine belastbaren Zusatzdaten",
            lineup: (try? c.decode(String.self, forKey: .lineup)) ?? "keine bestaetigten Lineups",
            dataQuality: (try? c.decode(String.self, forKey: .dataQuality)) ?? "niedrig: nur Basisdaten verfuegbar",
            structuredLineup: (try? c.decode(String.self, forKey: .structuredLineup)) ?? "keine belastbaren Zusatzdaten",
            playerValue: (try? c.decode(String.self, forKey: .playerValue)) ?? "keine belastbaren Zusatzdaten",
            closingLine: (try? c.decode(String.self, forKey: .closingLine)) ?? "keine belastbaren Zusatzdaten",
            historicalBaseline: (try? c.decode(String.self, forKey: .historicalBaseline)) ?? "keine belastbaren Zusatzdaten",
            scorelineCalibration: (try? c.decode(String.self, forKey: .scorelineCalibration)) ?? "keine belastbaren Zusatzdaten",
            learnedWeightHint: (try? c.decode(String.self, forKey: .learnedWeightHint)) ?? "keine belastbaren Zusatzdaten",
            homeAttackAdjustment: (try? c.decode(Double.self, forKey: .homeAttackAdjustment)) ?? 0,
            awayAttackAdjustment: (try? c.decode(Double.self, forKey: .awayAttackAdjustment)) ?? 0,
            homeDefenseAdjustment: (try? c.decode(Double.self, forKey: .homeDefenseAdjustment)) ?? 0,
            awayDefenseAdjustment: (try? c.decode(Double.self, forKey: .awayDefenseAdjustment)) ?? 0,
            totalGoalsAdjustment: (try? c.decode(Double.self, forKey: .totalGoalsAdjustment)) ?? 0,
            lineupImpact: (try? c.decode(Double.self, forKey: .lineupImpact)) ?? 0,
            playerValueImpact: (try? c.decode(Double.self, forKey: .playerValueImpact)) ?? 0,
            sharpMarketDelta: (try? c.decode(Double.self, forKey: .sharpMarketDelta)) ?? 0,
            closingLineValue: (try? c.decode(Double.self, forKey: .closingLineValue)) ?? 0,
            historicalGoalBaseline: (try? c.decode(Double.self, forKey: .historicalGoalBaseline)) ?? 0,
            scorelineDrawCalibration: (try? c.decode(Double.self, forKey: .scorelineDrawCalibration)) ?? 0,
            marketWeightHint: (try? c.decode(Double.self, forKey: .marketWeightHint)) ?? 0,
            confidence: (try? c.decode(Double.self, forKey: .confidence)) ?? 0,
            sources: (try? c.decode([String].self, forKey: .sources)) ?? []
        )
    }
}

struct PlayerAbsence: Identifiable, Hashable {
    let playerName: String
    let teamName: String
    let type: String
    let reason: String

    var id: String { "\(teamName)-\(playerName)-\(type)-\(reason)" }
}

struct LLMClosingLineUpdate: Codable, Hashable {
    let spieltag: Int
    let heim: String
    let gast: String
    let closingLine: String
    let closingLineValue: Double
    let sources: [String]

    private enum CodingKeys: String, CodingKey {
        case spieltag, heim, gast, sources
        case closingLine = "closing_line"
        case closingLineValue = "closing_line_value"
    }
}

struct MatchReferee: Identifiable, Hashable {
    let heim: String
    let gast: String
    let referee: String
    var id: String { "\(heim)-\(gast)" }
}

struct TeamExtraFixture: Identifiable, Hashable {
    let teamName: String
    let competition: String   // "Champions League", "Europa League", "DFB-Pokal" etc.
    let opponent: String
    let date: String          // ISO8601
    let isHome: Bool
    var id: String { "\(teamName)-\(competition)-\(date)" }
}

struct TeamSeasonShots: Identifiable, Hashable {
    let teamName: String
    let shotsOnGoalPerGameHome: Double
    let shotsOnGoalPerGameAway: Double
    let shotsOnGoalConversionHome: Double  // goals / shots on goal (home)
    let shotsOnGoalConversionAway: Double  // goals / shots on goal (away)
    var id: String { teamName }
}

struct TipGenerationRecord: Codable, Identifiable {
    var id: UUID
    let timestamp: Date
    let spieltag: Int
    let tips: [SuggestedTip]
    let odds: [BettingOdds]

    init(id: UUID, timestamp: Date, spieltag: Int, tips: [SuggestedTip], odds: [BettingOdds]) {
        self.id = id
        self.timestamp = timestamp
        self.spieltag = spieltag
        self.tips = tips
        self.odds = odds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self,           forKey: .id)
        timestamp = try c.decode(Date.self,           forKey: .timestamp)
        spieltag  = try c.decode(Int.self,            forKey: .spieltag)
        tips      = try c.decode([SuggestedTip].self, forKey: .tips)
        odds      = (try? c.decode([BettingOdds].self, forKey: .odds)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, spieltag, tips, odds
    }
}
