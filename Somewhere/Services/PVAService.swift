import Foundation
import CoreLocation
import FirebaseFirestore
import FirebaseFunctions
import UIKit

// MARK: - PVA Result
struct PVAResult {
    var newVenuesAdded: Int = 0
    var venuesAlreadyKnown: Int = 0
    var venuesMarkedClosed: Int = 0
    var apiCallsMade: Int = 0
    var cellsProcessed: [String] = []
    var error: Error?
}

// MARK: - Auto-Scan Concurrency Limiter
/// Caps how many venue auto-scans can run concurrently.
///
/// When PVA discovers a batch of new venues (e.g. 12 in one search), firing
/// autoScanVenue for all of them at once produces 12 simultaneous
/// httpsCallable requests to `scanWebsite`. The Firebase Functions SDK's
/// GTMSessionFetcher chokes on the burst and starts sending requests
/// without auth/App-Check tokens — the server responds UNAUTHENTICATED and
/// none of the calls even show up in `firebase functions:log`.
///
/// Serializing to 3 concurrent scans keeps every callable request properly
/// authenticated. Total wall-clock is barely affected because Firecrawl +
/// Claude on each venue take 30–90s regardless.
private actor AutoScanLimiter {
    static let shared = AutoScanLimiter()
    private let maxConcurrent = 3
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        self.available = maxConcurrent
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        } else {
            available += 1
        }
    }
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
        print("PVA processSearch start: coord=\(coordinate.latitude),\(coordinate.longitude) radius=\(radiusMiles)mi pvaEnabled=\(config.pvaModeEnabled) apiCalls=\(config.dailyApiCallCount)/\(config.maxPlacesApiCallsPerDay)")
        guard config.pvaModeEnabled else { print("PVA bailed: pvaModeEnabled is false"); return result }

        // Check daily API limit
        if config.dailyApiCallCount >= config.maxPlacesApiCallsPerDay {
            print("PVA bailed: daily API limit reached")
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
        var existingPlaceIds = Set(existingVenues.map { $0.placeId })

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
                    config: config,
                    userId: userId
                )

                // Update known place IDs so subsequent cells don't re-add the same venue
                existingPlaceIds.formUnion(searchResult.addedPlaceIds)

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
                print("PVA cell search error (\(cellId)): \(error)")
                result.error = error
            }
        }
        print("PVA processSearch done: newVenues=\(result.newVenuesAdded) alreadyKnown=\(result.venuesAlreadyKnown) apiCalls=\(result.apiCallsMade) cells=\(result.cellsProcessed.count)")

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
        var addedPlaceIds: [String] = []
    }

    private func searchCell(
        center: CLLocationCoordinate2D,
        radiusMeters: Int,
        existingPlaceIds: Set<String>,
        config: PVAConfig,
        userId: String?
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
                await addNewVenue(from: placeVenue, autoScan: config.autoScanWebsites, userId: userId)
                result.added += 1
                result.addedPlaceIds.append(placeVenue.placeId)

                if result.added >= config.maxNewVenuesPerSearch {
                    return result
                }
            }

            // Google requires the next_page_token to "bake" for ~2s before it becomes valid,
            // otherwise it returns INVALID_REQUEST. Use max(configured, 2.5s).
            if pageToken != nil {
                let seconds = max(config.scanDelaySeconds, 2.5)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        } while pageToken != nil && pageCount < maxPages

        return result
    }

    private func addNewVenue(from placeVenue: PlacesVenue, autoScan: Bool, userId: String?) async {
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
            instagramHandle: nil,
            facebookURL: nil,
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

        // Fire-and-forget scan so the user doesn't wait for scraping/OCR.
        // Combines website pages, website images, and Google Places photos into one text pool.
        if autoScan, let userId = userId {
            let venueAddress = venue.formattedAddress
            let venueName = venue.name
            let venueLat = venue.latitude
            let venueLng = venue.longitude
            let placeId = placeVenue.placeId
            Task.detached {
                await PVAService.autoScanVenue(
                    placeId: placeId,
                    venueId: venueId,
                    venueName: venueName,
                    venueAddress: venueAddress,
                    venueLatitude: venueLat,
                    venueLongitude: venueLng,
                    userId: userId
                )
            }
        }
    }

    // MARK: - Auto Scan

    /// End-to-end auto-scan: fetches the venue's Google details, scans its website (pages + images),
    /// OCRs Google Places photos (owner + user-posted, often including menus), and saves any deals found.
    /// Static so many venues can scan in parallel; concurrency is bounded to 3 by AutoScanLimiter to
    /// keep Firebase Functions from dropping auth tokens under burst load.
    static func autoScanVenue(
        placeId: String,
        venueId: String,
        venueName: String,
        venueAddress: String,
        venueLatitude: Double,
        venueLongitude: Double,
        userId: String
    ) async {
        // Gate: only 3 auto-scans run at once. Under heavier bursts the Firebase Functions
        // SDK sends requests without valid auth headers and the server rejects them all
        // with UNAUTHENTICATED (verified via functions:log showing zero invocations while
        // the client sees error 16 on every call).
        await AutoScanLimiter.shared.acquire()
        defer { Task { await AutoScanLimiter.shared.release() } }

        print("PVAService auto-scan: starting \(venueName)")

        // 1. Get details (website + all photo references).
        let details = try? await PlacesService.shared.getPlaceDetails(placeId: placeId)
        let website = details?.website ?? ""
        let photoRefs = (try? await PlacesService.shared.getPlacePhotoReferences(placeId: placeId, venueName: venueName, limit: 10)) ?? []

        // 2. Website scan via server-side scanWebsite (Firecrawl + Claude) Cloud Function.
        var allExtracted: [ExtractedDeal] = []
        var sources: [String] = []
        if !website.isEmpty {
            do {
                let webScan = try await WebScanService.shared.scanForDeals(url: website)

                // Closure detected on homepage — mark venue and bail out immediately.
                if webScan.isPermanentlyClosed {
                    print("PVAService auto-scan: \(venueName) homepage says permanently closed — marking venue")
                    try? await FirestoreService.shared.markVenueClosed(id: venueId)
                    return
                }

                allExtracted.append(contentsOf: webScan.extractedDeals)
                sources.append("website")
                print("PVAService auto-scan: \(venueName) website → \(webScan.extractedDeals.count) deals")
            } catch WebScanError.missingAPIKey {
                print("PVAService auto-scan: scanWebsite function not configured, skipping web scan for \(venueName)")
            } catch {
                print("PVAService auto-scan: \(venueName) website scan failed: \(error)")
            }
        }

        // 3. Google Places photos — prioritized by portrait/owner score, OCR up to 10.
        if !photoRefs.isEmpty {
            let photoResults = await ocrPlacePhotos(refs: Array(photoRefs.prefix(10)))
            var photoDealCount = 0
            for (ocrText, photoURL) in photoResults {
                let photoDeals = await PhotoScanService.shared
                    .extractDeals(from: ocrText, sourceURL: photoURL.absoluteString).extractedDeals
                allExtracted.append(contentsOf: photoDeals)
                photoDealCount += photoDeals.count
            }
            if photoDealCount > 0 {
                sources.append("places-photos")
                print("PVAService auto-scan: \(venueName) places photos → \(photoDealCount) deals")
            }
        }

        // 4. De-duplicate by title (case-insensitive) and save.
        let firestoreService = FirestoreService.shared

        // Seed seen-set with titles already in Firestore to prevent cross-run duplicates.
        let existingTitles = (try? await firestoreService.getAllDealsForVenue(venueId: venueId))
            .map { $0.map { $0.title.lowercased().trimmingCharacters(in: .whitespaces) } } ?? []
        var seen = Set(existingTitles)
        var savedCount = 0
        let sourceNote = sources.isEmpty ? "auto-scan" : "auto-scan (\(sources.joined(separator: ", ")))"

        for extracted in allExtracted {
            let key = extracted.title.lowercased().trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }

            let deal = Deal(
                id: UUID().uuidString,
                venueId: venueId,
                venueName: venueName,
                venueAddress: venueAddress,
                venueLatitude: venueLatitude,
                venueLongitude: venueLongitude,
                title: extracted.title,
                description: extracted.description,
                category: extracted.suggestedCategory,
                days: extracted.suggestedDays,
                startTime: extracted.suggestedStartTime,
                endTime: extracted.suggestedEndTime,
                source: .automated,
                status: .active,
                isVerified: false,
                upvotes: 0,
                downvotes: 0,
                reportCount: 0,
                imageURL: nil,
                sourceURL: extracted.sourceURL ?? (website.isEmpty ? nil : website),
                createdBy: userId,
                createdByName: nil,
                createdAt: Timestamp(),
                updatedAt: Timestamp(),
                startDate: nil,
                expiresAt: nil,
                adminNotes: sourceNote
            )
            do {
                try await firestoreService.saveDeal(deal)
                savedCount += 1
            } catch {
                print("PVAService auto-scan: failed to save deal for \(venueName): \(error)")
            }
        }

        // Mark venue as scanned (or failed if no sources were reachable at all).
        let finalStatus: VenueScanStatus = sources.isEmpty ? .failed : .scanned
        do {
            var fields: [String: Any] = [
                "scanStatus": finalStatus.rawValue,
                "lastScannedAt": Timestamp(),
                "updatedAt": Timestamp()
            ]
            if savedCount > 0 {
                fields["dealCount"] = FieldValue.increment(Int64(savedCount))
            }
            try await firestoreService.venuesRef.document(venueId).updateData(fields)
        } catch {
            print("PVAService auto-scan: failed to update scanStatus for \(venueName): \(error)")
        }

        if savedCount > 0 {
            print("PVAService auto-scan: saved \(savedCount) deal(s) for \(venueName) → \(finalStatus.rawValue)")
        } else {
            print("PVAService auto-scan: \(venueName) found 0 deals (sources: \(sources.isEmpty ? "none" : sources.joined(separator: ", "))) → \(finalStatus.rawValue)")
        }

        // Fire-and-forget social scan. Does its own discovery, saves handles to the
        // venue doc, extracts deals, and writes them as pending. Runs after the
        // main scan finishes so the venue is already visible to users first.
        Task.detached(priority: .background) {
            await triggerSocialScan(venueId: venueId, venueName: venueName)
        }
    }

    /// Kicks off the scanVenueSocial Cloud Function for a venue.
    /// Long-running (up to ~5 min) and independent of the main auto-scan path.
    private static func triggerSocialScan(venueId: String, venueName: String) async {
        do {
            let callable = Functions.functions().httpsCallable("scanVenueSocial")
            callable.timeoutInterval = 420
            let result = try await callable.call(["venueId": venueId])
            if let dict = result.data as? [String: Any] {
                let saved = dict["dealsSaved"] as? Int ?? 0
                print("PVAService social-scan: \(venueName) → \(saved) pending deal(s)")
            }
        } catch {
            print("PVAService social-scan: \(venueName) failed: \(error.localizedDescription)")
        }
    }

    /// Download each Google Places photo, pre-filter for menu-like content, then OCR.
    private static func ocrPlacePhotos(refs: [String]) async -> [(text: String, photoURL: URL)] {
        var results: [(text: String, photoURL: URL)] = []
        for ref in refs {
            guard let url = PlacesService.shared.photoURL(reference: ref, maxWidth: 1600) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else { continue }
                // Skip photos that don't look like menus/signs/specials boards
                guard await PhotoScanService.shared.looksLikeMenuPhoto(image) else {
                    print("PVAService photo pre-filter: skipped non-menu photo \(url.lastPathComponent)")
                    continue
                }
                let recognized = try await PhotoScanService.shared.recognizeText(in: image)
                if !recognized.isEmpty {
                    results.append((text: recognized, photoURL: url))
                }
            } catch {
                continue
            }
        }
        return results
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

    // MARK: - Admin Region Refresh

    /// Admin-triggered: rescan all existing venues in the area AND discover new ones.
    /// Returns (rescanned existing count, new venues found).
    static func refreshRegion(
        coordinate: CLLocationCoordinate2D,
        radiusMiles: Double,
        userId: String
    ) async -> (rescanned: Int, newVenues: Int) {
        let firestoreService = FirestoreService.shared
        let bounds = coordinate.boundingBox(radiusMiles: radiusMiles)

        // 1. Fetch every venue already in the DB for this area
        let existing = (try? await firestoreService.getVenuesInBounds(
            minLat: bounds.minLat, maxLat: bounds.maxLat,
            minLng: bounds.minLng, maxLng: bounds.maxLng
        )) ?? []

        // 2. Clear deals and re-scan each existing venue in background
        for venue in existing {
            Task.detached {
                _ = try? await firestoreService.deleteDealsForVenue(id: venue.id)
                try? await firestoreService.updateVenueField(id: venue.id, field: "dealCount", value: 0)
                try? await firestoreService.updateVenueField(id: venue.id, field: "scanStatus",
                                                             value: VenueScanStatus.pending.rawValue)
                await PVAService.autoScanVenue(
                    placeId: venue.placeId,
                    venueId: venue.id,
                    venueName: venue.name,
                    venueAddress: venue.formattedAddress,
                    venueLatitude: venue.latitude,
                    venueLongitude: venue.longitude,
                    userId: userId
                )
            }
        }

        // 3. Run a forced Places API search to find venues not yet in the DB
        let newCount = await PVAService.shared.forceSearch(
            coordinate: coordinate,
            radiusMiles: radiusMiles,
            userId: userId
        )

        return (rescanned: existing.count, newVenues: newCount)
    }

    /// Searches the Places API for the region regardless of cell staleness or daily limits.
    /// Only adds venues not already in the DB.
    func forceSearch(
        coordinate: CLLocationCoordinate2D,
        radiusMiles: Double,
        userId: String
    ) async -> Int {
        let config = (try? await firestoreService.getPVAConfig()) ?? PVAConfig.default
        let cellIds = gridCellIds(for: coordinate, radiusMiles: radiusMiles)
        let bounds = coordinate.boundingBox(radiusMiles: radiusMiles)

        let existingVenues = (try? await firestoreService.getVenuesInBounds(
            minLat: bounds.minLat, maxLat: bounds.maxLat,
            minLng: bounds.minLng, maxLng: bounds.maxLng
        )) ?? []
        var existingPlaceIds = Set(existingVenues.map { $0.placeId })

        var newCount = 0
        for cellId in cellIds {
            let center = cellCenter(for: cellId)
            guard let result = try? await searchCell(
                center: center,
                radiusMeters: Int(cellSizeDegrees * 111_320 * 1.5),
                existingPlaceIds: existingPlaceIds,
                config: config,
                userId: userId
            ) else { continue }

            existingPlaceIds.formUnion(result.addedPlaceIds)
            newCount += result.added

            let existingCell = try? await firestoreService.getPVACell(id: cellId)
            let updatedCell = PVACell(
                id: cellId,
                centerLatitude: center.latitude,
                centerLongitude: center.longitude,
                lastSearchedAt: Timestamp(),
                venueCount: result.added + result.existing,
                searchCount: (existingCell?.searchCount ?? 0) + 1,
                isStale: false,
                createdAt: existingCell?.createdAt ?? Timestamp()
            )
            try? await firestoreService.savePVACell(updatedCell)

            for _ in 0..<result.apiCalls {
                try? await firestoreService.incrementApiCallCount()
            }
        }
        return newCount
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
