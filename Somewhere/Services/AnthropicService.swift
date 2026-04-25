import Foundation

// MARK: - Anthropic Service
/// Calls the Claude API to extract happy hour deals from raw text.
/// Requests are serialized through an actor to stay under the 50 req/min rate limit.
actor AnthropicService {
    static let shared = AnthropicService()
    private init() {}

    private var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_API_KEY") as? String ?? ""
    }

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-haiku-4-5-20251001"

    // Minimum seconds between consecutive API calls — keeps us well under 50 req/min.
    private let minIntervalSeconds: Double = 1.5
    private var lastCallTime: Date = .distantPast

    private static let systemPrompt = """
    You extract happy hour and daily specials deals from bar/restaurant text. Return ONLY a JSON object — no markdown fences, no explanation before or after.

    INCLUDE a deal when ALL of these are true:
    • It names a food or drink item (or a bar event like trivia/karaoke)
    • It has a price, discount, or offer (e.g. $6, half off, 50% off, 2-for-1, half-priced, complimentary)
    • It is tied to specific days or a time window. If the section is labelled "Happy Hour", "Specials", or a day of the week, use those as context.

    EXCLUDE:
    • Regular full-price menu items with no discount
    • Generic descriptions with no price or offer
    • Standard cocktail/drink menus unless they explicitly reference a special, discount, or time offer

    TITLE: 2–4 words, no prices or times (e.g. "House Margarita", "Chicken Wings", "Trivia Night")
    CATEGORY: "drinks", "food", or "activity"
    DAYS: lowercase array of day names
    TIMES: 24-hour "HH:MM". Default happy hour: startTime "16:00", endTime "19:00"
    CONFIDENCE: 0.0–1.0

    Respond with ONLY this JSON, nothing else:
    {"deals":[{"title":"...","description":"...","category":"drinks","days":["monday"],"startTime":"16:00","endTime":"19:00","confidence":0.85}]}

    If nothing qualifies: {"deals":[]}
    """

    // MARK: - Extract Deals

    func extractDeals(from text: String, sourceURL: String? = nil) async -> [ExtractedDeal] {
        guard !apiKey.isEmpty, apiKey != "YOUR_ANTHROPIC_API_KEY" else { return [] }
        let trimmed = String(text.prefix(8_000))
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // Throttle: wait until minInterval has elapsed since the last call.
        let elapsed = Date().timeIntervalSince(lastCallTime)
        if elapsed < minIntervalSeconds {
            try? await Task.sleep(nanoseconds: UInt64((minIntervalSeconds - elapsed) * 1_000_000_000))
        }
        lastCallTime = Date()

        var userContent = "Extract happy hour deals from this text"
        if let url = sourceURL { userContent += " (source: \(url))" }
        userContent += ":\n\n\(trimmed)"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": Self.systemPrompt,
            "messages": [["role": "user", "content": userContent]]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        // Retry once on 429.
        for attempt in 1...2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return [] }

                if http.statusCode == 429 {
                    if attempt == 1 {
                        print("AnthropicService: rate limited, waiting 5s before retry…")
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        lastCallTime = Date()
                        continue
                    }
                    print("AnthropicService: rate limited after retry, falling back to regex")
                    return []
                }

                if http.statusCode != 200 {
                    print("AnthropicService HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
                    return []
                }

                return parseResponse(data, sourceURL: sourceURL)
            } catch {
                print("AnthropicService error: \(error.localizedDescription)")
                return []
            }
        }
        return []
    }

    // MARK: - Response Parsing

    private func parseResponse(_ data: Data, sourceURL: String?) -> [ExtractedDeal] {
        guard
            let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = outer["content"] as? [[String: Any]],
            let rawText = content.first?["text"] as? String
        else { return [] }

        // Extract just the {...} block — ignore any text before/after.
        guard
            let jsonStart = rawText.range(of: "{"),
            let jsonEnd   = rawText.range(of: "}", options: .backwards)
        else {
            print("AnthropicService: no JSON object in response: \(rawText.prefix(120))")
            return []
        }
        let jsonString = String(rawText[jsonStart.lowerBound...jsonEnd.upperBound])

        guard
            let jsonData  = jsonString.data(using: .utf8),
            let parsed    = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let dealsArr  = parsed["deals"] as? [[String: Any]]
        else {
            print("AnthropicService: failed to parse JSON: \(rawText.prefix(200))")
            return []
        }

        return dealsArr.compactMap { parseDeal($0, sourceURL: sourceURL) }
    }

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
