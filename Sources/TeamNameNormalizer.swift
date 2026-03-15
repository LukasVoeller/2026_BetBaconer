import Foundation

public func normalizeTeamName(_ name: String) -> String {
    let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let lowered = folded.lowercased()
    let allowedScalars = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    let compact = String(String.UnicodeScalarView(allowedScalars))

    let aliases: [String: String] = [
        "borussiamonchengladbach": "monchengladbach",
        "bormonchengladbach": "monchengladbach",
        "tsghoffenheim": "hoffenheim",
        "1899hoffenheim": "hoffenheim",
        "svwerderbremen": "werderbremen",
        "werderbremen": "werderbremen",
        "1fsvmainz05": "mainz05",
        "fsvmainz05": "mainz05",
        "1fcunionberlin": "unionberlin",
        "unionberlin": "unionberlin",
        "fcbayernmunchen": "bayernmunchen",
        "bayernmunchen": "bayernmunchen",
    ]

    return aliases[compact] ?? compact
}

public func normalizedTeamKey(_ heim: String, _ gast: String) -> String {
    "\(normalizeTeamName(heim))|\(normalizeTeamName(gast))"
}

public func teamNamesLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = normalizeTeamName(lhs)
    let right = normalizeTeamName(rhs)
    return left == right || left.contains(right) || right.contains(left)
}

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
