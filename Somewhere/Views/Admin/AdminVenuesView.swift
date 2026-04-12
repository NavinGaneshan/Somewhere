import SwiftUI

struct AdminVenuesView: View {
    @EnvironmentObject var viewModel: AdminViewModel
    @State private var searchQuery = ""
    @State private var filterClosed = false
    @State private var filterPending = false
    @State private var venueToDelete: Venue?
    @State private var showingDeleteAlert = false

    private var filteredVenues: [Venue] {
        viewModel.venues.filter { venue in
            if filterClosed && !venue.isPermanentlyClosed { return false }
            if filterPending && venue.scanStatus != .pending { return false }
            if !searchQuery.isEmpty {
                let q = searchQuery.lowercased()
                return venue.name.lowercased().contains(q) || venue.address.lowercased().contains(q)
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                AuthTextField(placeholder: "Search venues...", text: $searchQuery, icon: "magnifyingglass")

                HStack(spacing: 8) {
                    FilterChip(label: "Permanently Closed", icon: "xmark.circle", color: filterClosed ? .appError : .appSubtext) {
                        filterClosed.toggle()
                    }
                    FilterChip(label: "Pending Scan", icon: "hourglass", color: filterPending ? .appWarning : .appSubtext) {
                        filterPending.toggle()
                    }
                    Spacer()
                }
            }
            .padding(16)
            .background(Color.appBackground)

            List {
                ForEach(filteredVenues) { venue in
                    AdminVenueRow(venue: venue) {
                        // Mark closed
                        Task { await viewModel.markVenueClosed(id: venue.id) }
                    } onDelete: {
                        venueToDelete = venue
                        showingDeleteAlert = true
                    }
                }
            }
            .listStyle(.plain)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Venues (\(viewModel.totalVenues))")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete Venue", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let venue = venueToDelete {
                    Task { await viewModel.deleteVenue(id: venue.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \(venueToDelete?.name ?? "this venue") and all its deals. This cannot be undone.")
        }
        .onAppear {
            if viewModel.venues.isEmpty {
                Task { await viewModel.loadVenues() }
            }
        }
    }
}

struct AdminVenueRow: View {
    let venue: Venue
    let onMarkClosed: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Photo
            VenuePhotoView(photoReference: venue.photoReference, maxWidth: 44)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    venue.isPermanentlyClosed ?
                        Color.black.opacity(0.5).clipShape(RoundedRectangle(cornerRadius: 8)) : nil
                )

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(venue.name)
                        .font(.appSubheadline.weight(.medium))
                        .foregroundColor(venue.isPermanentlyClosed ? .appSubtext : .appText)
                        .strikethrough(venue.isPermanentlyClosed)
                    if venue.isPermanentlyClosed {
                        Text("CLOSED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.appError)
                            .cornerRadius(4)
                    }
                }
                Text(venue.address)
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(venue.category.displayName)
                        .font(.appCaption2)
                        .foregroundColor(.appSubtext)
                    Text("·")
                    scanStatusBadge(venue.scanStatus)
                    Text("·")
                    Text("\(venue.dealCount) deals")
                        .font(.appCaption2)
                        .foregroundColor(.appSubtext)
                }
            }

            Spacer()

            Menu {
                if !venue.isPermanentlyClosed {
                    Button("Mark as Closed") { onMarkClosed() }
                }
                Button("Delete", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.appSubtext)
            }
        }
        .padding(.vertical, 4)
    }

    private func scanStatusBadge(_ status: VenueScanStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .pending: return ("Pending", .appWarning)
            case .scanning: return ("Scanning", .appPrimary)
            case .scanned: return ("Scanned", .appSuccess)
            case .failed: return ("Failed", .appError)
            case .noDeals: return ("No Deals", .appSubtext)
            }
        }()
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
    }
}
