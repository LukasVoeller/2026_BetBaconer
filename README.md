# BetBaconer

![BetBaconer Logo](Sources/Resources/logo.png)

BetBaconer ist eine native macOS-App, die Bundesliga-Tipps für Kicktipp automatisch vorbereitet, per lokaler KI analysiert und auf Wunsch direkt in die Kicktipp-Tippabgabe einträgt. Mit einem kleinen Augenzwinkern gesagt: Der Keiler macht dir die Tipps speckfett.

Technisch kombiniert die App Bundesliga-Daten, Wettquoten (H2H, O/U 2.5, BTTS, Asian Handicap), Ausfallinformationen, Schiedsrichter- und Belastungsdaten, Shots-Statistiken und Wetterdaten zu einem strukturierten Prompt, führt mehrere lokale Codex-Läufe aus und aggregiert daraus einen konsolidierten Tippvorschlag.

![BetBaconer Screenshot](Sources/Resources/screenshot.png)

BetBaconer ist für den lokalen Einsatz auf macOS als gehärtete `v1` ausgelegt:
- keine OpenAI-API-Schlüssel in der App
- lokale Modell-Ausführung über Codex CLI
- sicher gespeicherte Drittanbieter-Secrets im macOS-Keychain
- reproduzierbare Build- und Test-Pipeline über SwiftPM und GitHub Actions

## Kernfunktionen

Mit einem Lauf über **"Tipps generieren"** durchläuft die App folgenden Workflow:

1. Bundesliga-Saisondaten über OpenLigaDB laden
2. Wettquoten (H2H, O/U 2.5, BTTS, Asian Handicap) über The Odds API laden, mit Kicktipp-DOM als Fallback
3. Verletzungen und Sperren über SofaScore verdichten
4. Team-, Stadion- und Ortsdaten über TheSportsDB laden
5. Schiedsrichter, europäische/Pokal-Belastung und Shots-Statistiken über API-Football laden (optional)
6. Wetterprognosen über Open-Meteo anreichern
7. Frühere Vorhersagen für denselben Spieltag als Konsistenzsignal einbeziehen
8. Mehrere Codex-Läufe lokal ausführen und per Ensemble aggregieren
9. JSON-Antworten validieren, post-processen und lokal persistieren
10. Tipps in die Kicktipp-Tippabgabe eintragen und optional absenden

## Architektur

Die Anwendung besteht aus vier Hauptbereichen:

| Bereich | Verantwortung |
|---|---|
| SwiftUI App/UI | Bedienung, Statusanzeige, Browser-Einbettung |
| Workflow-Orchestrierung | Datenquellen laden, Prompt erzeugen, Ensemble ausführen |
| Services | OpenLigaDB, The Odds API, SofaScore, TheSportsDB, Open-Meteo, Codex CLI |
| Persistenz | Learning-Store, Tipp-Verlauf, Keychain-Secrets |

Wichtige Dateien:
- [Sources/AppState.swift](Sources/AppState.swift): zentrale Workflow-Orchestrierung
- [Sources/KicktippAutomation.swift](Sources/KicktippAutomation.swift): Kicktipp-WebView- und DOM-Automation
- [Sources/TipWorkflowService.swift](Sources/TipWorkflowService.swift): Prompt-Aufbau und JSON-Parsing
- [Sources/EnsembleService.swift](Sources/EnsembleService.swift): Mehrheitsaggregation
- [Sources/PredictionStore.swift](Sources/PredictionStore.swift): Learning-Persistenz
- [Sources/TipHistoryStore.swift](Sources/TipHistoryStore.swift): Tipp-Verlauf
- [Sources/KeychainSecretStore.swift](Sources/KeychainSecretStore.swift): sichere Secret-Speicherung

## Datenquellen

| Quelle | Zweck |
|---|---|
| OpenLigaDB | Ergebnisse und Spielplan der Bundesliga |
| The Odds API | Marktquoten H2H, O/U 2.5, BTTS und Asian Handicap |
| Kicktipp DOM | Quoten-Fallback und Tippformular |
| SofaScore | Verletzungen und Sperren |
| TheSportsDB | Team- und Stadion-Metadaten |
| API-Football | Schiedsrichter, europäische/Pokal-Belastung (CL/EL/ECL/DFB-Pokal), Shots-Statistiken (optional, eigener Key) |
| Open-Meteo | Geocoding und Wetter zur Anstoßzeit |
| Lokale Historie | Konsistenzsignal früherer KI-Läufe |

## Analysemodell

Der generierte Prompt instruiert das LLM, die folgenden Analyseschritte sequenziell intern durchzuführen und danach ausschließlich JSON auszugeben.

### Eingabedaten im Prompt

| Datenblock | Inhalt |
|---|---|
| Formtabelle | Mini-Tabelle der letzten 6 Spieltage: Punkte, Tore, Tordifferenz je Team (Normierungssignal) |
| Teamprofile | Tabellenrang, Punkte, Tordifferenz, Stadion/Ort, gewichtete Kernwerte, Heim-/Auswärtsform (je letzte 5 Spiele), Shots-on-Goal/Spiel und Verwertungsrate (wenn API-Football Key vorhanden) |
| Spielplan | Datum, Tabellenkontext beider Teams, Motivationslage, Resttage, Stadion, Wetter, H2H, Schiedsrichter, europäische/Pokal-Belastung, H2H-Quoten inkl. impliziter Wahrscheinlichkeiten, O/U 2.5, BTTS, Asian Handicap |
| Ausfälle | Verletzungen und Sperren je Team, priorisiert nach Spielerbedeutung (TW/Topscorer/Abwehr > Stammspieler > Rotation) |
| Saisonstatistik | Ø Heimsiege / Auswärtssiege / Unentschieden pro Spieltag über alle abgeschlossenen Spieltage, mit Zielbereichen für den aktuellen Spieltag |
| Konsistenzsignal | Häufigkeitsverteilung früherer KI-Vorhersagen für denselben Spieltag aus mehreren Läufen |
| Learning-Korrekturen | Regelbasierte Nachkorrekturen aus ausgewerteten Vorhersagen (ab 30 Datenpunkten aktiv), inkl. Brier-Score-Vergleich mit Markt-Baseline |

### Analyseschritte (LLM-Methodik)

1. **Teamstärke** — Gewichtete Kernwerte: letzte 5 Spiele 50 %, Spiele 6–10 30 %, ältere 20 %. Pro Team: Angriffsstärke und Defensivstärke relativ zum Liga-Durchschnitt (~1,45 Tore/Spiel). Heimvorteil-Faktor ~1,25 explizit eingepreist. Formtabelle der letzten 6 Spieltage als kompaktes Normierungssignal. Wenn Shots-Daten verfügbar: Angriffsstärke = Ø ShotsOnGoal × Verwertungsrate statt reiner Tore/Spiel.

2. **Verletzungen & Sperren** — Angriffs- oder Defensivstärke des betroffenen Teams wird entsprechend der Spielerbedeutung reduziert.

3. **Marktquoten** (Gewicht 30–40 %) — Implizite Wahrscheinlichkeiten aus H2H-, O/U-2.5-, BTTS- und Asian-Handicap-Quoten aggregieren Marktwissen inklusive Verletzungen und Form. Abweichung nur bei klar gegenteiliger eigener Analyse.

4. **Head-to-Head** (max. 5–10 %) — Direkte Duelle der letzten fünf Begegnungen nur als schwaches Zusatzsignal.

5. **Tabellenkontext & Motivation** — Abstiegskampf, Europaränge, Titelrennen und Punkteabstände als moderates Kontextsignal.

6. **Rest & Belastung** — Resttage seit letztem Pflichtspiel; sehr kurze Regenerationszeit als leicht negatives Signal. Europäische/Pokal-Belastung unter der Woche (CL/EL/ECL/DFB-Pokal) ist ein deutlich stärkeres negatives Signal als reine Liga-Resttage.

7. **Wetter & Spielort** — Starker Regen, Wind oder winterliche Bedingungen können Tempo und Torerwartung senken (moderates Signal).

8. **Torerwartung (xG-Proxy)** — `xG_Heim = Angriff_Heim × Abwehr_Gast × Heimvorteil-Faktor`, `xG_Gast = Angriff_Gast × Abwehr_Heim`. Plausibilitätsprüfung gegen Marktquoten.

9. **Simulation** — Gedankliche Poisson-Simulation über 500 Durchläufe je Spiel. Bei mehreren nah beieinander liegenden Ergebnissen gewinnt das marktnähere und realistischere Resultat.

10. **Konsistenz** (5–10 %) — Frühere KI-Vorhersagen für denselben Spieltag als leichtes Stabilitätssignal.

### Kalibrierungsregeln

- Typische Bundesliga-Scorelines: 1:0, 2:1, 1:1, 2:0, 0:1, 1:2, 0:0, 3:1, 2:2, 3:0
- Keine Ergebnisse mit mehr als 5 Toren Differenz
- Tipp-Verteilung (Heimsiege / Auswärtssiege / Unentschieden) muss im errechneten Zielbereich der Saisonstatistik liegen; grenzwertige Spiele werden entsprechend angepasst — aber keine klaren Favoriten werden nur wegen der Kalibrierung geändert
- Bei fehlenden Saisondaten gilt der Faustrichtwert ~25 % Unentschieden

### Ensemble & Aggregation

Das Modell wird mehrfach ausgeführt. Die Einzelergebnisse werden aggregiert:
- Primär über Mehrheitsentscheidung je Spiel
- Bei Gleichstand: Annäherung an Marktausrichtung
- Anschließend: konservativere Scoreline bevorzugt

## Sicherheits- und Produktionsmerkmale

BetBaconer ist auf sicheren lokalen Betrieb ausgelegt:

- Der The-Odds-API-Key und der API-Football-Key werden im macOS-Keychain gespeichert, nicht in `UserDefaults`.
- Externe Netzwerkanfragen verwenden zentrale Session-Konfiguration mit Timeouts.
- Der Workflow bricht kontrolliert ab, wenn für den Spieltag keine vollständige Quotenabdeckung vorliegt.
- Ein Codex-Ensemble gilt nur dann als erfolgreich, wenn eine Mindestanzahl von Runs erfolgreich war.
- Learning-Daten und Tipp-Verlauf werden atomar lokal gespeichert.
- Die App schreibt strukturierte Laufzeitlogs über `OSLog`.

## Voraussetzungen

- macOS 14+
- Xcode Command Line Tools oder Xcode mit Swift 6 Toolchain
- installierte und angemeldete [Codex CLI](https://github.com/openai/codex)
- optional: The-Odds-API-Key für primäre Quotenversorgung (H2H, O/U 2.5, BTTS, Asian Handicap)
- optional: API-Football-Key für Schiedsrichter-, Belastungs- und Shots-Daten

## Konfiguration

In der App können folgende Werte gesetzt werden:

| Einstellung | Beschreibung |
|---|---|
| `Codex Pfad` | Pfad zur installierten Codex CLI |
| `Competition Slug` | Kicktipp-Runden-Slug für die Tippabgabe |
| `The Odds API Key` | wird sicher im macOS-Keychain gespeichert |
| `API-Football Key` | wird sicher im macOS-Keychain gespeichert (optional) |
| `Codex-Läufe` | Anzahl der Ensemble-Runs pro Analyse |
| `Nachkorrektur aktiv` | regelbasierte Learning-Nachkorrektur |

Zusätzlich können `THE_ODDS_API_KEY` und `API_FOOTBALL_KEY` als Umgebungsvariablen verwendet werden. Beim Speichern in der App werden die Werte in den Keychain übernommen.

## Build, Test und Start

```bash
swift build
swift test
swift run
```

## Kontinuierliche Integration

Es ist eine GitHub-Actions-CI enthalten:

- Build auf `macos-14`
- `swift build`
- `swift test`

Datei: [`.github/workflows/ci.yml`](.github/workflows/ci.yml)

## Persistenz

BetBaconer speichert lokale Daten in `Application Support/BetBaconer`:

- `learning-store.json`: ausgewertete Vorhersagehistorie
- `tip-history.json`: importierte bzw. erzeugte Tipps pro Spieltag

Secrets werden nicht dort abgelegt, sondern separat im macOS-Keychain gehalten.

## Betriebsgrenzen

Die Anwendung ist intern auf Produktionsniveau gehärtet, aber einige Betriebsrisiken liegen naturgemäß außerhalb des eigenen Codes:

- Kicktipp wird über WebView- und DOM-Automation integriert; HTML-Änderungen auf Kicktipp können die Automation beeinflussen.
- Drittanbieter-APIs können sich in Verfügbarkeit, Format oder Rate Limits ändern.
- Die Vorhersagequalität bleibt trotz Learning- und Ensemble-Logik probabilistisch und nicht deterministisch korrekt.

## Antwortformat der Modellausgabe

```json
{
  "tips": [
    {
      "spieltag": 26,
      "heim": "Team A",
      "gast": "Team B",
      "tore_heim": 2,
      "tore_gast": 1,
      "rationale": "Starke Heimform, passende Quoten, Ausfälle beim Gast."
    }
  ]
}
```

## Entwicklungsstatus

Stand dieser README:
- Build und Test über SwiftPM eingerichtet
- Produktionsnahe lokale Ausführung auf macOS vorgesehen
- First-commit-fähige Dokumentation ohne offene Platzhalter oder TODO-Notizen
