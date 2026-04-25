import SwiftUI
import CoreLocation

struct HomeView: View {
    @StateObject private var viewModel = DealsViewModel()
    @EnvironmentObject var locationService: LocationService
    @State private var showingFilter = false
    @State private var showingLocationPermission = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Search bar + filter button
                searchHeader

                // Active filter chips
                if viewModel.filter.isFiltered {
                    filterChipsRow
                }

                // Results header
                if !viewModel.isLoading {
                    resultsHeader
                }

                // Main content
                if viewModel.isLoading && viewModel.filteredVenuesWithDeals.isEmpty {
                    loadingView
                } else if viewModel.filteredVenuesWithDeals.isEmpty && !viewModel.isLoading {
                    emptyStateView
                } else {
                    dealsList
                }
            }
        }
        .navigationTitle("Somewhere")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingFilter) {
            FilterSheetView(filter: $viewModel.filter) { newFilter in
                viewModel.updateFilter(newFilter)
            }
        }
        .alert("Location Access", isPresented: $showingLocationPermission) {
            Button("Open Settings") { locationService.openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable location access in Settings to find deals near you.")
        }
        .onAppear {
            if locationService.hasPermission {
                Task { await viewModel.searchDeals() }
            } else {
                locationService.requestPermission()
            }
        }
        .onChange(of: locationService.authorizationStatus) { status in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                Task { await viewModel.searchDeals() }
            } else if status == .denied {
                showingLocationPermission = true
            }
        }
        .refreshable {
            await viewModel.searchDeals()
        }
    }

    // MARK: - Search Header

    private var searchHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.appSubtext)
                TextField("Search deals, venues...", text: $viewModel.filter.searchQuery)
                    .onChange(of: viewModel.filter.searchQuery) { _ in
                        viewModel.applyFilter()
                    }
                if !viewModel.filter.searchQuery.isEmpty {
                    Button {
                        viewModel.filter.searchQuery = ""
                        viewModel.applyFilter()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.appSubtext)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.appSurface)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)

            Button {
                showingFilter = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18))
                        .foregroundColor(.appText)
                        .frame(width: 44, height: 44)
                        .background(Color.appSurface)
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)

                    if viewModel.filter.activeFilterCount > 0 {
                        Text("\(viewModel.filter.activeFilterCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(Color.appAccent)
                            .clipShape(Circle())
                            .offset(x: 4, y: -4)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Filter Chips

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Clear all
                Button {
                    viewModel.resetFilter()
                } label: {
                    Label("Clear", systemImage: "xmark")
                        .font(.appCaption.weight(.semibold))
                        .foregroundColor(.appError)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.appError.opacity(0.1))
                        .cornerRadius(20)
                }

                if viewModel.filter.showOnlyActiveNow {
                    FilterChip(label: "Now", icon: "clock.fill", color: .activeGreen) {
                        viewModel.filter.showOnlyActiveNow = false
                        viewModel.applyFilter()
                    }
                }

                ForEach(Array(viewModel.filter.categories), id: \.self) { cat in
                    FilterChip(label: cat.displayName, icon: nil, color: cat.uiColor) {
                        viewModel.filter.categories.remove(cat)
                        viewModel.applyFilter()
                    }
                }

                if viewModel.filter.timeFilter != .anytime {
                    FilterChip(label: viewModel.filter.timeFilter.displayName, icon: "clock", color: .appPrimary) {
                        viewModel.filter.timeFilter = .anytime
                        viewModel.applyFilter()
                    }
                }

                if viewModel.filter.searchRadius != 1.0 {
                    FilterChip(label: "\(String(format: "%.1f", viewModel.filter.searchRadius)) mi", icon: "location", color: .appAccent) {
                        viewModel.filter.searchRadius = 1.0
                        viewModel.applyFilter()
                    }
                }

                if !viewModel.filter.locationQuery.isEmpty {
                    FilterChip(label: viewModel.filter.locationQuery, icon: "mappin.and.ellipse", color: .appPrimary) {
                        var newFilter = viewModel.filter
                        newFilter.locationQuery = ""
                        viewModel.updateFilter(newFilter)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Results Header

    private var resultsHeader: some View {
        HStack {
            if viewModel.isSearchingNewVenues {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Scanning for new venues...")
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)
                }
            } else {
                Text("\(viewModel.totalVenuesCount) venue\(viewModel.totalVenuesCount == 1 ? "" : "s") · \(viewModel.totalDealsCount) deal\(viewModel.totalDealsCount == 1 ? "" : "s")")
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
            }

            Spacer()

            if viewModel.activeDealsCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.activeGreen).frame(width: 7, height: 7)
                    Text("\(viewModel.activeDealsCount) active now")
                        .font(.appCaption.weight(.semibold))
                        .foregroundColor(.activeGreen)
                }
            }

            if !viewModel.filteredVenuesWithDeals.isEmpty {
                Button {
                    withAnimation(AppConstants.springAnimation) {
                        if viewModel.allExpanded {
                            viewModel.collapseAll()
                        } else {
                            viewModel.expandAll()
                        }
                    }
                    HapticFeedback.impact(.light)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.allExpanded ? "chevron.up.square" : "chevron.down.square")
                            .font(.system(size: 12, weight: .semibold))
                        Text(viewModel.allExpanded ? "Collapse all" : "Expand all")
                            .font(.appCaption.weight(.semibold))
                    }
                    .foregroundColor(.appPrimary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Deals List

    private var dealsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.filteredVenuesWithDeals) { vwd in
                    VenueCardView(
                        venueWithDeals: vwd,
                        userLocation: viewModel.lastSearchLocation,
                        isExpanded: viewModel.expandedVenueIds.contains(vwd.id),
                        onToggleExpand: { viewModel.toggleVenueExpansion(vwd.id) },
                        onVote: { dealId, upvote in
                            Task { await viewModel.vote(dealId: dealId, upvote: upvote) }
                        }
                    )
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { _ in
                    VenueCardSkeletonView()
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wineglass")
                .font(.system(size: 64))
                .foregroundColor(.appSubtext.opacity(0.4))

            Text(viewModel.filter.isFiltered ? "No deals match your filters" : "No deals found nearby")
                .font(.appTitle3)
                .foregroundColor(.appText)

            Text(viewModel.filter.isFiltered
                 ? "Try adjusting your filters to see more deals."
                 : "Be the first to add a happy hour deal in your area!")
                .font(.appSubheadline)
                .foregroundColor(.appSubtext)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if viewModel.filter.isFiltered {
                Button("Clear Filters") { viewModel.resetFilter() }
                    .buttonStyle(.borderedProminent)
                    .tint(.appPrimary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if let location = viewModel.lastSearchLocation {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.appPrimary)
                    Text("Near You")
                        .font(.appCaption.weight(.medium))
                        .foregroundColor(.appPrimary)
                }
            }
        }
    }
}

// MARK: - Filter Chip
struct FilterChip: View {
    let label: String
    let icon: String?
    let color: Color
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon).font(.system(size: 10))
            }
            Text(label).font(.appCaption.weight(.medium))
            Button { onRemove() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12))
        .cornerRadius(20)
    }
}
