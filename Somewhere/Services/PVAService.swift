import Foundation
import CoreLocation
import FirebaseFirestore

// MARK: - PVA Result
struct PVAResult {
    var newVenuesAdded: Int = 0
    var venuesAlreadyKnown: Int = 0
    var venuesMarkedClosed: Int = 0
    var apiCallsMade: Int = 0
    var cellsProcessed: [String] = []
    var error: Error?
}

// MARK: - Progressive Venue Addition Service
/// Core engine that manages the intelligent discovery and deduplication of venues.
/// Uses a grid-based cell system to avoid redundant API calls.
actor PVAService {
    static let shared = PVAService()

    private let firestoreService = FirestoreService.shared
    private let placesService = PlacesService.shared

    // Grid cell size in degrees (approx 0.5 miles at mid-latitudes)
    private let cellSizeDegrees: Double = 0.007246  // ~0.5 miles

    private var isRunning = false

    private init() {}

    // MARK: - Main PVA Entry Point

    /// Called when a user searches a location. Finds and ingests new venues.
    func processSearch(
        coordinate: CLLocationCoordinate2D,
        radiusMiles: Double = 1.0,
        userId: String?
    ) async throws -> PVAResult {
        guard !isRunning else {
            return PVAResult()  // Already running, skip
        }

        isRunning = true
        defer { isRunning = false }

        var result = PVAResult()
        let startTime = Date()

        // Get PVA config
        let config = (try? await firestoreService.getPVAConfig()) ?? PVAConfig.default
        guard config.pvaModeEnabled else { return result }

        // Check daily API limit
        if config.dailyApiCallCount >= config.maxPlacesApiCallsPerDay {
            return result  // Over limit, skip
        }

        // Determine which grid cells to search
        let cellIds = gridCellIds(for: coordinate, radiusMiles: radiusMiles)
        result.cellsProcessed = cellIds

        // Get all existing venues in the area first (to avoid redundant queries)
        let bounds = coordinate.boundingBox(radiusMiles: radiusMiles)
        let existingVenues = try await firestoreService.getVenuesInBounds(
            minLat: bounds.minLat, maxLat: bounds.maxLat,
            minLng: bounds.minLng, maxLng: bounds.maxLng
        )
        let existingPlaceIds = Set(existingVenues.map { $0.placeId })

        // Process each cell that needs searching
        var newVenueCount = 0
        for cellId in cellIds {
            let cell = try? await firestoreService.getPVACell(id: cellId)
            let cellCenter = cellCenter(for: cellId)

            // Skip if cell was recently searched
            if let cell = cell,
               let ageDays = cell.ageDays,
               ageDays < Double(config.cellStaleDays) {
                continue
            }

            // Search Google Places for this cell
            do {
                let searchResult = try await searchCell(
                    center: cellCenter,
                    radiusMeters: Int(cellSizeDegrees * 111_320 * 1.5),
                    existingPlaceIds: existingPlaceIds,
                    config: config
                )

                newVenueCount += searchResult.added
                result.newVenuesAdded += searchResult.added
                result.venuesAlreadyKnown += searchResult.existing
                result.venuesMarkedClosed += searchResult.closed
                result.apiCallsMade += searchResult.apiCalls

                // Update cell record
                let updatedCell = PVACell(
                    id: cellId,
                    centerLatitude: cellCenter.latitude,
                    centerLongitude: cellCenter.longitude,
                    lastSearchedAt: Timestamp(),
                    venueCount: searchResult.added + searchResult.existing,
                    searchCount: (cell?.searchCount ?? 0) + 1,
                    isStale: false,
                    createdAt: cell?.createdAt ?? Timestamp()
                )
                try? await firestoreService.savePVACell(updatedCell)

                // Increment API call counter
                for _ in 0..<searchResult.apiCalls {
                    try? await firestoreService.incrementApiCallCount()
                }

                // Stop if we've hit our new-venue limit
                if newVenueCount >= config.maxNewVenuesPerSearch { break }
            } catch {
                result.error = error
            }
        }

        // Log search
        let log = SearchLog(
            id: UUID().uuidString,
            userId: userId,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: radiusMiles,
            newVenuesFound: result.newVenuesAdded,
            dealsReturned: 0,
            apiCallsMade: result.apiCallsMade,
            searchDuration: Date().timeIntervalSince(startTime),
            timestamp: Timestamp(),
            cellsSearched: result.cellsProcessed
        )
        try? await firestoreService.logSearch(log)

        return result
    }

    // MARK: - Cell Search

    private struct CellSearchResult {
        var added: Int = 0
        var existing: Int = 0
        var closed: Int = 0
        var apiCalls: Int = 0
    }

    private func searchCell(
        center: CLLocationCoordinate2D,
        radiusMeters: Int,
        existingPlaceIds: Set<String>,
        config: PVAConfig
    ) async throws -> CellSearchResult {
        var result = CellSearchResult()
        var pageToken: String? = nil
        var pageCount = 0
        let maxPages = 3  // Google Places returns up to 60 results (20 per page)

        repeat {
            let (venues, nextToken) = try await placesService.searchNearbyVenues(
                location: center,
                radiusMeters: radiusMeters,
                pageToken: pageToken
            )
            result.apiCalls += 1
            pageToken = nextToken
            pageCount += 1

            for placeVenue in venues {
                if placeVenue.isPermanentlyClosed {
                    // Check if we have this venue and mark it closed
                    if existingPlaceIds.contains(placeVenue.placeId) {
                        // Find and mark closed
                        await markExistingVenueClosed(placeId: placeVenue.placeId)
                        result.closed += 1
                    }
                    continue
                }

                if existingPlaceIds.contains(placeVenue.placeId) {
                    result.existing += 1
                    continue
                }

                // New venue - add to database
                await addNewVenue(from: placeVenue)
                result.added += 1

                if result.added >= config.maxNewVenuesPerSearch {
                    return result
                }
            }

            // Delay between pages to respect rate limits
            if pageToken != nil {
                try await Task.sleep(nanoseconds: UInt64(config.scanDelaySeconds * 1_000_000_000))
            }
        } while pageToken != nil && pageCount < maxPages

        return result
    }

    private func addNewVenue(from placeVenue: PlacesVenue) async {
        let venueId = UUID().uuidString
        let cellIds = gridCellIds(
            for: CLLocationCoordinate2D(latitude: placeVenue.latitude, longitude: placeVenue.longitude),
            radiusMiles: 0.3
        )

        // Parse address components
        let addressParts = placeVenue.address.components(separatedBy: ", ")

        let venue = Venue(
            id: venueId,
            name: placeVenue.name,
            address: addressParts.first ?? placeVenue.address,
            city: addressParts.count > 1 ? addressParts[1] : "",
            state: addressParts.count > 2 ? String(addressParts[2].prefix(2)) : "",
            zipCode: "",
            latitude: placeVenue.latitude,
            longitude: placeVenue.longitude,
            placeId: placeVenue.placeId,
            phone: placeVenue.phone,
            website: placeVenue.website,
            category: placeVenue.venueCategory,
            isPermanentlyClosed: false,
            scanStatus: .pending,
            lastScanned: nil,
            lastVerified: nil,
            dealCount: 0,
            rating: placeVenue.rating,
            priceLevel: placeVenue.priceLevel,
            photoReference: placeVenue.photoReference,
            createdAt: Timestamp(),
            updatedAt: Timestamp(),
            createdBy: nil,
            searchCellIds: cellIds
        )

        try? await firestoreService.saveVenue(venue)
    }

    private func markExistingVenueClosed(placeId: String) async {
        // Find venue by place ID and mark as closed
        do {
            let snapshot = try await firestoreService.venuesRef
                .whereField("placeId", isEqualTo: placeId)
                .limit(to: 1)
                .getDocuments()
            if let doc = snapshot.documents.first {
                try? await firestoreService.markVenueClosed(id: doc.documentID)
            }
        } catch {
            print("Error marking venue closed: \(error)")
        }
    }

    // MARK: - Grid Helpers

    /// Generate grid cell IDs covering a circular area
    func gridCellIds(
        for coordinate: CLLocationCoordinate2D,
        radiusMiles: Double
    ) -> [String] {
        let radiusDegrees = radiusMiles / 69.0  // 1 degree lat ≈ 69 miles
        var cells: [String] = []

        let latSteps = Int(ceil(radiusDegrees * 2 / cellSizeDegrees)) + 1
        let lngSteps = Int(ceil(radiusDegrees * 2 / cellSizeDegrees)) + 1

        let startLat = coordinate.latitude - radiusDegrees
        let startLng = coordinate.longitude - radiusDegrees

        for i in 0...latSteps {
            for j in 0...lngSteps {
                let lat = startLat + Double(i) * cellSizeDegrees
                let lng = startLng + Double(j) * cellSizeDegrees
                let cellCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                if coordinate.distance(to: cellCoord) <= radiusMiles * 1609.34 {
                    cells.append(cellId(for: cellCoord))
                }
            }
        }
        return Array(Set(cells))  // Deduplicate
    }

    func cellId(for coordinate: CLLocationCoordinate2D) -> String {
        let latIndex = Int(floor(coordinate.latitude / cellSizeDegrees))
        let lngIndex = Int(floor(coordinate.longitude / cellSizeDegrees))
        return "cell_\(latIndex)_\(lngIndex)"
    }

    func cellCenter(for cellId: String) -> CLLocationCoordinate2D {
        let parts = cellId.split(separator: "_")
        guard parts.count == 3,
              let latIndex = Double(parts[1]),
              let lngIndex = Double(parts[2]) else {
            return CLLocationCoordinate2D()
        }
        return CLLocationCoordinate2D(
            latitude: (latIndex + 0.5) * cellSizeDegrees,
            longitude: (lngIndex + 0.5) * cellSizeDegrees
        )
    }

    // MARK: - Stale venue verification

    /// Re-verify venues that haven't been checked recently
    func reverifyStaleVenues(olderThanDays days: Int = 90, limit: Int = 10) async {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let cutoff = Timestamp(date: cutoffDate)

        do {
            let snapshot = try await firestoreService.venuesRef
                .whereField("isPermanentlyClosed", isEqualTo: false)
                .whereField("lastVerified", isLessThan: cutoff)
                .limit(to: limit)
                .getDocuments()

            for doc in snapshot.documents {
                guard let venue = Venue.fromFirestore(doc.data(), id: doc.documentID) else { continue }
                let details = try? await placesService.getPlaceDetails(placeId: venue.placeId)
                if details?.isPermanentlyClosed == true {
                    try? await firestoreService.markVenueClosed(id: venue.id)
                } else {
                    try? await firestoreService.updateVenueField(
                        id: venue.id,
                        field: "lastVerified",
                        value: Timestamp()
                    )
                }
                try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s delay
            }
        } catch {
            print("Error reverifying venues: \(error)")
        }
    }
}
