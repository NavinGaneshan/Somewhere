import SwiftUI
import CoreLocation

struct HomeView: View {
    @EnvironmentObject var viewModel: DealsViewModel
    @EnvironmentObject var locationService: LocationService
    @State private var showingFilter = false
    @State private var showingLocationPermission = false
    @State private var radiusDebounceTask: Task<Void, Never>? = nil
    @State private var isRadiusDebouncing = false
    @State private var showFiltersPanel = true

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Brand header
                brandHeader

                // Row 1: search + favorites toggle + filter icon
                // Row 2: distance slider
                searchFilterRows

                // Results header — always visible when re-fetching with existing results
                if !viewModel.isLoading || !viewModel.filteredVenuesWithDeals.isEmpty || isRadiusDebouncing {
                    resultsHeader
                }

                // Collapsible filter chips
                if showFiltersPanel && viewModel.filter.isFiltered {
                    filterChipsRow
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
            viewModel.loadFavorites()
            // Only trigger a search if we haven't already loaded once — the DealsViewModel
            // is shared with the Map tab, so avoid re-fetching on every tab switch.
            if viewModel.lastSearchLocation == nil {
                if locationService.hasPermission {
                    Task { await viewModel.searchDeals() }
                } else {
                    locationService.requestPermission()
                }
            }
        }
        .onChange(of: locationService.authorizationStatus) { status in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                Task { await viewModel.searchDeals() }
            } else if status == .denied {
                showingLocationPermission = true
            }
        }
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                (Text("Some")
                    .font(.custom("Fraunces-Light", size: 36))
                    .foregroundColor(.appText)
                + Text("w")
                    .font(.custom("Fraunces-Italic", size: 36))
                    .foregroundColor(.appPrimary)
                + Text("here.")
                    .font(.custom("Fraunces-Light", size: 36))
                    .foregroundColor(.appText))
                .tracking(-0.5)

                Text("It's happy hour. Find deals right here, right now.")
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 0)
        .padding(.bottom, 4)
    }

    // MARK: - Search + Filter Rows

    private var searchFilterRows: some View {
        VStack(spacing: 6) {
            // Row 1: search field + favorites toggle + filter icon
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.appSubtext)
                    TextField("Search…", text: $viewModel.filter.searchQuery)
                        .font(.system(size: 13))
                        .foregroundColor(.appText)
                        .onChange(of: viewModel.filter.searchQuery) { _ in viewModel.applyFilter() }
                    if !viewModel.filter.searchQuery.isEmpty {
                        Button {
                            viewModel.filter.searchQuery = ""
                            viewModel.applyFilter()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.appSubtext)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.appSurface)
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)

                // Favorites toggle
                Button {
                    viewModel.filter.showOnlyFavorites.toggle()
                    viewModel.applyFilter()
                    HapticFeedback.impact(.light)
                } label: {
                    Image(systemName: viewModel.filter.showOnlyFavorites ? "heart.fill" : "heart")
                        .font(.system(size: 16))
                        .foregroundColor(viewModel.filter.showOnlyFavorites ? .red : .appSubtext)
                        .frame(width: 34, height: 34)
                        .background(Color.appSurface)
                        .cornerRadius(10)
                        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
                }

                // Filter button
                Button { showingFilter = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15))
                            .foregroundColor(.appText)
                            .frame(width: 34, height: 34)
                            .background(Color.appSurface)
                            .cornerRadius(10)
                            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
                        if viewModel.filter.activeFilterCount > 0 {
                            Text("\(viewModel.filter.activeFilterCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 14, height: 14)
                                .background(Color.appAccent)
                                .clipShape(Circle())
                                .offset(x: 3, y: -3)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)

            // Row 2: distance slider full width
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.appPrimary)
                Slider(
                    value: $viewModel.filter.searchRadius,
                    in: AppConstants.minSearchRadiusMiles...AppConstants.maxSearchRadiusMiles,
                    step: 0.25,
                    onEditingChanged: { editing in
                        if editing {
                            radiusDebounceTask?.cancel()
                            isRadiusDebouncing = false
                        } else {
                            // Radius may have grown → need a fresh Firestore query to pull
                            // deals from the newly-visible outer ring. Short debounce so
                            // rapid slider adjustments coalesce into one query.
                            isRadiusDebouncing = true
                            radiusDebounceTask?.cancel()
                            radiusDebounceTask = Task {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                guard !Task.isCancelled else { return }
                                isRadiusDebouncing = false
                                await viewModel.searchDeals()
                            }
                        }
                    }
                )
                .tint(.appPrimary)
                // Live in-memory refilter as the user drags — deals outside the new
                // radius disappear instantly so the slider feels responsive. When the
                // slider is released, onEditingChanged fires a debounced Firestore
                // fetch to backfill deals from any newly-included outer ring.
                .onChange(of: viewModel.filter.searchRadius) { _ in
                    viewModel.applyFilter()
                }
                Text("\(String(format: "%.1f", viewModel.filter.searchRadius))mi")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appText)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
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
                        .font(.appCaptionSemiBold)
                        .foregroundColor(.appError)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.appError.opacity(0.1))
                        .cornerRadius(20)
                }

                // Time filter chip — tap to reset to default (Right Now).
                if viewModel.filter.timeFilter != .now {
                    FilterChip(label: viewModel.filter.timeFilter.displayName,
                               icon: viewModel.filter.timeFilter.icon,
                               color: .appPrimary) {
                        viewModel.filter.timeFilter = .now
                        viewModel.applyFilter()
                    }
                }

                if viewModel.filter.categories != SearchFilter.defaultCategories {
                    ForEach(Array(viewModel.filter.categories).sorted { $0.rawValue < $1.rawValue }, id: \.self) { cat in
                        FilterChip(label: cat.displayName, icon: nil, color: cat.uiColor) {
                            viewModel.filter.categories.remove(cat)
                            viewModel.applyFilter()
                        }
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
            if isRadiusDebouncing || (viewModel.isLoading && !viewModel.filteredVenuesWithDeals.isEmpty) {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Updating radius…")
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)
                }
            } else if viewModel.isSearchingNewVenues {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Looking around…")
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)
                }
            } else {
                HStack(spacing: 6) {
                    Text("\(viewModel.totalVenuesCount) venue\(viewModel.totalVenuesCount == 1 ? "" : "s") · \(viewModel.totalDealsCount) deal\(viewModel.totalDealsCount == 1 ? "" : "s")")
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)

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
                            Image(systemName: viewModel.allExpanded ? "chevron.up.circle" : "chevron.down.circle")
                                .font(.system(size: 13))
                                .foregroundColor(.appSubtext)
                        }
                    }
                }
            }

            Spacer()

            if viewModel.activeDealsCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.activeGreen).frame(width: 7, height: 7)
                    Text("\(viewModel.activeDealsCount) on now")
                        .font(.appCaptionSemiBold)
                        .foregroundColor(.activeGreen)
                }
            }

            Button {
                withAnimation(AppConstants.springAnimation) { showFiltersPanel.toggle() }
                HapticFeedback.impact(.light)
            } label: {
                Image(systemName: showFiltersPanel ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 16))
                    .foregroundColor(showFiltersPanel ? .appPrimary : .appSubtext)
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
                        },
                        isFavorite: viewModel.favoriteVenueIds.contains(vwd.venue.id),
                        onToggleFavorite: {
                            Task { await viewModel.toggleFavorite(venueId: vwd.venue.id) }
                        }
                    )
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 8)
        }
        .refreshable {
            await viewModel.searchDeals()
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
        VStack(spacing: 16) {
            Spacer()
            Text(viewModel.filter.isFiltered ? "Nothing matches." : "Nothing nearby yet.")
                .font(.custom("Fraunces-Italic", size: 28))
                .foregroundColor(.appText)
                .multilineTextAlignment(.center)

            Text(viewModel.filter.isFiltered
                 ? "Try loosening your filters."
                 : "Be the first to share one.")
                .font(.appSubheadline)
                .foregroundColor(.appSubtext)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if viewModel.filter.isFiltered {
                Button("Reset") { viewModel.resetFilter() }
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
            if viewModel.lastSearchLocation != nil {
                HStack(spacing: 3) {
                    Circle().fill(Color.activeGreen).frame(width: 5, height: 5)
                    Text("Nearby")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.appSubtext)
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
            Text(label).font(.appCaption)
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
