import SwiftUI

struct AdminVenuesView: View {
    @EnvironmentObject var viewModel: AdminViewModel
    @EnvironmentObject var authService: AuthService
    @State private var searchQuery = ""
    @State private var filterClosed = false
    @State private var filterPending = false
    @State private var venueToDelete: Venue?
    @State private var showingDeleteAlert = false
    @State private var showingScanAllConfirm = false

    private var filteredVenues: [Venue] {
        viewModel.venues.filter { venue in
            if filterClosed && !venue.isPermanentlyClosed { return false }
            if filterPending && venue.scanStatus != .pending { return false }
            if !searchQuery.isEmpty {
                let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
                return venue.name.lowercased().contains(q)
                    || venue.address.lowercased().contains(q)
                    || venue.city.lowercased().contains(q)
                    || venue.zipCode.lowercased().contains(q)
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
                    NavigationLink(destination:
                        AdminVenueDetailView(venue: venue)
                            .environmentObject(viewModel)
                            .environmentObject(authService)
                    ) {
                        AdminVenueRow(
                            venue: venue,
                            onMarkClosed: { Task { await viewModel.markVenueClosed(id: venue.id) } },
                            onRescan: {
                                guard let uid = authService.currentUser?.id else { return }
                                Task { await viewModel.rescanVenue(venue, currentUserId: uid) }
                            },
                            onDelete: {
                                venueToDelete = venue
                                showingDeleteAlert = true
                            }
                        )
                    }
                    .listRowBackground(Color.appSurface)
                    .listRowSeparatorTint(Color.appDivider)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Venues (\(viewModel.totalVenues))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingScanAllConfirm = true
                } label: {
                    Label("Scan All", systemImage: "arrow.clockwise.circle")
                }
            }
        }
        .confirmationDialog(
            "Scan unscanned venues?",
            isPresented: $showingScanAllConfirm
        ) {
            Button("Scan Next 50 Venues (any location)") {
                guard let uid = authService.currentUser?.id else { return }
                Task { await viewModel.scanAllUnscannedVenues(userId: uid, batchSize: 50) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Fires background scans for up to 50 unscanned venues. To restrict by location, use PVA Controls → Bulk Deal Scan.")
        }
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
    let onRescan: () -> Void
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
                        .font(.appSubheadlineMedium)
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
                Button("Rescan for Deals", systemImage: "arrow.clockwise") { onRescan() }
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

// MARK: - Venue Detail View

struct AdminVenueDetailView: View {
    let venue: Venue
    @EnvironmentObject var viewModel: AdminViewModel
    @EnvironmentObject var authService: AuthService
    @State private var deals: [Deal] = []
    @State private var isLoading = true
    @State private var dealToDelete: Deal?
    @State private var showingDeleteDealConfirm = false
    @State private var showingVenueDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            // Venue header
            Section {
                HStack(spacing: 12) {
                    VenuePhotoView(photoReference: venue.photoReference, maxWidth: 60)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(venue.name).font(.appHeadline).foregroundColor(.appText)
                        Text(venue.formattedAddress).font(.appCaption).foregroundColor(.appSubtext)
                        HStack(spacing: 6) {
                            Text(venue.category.displayName).font(.appCaption2).foregroundColor(.appSubtext)
                            Text("·").foregroundColor(.appSubtext)
                            scanStatusText(venue.scanStatus)
                            Text("·").foregroundColor(.appSubtext)
                            Text("\(deals.count) deal\(deals.count == 1 ? "" : "s")").font(.appCaption2).foregroundColor(.appSubtext)
                        }
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.appSurface)
            }

            // Actions
            Section {
                Button {
                    guard let uid = authService.currentUser?.id else { return }
                    Task { await viewModel.rescanVenue(venue, currentUserId: uid) }
                } label: {
                    Label("Rescan for Deals", systemImage: "arrow.clockwise")
                        .foregroundColor(.appPrimary)
                }
                .listRowBackground(Color.appSurface)
                if !venue.isPermanentlyClosed {
                    Button {
                        Task { await viewModel.markVenueClosed(id: venue.id) }
                    } label: {
                        Label("Mark as Permanently Closed", systemImage: "xmark.circle")
                            .foregroundColor(.appWarning)
                    }
                    .listRowBackground(Color.appSurface)
                }
                Button(role: .destructive) {
                    showingVenueDeleteConfirm = true
                } label: {
                    Label("Delete Venue & All Deals", systemImage: "trash")
                }
                .listRowBackground(Color.appSurface)
            }

            // Deals
            Section {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding()
                        .listRowBackground(Color.appSurface)
                } else if deals.isEmpty {
                    Text("No deals found for this venue.")
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.appSurface)
                } else {
                    ForEach(deals) { deal in
                        AdminDealCard(deal: deal) {
                            dealToDelete = deal
                            showingDeleteDealConfirm = true
                        }
                        .listRowBackground(Color.appSurface)
                        .listRowSeparatorTint(Color.appDivider)
                    }
                }
            } header: {
                Text("Deals")
                    .font(.appCaptionSemiBold)
                    .foregroundColor(.appSubtext)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(venue.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await loadDeals() } }
        .confirmationDialog("Delete deal?", isPresented: $showingDeleteDealConfirm) {
            Button("Delete", role: .destructive) {
                if let d = dealToDelete { Task { await deleteDeal(d) } }
            }
        }
        .confirmationDialog("Delete \(venue.name)?", isPresented: $showingVenueDeleteConfirm) {
            Button("Delete Venue & All Deals", role: .destructive) {
                Task {
                    await viewModel.deleteVenue(id: venue.id)
                    dismiss()
                }
            }
        } message: {
            Text("This permanently deletes the venue and all its deals.")
        }
    }

    private func loadDeals() async {
        isLoading = true
        deals = (try? await FirestoreService.shared.getAllDealsForVenue(venueId: venue.id)) ?? []
        isLoading = false
    }

    private func deleteDeal(_ deal: Deal) async {
        try? await FirestoreService.shared.deleteDeal(id: deal.id, venueId: venue.id)
        deals.removeAll { $0.id == deal.id }
    }

    private func scanStatusText(_ status: VenueScanStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .pending:  return ("Pending Scan", .appWarning)
            case .scanning: return ("Scanning", .appPrimary)
            case .scanned:  return ("Scanned", .appSuccess)
            case .failed:   return ("Scan Failed", .appError)
            case .noDeals:  return ("No Deals Found", .appSubtext)
            }
        }()
        return Text(label).font(.appCaption2).foregroundColor(color)
    }
}
