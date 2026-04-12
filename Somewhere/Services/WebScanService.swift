import Foundation

// MARK: - Web Scan Result
struct WebScanResult {
    var url: String
    var htmlContent: String
    var extractedText: String
    var extractedDeals: [ExtractedDeal]
    var error: Error?
}

// MARK: - Web Scan Service
/// Fetches and parses venue websites to find happy hour deals.
/// Heavy parsing is delegated to Firebase Cloud Functions for server-side execution.
class WebScanService {
    static let shared = WebScanService()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Fetch Website

    func fetchWebsite(url: String) async throws -> String {
        guard let validURL = URL(string: normalizeURL(url)) else {
            throw WebScanError.invalidURL
        }

        let (data, response) = try await session.data(from: validURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw WebScanError.fetchFailed
        }

        guard let html = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .isoLatin1) else {
            throw WebScanError.encodingError
        }

        return html
    }

    // MARK: - Scan for Deals

    func scanForDeals(url: String) async throws -> WebScanResult {
        let html = try await fetchWebsite(url: url)
        let text = extractText(from: html)
        let deals = extractDeals(from: text)

        return WebScanResult(
            url: url,
            htmlContent: html,
            extractedText: text,
            extractedDeals: deals
        )
    }

    // MARK: - Text Extraction

    func extractText(from html: String) -> String {
        var text = html

        // Remove script and style blocks
        text = removePattern(#"<script[^>]*>[\s\S]*?</script>"#, from: text)
        text = removePattern(#"<style[^>]*>[\s\S]*?</style>"#, from: text)
        text = removePattern(#"<nav[^>]*>[\s\S]*?</nav>"#, from: text)
        text = removePattern(#"<header[^>]*>[\s\S]*?</header>"#, from: text)
        text = removePattern(#"<footer[^>]*>[\s\S]*?</footer>"#, from: text)

        // Replace block elements with newlines
        text = text.replacingOccurrences(of: #"</?(p|div|br|h[1-6]|li|tr)[^>]*>"#,
                                          with: "\n",
                                          options: .regularExpression)

        // Remove remaining HTML tags
        text = removePattern(#"<[^>]+>"#, from: text)

        // Decode HTML entities
        text = decodeHTMLEntities(text)

        // Clean up whitespace
        text = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return text
    }

    // MARK: - Deal Extraction from Text

    private func extractDeals(from text: String) -> [ExtractedDeal] {
        // Focus on sections that mention happy hour
        let sections = findHappyHourSections(in: text)

        if sections.isEmpty {
            // Try to find any deal text if no "happy hour" sections
            return PhotoScanService.shared.extractDeals(from: text).extractedDeals
        }

        var deals: [ExtractedDeal] = []
        for section in sections {
            let sectionDeals = PhotoScanService.shared.extractDeals(from: section).extractedDeals
            deals.append(contentsOf: sectionDeals)
        }

        return deals
    }

    private func findHappyHourSections(in text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var sections: [String] = []
        var inHappyHourSection = false
        var currentSection: [String] = []
        var lineCount = 0

        let triggers = ["happy hour", "specials", "drink specials", "food specials", "deals"]

        for line in lines {
            let lower = line.lowercased()
            let isTrigger = triggers.contains { lower.contains($0) }

            if isTrigger {
                if !currentSection.isEmpty && inHappyHourSection {
                    sections.append(currentSection.joined(separator: "\n"))
                }
                inHappyHourSection = true
                currentSection = [line]
                lineCount = 0
            } else if inHappyHourSection {
                currentSection.append(line)
                lineCount += 1
                if lineCount > 20 {
                    // Section too long, save and reset
                    sections.append(currentSection.joined(separator: "\n"))
                    inHappyHourSection = false
                    currentSection = []
                }
            }
        }

        if !currentSection.isEmpty && inHappyHourSection {
            sections.append(currentSection.joined(separator: "\n"))
        }

        return sections
    }

    // MARK: - URL Validation

    func isValidVenueURL(_ urlString: String) -> Bool {
        let normalized = normalizeURL(urlString)
        guard let url = URL(string: normalized) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    func normalizeURL(_ urlString: String) -> String {
        var normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            normalized = "https://" + normalized
        }
        return normalized
    }

    // MARK: - Helpers

    private func removePattern(_ pattern: String, from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"),
            ("&apos;", "'"), ("&ndash;", "–"), ("&mdash;", "—"),
            ("&hellip;", "..."), ("&copy;", "©"), ("&reg;", "®")
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Decode numeric entities
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: result),
                   let code = Int(result[range]),
                   let scalar = Unicode.Scalar(code) {
                    let fullRange = Range(match.range, in: result)!
                    result = result.replacingCharacters(in: fullRange, with: String(scalar))
                }
            }
        }
        return result
    }
}

// MARK: - Web Scan Error
enum WebScanError: LocalizedError {
    case invalidURL
    case fetchFailed
    case encodingError
    case noDealsFound
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid website URL."
        case .fetchFailed: return "Failed to load the website."
        case .encodingError: return "Could not read the website content."
        case .noDealsFound: return "No happy hour deals found on the website."
        case .timeout: return "Website request timed out."
        }
    }
}
