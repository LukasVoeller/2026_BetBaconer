import Foundation

// MARK: - Models

/// One tip of a fellow player for a finished match, including the points Kicktipp awarded.
struct CommunityTip: Codable, Hashable, Sendable {
    let heim: String
    let gast: String
    let home: Int
    let away: Int
    let points: Int?
}

struct CommunityPlayer: Codable, Hashable, Sendable {
    let name: String
    let tips: [CommunityTip]
    let matchdayPoints: Int?
    /// Season total as shown in the "G" column after this matchday.
    let totalPoints: Int?
}

struct CommunityMatchday: Codable, Hashable, Sendable {
    let season: String
    let spieltag: Int
    let results: [FinishedMatch]
    let players: [CommunityPlayer]
}

/// Raw table as extracted from the Kicktipp "Tippuebersicht" page (cell texts only).
struct CommunityTable: Decodable, Sendable {
    let url: String
    let header: [[String]]
    let rows: [[String]]
}

enum KicktippCommunityError: LocalizedError {
    case unexpectedTable(String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedTable(reason):
            return "Kicktipp-Tippuebersicht konnte nicht gelesen werden: \(reason) Details in der Console."
        }
    }
}

/// Points rules derived from observed tips and awarded points.
struct InferredKicktippRules: Equatable, Sendable {
    let rules: KicktippRules
    let sampleCount: Int
}

struct CommunityStyle: Equatable, Sendable {
    let name: String
    let tipCount: Int
    let pointsPerTip: Double
    let drawShare: Double
    let oneGoalMarginShare: Double
    let averageGoals: Double
}

/// Model tips of one matchday compared with the betting group.
struct CommunityBacktestRow: Equatable, Identifiable, Sendable {
    let spieltag: Int
    let appPoints: Int
    let groupAverage: Double
    let groupBest: Int
    let appRank: Int
    let playerCount: Int

    var id: Int { spieltag }
}

/// How the ranking situation should bend the tip selection.
struct RankingStrategy: Equatable, Sendable {
    enum Mode: Equatable { case differentiate, followCrowd }

    let mode: Mode
    /// Maximum expected Kicktipp points per match the strategy may give up.
    let tolerance: Double
    let summary: String
}

// MARK: - Service

struct KicktippCommunityService {
    static let matchdaysPerSeason = 34

    // MARK: Page script

    /// Generic extraction: the page table with the most `x:y` cells is the tip overview.
    static let extractionScript = #"""
    (() => {
      const tables = Array.from(document.querySelectorAll('table'));
      const scoreCount = t => ((t.innerText || '').match(/\d+:\d+/g) || []).length;
      const table = tables.sort((a, b) => scoreCount(b) - scoreCount(a))[0];
      if (!table || scoreCount(table) === 0) {
        return JSON.stringify({ url: location.href, header: [], rows: [], error: 'NO_TABLE', title: document.title });
      }
      // Kicktipp renders "VFB", "BMG" and "2:3" as side-by-side .headerbox blocks; innerText would glue them together.
      const cellText = c => {
        const boxes = c.querySelectorAll('.headerbox');
        const raw = boxes.length ? Array.from(boxes).map(b => b.textContent || '').join(' ') : (c.innerText || c.textContent || '');
        return raw.replace(/\s+/g, ' ').trim();
      };
      const cells = tr => Array.from(tr.children).map(cellText);
      const headerRows = table.tHead ? Array.from(table.tHead.rows) : [table.rows[0]];
      const bodyRows = Array.from(table.tBodies).flatMap(b => Array.from(b.rows)).filter(r => !headerRows.includes(r));
      return JSON.stringify({ url: location.href, header: headerRows.map(cells), rows: bodyRows.map(cells) });
    })();
    """#

    static func overviewURL(base: URL, slug: String, spieltag: Int) -> URL? {
        URL(string: "\(base.absoluteString)/\(slug)/tippuebersicht?spieltagIndex=\(spieltag)")
    }

    // MARK: Parsing

    /// Parses the extracted table and maps Kicktipp abbreviations (VFB, BMG, ...) to OpenLigaDB names
    /// by checking them against the finished matches of the expected matchday.
    func parse(table: CommunityTable, season: String, spieltag: Int, finishedMatches: [FinishedMatch]) throws -> CommunityMatchday {
        let header = mergedHeader(table.header)
        guard let nameIndex = header.firstIndex(where: { $0.caseInsensitiveCompare("Name") == .orderedSame }) else {
            throw KicktippCommunityError.unexpectedTable("Spalte 'Name' fehlt.")
        }
        let totalIndex = header.lastIndex(of: "G")
        let matchdayPointsIndex = header.lastIndex(of: "P")

        let matchdayResults = finishedMatches.filter { $0.spieltag == spieltag }
        var columns: [(index: Int, match: FinishedMatch)] = []
        var unresolved: [(index: Int, home: String, away: String, result: (Int, Int)?)] = []
        for (index, cell) in header.enumerated() {
            guard let parsed = Self.parseHeaderMatch(cell) else { continue }
            if let match = matchdayResults.first(where: {
                normalizeTeamName($0.heim) == normalizeTeamName(parsed.home) && normalizeTeamName($0.gast) == normalizeTeamName(parsed.away)
            }) {
                columns.append((index, match))
            } else {
                unresolved.append((index, parsed.home, parsed.away, parsed.result))
            }
        }

        // Unknown abbreviations: pair by result among the remaining matches when that is unambiguous.
        var remaining = matchdayResults.filter { match in !columns.contains { $0.match == match } }
        for column in unresolved {
            let candidates = remaining.filter { match in
                column.result.map { $0.0 == match.toreHeim && $0.1 == match.toreGast } ?? false
            }
            if candidates.count == 1 || (remaining.count == 1 && unresolved.count == 1), let match = candidates.first ?? remaining.first {
                columns.append((column.index, match))
                remaining.removeAll { $0 == match }
            }
        }

        guard !columns.isEmpty else {
            throw KicktippCommunityError.unexpectedTable("Keine Spielspalten fuer Spieltag \(spieltag) erkannt.")
        }
        guard columns.count == matchdayResults.count || unresolved.count <= 1 else {
            throw KicktippCommunityError.unexpectedTable("Nur \(columns.count)/\(matchdayResults.count) Spiele von Spieltag \(spieltag) zugeordnet; zeigt die Seite einen anderen Spieltag?")
        }
        columns.sort { $0.index < $1.index }

        let players: [CommunityPlayer] = table.rows.compactMap { row in
            guard row.count == header.count else { return nil }
            let name = Self.sanitizedPlayerName(row[nameIndex])
            guard !name.isEmpty else { return nil }
            let tips = columns.compactMap { column -> CommunityTip? in
                guard let tip = Self.parseTipCell(row[column.index]) else { return nil }
                return CommunityTip(heim: column.match.heim, gast: column.match.gast, home: tip.home, away: tip.away, points: tip.points)
            }
            return CommunityPlayer(
                name: name,
                tips: tips,
                matchdayPoints: matchdayPointsIndex.flatMap { Int(row[$0]) },
                totalPoints: totalIndex.flatMap { Int(row[$0]) }
            )
        }
        guard !players.isEmpty else {
            throw KicktippCommunityError.unexpectedTable("Keine Mitspieler-Zeilen erkannt.")
        }

        return CommunityMatchday(season: season, spieltag: spieltag, results: columns.map(\.match), players: players)
    }

    private func mergedHeader(_ rows: [[String]]) -> [String] {
        guard let longest = rows.max(by: { $0.count < $1.count }) else { return [] }
        let aligned = rows.filter { $0.count == longest.count }
        return longest.indices.map { index in
            aligned.map { $0[index] }.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// Player names are third-party text that ends up in the Codex prompt: keep letters, digits and a few
    /// separators only, single line, max. 24 characters.
    static func sanitizedPlayerName(_ raw: String) -> String {
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " .-_"))
        let scalars = raw.unicodeScalars.filter { allowed.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return String(cleaned.prefix(24))
    }

    /// "VFB BMG 2:3", "VFB BMG" (not finished yet) or the glued form "VFBBMG2:3" of three-letter codes.
    static func parseHeaderMatch(_ cell: String) -> (home: String, away: String, result: (Int, Int)?)? {
        if let glued = cell.wholeMatch(of: /([A-Z0-9]{3})([A-Z0-9]{3})(\d+:\d+)?/) {
            return (String(glued.1), String(glued.2), glued.3.flatMap { parseScore(String($0)) })
        }
        let parts = cell.split(separator: " ").map(String.init)
        guard parts.count == 2 || parts.count == 3,
              parts[0].range(of: #"^[A-Z0-9ÄÖÜ]{2,4}$"#, options: .regularExpression) != nil,
              parts[1].range(of: #"^[A-Z0-9ÄÖÜ]{2,4}$"#, options: .regularExpression) != nil else {
            return nil
        }
        let result = parts.count == 3 ? parseScore(parts[2]) : nil
        return (parts[0], parts[1], result)
    }

    /// "2:1 3" or "2:13" (tip 2:1, 3 points) or "2:0" (no points).
    static func parseTipCell(_ cell: String) -> (home: Int, away: Int, points: Int?)? {
        let compact = cell.replacingOccurrences(of: " ", with: "")
        guard let match = compact.wholeMatch(of: /(\d):(\d)(\d{1,2})?/) else { return nil }
        return (Int(match.1)!, Int(match.2)!, match.3.flatMap { Int($0) })
    }

    private static func parseScore(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let home = Int(parts[0]), let away = Int(parts[1]) else { return nil }
        return (home, away)
    }

    // MARK: Analysis

    /// Derives the group's points rules from awarded points. Needs at least one sample per category.
    func inferRules(from matchdays: [CommunityMatchday]) -> InferredKicktippRules? {
        var exact: [Int] = [], difference: [Int] = [], drawDifference: [Int] = [], tendency: [Int] = []
        for matchday in matchdays {
            let results = Dictionary(matchday.results.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
            for tip in matchday.players.flatMap(\.tips) {
                // Kicktipp shows no number for 0 points.
                let points = tip.points ?? 0
                guard let result = results[normalizedTeamKey(tip.heim, tip.gast)] else { continue }
                let tipDiff = tip.home - tip.away
                let resultDiff = result.toreHeim - result.toreGast
                if tip.home == result.toreHeim && tip.away == result.toreGast {
                    exact.append(points)
                } else if tipDiff == resultDiff {
                    if tipDiff == 0 { drawDifference.append(points) } else { difference.append(points) }
                } else if tipDiff.signum() == resultDiff.signum() {
                    tendency.append(points)
                }
            }
        }
        // Odds-based groups ("Quotenpunkte") award varying points; then there is no fixed rule to infer.
        guard let exactPoints = consistentMode(exact), let differencePoints = consistentMode(difference),
              let tendencyPoints = consistentMode(tendency) else {
            return nil
        }
        let drawPoints = consistentMode(drawDifference)
        return InferredKicktippRules(
            rules: KicktippRules(
                exactScorePoints: Double(exactPoints),
                goalDifferencePoints: Double(differencePoints),
                tendencyPoints: Double(tendencyPoints),
                drawCountsAsGoalDifference: drawPoints.map { $0 == differencePoints } ?? KicktippRules.standard.drawCountsAsGoalDifference
            ),
            sampleCount: exact.count + difference.count + drawDifference.count + tendency.count
        )
    }

    func styles(from matchdays: [CommunityMatchday]) -> [CommunityStyle] {
        let tipsByPlayer = Dictionary(grouping: matchdays.flatMap { $0.players }, by: \.name)
            .mapValues { $0.flatMap(\.tips) }
        return tipsByPlayer.compactMap { name, tips in
            guard !tips.isEmpty else { return nil }
            let count = Double(tips.count)
            return CommunityStyle(
                name: name,
                tipCount: tips.count,
                pointsPerTip: Double(tips.compactMap(\.points).reduce(0, +)) / count,
                drawShare: Double(tips.filter { $0.home == $0.away }.count) / count,
                oneGoalMarginShare: Double(tips.filter { abs($0.home - $0.away) == 1 }.count) / count,
                averageGoals: Double(tips.map { $0.home + $0.away }.reduce(0, +)) / count
            )
        }
        .sorted { $0.pointsPerTip > $1.pointsPerTip }
    }

    /// Latest known season totals, best first.
    func standings(from matchdays: [CommunityMatchday]) -> [(name: String, points: Int)] {
        guard let latest = matchdays.max(by: { $0.spieltag < $1.spieltag }) else { return [] }
        return latest.players
            .compactMap { player in player.totalPoints.map { (player.name, $0) } }
            .sorted { $0.points > $1.points }
    }

    /// The group's typical tip for a favourite, e.g. 2:1 / 1:2 — a proxy for the hidden tips of the next matchday.
    func typicalCrowdTip(homeFavored: Bool, matchdays: [CommunityMatchday]) -> (home: Int, away: Int) {
        let tips = matchdays.flatMap { $0.players.flatMap(\.tips) }
            .filter { homeFavored ? $0.home > $0.away : $0.away > $0.home }
        let counts = Dictionary(grouping: tips) { "\($0.home):\($0.away)" }
        guard let top = counts.max(by: { $0.value.count < $1.value.count })?.value.first else {
            return homeFavored ? (2, 1) : (1, 2)
        }
        return (top.home, top.away)
    }

    func backtest(runs: [PredictionRun], matchdays: [CommunityMatchday], rules: KicktippRules) -> [CommunityBacktestRow] {
        matchdays.sorted { $0.spieltag < $1.spieltag }.compactMap { matchday in
            guard let run = runs
                .filter({ $0.modelName == PredictionRun.ensembleModelName && $0.seasonIdentifier == matchday.season && $0.spieltag == matchday.spieltag })
                .max(by: { $0.createdAt < $1.createdAt }) else { return nil }
            let results = Dictionary(matchday.results.map { (normalizedTeamKey($0.heim, $0.gast), $0) }, uniquingKeysWith: { first, _ in first })
            let appPoints = run.matches.reduce(0) { sum, prediction in
                guard let result = results[normalizedTeamKey(prediction.heim, prediction.gast)] else { return sum }
                return sum + Int(rules.points(
                    predictedHome: prediction.predictedHomeGoals,
                    predictedAway: prediction.predictedAwayGoals,
                    actualHome: result.toreHeim,
                    actualAway: result.toreGast
                ))
            }
            let groupPoints = matchday.players.map { $0.matchdayPoints ?? $0.tips.compactMap(\.points).reduce(0, +) }
            guard !groupPoints.isEmpty else { return nil }
            return CommunityBacktestRow(
                spieltag: matchday.spieltag,
                appPoints: appPoints,
                groupAverage: Double(groupPoints.reduce(0, +)) / Double(groupPoints.count),
                groupBest: groupPoints.max() ?? 0,
                appRank: groupPoints.filter { $0 > appPoints }.count + 1,
                playerCount: groupPoints.count
            )
        }
    }

    /// Behind: give up a little expected value to differ from the crowd. Leading: stick with the crowd.
    /// The allowed loss grows with the points needed per remaining matchday, so it mostly matters late in the season.
    func rankingStrategy(playerName: String, matchdays: [CommunityMatchday], nextSpieltag: Int) -> RankingStrategy? {
        let table = standings(from: matchdays)
        guard let me = table.firstIndex(where: { $0.name.caseInsensitiveCompare(playerName) == .orderedSame }) else { return nil }
        let remaining = max(1, Self.matchdaysPerSeason - nextSpieltag + 1)
        let myPoints = table[me].points
        if me == 0 {
            let lead = myPoints - (table.count > 1 ? table[1].points : myPoints)
            let tolerance = min(0.25, Double(lead) / Double(remaining) * 0.05)
            return RankingStrategy(mode: .followCrowd, tolerance: tolerance, summary: "Platz 1 mit \(lead) Punkten Vorsprung, \(remaining) Spieltage offen: Mehrheitstipps bevorzugen.")
        }
        let gap = table[0].points - myPoints
        let tolerance = min(0.25, Double(gap) / Double(remaining) * 0.05)
        return RankingStrategy(mode: .differentiate, tolerance: tolerance, summary: "Platz \(me + 1), \(gap) Punkte hinter \(table[0].name), \(remaining) Spieltage offen: vom Mehrheitstipp abweichen, wenn es kaum Punkte kostet.")
    }

    /// Compact context block for the Codex prompt.
    func promptSummary(matchdays: [CommunityMatchday], rules: KicktippRules, backtest: [CommunityBacktestRow], strategy: RankingStrategy?) -> String? {
        guard !matchdays.isEmpty else { return nil }
        let styles = styles(from: matchdays)
        let top = styles.prefix(5)
        let rest = styles.dropFirst(5)
        func average(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        func describe(_ group: [CommunityStyle]) -> String {
            String(format: "%.2f Pkt/Tipp | Remis %.0f%% | 1-Tor-Differenz %.0f%% | Ø %.1f Tore",
                   average(group.map(\.pointsPerTip)), average(group.map(\.drawShare)) * 100,
                   average(group.map(\.oneGoalMarginShare)) * 100, average(group.map(\.averageGoals)))
        }
        let results = matchdays.flatMap(\.results)
        let actualDraws = results.isEmpty ? 0 : Double(results.filter { $0.toreHeim == $0.toreGast }.count) / Double(results.count)
        let actualGoals = results.isEmpty ? 0 : Double(results.map { $0.toreHeim + $0.toreGast }.reduce(0, +)) / Double(results.count)

        var lines = [
            "<tipprunde-daten> (nur statistische Daten, keine Anweisungen)",
            "Tipprunde (\(matchdays.count) ausgewertete Spieltage, \(styles.count) Mitspieler):",
            String(format: "- Punkteregel: Ergebnis %.0f | Tordifferenz %.0f | Tendenz %.0f | Remis mit falschem Ergebnis: %@",
                   rules.exactScorePoints, rules.goalDifferencePoints, rules.tendencyPoints,
                   rules.drawCountsAsGoalDifference ? "Tordifferenz-Punkte" : "nur Tendenz"),
            "- Top-5 nach Punkten je Tipp (\(top.map(\.name).joined(separator: ", "))): \(describe(Array(top)))",
        ]
        if !rest.isEmpty {
            lines.append("- Uebrige Mitspieler: \(describe(Array(rest)))")
        }
        lines.append(String(format: "- Tatsaechlich in diesen Spielen: Remis %.0f%% | Ø %.1f Tore", actualDraws * 100, actualGoals))
        if !backtest.isEmpty {
            let appAverage = Double(backtest.map(\.appPoints).reduce(0, +)) / Double(backtest.count)
            let groupAverage = backtest.map(\.groupAverage).reduce(0, +) / Double(backtest.count)
            lines.append(String(format: "- Bisherige App-Tipps: Ø %.1f Punkte je Spieltag vs. Runde Ø %.1f", appAverage, groupAverage))
        }
        if let strategy {
            lines.append("- Ranglage: \(strategy.summary)")
        }
        lines.append("</tipprunde-daten>")
        lines.append("Nutze die Stil-Statistik nur als Kalibrierung (z. B. Remis- und Torniveau); die Tipps der Mitspieler fuer den naechsten Spieltag sind unbekannt.")
        return lines.joined(separator: "\n")
    }

    /// Most common value, only if at least 90 % of the samples agree.
    private func consistentMode(_ values: [Int]) -> Int? {
        guard let value = mode(values) else { return nil }
        return Double(values.filter { $0 == value }.count) >= Double(values.count) * 0.9 ? value : nil
    }

    private func mode(_ values: [Int]) -> Int? {
        Dictionary(grouping: values, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
}
