import Foundation
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
            venues = snapshot.documents.compactMap {
                Venue.fromFirestore($0.data(), id: $0.documentID)
            }
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
            allDeals = snapshot.documents.compactMap { try? $0.data(as: Deal.self) }
            totalDeals = try await firestoreService.getDealCount()
        } catch {
            errorMessage = "Failed to load deals."
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
