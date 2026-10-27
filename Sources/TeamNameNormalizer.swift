import Foundation

/// Canonical Bundesliga club keys. Every name variant seen in OpenLigaDB, Kicktipp (incl. its 3-letter codes), The Odds API,
/// SofaScore or LLM output maps to one key, so exact key comparison works across sources.
private let teamAliases: [String: String] = {
    let groups: [String: [String]] = [
        "bayernmunchen": ["fcbayernmunchen", "bayernmunchen", "fcbayern", "bayern", "fcb", "bayernmunich"],
        "dortmund": ["borussiadortmund", "bordortmund", "bvb", "dortmund"],
        "leipzig": ["rbleipzig", "rasenballsportleipzig", "leipzig", "rbl"],
        "bayerleverkusen": ["bayer04leverkusen", "bayer04", "bayerleverkusen", "leverkusen", "b04"],
        "monchengladbach": ["borussiamonchengladbach", "bormonchengladbach", "monchengladbach", "gladbach", "bmg", "mgladbach"],
        "frankfurt": ["eintrachtfrankfurt", "sgeintrachtfrankfurt", "frankfurt", "sge", "einfrankfurt"],
        "freiburg": ["scfreiburg", "sportclubfreiburg", "freiburg", "scf"],
        "hoffenheim": ["tsghoffenheim", "1899hoffenheim", "tsg1899hoffenheim", "hoffenheim", "tsg"],
        "werderbremen": ["svwerderbremen", "werderbremen", "bremen", "svw"],
        "mainz05": ["1fsvmainz05", "fsvmainz05", "mainz05", "mainz", "m05"],
        "unionberlin": ["1fcunionberlin", "fcunionberlin", "unionberlin", "fcu"],
        "wolfsburg": ["vflwolfsburg", "wolfsburg", "wob"],
        "stuttgart": ["vfbstuttgart", "stuttgart", "vfb"],
        "augsburg": ["fcaugsburg", "augsburg", "fca"],
        "heidenheim": ["1fcheidenheim1846", "1fcheidenheim", "fcheidenheim", "heidenheim", "fch", "hdh"],
        "koln": ["1fckoln", "fckoln", "koln", "koe"],
        "stpauli": ["fcstpauli", "stpauli", "stp"],
        "hamburgersv": ["hamburgersv", "hsv", "hamburg"],
        "bochum": ["vflbochum", "vflbochum1848", "bochum", "boc"],
        "holsteinkiel": ["holsteinkiel", "kiel", "ksv"],
        "svelversberg": ["sv07elversberg", "svelversberg", "elversberg", "elv"],
        "schalke04": ["fcschalke04", "schalke04", "schalke", "s04"],
        "darmstadt98": ["svdarmstadt98", "darmstadt98", "darmstadt", "d98"],
        "herthabsc": ["herthabsc", "herthaberlin", "hertha", "bsc"],
        "bielefeld": ["dscarminiabielefeld", "arminiabielefeld", "bielefeld", "dsc"],
        "greutherfurth": ["spvgggreutherfurth", "greutherfurth", "furth", "sgf"],
        "paderborn07": ["scpaderborn07", "paderborn07", "paderborn", "scp"],
    ]
    var aliases: [String: String] = [:]
    for (canonical, variants) in groups {
        for variant in variants { aliases[variant] = canonical }
    }
    return aliases
}()

public func normalizeTeamName(_ name: String) -> String {
    let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    let allowedScalars = folded.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    let compact = String(String.UnicodeScalarView(allowedScalars))
    return teamAliases[compact] ?? compact
}

public func normalizedTeamKey(_ heim: String, _ gast: String) -> String {
    "\(normalizeTeamName(heim))|\(normalizeTeamName(gast))"
}

/// Exact canonical match first; substring fallback only for names long enough to be unambiguous.
public func teamNamesLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = normalizeTeamName(lhs)
    let right = normalizeTeamName(rhs)
    if left == right { return !left.isEmpty }
    guard min(left.count, right.count) >= 5 else { return false }
    return left.contains(right) || right.contains(left)
}

public func matchesLikelyEqual(_ heimA: String, _ gastA: String, _ heimB: String, _ gastB: String) -> Bool {
    teamNamesLikelyMatch(heimA, heimB) && teamNamesLikelyMatch(gastA, gastB)
}

/// Formats a stored kickoff (UTC ISO-8601 or legacy local `yyyy-MM-dd'T'HH:mm:ss`) for display in German local time.
public func formattedKickoff(_ raw: String) -> String {
    guard let date = parseKickoffDate(raw) else { return raw }
    return date.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits).hour().minute().locale(Locale(identifier: "de_DE")))
}

public func parseKickoffDate(_ raw: String) -> Date? {
    if let date = kickoffISOFractional.date(from: raw) ?? kickoffISO.date(from: raw) {
        return date
    }
    return kickoffLegacyLocal.date(from: raw)
}

nonisolated(unsafe) private let kickoffISO = ISO8601DateFormatter()
nonisolated(unsafe) private let kickoffISOFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let kickoffLegacyLocal: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter
}()

public func absenceEmoji(for type: String) -> String {
    switch type {
    case "Sperre (Rote Karte)":  return "🟥"
    case "Sperre (Gelbe Karte)": return "🟨"
    default:                     return "🏥"
    }
}

public func outcome(forHomeGoals homeGoals: Int, awayGoals: Int) -> MatchOutcome {
    if homeGoals > awayGoals {
        return .homeWin
    }
    if homeGoals < awayGoals {
        return .awayWin
    }
    return .draw
}
