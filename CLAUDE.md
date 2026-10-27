# BetBaconer

Native macOS-App (Swift 6, SwiftUI, macOS 14+) die Bundesliga-Tipps für Kicktipp automatisiert.

## Ziel

Der Nutzer soll mit einem einzigen Klick KI-gestützte Tipps in sein Kicktipp-Konto eintragen können:
1. Bundesliga-Saison-Daten von OpenLigaDB laden
2. Analyse-Prompt für die Codex CLI erzeugen
3. Prompt an lokale Codex CLI senden (kein API-Key in der App)
4. LLM-Antwort als JSON empfangen und Tipps parsen
5. Tipps per JavaScript-Injection in die Kicktipp-Tippabgabe-Seite eintragen
6. Formular absenden

## Architektur

- **AppState** (`AppState.swift`) — zentraler `@MainActor @Observable` State, orchestriert alle Services; `isBusy` sperrt parallele Vorgänge
- **KicktippAutomation** (`KicktippAutomation.swift`) — `@Observable` WKWebView-Wrapper mit JS-Injection für Kicktipp
- **KicktippWebView** (`KicktippWebView.swift`) — NSViewRepresentable-Wrapper für den eingebetteten Browser
- **OpenLigaDBService** (`OpenLigaDBService.swift`) — Spielplan/Ergebnisse; nutzt `matchDateTimeUTC`, überspringt Nachholspiele
- **TheOddsAPIService** / **SofaScoreService** / **TheSportsDBService** / **WeatherService** — Quoten, Ausfälle, Team-/Stadiondaten, Wetter (Open-Meteo)
- **TeamRatingService** (`TeamRatingService.swift`) — Poisson-Rating über 3 Saisons (Newton-Fit, L2, Aufsteiger, Tor-Kalibrierung) und `MarketModel` (erwartete Tore aus Quoten)
- **ModelBacktestService** (`ModelBacktestService.swift`) — Walk-forward-Backtest, lernt das Marktgewicht aus dem Quoten-Archiv
- **EnsembleService** (`EnsembleService.swift`) — Scoreline-Matrix (Dixon-Coles), Auswahl nach erwarteten Kicktipp-Punkten (`KicktippRules`)
- **TipWorkflowService** (`TipWorkflowService.swift`) — Prompt-Generierung und JSON-Parsing der LLM-Antworten (lehnt Duplikate/ungültige Ergebnisse ab)
- **CodexCLIService** (`CodexCLIService.swift`) — startet `codex exec` als Subprocess (Timeout, Abbruch über `CodexProcessHandle`)
- **PredictionEvaluator** / **LearningEngine** (`PredictionEvaluator.swift`, `LearningEngine.swift`) — Bewertung abgeschlossener Spiele und Self-Learning
- **PredictionStore** / **TipHistoryStore** — JSON-Persistenz in Application Support (`AppSupportPaths`), korrupte Dateien werden gesichert
- **KicktippCommunityService** (`KicktippCommunityService.swift`) — liest die Kicktipp-Tippübersicht (generische Tabellen-Extraktion), leitet Punkteregel, Stil-Benchmark, Backtest und Ranglisten-Strategie ab; gespeichert im Learning-Store
- **TeamNameNormalizer** (`TeamNameNormalizer.swift`) — kanonische Teamnamen, Match-Funktionen und Anstoßzeit-Parsing für alle Quellen
- **ContentView** (`ContentView.swift`) — SwiftUI UI mit NavigationSplitView

## UI-Struktur

```
NavigationSplitView
├── Sidebar: Kicktipp-Aktionen | Bundesliga-Workflow | Self-Learning
└── Detail:
    ├── Status-Strip (Fehler, Info, Codex-Status, Kicktipp-Status)
    └── Tabs: Kicktipp (Browser) | Codex (Prompt, Console, Import) | Bundesliga (Spiele/Tipps)
              | Verlauf | Learning | Einstellungen (inkl. Codex-Login, Punkteregel)
```

## Wichtige Konventionen

- Kein API-Key in der App für Codex — Codex läuft als externer Prozess (`codex exec --sandbox read-only`)
- Alle UI-Strings sind Deutsch
- Fehler werden als roter Banner im Status-Strip angezeigt; bei `noBettingFieldsFound` wird automatisch DOM-Debug-Info in die Console geloggt
- `KicktippAutomation` ist `@Observable` (NSObject-Subklasse) damit `isPageLoading` SwiftUI-reaktiv ist
- Die App wird als SPM-Executable gebaut (`Package.swift`); `NSApp.activate(ignoringOtherApps: true)` im AppDelegate ist notwendig damit Keyboard-Input funktioniert; SIGPIPE wird ignoriert (Codex-stdin)
- Teamnamen immer über `normalizedTeamKey` / `matchesLikelyEqual` vergleichen, nie per String-Gleichheit
- Änderungen an der Tipp-Auswahl erhöhen `AppState.promptVersion`
- Modelländerungen nur mit Backtest-Beleg (`Learning > Backtest ausführen`)

## LLM-Antwortformat

```json
{
  "tips": [
    {
      "spieltag": 26,
      "heim": "Eintracht Frankfurt",
      "gast": "1. FC Heidenheim 1846",
      "tore_heim": 2,
      "tore_gast": 0,
      "rationale": "Kurze Begruendung"
    }
  ]
}
```

## README

Die `README.md` ist immer aktuell zu halten. Nach jeder Änderung an Funktionen, Architektur, Datenquellen oder Konfigurationsmöglichkeiten muss die README entsprechend angepasst werden.

## Build

Die SwiftUI-Macros fehlen in den Command Line Tools, daher immer mit Xcode-Toolchain:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
swift run
```
