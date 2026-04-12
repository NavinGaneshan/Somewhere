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
}

// MARK: - Photo Scan Service
class PhotoScanService {
    static let shared = PhotoScanService()
    private init() {}

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

    func extractDeals(from text: String, venueName: String = "") -> PhotoScanResult {
        let deals = parseDealText(text)
        return PhotoScanResult(
            recognizedText: text,
            extractedDeals: deals,
            confidence: deals.isEmpty ? 0 : 0.7
        )
    }

    func scanImage(_ image: UIImage, venueName: String = "") async throws -> PhotoScanResult {
        let text = try await recognizeText(in: image)
        return extractDeals(from: text, venueName: venueName)
    }

    // MARK: - Text Parsing

    private func parseDealText(_ text: String) -> [ExtractedDeal] {
        var deals: [ExtractedDeal] = []
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Group lines into potential deal blocks
        var currentBlock: [String] = []
        var blocks: [[String]] = []

        for line in lines {
            if isNewDealIndicator(line) && !currentBlock.isEmpty {
                blocks.append(currentBlock)
                currentBlock = [line]
            } else {
                currentBlock.append(line)
            }
        }
        if !currentBlock.isEmpty { blocks.append(currentBlock) }

        // Parse each block
        for block in blocks {
            if let deal = parseDealBlock(block) {
                deals.append(deal)
            }
        }

        // If no structured deals found, try full-text parsing
        if deals.isEmpty {
            if let deal = parseUnstructuredText(text) {
                deals.append(deal)
            }
        }

        return deals
    }

    private func isNewDealIndicator(_ line: String) -> Bool {
        let lower = line.lowercased()
        let indicators = ["happy hour", "specials", "deal", "$", "half off", "50% off",
                         "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                         "daily", "weekday", "weekend"]
        return indicators.contains { lower.contains($0) }
    }

    private func parseDealBlock(_ lines: [String]) -> ExtractedDeal? {
        let fullText = lines.joined(separator: " ")
        let lower = fullText.lowercased()

        // Must look like a deal
        guard isDealText(lower) else { return nil }

        let title = extractTitle(from: lines)
        let description = lines.joined(separator: "\n")
        let days = extractDays(from: lower)
        let (startTime, endTime) = extractTimeRange(from: lower)
        let category = extractCategory(from: lower)

        return ExtractedDeal(
            title: title,
            description: description,
            suggestedCategory: category,
            suggestedDays: days,
            suggestedStartTime: startTime,
            suggestedEndTime: endTime,
            rawText: fullText,
            confidence: calculateConfidence(title: title, days: days, startTime: startTime)
        )
    }

    private func parseUnstructuredText(_ text: String) -> ExtractedDeal? {
        let lower = text.lowercased()
        guard isDealText(lower) else { return nil }

        let days = extractDays(from: lower)
        let (startTime, endTime) = extractTimeRange(from: lower)
        let category = extractCategory(from: lower)

        // Try to find a title line
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let title = lines.first { isDealText($0.lowercased()) } ?? "Happy Hour Special"

        return ExtractedDeal(
            title: title,
            description: text,
            suggestedCategory: category,
            suggestedDays: days.isEmpty ? [.monday, .tuesday, .wednesday, .thursday, .friday] : days,
            suggestedStartTime: startTime,
            suggestedEndTime: endTime,
            rawText: text,
            confidence: 0.5
        )
    }

    private func isDealText(_ text: String) -> Bool {
        let dealKeywords = ["happy hour", "special", "deal", "off", "discount",
                           "$", "half price", "free", "2-for-1", "two for one",
                           "drinks", "appetizer", "food", "beer", "wine", "cocktail"]
        return dealKeywords.contains { text.contains($0) }
    }

    private func extractTitle(from lines: [String]) -> String {
        // First non-empty line that looks like a title
        for line in lines {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count > 3 && cleaned.count < 80 {
                return cleaned
            }
        }
        return "Happy Hour Special"
    }

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
            if let _ = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                days.append(contentsOf: dayList)
            }
        }

        return Array(Set(days))
    }

    private func extractTimeRange(from text: String) -> (start: String, end: String) {
        // Pattern: "3pm-6pm", "3:00 PM - 6:00 PM", "3 to 6pm", etc.
        let pattern = #"(\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\s*(?:-|to|–|until)\s*(\d{1,2}(?::\d{2})?\s*(?:am|pm))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range1 = Range(match.range(at: 1), in: text),
              let range2 = Range(match.range(at: 2), in: text) else {
            return ("16:00", "19:00")  // Default 4pm-7pm
        }

        let time1 = parseTime(String(text[range1]))
        let time2 = parseTime(String(text[range2]))
        return (time1, time2)
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
        // Heuristic: if no AM/PM specified, times < 7 are PM
        if !isPM && !isAM && hour < 7 { hour24 += 12 }

        return String(format: "%02d:%02d", hour24, minute)
    }

    private func extractCategory(from text: String) -> DealCategory {
        let drinkKeywords = ["beer", "wine", "cocktail", "drink", "bar", "shot", "spirits",
                            "margarita", "draft", "pint", "bottle", "liquor"]
        let foodKeywords = ["food", "appetizer", "app", "bite", "eat", "snack", "pizza",
                           "burger", "taco", "wing", "nachos", "menu"]
        let activityKeywords = ["trivia", "game", "bingo", "karaoke", "event", "activity",
                               "live music", "music", "show", "dj"]

        let drinkScore = drinkKeywords.filter { text.contains($0) }.count
        let foodScore = foodKeywords.filter { text.contains($0) }.count
        let activityScore = activityKeywords.filter { text.contains($0) }.count

        if activityScore > foodScore && activityScore > drinkScore { return .activity }
        if foodScore > drinkScore { return .food }
        return .drinks  // Default to drinks for happy hour
    }

    private func calculateConfidence(title: String, days: [DayOfWeek], startTime: String) -> Float {
        var confidence: Float = 0.3
        if !title.isEmpty && title != "Happy Hour Special" { confidence += 0.2 }
        if !days.isEmpty { confidence += 0.25 }
        if startTime != "16:00" { confidence += 0.25 }
        return min(confidence, 1.0)
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
        case .invalidImage: return "Could not process the image."
        case .noTextFound: return "No text was found in the image."
        case .noDealsFound: return "No happy hour deals were detected."
        case .processingFailed: return "Image processing failed."
        }
    }
}
