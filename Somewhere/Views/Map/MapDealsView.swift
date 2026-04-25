import SwiftUI
import MapKit

struct MapDealsView: View {
    @StateObject private var viewModel = DealsViewModel()
    @EnvironmentObject var locationService: LocationService
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 33.7890, longitude: -84.3880),
        span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
    )
    @State private var selectedVenueId: String?
    @State private var showingFilter = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Map
            Map(coordinateRegion: $region, showsUserLocation: true, annotationItems: viewModel.filteredVenuesWithDeals) { vwd in
                MapAnnotation(coordinate: vwd.venue.coordinate) {
                    VenueMapPin(
                        venueWithDeals: vwd,
                        isSelected: selectedVenueId == vwd.id
                    ) {
                        withAnimation {
                            selectedVenueId = selectedVenueId == vwd.id ? nil : vwd.id
                        }
                        HapticFeedback.impact(.light)
                    }
                }
            }
            .ignoresSafeArea(edges: .top)

            // Selected venue detail card
            if let selectedId = selectedVenueId,
               let vwd = viewModel.filteredVenuesWithDeals.first(where: { $0.id == selectedId }) {
                selectedVenueCard(vwd)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }

            // Filter button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        showingFilter = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 18))
                                .foregroundColor(.appText)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
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
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()
            }
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFilter) {
            FilterSheetView(filter: $viewModel.filter) { newFilter in
                viewModel.updateFilter(newFilter)
            }
        }
        .onAppear {
            if let location = locationService.userLocation {
                region.center = location.coordinate
            }
            Task { await viewModel.searchDeals() }
        }
        .onChange(of: locationService.userLocation) { loc in
            if let loc = loc {
                withAnimation {
                    region.center = loc.coordinate
                }
            }
        }
    }

    private func selectedVenueCard(_ vwd: VenueWithDeals) -> some View {
        VStack(spacing: 0) {
            // Handle bar
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.appDivider)
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 4)

            VenueCardView(
                venueWithDeals: vwd,
                userLocation: locationService.userLocation,
                isExpanded: true,
                onToggleExpand: {},
                onVote: { dealId, upvote in
                    Task { await viewModel.vote(dealId: dealId, upvote: upvote) }
                }
            )
        }
        .background(Color.appSurface)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

// MARK: - Map Pin
struct VenueMapPin: View {
    let venueWithDeals: VenueWithDeals
    let isSelected: Bool
    let onTap: () -> Void

    private var venue: Venue { venueWithDeals.venue }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(pinColor)
                        .frame(width: isSelected ? 44 : 36, height: isSelected ? 44 : 36)
                        .shadow(color: pinColor.opacity(0.4), radius: isSelected ? 8 : 4, y: 2)

                    if venueWithDeals.hasActiveDeals {
                        // Pulse ring
                        Circle()
                            .stroke(pinColor.opacity(0.3), lineWidth: 2)
                            .frame(width: isSelected ? 54 : 44, height: isSelected ? 54 : 44)
                    }

                    Text(venue.category.icon)
                        .font(.system(size: isSelected ? 20 : 16))
                }

                // Deal count badge
                if venueWithDeals.deals.count > 0 {
                    Text("\(venueWithDeals.deals.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(venueWithDeals.hasActiveDeals ? Color.activeGreen : Color.appSubtext)
                        .cornerRadius(10)
                        .offset(y: -4)
                }
            }
        }
        .animation(AppConstants.springAnimation, value: isSelected)
    }

    private var pinColor: Color {
        if venueWithDeals.hasActiveDeals { return .appPrimary }
        return .appSubtext
    }
}
