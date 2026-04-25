import Foundation
import CoreLocation
import FirebaseFirestore
import Combine

@MainActor
class AdminViewModel: ObservableObject {
    // Users
    @Published var users: [AppUser] = []
    @Published var totalUsers = 0

    // Venues
    @Published var venues: [Venue] = []
    @Published var totalVenues = 0
    @Published var pendingVenues: [Venue] = []

    // Deals
    @Published var pendingDeals: [Deal] = []
    @Published var allDeals: [Deal] = []
    @Published var totalDeals = 0

    // PVA
    @Published var pvaConfig = PVAConfig.default
    @Published var pvaStats = PVAStats.empty
    @Published var pvaCells: [PVACell] = []

    // Analytics
    @Published var searchLogs: [SearchLog] = []
    @Published var newVenuesLast7Days = 0
    @Published var newDealsLast7Days = 0
    @Published var activeUsersLast7Days = 0

    // UI State
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var selectedTab = 0

    private let firestoreService = FirestoreService.shared
    private var dealListener: ListenerRegistration?

    deinit {
        dealListener?.remove()
    }

    // MARK: - Load Dashboard

    func loadDashboard() async {
        isLoading = true
        errorMessage = nil

        async let usersTask = loadUsers()
        async let venuesTask = loadVenues()
        async let pvaTask = loadPVAConfig()
        async let statsTask = loadStats()

        await usersTask
        await venuesTask
        await pvaTask
        await statsTask

        setupPendingDealsListener()
        isLoading = false
    }

    // MARK: - Users

    func loadUsers() async {
        do {
            users = try await firestoreService.getAllUsers(limit: 200)
            totalUsers = try await firestoreService.getUserCount()
        } catch {
            errorMessage = "Failed to load users: \(error.localizedDescription)"
        }
    }

    func updateUserRole(userId: String, role: UserRole) async {
        do {
            try await firestoreService.updateUserRole(uid: userId, role: role)
            if let idx = users.firstIndex(where: { $0.id == userId }) {
                users[idx].role = role
            }
            successMessage = "User role updated."
            HapticFeedback.success()
        } catch {
            errorMessage = "Failed to update role: \(error.localizedDescription)"
        }
    }

    func toggleBanUser(userId: String, banned: Bool) async {
        do {
            try await firestoreService.banUser(uid: userId, banned: banned)
            if let idx = users.firstIndex(where: { $0.id == userId }) {
                users[idx].isBanned = banned
            }
            successMessage = banned ? "User banned." : "User unbanned."
        } catch {
            errorMessage = "Failed to update ban status."
        }
    }

    // MARK: - Venues

    func loadVenues(limit: Int = 100) async {
        do {
            let snapshot = try await firestoreService.venuesRef
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
                .getDocuments()
            var loaded = snapshot.documents.compactMap {
                Venue.fromFirestore($0.data(), id: $0.documentID)
            }
            if let loc = LocationService.shared.currentLocation {
                loaded.sort { $0.distanceMiles(from: loc) < $1.distanceMiles(from: loc) }
            }
            venues = loaded
            totalVenues = try await firestoreService.getVenueCount()
            pendingVenues = try await firestoreService.getVenuesPendingScan(limit: 20)
        } catch {
            errorMessage = "Failed to load venues: \(error.localizedDescription)"
        }
    }

    func deleteVenue(id: String) async {
        do {
            try await firestoreService.deleteVenue(id: id)
            venues.removeAll { $0.id == id }
            successMessage = "Venue deleted."
        } catch {
            errorMessage = "Failed to delete venue."
        }
    }

    func markVenueClosed(id: String) async {
        do {
            try await firestoreService.markVenueClosed(id: id)
            if let idx = venues.firstIndex(where: { $0.id == id }) {
                venues[idx].isPermanentlyClosed = true
            }
            successMessage = "Venue marked as closed."
        } catch {
            errorMessage = "Failed to update venue."
        }
    }

    func deleteAllVenuesAndDeals() async {
        isLoading = true
        do {
            let deletedDeals = try await firestoreService.deleteAllDocuments(in: firestoreService.dealsRef)
            let deletedVenues = try await firestoreService.deleteAllDocuments(in: firestoreService.venuesRef)
            venues = []
            allDeals = []
            pendingDeals = []
            totalVenues = 0
            totalDeals = 0
            successMessage = "Deleted \(deletedVenues) venues and \(deletedDeals) deals."
            HapticFeedback.success()
        } catch {
            errorMessage = "Cleanup failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - Deals

    func setupPendingDealsListener() {
        dealListener?.remove()
        dealListener = firestoreService.listenToPendingDeals { [weak self] deals in
            Task { @MainActor in
                self?.pendingDeals = deals
            }
        }
    }

    func loadAllDeals(limit: Int = 100) async {
        do {
            let snapshot = try await firestoreService.dealsRef
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
                .getDocuments()
            print("AdminViewModel.loadAllDeals: fetched \(snapshot.documents.count) docs")
            var loaded: [Deal] = snapshot.documents.compactMap { doc in
                if let deal = try? doc.data(as: Deal.self) { return deal }
                if let deal = Deal.fromFirestore(doc.data(), id: doc.documentID) { return deal }
                print("AdminViewModel.loadAllDeals: failed to parse doc \(doc.documentID) data=\(doc.data().keys.sorted())")
                return nil
            }
            if let loc = LocationService.shared.currentLocation {
                loaded.sort {
                    let d0 = CLLocation(latitude: $0.venueLatitude, longitude: $0.venueLongitude)
                    let d1 = CLLocation(latitude: $1.venueLatitude, longitude: $1.venueLongitude)
                    return loc.distance(from: d0) < loc.distance(from: d1)
                }
            }
            allDeals = loaded
            totalDeals = try await firestoreService.getDealCount()
        } catch {
            print("AdminViewModel.loadAllDeals error: \(error)")
            errorMessage = "Failed to load deals: \(error.localizedDescription)"
        }
    }

    func approveDeal(_ deal: Deal) async {
        do {
            try await firestoreService.approveDeal(id: deal.id, venueId: deal.venueId)
            pendingDeals.removeAll { $0.id == deal.id }
            successMessage = "Deal approved."
            HapticFeedback.success()
        } catch {
            errorMessage = "Failed to approve deal."
        }
    }

    func rejectDeal(_ deal: Deal, notes: String) async {
        do {
            try await firestoreService.rejectDeal(id: deal.id, adminNotes: notes)
            pendingDeals.removeAll { $0.id == deal.id }
            successMessage = "Deal rejected."
        } catch {
            errorMessage = "Failed to reject deal."
        }
    }

    func deleteDeal(_ deal: Deal) async {
        do {
            try await firestoreService.deleteDeal(id: deal.id, venueId: deal.venueId)
            allDeals.removeAll { $0.id == deal.id }
            pendingDeals.removeAll { $0.id == deal.id }
            successMessage = "Deal deleted."
        } catch {
            errorMessage = "Failed to delete deal."
        }
    }

    // MARK: - PVA Config

    func loadPVAConfig() async {
        do {
            if let config = try await firestoreService.getPVAConfig() {
                pvaConfig = config
            }
        } catch {
            // Use defaults if not found
        }
    }

    func savePVAConfig() async {
        do {
            try await firestoreService.savePVAConfig(pvaConfig)
            successMessage = "PVA configuration saved."
            HapticFeedback.success()
        } catch {
            errorMessage = "Failed to save PVA config."
        }
    }

    func resetDailyApiCount() async {
        do {
            try await firestoreService.pvaConfigRef.updateData([
                "dailyApiCallCount": 0,
                "apiCallsResetAt": Timestamp()
            ])
            pvaConfig.dailyApiCallCount = 0
            successMessage = "API call counter reset."
        } catch {
            errorMessage = "Failed to reset counter."
        }
    }

    func triggerPVAReverify() async {
        isLoading = true
        await PVAService.shared.reverifyStaleVenues(olderThanDays: pvaConfig.venueReverifyDays, limit: 10)
        successMessage = "Venue reverification started."
        isLoading = false
    }

    // MARK: - Search Logs

    func loadSearchLogs(limit: Int = 100) async {
        do {
            searchLogs = try await firestoreService.getRecentSearchLogs(limit: limit)
        } catch {
            errorMessage = "Failed to load search logs: \(error.localizedDescription)"
        }
    }

    // MARK: - Force Rescan

    /// Delete all deals for a venue and kick off a fresh website+photos scan.
    func rescanVenue(_ venue: Venue, currentUserId: String) async {
        isLoading = true
        do {
            let deleted = try await firestoreService.deleteDealsForVenue(id: venue.id)
            try? await firestoreService.updateVenueField(id: venue.id, field: "dealCount", value: 0)
            Task.detached {
                await PVAService.autoScanVenue(
                    placeId: venue.placeId,
                    venueId: venue.id,
                    venueName: venue.name,
                    venueAddress: venue.formattedAddress,
                    venueLatitude: venue.latitude,
                    venueLongitude: venue.longitude,
                    userId: currentUserId
                )
            }
            successMessage = "Rescan started (\(deleted) old deals cleared)."
        } catch {
            errorMessage = "Rescan failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Scan unscanned / failed venues in background. Optionally limits to venues within
    /// `radiusMiles` of a center coordinate; pass nil center to scan regardless of location.
    func scanAllUnscannedVenues(
        userId: String,
        center: CLLocationCoordinate2D? = nil,
        radiusMiles: Double = 5.0,
        batchSize: Int = 50
    ) async {
        isLoading = true
        do {
            // Fetch more than batchSize so we have room to filter by distance.
            let fetchLimit = center != nil ? batchSize * 4 : batchSize
            var candidates = try await firestoreService.getVenuesNeedingScan(limit: fetchLimit)

            if let center = center {
                let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
                candidates = candidates
                    .filter { $0.distanceMiles(from: centerLocation) <= radiusMiles }
                    .prefix(batchSize)
                    .map { $0 }
            }

            guard !candidates.isEmpty else {
                if let center = center {
                    // No existing venues — discover new ones via Places API then scan them
                    successMessage = "No existing venues found — discovering new venues in area..."
                    let (_, newVenues) = await PVAService.refreshRegion(
                        coordinate: center,
                        radiusMiles: radiusMiles,
                        userId: userId
                    )
                    successMessage = newVenues > 0
                        ? "Found \(newVenues) new venue(s). Scanning in background — check back in a minute."
                        : "No venues found in this area via Google Places."
                } else {
                    successMessage = "All venues already scanned."
                }
                isLoading = false
                return
            }

            for venue in candidates {
                Task.detached {
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
            successMessage = "Scanning \(candidates.count) venue(s) in background — check back in a minute."
        } catch {
            errorMessage = "Bulk scan failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Full region refresh: rescan existing venues + discover new ones via Places API.
    func refreshRegion(latitude: Double, longitude: Double, radiusMiles: Double, userId: String) async {
        isLoading = true
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let (rescanned, newVenues) = await PVAService.refreshRegion(
            coordinate: coordinate,
            radiusMiles: radiusMiles,
            userId: userId
        )
        let newMsg = newVenues > 0 ? " · \(newVenues) new venue(s) added." : ""
        successMessage = "Rescanning \(rescanned) venue(s) in background.\(newMsg)"
        isLoading = false
    }

    // MARK: - Stats

    func loadStats() async {
        do {
            let sevenDaysAgo = Timestamp(date: Calendar.current.date(byAdding: .day, value: -7, to: Date())!)

            // New venues in last 7 days
            let venueSnapshot = try await firestoreService.venuesRef
                .whereField("createdAt", isGreaterThan: sevenDaysAgo)
                .count
                .getAggregation(source: .server)
            newVenuesLast7Days = Int(truncating: venueSnapshot.count)

            // New deals in last 7 days
            let dealSnapshot = try await firestoreService.dealsRef
                .whereField("createdAt", isGreaterThan: sevenDaysAgo)
                .count
                .getAggregation(source: .server)
            newDealsLast7Days = Int(truncating: dealSnapshot.count)

            // Active users in last 7 days
            let userSnapshot = try await firestoreService.usersRef
                .whereField("lastActiveAt", isGreaterThan: sevenDaysAgo)
                .count
                .getAggregation(source: .server)
            activeUsersLast7Days = Int(truncating: userSnapshot.count)

            // Total active deals
            let totalDealSnapshot = try await firestoreService.dealsRef
                .whereField("status", isEqualTo: "active")
                .count
                .getAggregation(source: .server)
            totalDeals = Int(truncating: totalDealSnapshot.count)

            // PVA stats
            let pendingVenueSnapshot = try await firestoreService.venuesRef
                .whereField("scanStatus", isEqualTo: VenueScanStatus.pending.rawValue)
                .count
                .getAggregation(source: .server)

            let closedVenueSnapshot = try await firestoreService.venuesRef
                .whereField("isPermanentlyClosed", isEqualTo: true)
                .count
                .getAggregation(source: .server)

            pvaStats = PVAStats(
                totalCells: 0,
                staleCells: 0,
                cellsSearchedToday: 0,
                totalVenuesInDB: totalVenues,
                venuesPendingScan: Int(truncating: pendingVenueSnapshot.count),
                venuesScanned: totalVenues - Int(truncating: pendingVenueSnapshot.count),
                venuesClosed: Int(truncating: closedVenueSnapshot.count),
                apiCallsToday: pvaConfig.dailyApiCallCount,
                apiCallsLimit: pvaConfig.maxPlacesApiCallsPerDay,
                newVenuesToday: 0,
                newDealsToday: 0
            )
        } catch {
            // Stats are non-critical, don't show error
        }
    }
}
