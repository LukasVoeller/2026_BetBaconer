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

- **AppState** (`AppState.swift`) — zentraler `@Observable` State, orchestriert alle Services
- **KicktippAutomation** (`KicktippAutomation.swift`) — `@Observable` WKWebView-Wrapper mit JS-Injection für Kicktipp
- **OpenLigaDBService** (`OpenLigaDBService.swift`) — REST-API-Client für Bundesliga-Daten
- **TipWorkflowService** (`TipWorkflowService.swift`) — Prompt-Generierung und JSON-Parsing der LLM-Antwort
- **CodexCLIService** (`CodexCLIService.swift`) — startet lokale Codex CLI als Subprocess mit stdin/stdout-Streaming
- **ContentView** (`ContentView.swift`) — SwiftUI UI mit NavigationSplitView (Sidebar + TabView-Detail)
- **KicktippWebView** (`KicktippWebView.swift`) — NSViewRepresentable-Wrapper für den eingebetteten Browser

## UI-Struktur

```
NavigationSplitView
├── Sidebar: Einstellungen | Codex CLI | Kicktipp-Aktionen | Workflow
└── Detail:
    ├── Status-Strip (Fehler, Info, Codex-Status, Kicktipp-Status)
    └── TabView
        ├── Browser  — eingebetteter Kicktipp-WebView
        ├── Codex    — Prompt, Console, LLM-Antwort/Import
        └── Spiele   — Ergebnisse, Offene Spiele, Importierte Tipps
```

## Wichtige Konventionen

- Kein API-Key in der App — Codex läuft als externer Prozess (`codex exec`)
- Alle UI-Strings sind Deutsch
- Fehler werden als roter Banner im Status-Strip angezeigt; bei `noBettingFieldsFound` wird automatisch DOM-Debug-Info in die Console geloggt
- `KicktippAutomation` ist `@Observable` (NSObject-Subklasse) damit `isPageLoading` SwiftUI-reaktiv ist
- Die App wird als SPM-Executable gebaut (`Package.swift`); `NSApp.activate(ignoringOtherApps: true)` im AppDelegate ist notwendig damit Keyboard-Input funktioniert

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

## Build

```bash
swift build
swift run
```
