# BetBaconer

Native macOS-App fuer Bundesliga-Tipps in Kicktipp.

![BetBaconer Logo](Sources/Resources/logo.png)

## Was Die App Macht

- Laedt den naechsten Bundesliga-Spieltag.
- Laedt Quoten, Form, Tabelle, Verletzungen und Wetter.
- Recherchiert fehlende Zusatzdaten per LLM/Web-Recherche.
- Laesst Codex eine oder mehrere Analysen erzeugen.
- Berechnet pro Spiel xG aus Teamratings, Marktquoten und Kontextdaten.
- Waehlt das wahrscheinlichste exakte Ergebnis per Dixon-Coles/Poisson-Modell.
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

Copy-Buttons:

- `Alles kopieren`: Ergebnisse, Begruendung, xG, Quoten, Kontext, LLM-Zusatzdaten und Ausfaelle
- `Ergebnisse kopieren`: nur Paarung, Ergebnis und Kurzbegruendung

Manuell in Kicktipp eingetragene Tipps werden beim Laden, Lesen, Absenden oder Auswerten fuer Self-Learning gespeichert.

## Prognosemodell

Die finale Scoreline kommt nicht direkt von Codex.

Codex liefert Analyse und Begruendung. Die App berechnet danach deterministisch die wahrscheinlichste exakte Scoreline.

Beruecksichtigte Faktoren:

- Tabellenstand
- zeitgewichtete Teamratings per Maximum Likelihood
- Form der letzten Spiele mit Zeitverfall
- Tore und Gegentore pro Spiel
- Heim-/Auswaertsleistung
- Heimvorteil
- H2H-Quoten
- Over/Under-Quoten
- BTTS-Quoten
- Asian-Handicap-Quoten
- Verletzungen und Sperren
- Resttage
- LLM-recherchierte Zusatzbelastung durch Pokal/Europa, wenn belegbar
- LLM-recherchierte Shots-/Lineup-/Spielerimpact-Hinweise, wenn belegbar
- LLM-recherchierte Schiedsrichter-Stats, wenn belegbar
- LLM-recherchierte Sharp-Odds/Exchange-Hinweise, wenn belegbar
- LLM-recherchierte Spielerwert-Hinweise nach Minuten, Position, xG/xA, Defensive Actions oder Keeper-Wert
- LLM-recherchierte Closing-Line-/CLV-Hinweise, wenn oeffentlich belegbar
- LLM-recherchierte saisonuebergreifende historische Basisdaten
- LLM-recherchierte Scoreline-Kalibrierung aus historischer Ergebnisverteilung
- Wetter, wenn verfuegbar
- fruehere eigene Tipps und Self-Learning-Bias

Finalmodell:

- xG je Team aus Attack-/Defense-Rating
- fruehe Saisonwerte werden zur Liga-Norm zurueckgezogen
- Markt-Kalibrierung ueber H2H, O/U, BTTS und Asian Handicap
- marktnahe Spiele werden gegen unrealistische Kantersiege gedaempft
- Spieltage werden auf realistische Remis-Haeufigkeit kalibriert, meist 2-3 Remis bei 9 Spielen
- Marktgewicht steigt automatisch, wenn Self-Learning schlechter als Markt-Baseline kalibriert ist
- Dixon-Coles-Korrektur fuer `0:0`, `1:0`, `0:1`, `1:1`
- Scoreline-Matrix bis `6:6`
- hoechste Einzelwahrscheinlichkeit gewinnt

LLM-Zusatzdaten werden nur klein und confidence-gewichtet in xG eingerechnet. Nicht belegbare Signale bleiben neutral.
Neue PredictionRuns speichern xG, LLM-Lineup, Spielerwert, Sharp/Closing, historische Basis, Datenqualitaet und Modellversion.
Beim Auswerten werden fehlende Closing-Line-Hinweise per LLM/Web-Recherche nachgezogen und als CLV-Signal gespeichert.
Self-Learning zeigt Backtesting je Modellversion, sobald mindestens 5 bewertete Tipps fuer eine Version vorliegen.
Aktuelle Modellversion im Learning-Store: `xg-dixon-coles-shrinkage-llm-v4`.

## Datenquellen

- OpenLigaDB: Spielplan, Ergebnisse, Tabelle/Formbasis
- Kicktipp: Tippformular und Quoten-Fallback
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

Ohne The-Odds-API-Key nutzt die App Kicktipp-Quoten als Fallback. Nicht per API verfuegbare Zusatzdaten werden per LLM-Web-Recherche gesucht.

## Entwicklung

```bash
swift build
swift test
swift run
```

## Lokale Daten

Speicherort:

```text
~/Library/Application Support/BetBaconer
```

Dateien:

- `learning-store.json`
- `tip-history.json`

Secrets liegen im macOS-Keychain.
