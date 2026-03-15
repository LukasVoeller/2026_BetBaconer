import Foundation
import Observation
import WebKit

enum KicktippAutomationError: LocalizedError {
    case invalidCompetitionSlug
    case noBettingFieldsFound(debugInfo: String)
    case javaScriptError(String)

    var errorDescription: String? {
        switch self {
        case .invalidCompetitionSlug:
            return "Bitte einen gueltigen Kicktipp-Competition-Slug eintragen."
        case .noBettingFieldsFound:
            return "Keine Tippfelder gefunden. Details wurden in die Console geloggt."
        case let .javaScriptError(message):
            return message
        }
    }
}

@MainActor
@Observable
final class KicktippAutomation: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var currentCompetitionSlug: String?
    var isPageLoading: Bool = false
    private(set) var cachedOdds: [BettingOdds] = []
    private(set) var cachedOddsLog: String = ""

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.isPageLoading = true }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isPageLoading = false
            if webView.url?.absoluteString.contains("tippabgabe") == true {
                let result = await self.extractOddsFromPage()
                self.cachedOdds = result.odds
                self.cachedOddsLog = result.log
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.isPageLoading = false }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.isPageLoading = false }
    }

    func isLoggedIn() async -> Bool {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let hasSession = cookies.contains { $0.domain.contains("kicktipp.de") }
                continuation.resume(returning: hasSession)
            }
        }
    }

    func openLogin() {
        webView.load(URLRequest(url: URL(string: "https://www.kicktipp.de/info/profil/login")!))
    }

    func loadTippabgabe(for competitionSlug: String) throws {
        let trimmed = competitionSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KicktippAutomationError.invalidCompetitionSlug
        }
        currentCompetitionSlug = trimmed
        webView.load(URLRequest(url: URL(string: "https://www.kicktipp.de/\(trimmed)/tippabgabe")!))
    }

    func extractOdds(competitionSlug: String) async -> (odds: [BettingOdds], log: String) {
        // Return cached odds that were extracted when the page finished loading
        if !cachedOdds.isEmpty {
            return (cachedOdds, "[Quoten] \(cachedOdds.count) gecachte Quoten verwendet.\n")
        }
        // Fallback: try live extraction
        return await extractOddsFromPage()
    }

    private func extractOddsFromPage() async -> (odds: [BettingOdds], log: String) {
        let currentURL = webView.url?.absoluteString ?? ""

        let script = #"""
        (() => {
          const normalizeQuote = (value) => {
            if (!value) return null;
            const cleaned = String(value).trim().replace(',', '.');
            return /^\d+(\.\d+)?$/.test(cleaned) ? cleaned : null;
          };

          const rows = Array.from(document.querySelectorAll('tr')).filter(row => {
            const text = (row.innerText || '').trim();
            return text.length > 0 && /(\d+[\.,]\d+)/.test(text);
          });

          const extracted = [];
          for (const row of rows) {
            const teamNodes = [
              row.querySelector('[data-from="1"]'),
              row.querySelector('[data-from="2"]'),
              row.querySelector('.teamHome'),
              row.querySelector('.teamGuest'),
              row.querySelector('.heim'),
              row.querySelector('.gast')
            ].filter(Boolean);

            let heim = teamNodes[0]?.textContent?.trim() || '';
            let gast = teamNodes[1]?.textContent?.trim() || '';

            if (!heim || !gast) {
              const textCells = Array.from(row.querySelectorAll('td, th, div, span')).filter(node => {
                const text = (node.textContent || '').trim();
                if (!text || text.length < 2) return false;
                if (/^\d+([\.,]\d+)?$/.test(text)) return false;
                if (/^[\d.:,\s]+$/.test(text)) return false;
                return true;
              }).map(node => (node.textContent || '').trim());

              const uniqueTextCells = [...new Set(textCells)];
              heim = heim || uniqueTextCells[0] || '';
              gast = gast || uniqueTextCells[1] || '';
            }

            const selectorCandidates = [
              '.tippabgabe-quoten .quoteheim .quote-text',
              '.tippabgabe-quoten .quoteremis .quote-text',
              '.tippabgabe-quoten .quotegast .quote-text',
              '.quoteheim .quote-text',
              '.quoteremis .quote-text',
              '.quotegast .quote-text',
            ];

            let heimQuote = normalizeQuote(row.querySelector(selectorCandidates[0])?.textContent)
              || normalizeQuote(row.querySelector(selectorCandidates[3])?.textContent);
            let drawQuote = normalizeQuote(row.querySelector(selectorCandidates[1])?.textContent)
              || normalizeQuote(row.querySelector(selectorCandidates[4])?.textContent);
            let gastQuote = normalizeQuote(row.querySelector(selectorCandidates[2])?.textContent)
              || normalizeQuote(row.querySelector(selectorCandidates[5])?.textContent);

            if (!heimQuote || !drawQuote || !gastQuote) {
              const quoteNodes = Array.from(row.querySelectorAll('[class*="quote"], [class*="odds"], [data-odd], [data-quote], a, span, div'))
                .map(node => normalizeQuote(node.textContent))
                .filter(Boolean);
              const uniqueQuotes = [...new Set(quoteNodes)];
              if (uniqueQuotes.length >= 3) {
                heimQuote = heimQuote || uniqueQuotes[0];
                drawQuote = drawQuote || uniqueQuotes[1];
                gastQuote = gastQuote || uniqueQuotes[2];
              }
            }

            if ((!heimQuote || !drawQuote || !gastQuote) && row.innerText) {
              const quoteMatches = Array.from(row.innerText.matchAll(/\b\d+[\.,]\d+\b/g)).map(match => normalizeQuote(match[0])).filter(Boolean);
              const uniqueQuotes = [...new Set(quoteMatches)];
              if (uniqueQuotes.length >= 3) {
                heimQuote = heimQuote || uniqueQuotes[0];
                drawQuote = drawQuote || uniqueQuotes[1];
                gastQuote = gastQuote || uniqueQuotes[2];
              }
            }

            if (heim && gast && heimQuote && drawQuote && gastQuote) {
              extracted.push({
                heim,
                gast,
                quoteHeim: heimQuote,
                quoteUnentschieden: drawQuote,
                quoteGast: gastQuote
              });
            }
          }

          if (!extracted.length) {
            return JSON.stringify({
              error: 'NO_SECTIONS',
              url: location.href,
              datarowCount: document.querySelectorAll('tr.datarow').length,
              trCount: document.querySelectorAll('tr').length,
              sampleRows: rows.slice(0, 5).map(row => (row.innerText || '').trim().slice(0, 300))
            });
          }

          return JSON.stringify({ odds: extracted, sectionCount: extracted.length });
        })();
        """#

        guard let raw = try? await evaluateJavaScriptString(script) else {
            return ([], "[Quoten] JS-Aufruf fehlgeschlagen (URL: \(currentURL))\n")
        }

        struct OddsPayload: Decodable {
            let heim: String
            let gast: String
            let quoteHeim: String
            let quoteUnentschieden: String
            let quoteGast: String
        }
        struct OddsResult: Decodable {
            let odds: [OddsPayload]?
            let sectionCount: Int?
            let error: String?
            let url: String?
            let datarowCount: Int?
            let trCount: Int?
        }

        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(OddsResult.self, from: data) else {
            return ([], "[Quoten] JSON-Parsing fehlgeschlagen. Raw: \(raw.prefix(300))\n")
        }

        if let error = result.error {
            return ([], "[Quoten] \(error) – datarows=\(result.datarowCount ?? -1), trs=\(result.trCount ?? -1), URL=\(result.url ?? currentURL)\n")
        }

        let bettingOdds = (result.odds ?? []).map {
            BettingOdds(heim: $0.heim, gast: $0.gast,
                        quoteHeim: $0.quoteHeim,
                        quoteUnentschieden: $0.quoteUnentschieden,
                        quoteGast: $0.quoteGast)
        }
        return (bettingOdds, "[Quoten] \(bettingOdds.count) Quoten extrahiert aus \(result.sectionCount ?? 0) Sektionen (URL: \(currentURL))\n")
    }

    func extractMatchFields() async throws -> [KicktippMatchField] {
        let script = #"""
        (() => {
          // Try multiple selector strategies for different Kicktipp HTML versions
          const strategies = [
            { home: 'input[id$="_heimTipp"]',   guest: 'input[id$="_gastTipp"]' },
            { home: 'input[name*="heimTipp"]',  guest: 'input[name*="gastTipp"]' },
            { home: 'input[name*="tippHeim"]',  guest: 'input[name*="tippGast"]' },
            { home: 'input[name*="heim"]',      guest: 'input[name*="gast"]' },
          ];

          let homeInputs = [], guestInputs = [];
          let usedStrategy = null;
          for (const s of strategies) {
            homeInputs = Array.from(document.querySelectorAll(s.home));
            guestInputs = Array.from(document.querySelectorAll(s.guest));
            if (homeInputs.length > 0 && homeInputs.length === guestInputs.length) {
              usedStrategy = s;
              break;
            }
          }

          if (homeInputs.length === 0) {
            // Auto-collect debug info for diagnosis
            const allInputs = Array.from(document.querySelectorAll('input')).slice(0, 30).map(i => ({
              tag: i.tagName, type: i.type, id: i.id, name: i.name, value: i.value.slice(0, 20)
            }));
            const tables = Array.from(document.querySelectorAll('table')).map(t => t.className || t.id || '?');
            return JSON.stringify({
              error: 'NO_FIELDS',
              url: location.href,
              title: document.title,
              allInputs,
              tables,
              bodySnippet: document.body.innerText.slice(0, 500)
            });
          }

          const matches = homeInputs.map((homeInput, i) => {
            const guestInput = guestInputs[i];
            // Walk up to the row to find team name cells
            const row = homeInput.closest('tr');
            const cells = row ? Array.from(row.querySelectorAll('td')) : [];
            // Try to find team name cells: skip cells that contain only numbers/odds/inputs
            const textCells = cells.filter(td => {
              const t = (td.innerText || '').trim();
              return t.length > 2 && !/^[\d.:,\s]+$/.test(t) && !td.querySelector('input');
            });
            return {
              heim: (textCells[0]?.innerText || '').trim(),
              gast: (textCells[1]?.innerText || '').trim(),
              heimField: homeInput.name || homeInput.id,
              gastField: guestInput.name || guestInput.id,
              existingHeim: homeInput.value || '',
              existingGast: guestInput.value || ''
            };
          });

          return JSON.stringify({ matches, strategy: usedStrategy });
        })();
        """#

        let raw = try await evaluateJavaScriptString(script)
        let data = Data(raw.utf8)

        // Check for debug/error payload
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorCode = obj["error"] as? String, errorCode == "NO_FIELDS" {
            let debugInfo = raw
            throw KicktippAutomationError.noBettingFieldsFound(debugInfo: debugInfo)
        }

        // Parse successful result
        struct Result: Decodable {
            let matches: [KicktippMatchField]
        }
        let result = try JSONDecoder().decode(Result.self, from: data)
        if result.matches.isEmpty {
            throw KicktippAutomationError.noBettingFieldsFound(debugInfo: "Matches array empty. URL: \(webView.url?.absoluteString ?? "unknown")")
        }
        return result.matches
    }

    func applyTips(_ updates: [(field: KicktippMatchField, tip: SuggestedTip)]) async throws {
        let payload = updates.map {
            [
                "heimField": $0.field.heimField,
                "gastField": $0.field.gastField,
                "heimValue": String($0.tip.toreHeim),
                "gastValue": String($0.tip.toreGast),
            ]
        }
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw KicktippAutomationError.javaScriptError("Kicktipp-Payload konnte nicht serialisiert werden.")
        }

        let script = """
        (() => {
          const updates = \(jsonString);
          for (const update of updates) {
            const homeInput = document.querySelector(`[name="${update.heimField}"]`);
            const guestInput = document.querySelector(`[name="${update.gastField}"]`);
            if (!homeInput || !guestInput) continue;
            homeInput.value = update.heimValue;
            guestInput.value = update.gastValue;
            homeInput.dispatchEvent(new Event('input', { bubbles: true }));
            guestInput.dispatchEvent(new Event('input', { bubbles: true }));
            homeInput.dispatchEvent(new Event('change', { bubbles: true }));
            guestInput.dispatchEvent(new Event('change', { bubbles: true }));
          }
          return 'ok';
        })();
        """

        try await evaluateJavaScriptVoid(script)
    }

    func submitTips() async throws {
        let script = #"""
        (() => {
          const form = document.querySelector('form');
          if (!form) {
            throw new Error('Kein Formular gefunden.');
          }
          const submitButton = form.querySelector('[type="submit"], button[name="submitbutton"], input[name="submitbutton"]');
          if (submitButton) {
            submitButton.click();
          } else if (form.requestSubmit) {
            form.requestSubmit();
          } else {
            form.submit();
          }
          return 'submitted';
        })();
        """#

        try await evaluateJavaScriptVoid(script)
    }

    private func evaluateJavaScriptString(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: KicktippAutomationError.javaScriptError(error.localizedDescription))
                } else if let value = result as? String {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: KicktippAutomationError.javaScriptError("JavaScript lieferte keinen String zurück."))
                }
            }
        }
    }

    private func evaluateJavaScriptVoid(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    continuation.resume(throwing: KicktippAutomationError.javaScriptError(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
