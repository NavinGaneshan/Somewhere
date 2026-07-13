import Foundation
import CoreLocation

// MARK: - Time Filter
enum TimeFilter: String, CaseIterable, Identifiable {
    case now = "now"
    case tonight = "tonight"
    case thisWeekend = "this_weekend"
    case custom = "custom"
    case anytime = "anytime"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .now: return "Happening Now"
        case .tonight: return "Tonight"
        case .thisWeekend: return "This Weekend"
        case .custom: return "Custom Time"
        case .anytime: return "Anytime"
        }
    }

    var icon: String {
        switch self {
        case .now: return "clock.fill"
        case .tonight: return "moon.fill"
        case .thisWeekend: return "sun.max.fill"
        case .custom: return "calendar"
        case .anytime: return "infinity"
        }
    }

    // Returns (days, startHour, endHour) for the filter
    var filterParams: (days: [DayOfWeek], startHour: Int, endHour: Int)? {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)

        switch self {
        case .now:
            return ([DayOfWeek.today], hour, hour + 1)
        case .tonight:
            let today = DayOfWeek.today
            return ([today], 17, 24) // 5pm to midnight
        case .thisWeekend:
            return ([.friday, .saturday, .sunday], 0, 24)
        case .anytime, .custom:
            return nil
        }
    }
}

// MARK: - Sort Option
enum SortOption: String, CaseIterable, Identifiable {
    case distance = "distance"
    case activeNow = "active_now"
    case newest = "newest"
    case topRated = "top_rated"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .distance: return "Nearest First"
        case .activeNow: return "Active Now"
        case .newest: return "Newest"
        case .topRated: return "Top Rated"
        }
    }
}

// MARK: - Search Filter
struct SearchFilter: Equatable {
    var categories: Set<DealCategory>         // empty = all categories
    var venueCategories: Set<VenueCategory>   // empty = all venue types
    var timeFilter: TimeFilter
    var selectedDays: Set<DayOfWeek>          // empty = all days
    var customStartTime: String               // "HH:mm"
    var customEndTime: String                 // "HH:mm"
    var searchRadius: Double                  // miles (0.25 to 5.0)
    var sortOption: SortOption
    var showOnlyVerified: Bool
    var showOnlyActiveNow: Bool
    var showOnlyFavorites: Bool
    var searchQuery: String                   // text search in name/description
    var locationQuery: String                 // city or zip; empty = use device location

    static let defaultCategories: Set<DealCategory> = [.food, .drinks]

    static var `default`: SearchFilter {
        SearchFilter(
            categories: defaultCategories,
            venueCategories: [],
            timeFilter: .anytime,
            selectedDays: [],
            customStartTime: "17:00",
            customEndTime: "21:00",
            searchRadius: 1.0,
            sortOption: .distance,
            showOnlyVerified: false,
            // Default to only currently-running deals — this is a happy hour app,
            // seeing yesterday's or next weekend's deals in the main list is noise.
            // User can toggle off via the "Now" chip to see everything.
            showOnlyActiveNow: true,
            showOnlyFavorites: false,
            searchQuery: "",
            locationQuery: ""
        )
    }

    static var nowFilter: SearchFilter {
        var f = SearchFilter.default
        f.timeFilter = .now
        f.showOnlyActiveNow = true
        f.sortOption = .distance
        return f
    }

    // "Filtered" means the current state differs from `.default`. Because the default
    // is now `showOnlyActiveNow: true`, turning that flag OFF (to browse all deals)
    // counts as filtering, not on.
    var isFiltered: Bool {
        categories != Self.defaultCategories ||
        !venueCategories.isEmpty ||
        timeFilter != .anytime ||
        !selectedDays.isEmpty ||
        showOnlyVerified ||
        !showOnlyActiveNow ||
        showOnlyFavorites ||
        !searchQuery.isEmpty ||
        !locationQuery.isEmpty ||
        searchRadius != 1.0
    }

    var activeFilterCount: Int {
        var count = 0
        if categories != Self.defaultCategories { count += 1 }
        if !venueCategories.isEmpty { count += 1 }
        if timeFilter != .anytime { count += 1 }
        if !selectedDays.isEmpty { count += 1 }
        if showOnlyVerified { count += 1 }
        if !showOnlyActiveNow { count += 1 }
        if showOnlyFavorites { count += 1 }
        if !locationQuery.isEmpty { count += 1 }
        if searchRadius != 1.0 { count += 1 }
        return count
    }

    // Returns days to filter on (combining timeFilter and selectedDays)
    var effectiveDays: [DayOfWeek] {
        if !selectedDays.isEmpty {
            return Array(selectedDays)
        }
        return timeFilter.filterParams?.days ?? []
    }

    func matches(deal: Deal) -> Bool {
        // Category filter
        if !categories.isEmpty && !categories.contains(deal.category) {
            return false
        }

        // Active now filter
        if showOnlyActiveNow && !deal.isActiveNow {
            return false
        }

        // Verified filter
        if showOnlyVerified && !deal.isVerified {
            return false
        }

        // Days filter
        let days = effectiveDays
        if !days.isEmpty {
            let daysSet = Set(days)
            if Set(deal.days).intersection(daysSet).isEmpty {
                return false
            }
        }

        // Text search
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            if !deal.title.lowercased().contains(query) &&
               !deal.description.lowercased().contains(query) &&
               !deal.venueName.lowercased().contains(query) {
                return false
            }
        }

        return true
    }

    func matches(venue: Venue, from userLocation: CLLocation? = nil) -> Bool {
        // Closed venues never match
        if venue.isPermanentlyClosed { return false }

        // Venue category filter
        if !venueCategories.isEmpty && !venueCategories.contains(venue.category) {
            return false
        }

        // Distance filter
        if let userLocation = userLocation {
            let miles = venue.distanceMiles(from: userLocation)
            if miles > searchRadius { return false }
        }

        return true
    }
}
