import Foundation
import CoreLocation
import FirebaseFirestore

// MARK: - PVA Grid Cell
/// Represents a geographic grid cell used for Progressive Venue Addition.
/// The world is divided into cells approximately 0.5 miles on each side.
struct PVACell: Codable, Identifiable {
    var id: String              // Hash key from lat/lng grid
    var centerLatitude: Double
    var centerLongitude: Double
    var lastSearchedAt: Timestamp?
    var venueCount: Int         // Number of venues found in this cell
    var searchCount: Int        // Times this cell has been searched
    var isStale: Bool           // Needs re-search
    var createdAt: Timestamp

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    var age: TimeInterval? {
        guard let lastSearched = lastSearchedAt else { return nil }
        return Date().timeIntervalSince(lastSearched.dateValue())
    }

    var ageDays: Double? {
        guard let age = age else { return nil }
        return age / 86400
    }
}

// MARK: - PVA Configuration (admin-controllable)
struct PVAConfig: Codable {
    // Grid settings
    var cellSizeMiles: Double           // Size of each PVA grid cell (default 0.5 miles)
    var searchRadiusMiles: Double       // How far around user to search (default 1.0 mile)

    // Staleness settings
    var cellStaleDays: Int              // Days before a cell is considered stale (default 30)
    var venueReverifyDays: Int          // Days before re-verifying venue is still open (default 90)

    // API throttling
    var maxNewVenuesPerSearch: Int      // Max new venues to process per user search (default 50)
    var maxPlacesApiCallsPerDay: Int    // Daily limit on Places API calls (default 500)
    var dailyApiCallCount: Int          // Current count (resets at midnight)
    var apiCallsResetAt: Timestamp?

    // Feature flags
    var pvaModeEnabled: Bool            // Master switch for PVA
    var autoScanWebsites: Bool          // Auto-scan new venue websites for deals
    var autoScanEnabled: Bool           // AI auto-detection of deals
    var userSubmissionsEnabled: Bool    // Allow users to add deals
    var requireApprovalForUserDeals: Bool // Deals need admin approval

    // Scan settings
    var scanDelaySeconds: Double        // Delay between venue scans (rate limiting)
    var maxScanAttemptsPerVenue: Int    // Max attempts before giving up on a venue

    static var `default`: PVAConfig {
        PVAConfig(
            cellSizeMiles: 0.5,
            searchRadiusMiles: 1.0,
            cellStaleDays: 30,
            venueReverifyDays: 90,
            maxNewVenuesPerSearch: 50,
            maxPlacesApiCallsPerDay: 500,
            dailyApiCallCount: 0,
            apiCallsResetAt: nil,
            pvaModeEnabled: true,
            autoScanWebsites: true,
            autoScanEnabled: true,
            userSubmissionsEnabled: true,
            requireApprovalForUserDeals: true,
            scanDelaySeconds: 1.0,
            maxScanAttemptsPerVenue: 3
        )
    }

    func toFirestore() -> [String: Any] {
        var dict: [String: Any] = [
            "cellSizeMiles": cellSizeMiles,
            "searchRadiusMiles": searchRadiusMiles,
            "cellStaleDays": cellStaleDays,
            "venueReverifyDays": venueReverifyDays,
            "maxNewVenuesPerSearch": maxNewVenuesPerSearch,
            "maxPlacesApiCallsPerDay": maxPlacesApiCallsPerDay,
            "dailyApiCallCount": dailyApiCallCount,
            "pvaModeEnabled": pvaModeEnabled,
            "autoScanWebsites": autoScanWebsites,
            "autoScanEnabled": autoScanEnabled,
            "userSubmissionsEnabled": userSubmissionsEnabled,
            "requireApprovalForUserDeals": requireApprovalForUserDeals,
            "scanDelaySeconds": scanDelaySeconds,
            "maxScanAttemptsPerVenue": maxScanAttemptsPerVenue
        ]
        if let apiCallsResetAt = apiCallsResetAt {
            dict["apiCallsResetAt"] = apiCallsResetAt
        }
        return dict
    }
}

// MARK: - PVA Stats (for admin dashboard)
struct PVAStats {
    var totalCells: Int
    var staleCells: Int
    var cellsSearchedToday: Int
    var totalVenuesInDB: Int
    var venuesPendingScan: Int
    var venuesScanned: Int
    var venuesClosed: Int
    var apiCallsToday: Int
    var apiCallsLimit: Int
    var newVenuesToday: Int
    var newDealsToday: Int

    var apiUsagePercent: Double {
        guard apiCallsLimit > 0 else { return 0 }
        return Double(apiCallsToday) / Double(apiCallsLimit) * 100
    }

    static var empty: PVAStats {
        PVAStats(
            totalCells: 0, staleCells: 0, cellsSearchedToday: 0,
            totalVenuesInDB: 0, venuesPendingScan: 0, venuesScanned: 0,
            venuesClosed: 0, apiCallsToday: 0, apiCallsLimit: 500,
            newVenuesToday: 0, newDealsToday: 0
        )
    }
}

// MARK: - Search Log (for analytics)
struct SearchLog: Codable, Identifiable {
    var id: String
    var userId: String?
    var latitude: Double
    var longitude: Double
    var radius: Double
    var newVenuesFound: Int
    var dealsReturned: Int
    var apiCallsMade: Int
    var searchDuration: Double      // seconds
    var timestamp: Timestamp
    var cellsSearched: [String]
}
