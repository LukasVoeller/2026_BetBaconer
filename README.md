# BetBaconer

Native macOS-App fuer Bundesliga-Tipps in Kicktipp.

![BetBaconer Logo](Sources/Resources/logo.png)

## Was Die App Macht

- Laedt den naechsten Bundesliga-Spieltag (Nachholspiele frueherer Spieltage werden uebersprungen).
- Laedt Quoten, Form, Tabelle, Verletzungen und Wetter.
- Recherchiert fehlende Zusatzdaten per LLM/Web-Recherche.
- Laesst Codex eine oder mehrere Analysen erzeugen.
- Berechnet pro Spiel xG aus Teamratings, Marktquoten und Kontextdaten.
- Waehlt pro Spiel das Ergebnis mit den meisten erwarteten Kicktipp-Punkten (Dixon-Coles/Poisson-Modell, Punkteregel der Tipprunde).
- Liest die Tipps der Mitspieler vergangener Spieltage aus der Kicktipp-Tippuebersicht.
- Speichert Tipps und Learning-Daten lokal.
- Traegt Tipps in Kicktipp ein und kann sie absenden.

## Was Die App Nicht Macht

- Garantiert keine richtigen Ergebnisse; Fussball bleibt probabilistisch.
- Berechnet Closing-Line-Value nur aus LLM/Web-Recherche, nicht aus einem garantierten Profi-Closing-Odds-Feed.
- Nutzt keine nicht konfigurierten oder nicht funktionierenden APIs im Tippworkflow.
- Ersetzt fehlende Daten nicht durch Fantasiewerte; nicht belegbare LLM-Signale werden mit `0` gewichtet.
- Platziert keine Wetten.

## Tippabgabe

1. `Kicktipp > Login oeffnen`
2. In Kicktipp anmelden.
3. `Kicktipp > Tippabgabe laden`
4. `Bundesliga > Tipps generieren`
5. Tipps pruefen.
6. `Kicktipp > Tipps eintragen`
7. `Kicktipp > Tipps absenden`

Sicherheitsnetze:

- Tipps werden nur eingetragen, wenn sie zum offenen Spieltag passen und alle Spiele zugeordnet werden koennen.
- Bereits vorhandene, abweichende Tipps werden erst nach Bestaetigung ueberschrieben.
- Nach dem Eintragen liest die App das Formular erneut aus und meldet Abweichungen.
- Beim Absenden werden Abweichungen zwischen Formular und importierten Tipps in die Console geschrieben.
- Waehrend ein Vorgang laeuft, sind alle Aktionen gesperrt; Codex-Laeufe koennen per `Codex abbrechen` gestoppt werden.

Copy-Buttons:

- `Alles kopieren`: Ergebnisse, Begruendung, xG, Quoten, Kontext, LLM-Zusatzdaten und Ausfaelle
- `Ergebnisse kopieren`: nur Paarung, Ergebnis und Kurzbegruendung

Manuell in Kicktipp eingetragene Tipps werden beim Laden, Lesen, Absenden oder Auswerten fuer Self-Learning gespeichert.

## Prognosemodell

Die finale Scoreline kommt nicht direkt von Codex.

Codex liefert Analyse, Begruendung und eine eigene Scoreline. Der Mittelwert der Codex-Scorelines fliesst mit 20 % in das statistische xG ein; die finale Scoreline berechnet die App deterministisch.

Finalmodell (jede Entscheidung per Walk-forward-Backtest belegt, Bundesliga 2019-2025):

1. **Markt zuerst:** Liegen Quoten vor, bestimmen sie allein die erwarteten Tore (Marktgewicht 100 %, gelernt). Die Tendenz kommt aus den 1X2-Quoten, das Torniveau aus O/U-Quoten, sonst aus dem Team-Rating.
2. **Team-Rating als Fallback:** zeitgewichtetes Poisson-Modell ueber die laufende und zwei Vorsaisons (L2, Aufsteiger-Malus, Tor-Kalibrierung). Es greift, wenn fuer ein Spiel keine Quoten vorliegen; dann wirken auch Ausfaelle, Resttage, LLM-News und Learning-Korrekturen.
3. **Auswahl:** Dixon-Coles-Scoreline-Matrix; gewaehlt wird das Ergebnis mit den meisten erwarteten Kicktipp-Punkten (Punkteregel der Tipprunde).
4. Gespeichert werden 1/X/2-Wahrscheinlichkeiten, Top-3-Ergebnisse und ein heuristischer Sicherheitswert.

Backtest mit Pinnacle-Schlussquoten (1.885 Spiele, Saisons 2019/20-2025/26):

| Methode | Punkte/Tipp |
|---|---|
| **App: Markt + erwartete Kicktipp-Punkte, mit O/U** | **1,343** |
| App, nur 1X2-Quoten (z. B. Kicktipp) | 1,331 |
| Faustregel „Favorit 2:1“ | 1,290 |
| Team-Rating ohne Quoten | 1,269 |
| „Wahrscheinlichstes Ergebnis“ (fruehere App-Logik) mit denselben Quoten | 1,207 |

Verworfen, weil im Backtest schlechter: Daempfung von Kantersiegen (-0,016), Torniveau aus der Remisquote (-0,014), Mischung von Markt und Rating (bis -0,08), zusaetzliche Codex-Scorelines bei vorhandenen Quoten.

## Quoten-Archiv und Backtest

Jede Quote, die die App sieht (The Odds API oder Kicktipp), wird pro Spiel im Learning-Store archiviert (die letzte vor Anstoss gewinnt). `Kicktipp-Historie laden` liest zusaetzlich die Quoten vergangener Spieltage aus `tippabgabe?spieltagIndex=<n>` nach, sofern Kicktipp sie dort anzeigt.

Fuer einen sofort belastbaren Backtest: `Learning > Quoten-CSV importieren` mit den Dateien `https://www.football-data.co.uk/mmz4281/<saison>/D1.csv` (z. B. `2324`, `2425`). Bevorzugt werden Schlussquoten (Pinnacle, sonst Durchschnitt).

`Learning > Backtest ausfuehren` laedt die letzten Saisons von OpenLigaDB, sagt jeden Spieltag nur aus vorher gespielten Spielen vorher und vergleicht Modell, Faustregel und Marktgewichte 0-100 % auf den archivierten Quoten. Das beste Marktgewicht wird automatisch uebernommen.

LLM-Zusatzdaten werden nur klein und confidence-gewichtet in xG eingerechnet. Nicht belegbare Signale bleiben neutral.
Neue PredictionRuns speichern xG, LLM-Lineup, Spielerwert, Sharp/Closing, historische Basis, Datenqualitaet und Modellversion.
Beim Auswerten werden fehlende Closing-Line-Hinweise per LLM/Web-Recherche nachgezogen und als CLV-Signal gespeichert.
Self-Learning bewertet alle Runs, lernt aber pro Spieltag nur aus einem: dem in Kicktipp eingetragenen Stand, sonst dem Ensemble, sonst dem neuesten Einzel-Lauf.
Self-Learning zeigt Backtesting je Modellversion, sobald mindestens 5 bewertete Tipps fuer eine Version vorliegen.
Aktuelle Modellversion im Learning-Store: `market-ev-kicktipp-v8`.

## Kurz vor Anstoss

Optional (`Einstellungen > Kurz vor Anstoss`): Solange die App geoeffnet ist, prueft sie alle 10 Minuten, ob ein Spiel in den naechsten 75 Minuten beginnt. Fuer diese Spiele holt sie die aktuellsten Quoten (The Odds API, sonst Kicktipp), archiviert sie, berechnet den Tipp ohne neuen Codex-Lauf neu und traegt geaenderte Tipps auf Wunsch automatisch ein (mit Read-back) und sendet ab. Quoten direkt vor Anstoss enthalten Aufstellungen und Kurzfrist-News und sind die genaueste verfuegbare Prognose.

Liegen Quoten vor, fliessen die Codex-Scorelines nicht zusaetzlich ins xG ein, weil Codex dieselben Quoten im Prompt sieht (keine Doppelzaehlung).

## Mitspieler-Tipps

`Self-Learning > Mitspieler-Tipps laden` (und automatisch bei `Tipps generieren`) oeffnet fuer jeden abgeschlossenen Spieltag `https://www.kicktipp.de/<slug>/tippuebersicht?spieltagIndex=<n>`, liest Tipps, Punkte und Gesamtstand aller Mitspieler und gleicht die Kicktipp-Kuerzel (VFB, BMG, ...) mit den OpenLigaDB-Ergebnissen ab. Fehlende Spieltage werden nachgeladen, der letzte wird aktualisiert. Danach kehrt der Browser zur Tippabgabe zurueck.

Verwendung:

- **Punkteregel pruefen:** Aus vergebenen Punkten wird die Regel der Tipprunde abgeleitet; Abweichungen zur Einstellung werden angezeigt und koennen uebernommen werden.
- **Stil-Benchmark im Prompt:** Punkte je Tipp, Remis-Anteil, 1-Tor-Differenz und Torniveau der Top-5 vs. Rest sowie die tatsaechliche Remis-/Torquote gehen als Kalibrierung an Codex.
- **App vs. Tipprunde:** Der Learning-Tab zeigt je Spieltag Punkte und Rang der App-Tipps innerhalb der Runde.
- **Ranglisten-Strategie (optional, Default aus):** Mit eigenem Namen in den Einstellungen bestimmt die Ranglage, ob die App vom typischen Mehrheitstipp der Runde (z. B. 2:1) abweicht (bei Rueckstand) oder ihm folgt (bei Fuehrung). Der Verzicht ist auf `0,05 x Punkte je Restspieltag`, maximal 0,25 erwartete Punkte pro Spiel begrenzt und wirkt daher vor allem spaet in der Saison.

Die Tipps der Mitspieler fuer den kommenden Spieltag sind vor Anstoss nicht sichtbar und fliessen daher nicht direkt in die Vorhersage ein.

## Datenquellen

- OpenLigaDB: Spielplan, Ergebnisse, Tabelle/Formbasis
- Kicktipp: Tippformular, Quoten-Fallback und Tippuebersicht der Mitspieler
- The Odds API: H2H, O/U, BTTS, Asian Handicap
- SofaScore: Verletzungen und Sperren
- TheSportsDB: Team- und Stadiondaten
- Open-Meteo: Wetter
- Codex/LLM-Web-Recherche: fehlende Zusatzdaten, Sharp-Odds, Lineups, Schiedsrichter-Stats, Zusatzbelastung
- Codex/LLM-Web-Recherche nach Spielschluss: closing-nahe Marktbewegung und CLV-Hinweise
- Lokaler Store: Verlauf und Self-Learning

## Einstellungen

- `Codex Pfad`: Pfad zur Codex CLI
- `Competition Slug`: Kicktipp-Runde
- `The Odds API Key`: optional, im macOS-Keychain
- `Codex-Laeufe`: Anzahl der Analyse-Laeufe, Default `1`
- `Kicktipp-Punkteregel`: Punkte fuer Ergebnis/Tordifferenz/Tendenz (Default 4/3/2) und ob Remis mit falschem Ergebnis Tordifferenz-Punkte geben (Default ja, wie im Kicktipp-Standard: 1:1 bei 0:0 = 3 Punkte)

Codex wird immer mit `--sandbox read-only` und einem Timeout (15 Minuten pro Lauf, 60 Sekunden fuer den Statuscheck) gestartet.

Ohne The-Odds-API-Key nutzt die App Kicktipp-Quoten als Fallback. Nicht per API verfuegbare Zusatzdaten werden per LLM-Web-Recherche gesucht.

## Entwicklung

Fertige App (Release, `dist/BetBaconer.app`, per Doppelklick startbar): `./scripts/build-app.sh`. Einstellungen und API-Key einer frueheren `swift run`-Installation werden beim ersten Start uebernommen.

Die SwiftUI-Macros sind nur in der Xcode-Toolchain enthalten, nicht in den Command Line Tools:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
swift run
```

Die Tests laufen ohne Netz und ohne echte Nutzerdaten. `WorkflowEndToEndTests` spielt den kompletten Ablauf durch: gestubbte OpenLigaDB, ein Fake-Codex-Skript, ein Kicktipp-Nachbau in einem echten WKWebView. Der Test deckt Tipps generieren, eintragen, pruefen und absenden ab. GitHub Actions fuehrt Build und Tests bei jedem Push aus.

## Lokale Daten

Speicherort:

```text
~/Library/Application Support/BetBaconer
```

Dateien:

- `learning-store.json`
- `tip-history.json`

Kann eine Datei nicht gelesen werden, wird sie als `*.corrupt-<Zeitstempel>.json` gesichert und die App startet mit leerem Stand. Schlaegt das Sichern fehl, wird das Speichern deaktiviert, damit nichts ueberschrieben wird.

Secrets liegen im macOS-Keychain.
