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

