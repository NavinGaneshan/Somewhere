import Foundation
import FirebaseFunctions

// MARK: - Web Scan Result
struct WebScanResult {
    var url: String
    var extractedDeals: [ExtractedDeal]
    var isPermanentlyClosed: Bool
    var error: Error?
}

// MARK: - Web Scan Service
/// Used to call Firecrawl + Claude directly from the device. Both API keys now live
/// behind the `scanWebsite` Cloud Function — this stays as a thin wrapper so callers
/// (`PVAService`, `AddDealViewModel`) don't have to change.
class WebScanService {
    static let shared = WebScanService()
    private init() {}

    private lazy var functions = Functions.functions()

    // MARK: - Scan for Deals

    /// Calls the server-side `scanWebsite` callable. The Cloud Function fetches the
    /// page (and up to 3 deal-relevant subpages) via Firecrawl, then runs the combined
    /// markdown through Claude for extraction.
    func scanForDeals(url: String) async throws -> WebScanResult {
        let normalizedURL = normalizeURL(url)
        guard isValidVenueURL(normalizedURL) else { throw WebScanError.invalidURL }

        do {
            let result = try await functions
                .httpsCallable("scanWebsite")
                .call(["url": normalizedURL])

            guard let dict = result.data as? [String: Any] else {
                throw WebScanError.fetchFailed
            }

            let isClosed = dict["isPermanentlyClosed"] as? Bool ?? false
            let returnedURL = dict["url"] as? String ?? normalizedURL
            let dealsArr = dict["extractedDeals"] as? [[String: Any]] ?? []
            let deals = dealsArr.compactMap { parseDeal($0, sourceURL: returnedURL) }

            return WebScanResult(
                url: url,
                extractedDeals: deals,
                isPermanentlyClosed: isClosed
            )
        } catch let error as NSError where error.domain == FunctionsErrorDomain {
            switch FunctionsErrorCode(rawValue: error.code) {
            case .resourceExhausted:
                throw WebScanError.quotaExceeded
            case .failedPrecondition:
                throw WebScanError.missingAPIKey
            case .deadlineExceeded:
                throw WebScanError.timeout
            default:
                print("WebScanService Functions error \(error.code): \(error.localizedDescription)")
                throw WebScanError.fetchFailed
            }
        }
    }

    // MARK: - URL Helpers

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

    // MARK: - Deal Parsing

    private func parseDeal(_ dict: [String: Any], sourceURL: String?) -> ExtractedDeal? {
        guard let title = dict["title"] as? String, !title.isEmpty else { return nil }

        let description = dict["description"] as? String ?? title
        let categoryStr = dict["category"] as? String ?? "drinks"
        let daysArr     = dict["days"] as? [String] ?? []
        let startTime   = dict["startTime"] as? String ?? "16:00"
        let endTime     = dict["endTime"] as? String ?? "19:00"
        let confidence  = (dict["confidence"] as? Double).map { Float($0) } ?? 0.75

        let category: DealCategory
        switch categoryStr.lowercased() {
        case "food":     category = .food
        case "activity": category = .activity
        default:         category = .drinks
        }

        let days: [DayOfWeek] = daysArr.compactMap {
            switch $0.lowercased() {
            case "monday":    return .monday
            case "tuesday":   return .tuesday
            case "wednesday": return .wednesday
            case "thursday":  return .thursday
            case "friday":    return .friday
            case "saturday":  return .saturday
            case "sunday":    return .sunday
            default:          return nil
            }
        }

        return ExtractedDeal(
            title: title,
            description: description,
            suggestedCategory: category,
            suggestedDays: days,
            suggestedStartTime: startTime,
            suggestedEndTime: endTime,
            rawText: description,
            confidence: confidence,
            sourceURL: sourceURL
        )
    }
}

// MARK: - Web Scan Error
enum WebScanError: LocalizedError {
    case invalidURL
    case fetchFailed
    case encodingError
    case noDealsFound
    case timeout
    case missingAPIKey
    case quotaExceeded

    var errorDescription: String? {
        switch self {
        case .invalidURL:      return "Invalid website URL."
        case .fetchFailed:     return "Failed to load the website."
        case .encodingError:   return "Could not read the website content."
        case .noDealsFound:    return "No happy hour deals found on the website."
        case .timeout:         return "Website request timed out."
        case .missingAPIKey:   return "Scan service is not configured. Contact support."
        case .quotaExceeded:   return "Scan quota exceeded. Try again later."
        }
    }
}
