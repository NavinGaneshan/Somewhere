import SwiftUI

struct AdminDealsView: View {
    @EnvironmentObject var viewModel: AdminViewModel
    @State private var selectedTab = 0
    @State private var searchQuery = ""
    @State private var dealToReject: Deal?
    @State private var rejectionNotes = ""
    @State private var showingRejectAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector
            Picker("", selection: $selectedTab) {
                Text("Pending (\(viewModel.pendingDeals.count))").tag(0)
                Text("All Deals (\(viewModel.allDeals.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(16)
            .background(Color.appBackground)

            // Search (for All Deals tab)
            if selectedTab == 1 {
                AuthTextField(placeholder: "Search deals...", text: $searchQuery, icon: "magnifyingglass")
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .background(Color.appBackground)
            }

            List {
                if selectedTab == 0 {
                    pendingDealsList
                } else {
                    allDealsList
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Deals")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingRejectAlert) {
            rejectSheet
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            if viewModel.allDeals.isEmpty {
                Task { await viewModel.loadAllDeals() }
            }
        }
        .refreshable {
            Task { await viewModel.loadAllDeals() }
        }
    }

    // MARK: - Lists

    @ViewBuilder
    private var pendingDealsList: some View {
        if viewModel.pendingDeals.isEmpty {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.appSuccess)
                        Text("All caught up!")
                            .font(.appTitle3)
                        Text("No deals pending review")
                            .font(.appSubheadline)
                            .foregroundColor(.appSubtext)
                    }
                    .padding(.vertical, 40)
                    Spacer()
                }
            }
            .listRowBackground(Color.appBackground)
        } else {
            ForEach(viewModel.pendingDeals) { deal in
                PendingDealRow(deal: deal) {
                    Task { await viewModel.approveDeal(deal) }
                } onReject: {
                    dealToReject = deal
                    showingRejectAlert = true
                }
                .listRowBackground(Color.appSurface)
            }
        }
    }

    @ViewBuilder
    private var allDealsList: some View {
        let filtered = viewModel.allDeals.filter { deal in
            guard !searchQuery.isEmpty else { return true }
            let q = searchQuery.lowercased()
            return deal.title.lowercased().contains(q) ||
                   deal.venueName.lowercased().contains(q) ||
                   deal.description.lowercased().contains(q)
        }

        ForEach(filtered) { deal in
            AdminDealRow(deal: deal) {
                Task { await viewModel.deleteDeal(deal) }
            }
            .listRowBackground(Color.appSurface)
        }
    }

    // MARK: - Reject Sheet

    private var rejectSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let deal = dealToReject {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(deal.title)
                            .font(.appTitle3)
                        Text(deal.venueName)
                            .font(.appSubheadline)
                            .foregroundColor(.appSubtext)
                        Text(deal.description)
                            .font(.appBody)
                            .foregroundColor(.appSubtext)
                    }
                    .padding(16)
                    .background(Color.appSurface)
                    .cornerRadius(12)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Rejection Reason").font(.appSubheadlineMedium)
                    ZStack(alignment: .topLeading) {
                        if rejectionNotes.isEmpty {
                            Text("Explain why this deal was rejected...")
                                .font(.appBody)
                                .foregroundColor(.appSubtext)
                                .padding(12)
                        }
                        TextEditor(text: $rejectionNotes)
                            .frame(minHeight: 100)
                            .font(.appBody)
                            .padding(8)
                    }
                    .background(Color.appSurface)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appDivider, lineWidth: 1))
                }

                Spacer()
            }
            .padding(16)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Reject Deal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingRejectAlert = false
                        rejectionNotes = ""
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reject") {
                        if let deal = dealToReject {
                            Task { await viewModel.rejectDeal(deal, notes: rejectionNotes) }
                        }
                        showingRejectAlert = false
                        rejectionNotes = ""
                    }
                    .foregroundColor(.appError)
                    .disabled(rejectionNotes.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Pending Deal Row
struct PendingDealRow: View {
    let deal: Deal
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: deal.category.icon)
                    .font(.system(size: 16))
                    .foregroundColor(deal.category.uiColor)
                    .frame(width: 36, height: 36)
                    .background(deal.category.uiColor.opacity(0.12))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(deal.title).font(.appSubheadlineSemiBold)
                    Text(deal.venueName).font(.appCaption).foregroundColor(.appSubtext)
                }

                Spacer()

                Text(deal.source.displayName)
                    .font(.appCaption2)
                    .foregroundColor(.appSubtext)
            }

            Text(deal.description)
                .font(.appCaption)
                .foregroundColor(.appSubtext)
                .lineLimit(3)

            HStack(spacing: 6) {
                Label(deal.formattedTimeRange, systemImage: "clock")
                Text("·")
                Text(deal.formattedDays)
            }
            .font(.appCaption)
            .foregroundColor(.appText)

            HStack(spacing: 10) {
                Button(action: onApprove) {
                    Label("Approve", systemImage: "checkmark")
                        .font(.appCaptionBold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.appSuccess)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.borderless)

                Button(action: onReject) {
                    Label("Reject", systemImage: "xmark")
                        .font(.appCaptionBold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.appError)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}

struct AdminDealRow: View {
    let deal: Deal
    let onDelete: () -> Void

    var body: some View {
        AdminDealCard(deal: deal, onDelete: onDelete)
    }
}

// MARK: - Deal Card (shared between Deals list and Venue detail)

struct AdminDealCard: View {
    let deal: Deal
    let onDelete: () -> Void
    @State private var showingDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                // Category badge
                Image(systemName: deal.category.icon)
                    .font(.system(size: 16))
                    .foregroundColor(deal.category.uiColor)
                    .frame(width: 36, height: 36)
                    .background(deal.category.uiColor.opacity(0.12))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(deal.title)
                            .font(.appSubheadlineSemiBold)
                            .foregroundColor(.appText)
                        Spacer()
                        dealStatusBadge(deal.status)
                    }
                    Text(deal.venueName)
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)
                }
            }

            // Description (the actual deal text including price)
            if !deal.description.isEmpty && deal.description != deal.title {
                Text(deal.description)
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Time + days
            HStack(spacing: 8) {
                Label(deal.formattedTimeRange, systemImage: "clock")
                Text("·").foregroundColor(.appDivider)
                Text(deal.formattedDays)
                Spacer()
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(.appError)
                }
                .buttonStyle(.borderless)
            }
            .font(.appCaption)
            .foregroundColor(.appText)
        }
        .padding(.vertical, 10)
        .confirmationDialog("Delete this deal?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private func dealStatusBadge(_ status: DealStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .active:      return ("Active", .appSuccess)
            case .pending:     return ("Pending", .appWarning)
            case .rejected:    return ("Rejected", .appError)
            case .expired:     return ("Expired", .appSubtext)
            case .unverified:  return ("Unverified", .inactiveGray)
            }
        }()
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}
