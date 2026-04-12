import SwiftUI
import CoreLocation
import MapKit

struct VenueCardView: View {
    let venueWithDeals: VenueWithDeals
    let userLocation: CLLocation?
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onVote: (String, Bool) -> Void

    private var venue: Venue { venueWithDeals.venue }
    private var deals: [Deal] { venueWithDeals.deals }

    var body: some View {
        VStack(spacing: 0) {
            // Venue header (always visible)
            venueHeader
                .onTapGesture {
                    withAnimation(AppConstants.springAnimation) {
                        onToggleExpand()
                    }
                    HapticFeedback.impact(.light)
                }

            // Deals list (collapsible)
            if isExpanded && !deals.isEmpty {
                Divider().padding(.horizontal, 16)
                dealsSection
            }
        }
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.07), radius: 4, x: 0, y: 2)
    }

    // MARK: - Venue Header

    private var venueHeader: some View {
        HStack(spacing: 12) {
            // Photo thumbnail
            VenuePhotoView(photoReference: venue.photoReference, maxWidth: 64)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(venue.name)
                        .font(.appHeadline)
                        .foregroundColor(.appText)
                        .lineLimit(1)
                    Spacer()
                    if venueWithDeals.hasActiveDeals {
                        activeNowBadge
                    }
                }

                HStack(spacing: 6) {
                    Text(venue.category.icon)
                    Text(venue.category.displayName)
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)
                    if let priceLevel = venue.priceLevelString, !priceLevel.isEmpty {
                        Text("·").foregroundColor(.appSubtext)
                        Text(priceLevel)
                            .font(.appCaption)
                            .foregroundColor(.appSubtext)
                    }
                    if let rating = venue.rating {
                        Text("·").foregroundColor(.appSubtext)
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.appAccent)
                            Text(String(format: "%.1f", rating))
                                .font(.appCaption)
                                .foregroundColor(.appSubtext)
                        }
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.appPrimary)
                    if let userLocation = userLocation {
                        Text(venue.formattedDistance(from: userLocation))
                    }
                    Text("·")
                    Text(venue.address)
                        .lineLimit(1)
                }
                .font(.appCaption)
                .foregroundColor(.appSubtext)
            }

            // Chevron
            VStack {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appSubtext)
                    .padding(8)
            }
        }
        .padding(16)
    }

    private var activeNowBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.activeGreen)
                .frame(width: 6, height: 6)
            Text("Now")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.activeGreen)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.activeGreen.opacity(0.12))
        .cornerRadius(10)
    }

    // MARK: - Deals Section

    private var dealsSection: some View {
        VStack(spacing: 0) {
            ForEach(deals) { deal in
                DealRowView(deal: deal, onVote: onVote)
                if deal.id != deals.last?.id {
                    Divider().padding(.horizontal, 16)
                }
            }

            // Navigation buttons
            Divider().padding(.horizontal, 16)
            navigationButtons
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            // Navigate button
            NavigationButton(
                title: "Directions",
                icon: "arrow.triangle.turn.up.right.circle.fill",
                color: .appPrimary
            ) {
                openNavigation()
            }

            // Website button
            if let website = venue.website, let url = URL(string: website) {
                NavigationButton(
                    title: "Website",
                    icon: "safari",
                    color: .appAccent
                ) {
                    UIApplication.shared.open(url)
                }
            }

            // Call button
            if let phone = venue.phone {
                let digits = phone.filter { $0.isNumber }
                if let url = URL(string: "tel://\(digits)") {
                    NavigationButton(
                        title: "Call",
                        icon: "phone.fill",
                        color: Color(hex: "#27AE60")
                    ) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func openNavigation() {
        let coordinate = venue.coordinate
        // Try Apple Maps first
        if let url = venue.appleMapsURL {
            UIApplication.shared.open(url)
        } else {
            let placemark = MKPlacemark(coordinate: coordinate)
            let mapItem = MKMapItem(placemark: placemark)
            mapItem.name = venue.name
            mapItem.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
            ])
        }
    }
}

// MARK: - Navigation Button
struct NavigationButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title).font(.appCaption.weight(.semibold))
            }
            .foregroundColor(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(color.opacity(0.1))
            .cornerRadius(20)
        }
    }
}

// MARK: - Skeleton Loading
struct VenueCardSkeletonView: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .frame(width: 64, height: 64)
                .foregroundColor(.appDivider)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: 140, height: 16)
                    .foregroundColor(.appDivider)
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: 100, height: 12)
                    .foregroundColor(.appDivider)
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: 80, height: 12)
                    .foregroundColor(.appDivider)
            }
            Spacer()
        }
        .padding(16)
        .background(Color.appSurface)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        .opacity(isAnimating ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
        .onAppear { isAnimating = true }
    }
}
