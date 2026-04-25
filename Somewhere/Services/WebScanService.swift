import Foundation
import UIKit

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

        // Skip binary/PDF responses — they can't be parsed as HTML text
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        let binaryTypes = ["application/pdf", "application/octet-stream",
                           "application/zip", "image/"]
        if binaryTypes.contains(where: { contentType.hasPrefix($0) }) {
            throw WebScanError.fetchFailed
        }

        // Also detect raw PDF bytes regardless of Content-Type header
        if data.prefix(5) == Data("%PDF-".utf8) {
            throw WebScanError.fetchFailed
        }

        guard let html = String(data: data, encoding: .utf8) ??
                         String(data: data, encoding: .isoLatin1) else {
            throw WebScanError.encodingError
        }

        return html
    }

    // MARK: - Scan for Deals

    private static let linkKeywordRegex = #"(?i)(menu|happy.?hour|happyhour|specials?|deals?|drinks?|food|cocktails?)"#
    private static let maxLinkedPages = 3
    private static let maxOCRImages = 5

    /// Fetches the venue website, follows links that look like menu / happy-hour / specials pages,
    /// and OCRs any images that look like menus/specials. Returns deals tagged with the specific
    /// page or image URL they were found on.
    func scanForDeals(url: String) async throws -> WebScanResult {
        let normalizedURL = normalizeURL(url)
        guard let rootURL = URL(string: normalizedURL) else {
            throw WebScanError.invalidURL
        }

        var visitedPages = Set<String>()
        var imageURLs = Set<String>()
        var allDeals: [ExtractedDeal] = []
        var aggregatedText = ""
        var mainHTML = ""

        // 1. Main page — extract deals tagged with the root URL.
        do {
            mainHTML = try await fetchWebsite(url: normalizedURL)
            visitedPages.insert(rootURL.absoluteString)
            let mainText = extractText(from: mainHTML)
            aggregatedText += section("main", mainText)
            imageURLs.formUnion(extractImageURLs(from: mainHTML, baseURL: rootURL))
            let mainDeals = await PhotoScanService.shared
                .extractDeals(from: mainText, sourceURL: normalizedURL).extractedDeals
            allDeals.append(contentsOf: mainDeals)
        } catch {
            throw error
        }

        // 2. Follow up to N links that look menu/happy-hour-ish.
        let candidateLinks = extractCandidateLinks(from: mainHTML, baseURL: rootURL, limit: Self.maxLinkedPages)
        for link in candidateLinks {
            guard !visitedPages.contains(link.absoluteString) else { continue }
            visitedPages.insert(link.absoluteString)
            do {
                let html = try await fetchWebsite(url: link.absoluteString)
                let pageText = extractText(from: html)
                aggregatedText += section(link.lastPathComponent, pageText)
                imageURLs.formUnion(extractImageURLs(from: html, baseURL: link))
                let pageDeals = await PhotoScanService.shared
                    .extractDeals(from: pageText, sourceURL: link.absoluteString).extractedDeals
                allDeals.append(contentsOf: pageDeals)
            } catch {
                continue
            }
        }

        // 3. OCR up to N images prioritized by menu-ish filenames/paths.
        let priorityImages = imageURLs
            .sorted { imageMenuScore($0) > imageMenuScore($1) }
            .prefix(Self.maxOCRImages)

        for imageURLString in priorityImages {
            guard imageMenuScore(imageURLString) > 0 else { break }
            guard let imageURL = URL(string: imageURLString) else { continue }
            do {
                let (data, _) = try await session.data(from: imageURL)
                guard let image = UIImage(data: data) else { continue }
                let imgText = try await PhotoScanService.shared.recognizeText(in: image)
                if !imgText.isEmpty {
                    aggregatedText += section("img:\(imageURL.lastPathComponent)", imgText)
                    let imgDeals = await PhotoScanService.shared
                        .extractDeals(from: imgText, sourceURL: imageURLString).extractedDeals
                    allDeals.append(contentsOf: imgDeals)
                }
            } catch {
                continue
            }
        }

        return WebScanResult(
            url: url,
            htmlContent: mainHTML,
            extractedText: aggregatedText,
            extractedDeals: allDeals
        )
    }

    private func section(_ label: String, _ body: String) -> String {
        guard !body.isEmpty else { return "" }
        return "\n\n=== \(label) ===\n\(body)"
    }

    // MARK: - Link + Image Extraction

    /// Finds `<a href="...">visible text</a>` pairs whose href or text hints at a menu / happy-hour / specials page.
    private func extractCandidateLinks(from html: String, baseURL: URL, limit: Int) -> [URL] {
        let pattern = #"<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)

        var seen = Set<String>()
        var results: [URL] = []
        for match in matches {
            guard
                let hrefRange = Range(match.range(at: 1), in: html),
                let textRange = Range(match.range(at: 2), in: html)
            else { continue }
            let href = String(html[hrefRange])
            let linkText = stripTags(String(html[textRange]))

            // Score on both href and visible text.
            let combined = "\(href) \(linkText)"
            guard combined.range(of: Self.linkKeywordRegex, options: .regularExpression) != nil else { continue }

            guard let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL else { continue }
            // Only follow http(s) on the same host.
            guard resolved.scheme?.hasPrefix("http") == true else { continue }
            guard resolved.host == baseURL.host else { continue }

            let key = resolved.absoluteString
            if seen.insert(key).inserted {
                results.append(resolved)
                if results.count >= limit { break }
            }
        }
        return results
    }

    /// Extracts all `<img src="...">` URLs resolved against baseURL.
    private func extractImageURLs(from html: String, baseURL: URL) -> Set<String> {
        let pattern = #"<img\s+[^>]*src\s*=\s*["']([^"']+)["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)

        var results = Set<String>()
        for match in matches {
            guard let srcRange = Range(match.range(at: 1), in: html) else { continue }
            let src = String(html[srcRange])
            guard let resolved = URL(string: src, relativeTo: baseURL)?.absoluteURL else { continue }
            guard resolved.scheme?.hasPrefix("http") == true else { continue }
            results.insert(resolved.absoluteString)
        }
        return results
    }

    /// Higher score = more likely to be a menu/specials image.
    private func imageMenuScore(_ urlString: String) -> Int {
        let lower = urlString.lowercased()
        var score = 0
        for keyword in ["menu", "happy-hour", "happyhour", "happy_hour", "specials", "special", "drink", "cocktail", "food"] {
            if lower.contains(keyword) { score += 1 }
        }
        return score
    }

    private func stripTags(_ html: String) -> String {
        removePattern(#"<[^>]+>"#, from: html)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - URL Validation

    func isValidVenueURL(_ urlString: String) -> Bool {
        let normalized = normalizeURL(urlString)
        guard let url = URL(string: normalized) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    func normalizeURL(_ urlString: String) -> String {
        var normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("http://") {
            normalized = "https://" + normalized.dropFirst("http://".count)
        } else if !normalized.hasPrefix("https://") {
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
