import Foundation

/// Imports historical Bundesliga odds from football-data.co.uk CSV files (e.g. `mmz4281/2324/D1.csv`)
/// into the odds archive, so the backtest can measure the market model over whole seasons.
/// Closing odds are preferred because they are the most accurate market estimate.
struct HistoricalOddsImporter {
    struct ImportResult {
        let odds: [ArchivedOdds]
        let unmatched: Int
    }

    private static let oneXTwoColumns = [
        ("PSCH", "PSCD", "PSCA"), ("AvgCH", "AvgCD", "AvgCA"), ("B365CH", "B365CD", "B365CA"),
        ("PSH", "PSD", "PSA"), ("AvgH", "AvgD", "AvgA"), ("B365H", "B365D", "B365A"),
    ]
    private static let overUnderColumns = [("PC>2.5", "PC<2.5"), ("AvgC>2.5", "AvgC<2.5"), ("P>2.5", "P<2.5"), ("Avg>2.5", "Avg<2.5")]

    /// - Parameter seasons: OpenLigaDB results per season start year; used to find the matchday of each row.
    func importCSV(_ text: String, seasons: [Int: [FinishedMatch]]) -> ImportResult {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else { return ImportResult(odds: [], unmatched: 0) }
        let header = headerLine.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let column = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        guard let home = column["HomeTeam"], let away = column["AwayTeam"], let dateIndex = column["Date"] else {
            return ImportResult(odds: [], unmatched: 0)
        }
        let oneXTwo = Self.oneXTwoColumns.first { column[$0.0] != nil && column[$0.1] != nil && column[$0.2] != nil }
        let overUnder = Self.overUnderColumns.first { column[$0.0] != nil && column[$0.1] != nil }

        var odds: [ArchivedOdds] = []
        var unmatched = 0
        for line in lines.dropFirst() {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cells.count == header.count, let oneXTwo,
                  let date = Self.parseDate(cells[dateIndex]),
                  let quoteHome = Self.validQuote(cells[column[oneXTwo.0]!]),
                  let quoteDraw = Self.validQuote(cells[column[oneXTwo.1]!]),
                  let quoteAway = Self.validQuote(cells[column[oneXTwo.2]!]) else { continue }

            let seasonStart = Self.seasonStart(for: date)
            guard let match = (seasons[seasonStart] ?? []).first(where: {
                normalizedTeamKey($0.heim, $0.gast) == normalizedTeamKey(cells[home], cells[away])
            }) else {
                unmatched += 1
                continue
            }
            let over = overUnder.flatMap { Self.validQuote(cells[column[$0.0]!]) }
            let under = overUnder.flatMap { Self.validQuote(cells[column[$0.1]!]) }
            odds.append(ArchivedOdds(
                season: String(seasonStart), spieltag: match.spieltag, heim: match.heim, gast: match.gast,
                quoteHeim: quoteHome, quoteUnentschieden: quoteDraw, quoteGast: quoteAway,
                overUnderLine: over != nil && under != nil ? 2.5 : nil, overQuote: over, underQuote: under,
                capturedAt: parseKickoffDate(match.datum) ?? date
            ))
        }
        return ImportResult(odds: odds, unmatched: unmatched)
    }

    private static func validQuote(_ raw: String) -> String? {
        guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), value > 1 else { return nil }
        return String(value)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        for format in ["dd/MM/yyyy", "dd/MM/yy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    private static func seasonStart(for date: Date) -> Int {
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "Europe/Berlin")!, from: date)
        return (components.month ?? 1) >= 7 ? (components.year ?? 0) : (components.year ?? 0) - 1
    }
}
