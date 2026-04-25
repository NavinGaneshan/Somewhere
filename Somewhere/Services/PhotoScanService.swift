import Foundation
import Vision
import UIKit

// MARK: - Scan Result
struct PhotoScanResult {
    var recognizedText: String
    var extractedDeals: [ExtractedDeal]
    var confidence: Float
}

// MARK: - Extracted Deal (raw, before user confirmation)
struct ExtractedDeal {
    var title: String
    var description: String
    var suggestedCategory: DealCategory
    var suggestedDays: [DayOfWeek]
    var suggestedStartTime: String
    var suggestedEndTime: String
    var rawText: String
    var confidence: Float
    var sourceURL: String?   // specific page URL or image URL this deal was found on
}

// MARK: - Photo Scan Service
class PhotoScanService {
    static let shared = PhotoScanService()
    private init() {}

    // MARK: - Menu Photo Pre-filter

    /// Fast check: does this image look like a menu, sign, or printed specials board?
    /// Uses a cheap `.fast` OCR pass to count text lines and check for price/food signals.
    /// Returns false for atmosphere shots, food photos, exteriors, etc.
    func looksLikeMenuPhoto(_ image: UIImage) async -> Bool {
        guard let cgImage = image.cgImage else { return false }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.count >= 2 }

                // Not enough text to be a menu
                guard lines.count >= 2 else { continuation.resume(returning: false); return }

                let joined = lines.joined(separator: " ").lowercased()
                let hasPrice = joined.range(of: #"\$\s*\d+"#, options: .regularExpression) != nil
                let hasFoodDrink = Self.allFoodDrinkKeywords.contains(where: { joined.contains($0) })
                let hasSpecialWord = ["special", "happy hour", "menu", "half", "off", "price",
                                      "daily", "tonight", "tonight", "tequila", "margarita",
                                      "monday", "tuesday", "wednesday", "thursday", "friday"].contains(where: { joined.contains($0) })

                // Pass if it has enough text density + at least one signal
                continuation.resume(returning: hasPrice || hasFoodDrink || hasSpecialWord || lines.count >= 10)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - OCR

    func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw ScanError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Deal Extraction

    func extractDeals(from text: String, venueName: String = "", sourceURL: String? = nil) async -> PhotoScanResult {
        // Try LLM first; fall back to regex if key not configured or call fails.
        var deals = await AnthropicService.shared.extractDeals(from: text, sourceURL: sourceURL)
        if deals.isEmpty {
            deals = parseDealText(text)
            if let url = sourceURL {
                deals = deals.map { var d = $0; d.sourceURL = url; return d }
            }
        }
        return PhotoScanResult(
            recognizedText: text,
            extractedDeals: deals,
            confidence: deals.isEmpty ? 0 : 0.85
        )
    }

    func scanImage(_ image: UIImage, venueName: String = "", sourceURL: String? = nil) async throws -> PhotoScanResult {
        let text = try await recognizeText(in: image)
        return await extractDeals(from: text, venueName: venueName, sourceURL: sourceURL)
    }

    // MARK: - Text Parsing

    private func parseDealText(_ text: String) -> [ExtractedDeal] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let isWholeHHMenu = isHappyHourDocument(lines)
        let sections = splitIntoSections(lines, forceHappyHour: isWholeHHMenu)

        var deals: [ExtractedDeal] = []
        var seenTitles = Set<String>()

        var docDays: [DayOfWeek] = []
        var docStart = "16:00"
        var docEnd = "19:00"

        for section in sections {
            let sectionText = section.lines.joined(separator: " ").lowercased()
            let rawSectionDays = extractDays(from: sectionText)
            let (rawStart, rawEnd) = extractTimeRange(from: sectionText)

            if section.isHappyHourSection {
                if docDays.isEmpty, !rawSectionDays.isEmpty { docDays = rawSectionDays }
                if docStart == "16:00", rawStart != "16:00" { docStart = rawStart; docEnd = rawEnd }
            }

            let effectiveDays  = rawSectionDays.isEmpty ? docDays : rawSectionDays
            let effectiveStart = rawStart != "16:00" ? rawStart : docStart
            let effectiveEnd   = rawStart != "16:00" ? rawEnd   : docEnd

            // Rule 2: skip sections with no explicit time/day context at all.
            let hasContext = !effectiveDays.isEmpty || effectiveStart != "16:00"
            guard hasContext || section.isHappyHourSection else { continue }

            // Section headers that name a deal category or day special
            if let headerDeal = parseCategoryHeader(
                section.header, days: effectiveDays, start: effectiveStart, end: effectiveEnd,
                isHHSection: section.isHappyHourSection
            ) {
                let key = headerDeal.title.lowercased()
                if seenTitles.insert(key).inserted { deals.append(headerDeal) }
            }

            for line in section.lines {
                // Food/drink line items
                if let item = parseLineItem(
                    line,
                    sectionText: sectionText,
                    requireDiscountLanguage: !section.isHappyHourSection
                ) {
                    var dealDays  = item.days.isEmpty ? effectiveDays : item.days
                    var dealStart = item.hasTime ? item.startTime : effectiveStart
                    var dealEnd   = item.hasTime ? item.endTime   : effectiveEnd

                    if section.isHappyHourSection {
                        // Section label is sufficient context — fall back to standard HH defaults
                        if dealDays.isEmpty { dealDays = [.monday, .tuesday, .wednesday, .thursday, .friday] }
                    } else {
                        // Rule 2: non-HH sections must have explicit day or time
                        guard !dealDays.isEmpty || dealStart != "16:00" else { continue }
                    }

                    let conf = calculateConfidence(title: item.title, days: dealDays, startTime: dealStart,
                                                   inHHSection: section.isHappyHourSection)
                    guard conf >= 0.5 else { continue }

                    let key = item.title.lowercased()
                    if seenTitles.insert(key).inserted {
                        deals.append(ExtractedDeal(
                            title: item.title,
                            description: String(line.prefix(120)),
                            suggestedCategory: item.category,
                            suggestedDays: dealDays,
                            suggestedStartTime: dealStart,
                            suggestedEndTime: dealEnd,
                            rawText: line,
                            confidence: conf
                        ))
                    }
                }

                // Rule 3: activity events (trivia, karaoke, etc.) — separate path
                if let actDeal = parseActivityLine(
                    line,
                    effectiveDays: effectiveDays,
                    effectiveStart: effectiveStart,
                    effectiveEnd: effectiveEnd
                ) {
                    let key = actDeal.title.lowercased()
                    if seenTitles.insert(key).inserted { deals.append(actDeal) }
                }
            }
        }

        return deals
    }

    // MARK: - Document-level HH detection

    /// True when the top few lines label the whole document as a happy-hour menu.
    private func isHappyHourDocument(_ lines: [String]) -> Bool {
        let header = lines.prefix(5).joined(separator: " ").lowercased()
        return Self.happyHourHeaderKeywords.contains(where: { header.contains($0) })
    }

    // MARK: - Sectioning

    private struct DealSection {
        var header: String
        var lines: [String]
        /// True for sections explicitly labeled as happy hour / specials.
        var isHappyHourSection: Bool
    }

    private static let happyHourHeaderKeywords = [
        // Explicit happy hour references
        "happy hour", "happyhour", "hh menu", "happy hour menu", "hh drinks", "hh food",
        // Specials with context (not just a menu name)
        "drink special", "food special", "bar special", "hh special",
        "late night special", "daily special", "weekend special", "weekday special",
        "today's special", "tonight's special", "daily deals",
        // Generic "specials" — implies a promotion, not just a menu
        "specials",
        // Explicit discount language in header
        "half price", "half off",
        // Time-qualified drink sections (cocktail hour, not just cocktail menu)
        "cocktail hour", "beer hour", "wine hour"
    ]

    private func splitIntoSections(_ lines: [String], forceHappyHour: Bool = false) -> [DealSection] {
        var sections: [DealSection] = []
        var current = DealSection(header: "", lines: [], isHappyHourSection: forceHappyHour)

        for line in lines {
            let lower = line.lowercased()
            if isSectionHeader(lower), !current.lines.isEmpty {
                sections.append(current)
                let isHH = forceHappyHour || Self.happyHourHeaderKeywords.contains(where: { lower.contains($0) })
                current = DealSection(header: line, lines: [line], isHappyHourSection: isHH)
            } else {
                if current.lines.isEmpty { current.header = line }
                current.lines.append(line)
            }
        }
        if !current.lines.isEmpty { sections.append(current) }
        return sections
    }

    private func isSectionHeader(_ lower: String) -> Bool {
        let headerKeywords = [
            "happy hour", "specials", "drink specials", "food specials", "late night",
            "weekday", "weekend", "daily", "brunch", "all day", "from the kitchen",
            "beer & seltzer", "beer and seltzer", "mocktails", "non-alcoholic", "beverages",
            "cocktails", "appetizers", "small plates", "chicken wings", "seafood", "quesadillas",
            "dinner", "lunch", "brunch specials"
        ]
        if headerKeywords.contains(where: { lower.contains($0) }) { return true }
        let dayOnly = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        if lower.count < 40, dayOnly.contains(where: { lower.contains($0) }) { return true }
        return false
    }

    // MARK: - Category Header Deals

    /// Emits a top-level deal for section headers.
    /// - Priced headers ("COCKTAILS $7") always qualify.
    /// - In HH sections, headers with deal/food/drink language qualify even without a price.
    private func parseCategoryHeader(
        _ header: String, days: [DayOfWeek], start: String, end: String,
        isHHSection: Bool = false
    ) -> ExtractedDeal? {
        guard header.count >= 4, header.count <= 80 else { return nil }
        let lower = header.lowercased()

        let hasDollarPrice = header.range(of: Self.dollarPricePattern, options: .regularExpression) != nil
        let hasDiscount = Self.discountPatterns.contains {
            header.range(of: $0, options: .regularExpression) != nil
        }

        let dealWords = ["cocktail", "beer", "wine", "drink", "appetizer", "food", "dinner",
                         "special", "draft", "seltzer", "mocktail", "whiskey", "shot",
                         "fishbowl", "trivia", "karaoke", "brunch", "burger", "taco",
                         "wing", "pizza", "totcho", "friday", "saturday", "monday",
                         "tuesday", "wednesday", "thursday", "sunday"]
        let hasDealWord = dealWords.contains(where: { lower.contains($0) })

        // Require either a price/discount, or (in HH sections) any deal-ish language
        guard hasDollarPrice || hasDiscount || (isHHSection && hasDealWord) else { return nil }

        let effectiveDays = days.isEmpty ? [.monday, .tuesday, .wednesday, .thursday, .friday] : days
        return ExtractedDeal(
            title: abbreviateTitle(header),
            description: header.trimmingCharacters(in: .whitespaces),
            suggestedCategory: extractCategory(from: lower),
            suggestedDays: effectiveDays,
            suggestedStartTime: start,
            suggestedEndTime: end,
            rawText: header,
            confidence: calculateConfidence(title: header, days: effectiveDays, startTime: start,
                                             inHHSection: isHHSection)
        )
    }

    // MARK: - Line-Item Extraction

    private struct LineItem {
        var title: String
        var category: DealCategory
        var days: [DayOfWeek]
        var startTime: String
        var endTime: String
        var hasTime: Bool
    }

    // Explicit discount language — qualifies in any context.
    private static let discountPatterns: [String] = [
        #"(?i)(half[-\s]?off|half[-\s]?price[d]?|\d{1,3}\s*%\s*off|buy\s*one\s*get\s*one|bogo|two\s*for\s*one|2[-\s]?for[-\s]?1)"#,
        #"\d+\s*(?:for|/)\s*\$\s*\d+"#,
        #"\$\s*\d+(?:\.\d{1,2})?\s+off\b"#,
    ]

    // Prices with explicit "$" sign.
    private static let dollarPricePattern  = #"\$\s*\d+(?:\.\d{1,2})?"#

    // Bare trailing prices on printed menus: "CHEESE 24", "SHRIMP 5.00 EA", "DRAFTS 6"
    private static let bareTrailingPrice   = #"(?<!\d)\d{1,3}(?:\.\d{2})?\s*(?:ea|each)?\s*$"#

    private static let drinkKeywords: Set<String> = [
        "beer", "wine", "cocktail", "drink", "shot", "spirits", "margarita", "draft", "pint",
        "whiskey", "tequila", "vodka", "rum", "gin", "bourbon", "scotch", "champagne", "prosecco",
        "seltzer", "cider", "mule", "lemonade", "spritz", "kombucha", "mocktail", "sangria",
        "mimosa", "bellini", "bloody", "daiquiri", "mojito", "martini", "manhattan", "cosmopolitan",
        "lemondrop", "glass", "glasses", "bottle", "bottles", "can", "cans", "draught", "tap",
        "slushie", "soda", "juice", "red bull", "rootbeer", "root beer", "shrub", "creamsicle",
        "aperitivo", "aperol", "spritzer", "hard cider", "hard seltzer", "session", "lager", "ale",
        "ipa", "stout", "porter", "pilsner", "saison", "hazy", "bubbly", "rosé", "rose"
    ]

    private static let foodKeywords: Set<String> = [
        "food", "appetizer", "app", "bite", "snack", "pizza", "burger", "taco", "wing", "nacho",
        "slider", "plate", "bowl", "ribs", "pasta", "chicken", "shrimp", "seafood", "salmon",
        "steak", "salad", "soup", "dip", "artichoke", "mozzarella", "calamari", "quesadilla",
        "guacamole", "risotto", "fries", "cheese", "oyster", "clam", "mussel", "prawn", "crab",
        "lobster", "sushi", "roll", "wrap", "sandwich", "flatbread", "hummus", "bruschetta",
        "charcuterie", "chowder", "bisque", "pork", "meat", "beef", "lamb", "fish", "tuna",
        "scallop", "brisket", "bacon", "sausage", "pepperoni", "anchovies", "tofu", "vegetarian",
        "vegan", "gluten", "dinner", "entree", "starter", "main", "side", "combo"
    ]

    private static let allFoodDrinkKeywords: Set<String> = drinkKeywords.union(foodKeywords)

    private static let activityEventKeywords: Set<String> = [
        "trivia", "karaoke", "bingo", "live music", "open mic", "comedy", "drag show",
        "drag night", "dance night", "dance party", "dance class", "quiz night", "game night",
        "pub quiz", "jazz night", "blues night", "speed dating", "paint night", "paint and sip",
        "sip and paint", "yoga", "bottomless brunch", "brunch party", "dj night", "open stage",
        "open bar", "themed night", "costume night", "trivia night", "karaoke night"
    ]

    private static let skipPhrases = [
        "read more", "click here", "learn more", "see menu", "our menu", "view menu",
        "order now", "reserve a table", "contact us", "follow us", "sign up", "subscribe",
        "consuming raw", "may increase your chances", "tax and gratuity", "prices subject to change",
        "not available for take", "while supplies last"
    ]

    /// Try to extract a single deal from one line.
    /// - Parameter requireDiscountLanguage: if true, bare prices alone don't qualify.
    private func parseLineItem(
        _ line: String, sectionText: String, requireDiscountLanguage: Bool
    ) -> LineItem? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 140 else { return nil }
        let lower = trimmed.lowercased()

        if Self.skipPhrases.contains(where: { lower.contains($0) }) { return nil }

        // 1. Explicit discount language: always qualifies.
        let hasDiscount = Self.discountPatterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }
        if hasDiscount { return buildLineItem(trimmed: trimmed, lower: lower, sectionText: sectionText) }

        if requireDiscountLanguage { return nil }

        // 2. In HH sections: any line with a price qualifies — no keyword check needed.
        let hasDollarPrice = trimmed.range(of: Self.dollarPricePattern, options: .regularExpression) != nil
        let hasBarePrice   = trimmed.range(of: Self.bareTrailingPrice,   options: .regularExpression) != nil

        guard hasDollarPrice || hasBarePrice else { return nil }

        return buildLineItem(trimmed: trimmed, lower: lower, sectionText: sectionText)
    }

    private func buildLineItem(trimmed: String, lower: String, sectionText: String) -> LineItem {
        let title = abbreviateTitle(trimmed)
        let days = extractDays(from: lower)
        let (start, end) = extractTimeRange(from: lower)
        let hasTime = start != "16:00" || end != "19:00"
        let category = extractCategory(from: lower + " " + sectionText)

        return LineItem(title: title, category: category, days: days,
                        startTime: start, endTime: end, hasTime: hasTime)
    }

    // MARK: - Activity Event Parsing (Rule 3)

    /// Emits a deal only when the line explicitly names a bar event (trivia, karaoke, etc.).
    private func parseActivityLine(
        _ line: String,
        effectiveDays: [DayOfWeek],
        effectiveStart: String,
        effectiveEnd: String
    ) -> ExtractedDeal? {
        let lower = line.lowercased()
        guard Self.activityEventKeywords.contains(where: { lower.contains($0) }) else { return nil }

        let lineDays = extractDays(from: lower)
        let (lineStart, lineEnd) = extractTimeRange(from: lower)
        let hasLineTime = lineStart != "16:00"

        let days  = lineDays.isEmpty ? effectiveDays : lineDays
        let start = hasLineTime ? lineStart : effectiveStart
        let end   = hasLineTime ? lineEnd   : effectiveEnd

        // Rule 2: must have explicit time or day
        guard !days.isEmpty || start != "16:00" else { return nil }

        let title = abbreviateTitle(line)
        guard title.count >= 3 else { return nil }

        let conf = calculateConfidence(title: title, days: days, startTime: start)
        guard conf >= 0.5 else { return nil }

        return ExtractedDeal(
            title: title,
            description: String(line.prefix(120)),
            suggestedCategory: .activity,
            suggestedDays: days,
            suggestedStartTime: start,
            suggestedEndTime: end,
            rawText: line,
            confidence: conf
        )
    }

    // MARK: - Title Abbreviation (Rule 4)

    /// Strips prices, discounts, times, and days from a raw line and returns a 2–4 word title.
    private func abbreviateTitle(_ raw: String) -> String {
        var s = raw

        // Strip price and discount patterns
        let stripPatterns: [String] = [
            #"\$\s*\d+(?:\.\d{1,2})?\s*(?:off\b)?"#,          // $6, $2 off
            #"\b\d{1,3}\s*%\s*off\b"#,                          // 20% off
            #"\bhalf[-\s]?off\b"#,                               // half off
            #"\bbogo\b"#,                                         // bogo
            #"\bbuy\s+one[\s\w]*get\s+one\b"#,                  // buy one get one
            #"\b2[-\s]for[-\s]1\b"#,                             // 2 for 1
            #"\btwo\s+for\s+one\b"#,                             // two for one
            #"\b\d+\s*(?:for|\/)\s*\$?\s*\d+"#,                 // 2 for $5
            #"(?<!\d)\d{1,3}(?:\.\d{2})?\s*(?:ea|each)?\s*$"#, // trailing bare price
        ]
        for pattern in stripPatterns {
            s = s.replacingOccurrences(of: pattern, with: " ",
                options: [.regularExpression, .caseInsensitive])
        }

        // Strip time ranges
        s = s.replacingOccurrences(
            of: #"\d{1,2}(?::\d{2})?\s*(?:am|pm)?\s*[-–to]+\s*\d{1,2}(?::\d{2})?\s*(?:am|pm)"#,
            with: " ", options: [.regularExpression, .caseInsensitive])

        // Strip day references
        s = s.replacingOccurrences(
            of: #"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun|weekdays?|weekends?|daily|every\s+day)\b"#,
            with: " ", options: [.regularExpression, .caseInsensitive])

        // Strip leading filler verbs and articles
        s = s.replacingOccurrences(
            of: #"^(enjoy|get|try|order|all|any|select|our|the|a|an)\s+"#,
            with: "", options: [.regularExpression, .caseInsensitive])

        // Collapse punctuation and extra whitespace
        s = s.replacingOccurrences(of: #"[,\-–|•·\+\(\)\[\]]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Take first 4 words
        let words = s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return raw.trimmingCharacters(in: .whitespaces) }
        let capped = words.prefix(4).joined(separator: " ")

        // Title case
        return capped.split(separator: " ").map { w -> String in
            let word = String(w)
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    // MARK: - Helpers

    private func extractDays(from text: String) -> [DayOfWeek] {
        var days: [DayOfWeek] = []
        let dayPatterns: [(String, [DayOfWeek])] = [
            ("every day|daily|7 days", DayOfWeek.allCases),
            ("weekday|mon.?-?fri|mon through fri", [.monday, .tuesday, .wednesday, .thursday, .friday]),
            ("weekend|sat.{0,5}sun|fri.{0,5}sat", [.friday, .saturday, .sunday]),
            ("monday|mon\\b", [.monday]),
            ("tuesday|tue\\b|tues\\b", [.tuesday]),
            ("wednesday|wed\\b", [.wednesday]),
            ("thursday|thu\\b|thur\\b|thurs\\b", [.thursday]),
            ("friday|fri\\b", [.friday]),
            ("saturday|sat\\b", [.saturday]),
            ("sunday|sun\\b", [.sunday])
        ]

        for (pattern, dayList) in dayPatterns {
            if (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text))) != nil {
                days.append(contentsOf: dayList)
            }
        }
        return Array(Set(days))
    }

    private func extractTimeRange(from text: String) -> (start: String, end: String) {
        // Try full range first: "4pm-7pm", "4pm to 7pm"
        let rangePattern = #"(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\s*(?:-|to|–|until)\s*(\d{1,2}(?::\d{2})?\s*(?:am|pm))"#
        if let regex = try? NSRegularExpression(pattern: rangePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r1 = Range(match.range(at: 1), in: text),
           let r2 = Range(match.range(at: 2), in: text) {
            return (parseTime(String(text[r1])), parseTime(String(text[r2])))
        }
        // Fall back to single time: "begins at 9pm", "starting 8pm", "@7pm"
        let singlePattern = #"(?:begins?|starts?|at|@)\s*(\d{1,2}(?::\d{2})?\s*(?:am|pm))"#
        if let regex = try? NSRegularExpression(pattern: singlePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r1 = Range(match.range(at: 1), in: text) {
            let start = parseTime(String(text[r1]))
            return (start, start) // end = start when only one time given
        }
        return ("16:00", "19:00")
    }

    private func parseTime(_ timeStr: String) -> String {
        let cleaned = timeStr.trimmingCharacters(in: .whitespaces).lowercased()
        let isPM = cleaned.contains("pm")
        let isAM = cleaned.contains("am")
        let numberStr = cleaned.replacingOccurrences(of: "[^0-9:]", with: "", options: .regularExpression)
        let parts = numberStr.split(separator: ":").compactMap { Int($0) }

        guard let hour = parts.first else { return "17:00" }
        let minute = parts.count > 1 ? parts[1] : 0

        var hour24 = hour
        if isPM && hour < 12 { hour24 += 12 }
        if isAM && hour == 12 { hour24 = 0 }
        if !isPM && !isAM && hour < 7 { hour24 += 12 }  // heuristic: bare "3" → 3pm

        return String(format: "%02d:%02d", hour24, minute)
    }

    private func extractCategory(from text: String) -> DealCategory {
        let drinkScore  = Self.drinkKeywords.filter { text.contains($0) }.count
        let foodScore   = Self.foodKeywords.filter  { text.contains($0) }.count
        let activityKws = ["trivia", "game", "bingo", "karaoke", "event", "live music", "show", "dj"]
        let actScore    = activityKws.filter { text.contains($0) }.count

        if actScore > foodScore && actScore > drinkScore { return .activity }
        if foodScore > drinkScore { return .food }
        return .drinks
    }

    private func calculateConfidence(title: String, days: [DayOfWeek], startTime: String,
                                     inHHSection: Bool = false) -> Float {
        var c: Float = 0.2
        if !title.isEmpty, title.count >= 3 { c += 0.2 }
        if !days.isEmpty { c += 0.3 }
        if startTime != "16:00" { c += 0.3 }
        // The HH section label itself is a time-frame reference — guarantee the deal passes the gate
        if inHHSection { c = max(c, 0.5) }
        return min(c, 1.0)
    }
}

// MARK: - Scan Error
enum ScanError: LocalizedError {
    case invalidImage
    case noTextFound
    case noDealsFound
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:      return "Could not process the image."
        case .noTextFound:       return "No text was found in the image."
        case .noDealsFound:      return "No happy hour deals were detected."
        case .processingFailed:  return "Image processing failed."
        }
    }
}
