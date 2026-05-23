import Foundation
import FirebaseFunctions

// MARK: - Anthropic Service (Cloud Function wrapper)
/// Used to call Claude directly with a hard-coded API key. The key has been moved to
/// the `extractDealsFromText` Cloud Function — this type stays as a thin wrapper so
/// callers (`WebScanService`, `PhotoScanService`, `PVAService`) don't have to change.
///
/// All deal-extraction LLM calls now flow through Firebase Cloud Functions, which
/// authenticates the caller (Firebase Auth) and holds the Anthropic key server-side.
actor AnthropicService {
    static let shared = AnthropicService()
    private init() {}

    private lazy var functions = Functions.functions()

    /// Sends text to the server-side `extractDealsFromText` callable and returns
    /// the parsed deals. Returns `[]` on any failure so callers can fall back to
    /// their local regex parsers.
    func extractDeals(from text: String, sourceURL: String? = nil) async -> [ExtractedDeal] {
        let trimmed = String(text.prefix(8_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var payload: [String: Any] = ["text": trimmed]
        if let sourceURL { payload["sourceURL"] = sourceURL }

        do {
            let result = try await functions.httpsCallable("extractDealsFromText").call(payload)
            guard let dict = result.data as? [String: Any],
                  let dealsArr = dict["extractedDeals"] as? [[String: Any]] else {
                return []
            }
            return dealsArr.compactMap { parseDeal($0, sourceURL: sourceURL) }
        } catch {
            print("AnthropicService.extractDeals failed: \(error.localizedDescription)")
            return []
        }
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
