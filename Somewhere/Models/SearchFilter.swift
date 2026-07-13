import Foundation
import CoreLocation

// MARK: - Time Filter
enum TimeFilter: String, CaseIterable, Identifiable {
    case now = "now"
    case today = "today"
    case anytime = "anytime"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .now:     return "Right Now"
        case .today:   return "Today"
        case .anytime: return "Anytime"
        }
    }

    var icon: String {
        switch self {
        case .now:     return "clock.fill"
        case .today:   return "calendar"
        case .anytime: return "infinity"
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
    var searchRadius: Double                  // miles (0.25 to 5.0)
    var sortOption: SortOption
    var showOnlyVerified: Bool
    var showOnlyFavorites: Bool
    var searchQuery: String                   // text search in name/description
    var locationQuery: String                 // city or zip; empty = use device location

    static let defaultCategories: Set<DealCategory> = [.food, .drinks]

    static var `default`: SearchFilter {
        SearchFilter(
            categories: defaultCategories,
            venueCategories: [],
            // Default to "Right Now" — this is a happy hour app; users want to see
            // what's happening right now, not what happened yesterday or last weekend.
            timeFilter: .now,
            selectedDays: [],
            searchRadius: 1.0,
            sortOption: .distance,
            showOnlyVerified: false,
            showOnlyFavorites: false,
            searchQuery: "",
            locationQuery: ""
        )
    }

    var isFiltered: Bool {
        categories != Self.defaultCategories ||
        !venueCategories.isEmpty ||
        timeFilter != .now ||
        !selectedDays.isEmpty ||
        showOnlyVerified ||
        showOnlyFavorites ||
        !searchQuery.isEmpty ||
        !locationQuery.isEmpty ||
        searchRadius != 1.0
    }

    var activeFilterCount: Int {
        var count = 0
        if categories != Self.defaultCategories { count += 1 }
        if !venueCategories.isEmpty { count += 1 }
        if timeFilter != .now { count += 1 }
        if !selectedDays.isEmpty { count += 1 }
        if showOnlyVerified { count += 1 }
        if showOnlyFavorites { count += 1 }
        if !locationQuery.isEmpty { count += 1 }
        if searchRadius != 1.0 { count += 1 }
        return count
    }

    func matches(deal: Deal) -> Bool {
        // Category
        if !categories.isEmpty && !categories.contains(deal.category) {
            return false
        }

        // Verified
        if showOnlyVerified && !deal.isVerified {
            return false
        }

        // Time — the single source of truth for time filtering.
        switch timeFilter {
        case .now:
            if !deal.isActiveNow { return false }
        case .today:
            if !deal.days.contains(DayOfWeek.today) { return false }
        case .anytime:
            break
        }

        // Explicit day picks (independent of timeFilter — user may want Anytime + Wed-only).
        if !selectedDays.isEmpty {
            if Set(deal.days).intersection(selectedDays).isEmpty {
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
