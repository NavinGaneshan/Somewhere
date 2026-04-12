import Foundation
import CoreLocation
import Combine
import FirebaseFirestore

@MainActor
class DealsViewModel: ObservableObject {
    @Published var venuesWithDeals: [VenueWithDeals] = []
    @Published var filteredVenuesWithDeals: [VenueWithDeals] = []
    @Published var filter = SearchFilter.default
    @Published var isLoading = false
    @Published var isSearchingNewVenues = false
    @Published var errorMessage: String?
    @Published var lastSearchLocation: CLLocation?
    @Published var pvaResult: PVAResult?
    @Published var showPVAResult = false
    @Published var expandedVenueIds: Set<String> = []

    private let firestoreService = FirestoreService.shared
    private let locationService = LocationService.shared
    private let pvaService = PVAService.shared
    private let authService = AuthService.shared

    private var deals: [Deal] = []
    private var venues: [Venue] = []
    private var loadTask: Task<Void, Never>?

    // MARK: - Search

    func searchDeals(at location: CLLocation? = nil) async {
        loadTask?.cancel()
        loadTask = Task {
            await performSearch(at: location)
        }
    }

    private func performSearch(at providedLocation: CLLocation?) async {
        isLoading = true
        errorMessage = nil

        do {
            // Get location
            let location: CLLocation
            if let provided = providedLocation {
                location = provided
            } else {
                location = try await locationService.getCurrentLocation()
            }
            lastSearchLocation = location

            let coordinate = location.coordinate
            let radius = filter.searchRadius

            // Load existing venues and deals from DB
            let bounds = coordinate.boundingBox(radiusMiles: radius)
            venues = try await firestoreService.getVenuesInBounds(
                minLat: bounds.minLat, maxLat: bounds.maxLat,
                minLng: bounds.minLng, maxLng: bounds.maxLng
            )
            .filter { !$0.isPermanentlyClosed }

            let venueIds = venues.map { $0.id }
            deals = try await firestoreService.getDealsForVenueIds(venueIds)

            buildVenuesWithDeals(userLocation: location)
            applyFilter()

            isLoading = false

            // Run PVA in background (non-blocking)
            isSearchingNewVenues = true
            if Task.isCancelled { return }

            let result = try await pvaService.processSearch(
                coordinate: coordinate,
                radiusMiles: radius,
                userId: authService.currentUser?.id
            )
            pvaResult = result

            // Reload if new venues were found
            if result.newVenuesAdded > 0 {
                venues = try await firestoreService.getVenuesInBounds(
                    minLat: bounds.minLat, maxLat: bounds.maxLat,
                    minLng: bounds.minLng, maxLng: bounds.maxLng
                )
                .filter { !$0.isPermanentlyClosed }

                let newVenueIds = venues.map { $0.id }
                deals = try await firestoreService.getDealsForVenueIds(newVenueIds)
                buildVenuesWithDeals(userLocation: location)
                applyFilter()
                showPVAResult = true
            }
            isSearchingNewVenues = false
        } catch is CancellationError {
            isLoading = false
            isSearchingNewVenues = false
        } catch let error as LocationError {
            errorMessage = error.localizedDescription
            isLoading = false
            isSearchingNewVenues = false
        } catch {
            errorMessage = "Failed to load deals: \(error.localizedDescription)"
            isLoading = false
            isSearchingNewVenues = false
        }
    }

    private func buildVenuesWithDeals(userLocation: CLLocation) {
        // Group deals by venue
        let dealsByVenue = Dictionary(grouping: deals, by: { $0.venueId })

        venuesWithDeals = venues
            .filter { venue in
                // Only show venues that have deals or are within radius
                let hasDeals = (dealsByVenue[venue.id]?.isEmpty == false)
                let inRadius = venue.distanceMiles(from: userLocation) <= filter.searchRadius
                return hasDeals && inRadius
            }
            .map { venue in
                VenueWithDeals(
                    venue: venue,
                    deals: dealsByVenue[venue.id] ?? [],
                    isExpanded: expandedVenueIds.contains(venue.id) || expandedVenueIds.isEmpty
                )
            }
            .sorted { lhs, rhs in
                // Sort by active deals first, then distance
                if lhs.hasActiveDeals != rhs.hasActiveDeals {
                    return lhs.hasActiveDeals
                }
                let lhsDist = lhs.venue.distanceMiles(from: userLocation)
                let rhsDist = rhs.venue.distanceMiles(from: userLocation)
                return lhsDist < rhsDist
            }
    }

    // MARK: - Filtering

    func applyFilter() {
        guard let userLocation = lastSearchLocation else {
            filteredVenuesWithDeals = venuesWithDeals
            return
        }

        filteredVenuesWithDeals = venuesWithDeals
            .compactMap { vwd -> VenueWithDeals? in
                guard filter.matches(venue: vwd.venue, from: userLocation) else { return nil }
                let filteredDeals = vwd.deals.filter { filter.matches(deal: $0) }
                guard !filteredDeals.isEmpty else { return nil }
                return VenueWithDeals(venue: vwd.venue, deals: filteredDeals, isExpanded: vwd.isExpanded)
            }
            .sorted { lhs, rhs in
                switch filter.sortOption {
                case .distance:
                    return lhs.venue.distanceMiles(from: userLocation) < rhs.venue.distanceMiles(from: userLocation)
                case .activeNow:
                    if lhs.hasActiveDeals != rhs.hasActiveDeals { return lhs.hasActiveDeals }
                    return lhs.venue.distanceMiles(from: userLocation) < rhs.venue.distanceMiles(from: userLocation)
                case .newest:
                    return lhs.deals.first?.createdAt.dateValue() ?? .distantPast >
                           rhs.deals.first?.createdAt.dateValue() ?? .distantPast
                case .topRated:
                    return lhs.deals.map { $0.score }.max() ?? 0 > rhs.deals.map { $0.score }.max() ?? 0
                }
            }
    }

    func updateFilter(_ newFilter: SearchFilter) {
        filter = newFilter
        applyFilter()
        if newFilter.searchRadius != filter.searchRadius {
            Task { await searchDeals() }
        }
    }

    func resetFilter() {
        filter = .default
        applyFilter()
    }

    // MARK: - Venue Expansion

    func toggleVenueExpansion(_ venueId: String) {
        if expandedVenueIds.contains(venueId) {
            expandedVenueIds.remove(venueId)
        } else {
            expandedVenueIds.insert(venueId)
        }
        // Update the filtered list
        filteredVenuesWithDeals = filteredVenuesWithDeals.map { vwd in
            var updated = vwd
            updated.isExpanded = expandedVenueIds.contains(vwd.id)
            return updated
        }
    }

    // MARK: - Vote

    func vote(dealId: String, upvote: Bool) async {
        guard let userId = authService.currentUser?.id else { return }
        do {
            try await firestoreService.voteDeal(id: dealId, upvote: upvote, userId: userId)
            HapticFeedback.impact(.light)
            // Update local state
            deals = deals.map { deal in
                guard deal.id == dealId else { return deal }
                var updated = deal
                if upvote { updated.upvotes += 1 } else { updated.downvotes += 1 }
                return updated
            }
            applyFilter()
        } catch {
            errorMessage = "Could not record your vote."
        }
    }

    // MARK: - Active counts

    var activeDealsCount: Int {
        filteredVenuesWithDeals.flatMap { $0.deals }.filter { $0.isActiveNow }.count
    }

    var totalDealsCount: Int {
        filteredVenuesWithDeals.flatMap { $0.deals }.count
    }

    var totalVenuesCount: Int {
        filteredVenuesWithDeals.count
    }
}
