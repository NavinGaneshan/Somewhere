import Foundation
import FirebaseFirestore

// MARK: - Deal Category
enum DealCategory: String, Codable, CaseIterable, Identifiable {
    case drinks = "drinks"
    case food = "food"
    case activity = "activity"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .drinks: return "Drinks"
        case .food: return "Food"
        case .activity: return "Activity"
        }
    }

    var icon: String {
        switch self {
        case .drinks:   return "wineglass.fill"
        case .food:     return "fork.knife"
        case .activity: return "ticket.fill"
        }
    }

    var color: String {
        switch self {
        case .drinks: return "#4A90D9"
        case .food: return "#E8A838"
        case .activity: return "#7B68EE"
        }
    }
}

// MARK: - Day of Week
enum DayOfWeek: String, Codable, CaseIterable, Identifiable, Comparable {
    case monday = "monday"
    case tuesday = "tuesday"
    case wednesday = "wednesday"
    case thursday = "thursday"
    case friday = "friday"
    case saturday = "saturday"
    case sunday = "sunday"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        case .sunday: return "Sun"
        }
    }

    var displayName: String {
        switch self {
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        case .sunday: return "Sunday"
        }
    }

    var calendarWeekday: Int {
        switch self {
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        }
    }

    static var today: DayOfWeek {
        let weekday = Calendar.current.component(.weekday, from: Date())
        return DayOfWeek.allCases.first { $0.calendarWeekday == weekday } ?? .monday
    }

    private var sortOrder: Int {
        switch self {
        case .monday: return 0
        case .tuesday: return 1
        case .wednesday: return 2
        case .thursday: return 3
        case .friday: return 4
        case .saturday: return 5
        case .sunday: return 6
        }
    }

    static func < (lhs: DayOfWeek, rhs: DayOfWeek) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: - Deal Source
enum DealSource: String, Codable {
    case photo = "photo"
    case website = "website"
    case manual = "manual"
    case automated = "automated"
    case userContributed = "user_contributed"

    var displayName: String {
        switch self {
        case .photo: return "Photo Scan"
        case .website: return "Website Scan"
        case .manual: return "Manual Entry"
        case .automated: return "Auto-detected"
        case .userContributed: return "User Submitted"
        }
    }
}

// MARK: - Deal Status
enum DealStatus: String, Codable {
    case active = "active"
    case pending = "pending"       // awaiting admin review
    case rejected = "rejected"
    case expired = "expired"
    case unverified = "unverified"
}

// MARK: - Deal Model
struct Deal: Codable, Identifiable, Equatable {
    @DocumentID var firestoreId: String?
    var id: String
    var venueId: String
    var venueName: String          // denormalized for queries
    var venueAddress: String       // denormalized for display
    var venueLatitude: Double      // denormalized for geo queries
    var venueLongitude: Double     // denormalized for geo queries
    var title: String
    var description: String
    var category: DealCategory
    var days: [DayOfWeek]
    var startTime: String          // "HH:mm" 24-hour format
    var endTime: String            // "HH:mm" 24-hour format
    var source: DealSource
    var status: DealStatus
    var isVerified: Bool
    var upvotes: Int
    var downvotes: Int
    var reportCount: Int
    var imageURL: String?          // Firebase Storage URL for scanned photo
    var sourceURL: String?         // Website URL if scraped
    var createdBy: String          // userId
    var createdByName: String?
    var createdAt: Timestamp
    var updatedAt: Timestamp
    var expiresAt: Timestamp?
    var adminNotes: String?

    // MARK: - Computed

    var isActiveNow: Bool {
        let now = Date()
        let currentDay = DayOfWeek.today
        guard days.contains(currentDay) else { return false }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let currentMinutes = hour * 60 + minute

        guard
            let start = timeToMinutes(startTime),
            let end = timeToMinutes(endTime)
        else { return false }

        if start <= end {
            return currentMinutes >= start && currentMinutes < end
        } else {
            // Overnight deal (e.g. 10pm - 2am)
            return currentMinutes >= start || currentMinutes < end
        }
    }

    var formattedTimeRange: String {
        "\(formatTime(startTime)) – \(formatTime(endTime))"
    }

    var formattedDays: String {
        if days.count == 7 { return "Every Day" }
        if days == [.monday, .tuesday, .wednesday, .thursday, .friday] { return "Weekdays" }
        if days == [.saturday, .sunday] { return "Weekends" }
        return days.sorted().map { $0.shortName }.joined(separator: ", ")
    }

    var score: Int { upvotes - downvotes }

    /// True when this deal runs today and its window contains `minutes` (minutes since midnight).
    func isActive(atMinutes minutes: Int) -> Bool {
        guard days.contains(.today) else { return false }
        guard let start = timeToMinutes(startTime), let end = timeToMinutes(endTime) else { return false }
        return start <= end ? (minutes >= start && minutes < end)
                            : (minutes >= start || minutes < end)
    }

    private func timeToMinutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    private func formatTime(_ time: String) -> String {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return time }
        let hour = parts[0]
        let minute = parts[1]
        let period = hour < 12 ? "AM" : "PM"
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return minute == 0 ? "\(displayHour)\(period)" : "\(displayHour):\(String(format: "%02d", minute))\(period)"
    }

    static func == (lhs: Deal, rhs: Deal) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Deal + Firestore
extension Deal {
    static func fromFirestore(_ data: [String: Any], id: String) -> Deal? {
        guard
            let venueId = data["venueId"] as? String,
            let venueName = data["venueName"] as? String,
            let title = data["title"] as? String,
            let description = data["description"] as? String,
            let categoryRaw = data["category"] as? String,
            let category = DealCategory(rawValue: categoryRaw),
            let daysRaw = data["days"] as? [String],
            let startTime = data["startTime"] as? String,
            let endTime = data["endTime"] as? String,
            let sourceRaw = data["source"] as? String,
            let source = DealSource(rawValue: sourceRaw),
            let statusRaw = data["status"] as? String,
            let status = DealStatus(rawValue: statusRaw),
            let createdBy = data["createdBy"] as? String,
            let createdAt = data["createdAt"] as? Timestamp,
            let updatedAt = data["updatedAt"] as? Timestamp
        else { return nil }

        let days = daysRaw.compactMap { DayOfWeek(rawValue: $0) }

        return Deal(
            id: (data["id"] as? String) ?? id,
            venueId: venueId,
            venueName: venueName,
            venueAddress: (data["venueAddress"] as? String) ?? "",
            venueLatitude: (data["venueLatitude"] as? Double) ?? 0,
            venueLongitude: (data["venueLongitude"] as? Double) ?? 0,
            title: title,
            description: description,
            category: category,
            days: days,
            startTime: startTime,
            endTime: endTime,
            source: source,
            status: status,
            isVerified: (data["isVerified"] as? Bool) ?? false,
            upvotes: (data["upvotes"] as? Int) ?? 0,
            downvotes: (data["downvotes"] as? Int) ?? 0,
            reportCount: (data["reportCount"] as? Int) ?? 0,
            imageURL: data["imageURL"] as? String,
            sourceURL: data["sourceURL"] as? String,
            createdBy: createdBy,
            createdByName: data["createdByName"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt,
            expiresAt: data["expiresAt"] as? Timestamp,
            adminNotes: data["adminNotes"] as? String
        )
    }

    func toFirestore() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "venueId": venueId,
            "venueName": venueName,
            "venueAddress": venueAddress,
            "venueLatitude": venueLatitude,
            "venueLongitude": venueLongitude,
            "title": title,
            "description": description,
            "category": category.rawValue,
            "days": days.map { $0.rawValue },
            "startTime": startTime,
            "endTime": endTime,
            "source": source.rawValue,
            "status": status.rawValue,
            "isVerified": isVerified,
            "upvotes": upvotes,
            "downvotes": downvotes,
            "reportCount": reportCount,
            "createdBy": createdBy,
            "createdAt": createdAt,
            "updatedAt": updatedAt
        ]
        if let imageURL = imageURL { dict["imageURL"] = imageURL }
        if let sourceURL = sourceURL { dict["sourceURL"] = sourceURL }
        if let createdByName = createdByName { dict["createdByName"] = createdByName }
        if let expiresAt = expiresAt { dict["expiresAt"] = expiresAt }
        if let adminNotes = adminNotes { dict["adminNotes"] = adminNotes }
        return dict
    }
}

// MARK: - Deals grouped by venue
struct VenueWithDeals: Identifiable {
    let venue: Venue
    let deals: [Deal]
    var id: String { venue.id }
    var isExpanded: Bool = true

    var activeDeals: [Deal] { deals.filter { $0.isActiveNow } }
    var hasActiveDeals: Bool { !activeDeals.isEmpty }
}
