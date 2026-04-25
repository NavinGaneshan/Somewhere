import SwiftUI

struct AdminDashboardView: View {
    @StateObject private var viewModel = AdminViewModel()
    @EnvironmentObject var authService: AuthService

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Stats Grid
                statsGrid

                // Pending deals alert
                if !viewModel.pendingDeals.isEmpty {
                    pendingDealsAlert
                }

                // Quick Links
                quickLinks
            }
            .padding(16)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Admin Dashboard")
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if viewModel.isLoading {
                ProgressView("Loading...").padding(20).background(.ultraThinMaterial).cornerRadius(12)
            }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            Task { await viewModel.loadDashboard() }
        }
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                AdminStatCard(
                    title: "Total Users",
                    value: "\(viewModel.totalUsers)",
                    trend: "+\(viewModel.activeUsersLast7Days) this week",
                    icon: "person.3.fill",
                    color: .appPrimary
                )
                AdminStatCard(
                    title: "Total Venues",
                    value: "\(viewModel.totalVenues)",
                    trend: "+\(viewModel.newVenuesLast7Days) this week",
                    icon: "building.2.fill",
                    color: Color(hex: "#5856D6")
                )
            }

            HStack(spacing: 12) {
                AdminStatCard(
                    title: "Active Deals",
                    value: "\(viewModel.totalDeals)",
                    trend: "+\(viewModel.newDealsLast7Days) this week",
                    icon: "tag.fill",
                    color: .appAccent
                )
                AdminStatCard(
                    title: "Pending Review",
                    value: "\(viewModel.pendingDeals.count)",
                    trend: "Requires attention",
                    icon: "clock.badge.exclamationmark.fill",
                    color: viewModel.pendingDeals.isEmpty ? .appSuccess : .appWarning
                )
            }

            // API Usage
            apiUsageCard
        }
    }

    private var apiUsageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("API Usage Today", systemImage: "network")
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundColor(.appText)
                Spacer()
                Text("\(viewModel.pvaStats.apiCallsToday) / \(viewModel.pvaStats.apiCallsLimit)")
                    .font(.appCaption.weight(.bold))
                    .foregroundColor(viewModel.pvaStats.apiUsagePercent > 80 ? .appError : .appText)
            }

            ProgressView(value: viewModel.pvaStats.apiUsagePercent / 100)
                .tint(viewModel.pvaStats.apiUsagePercent > 80 ? .appError :
                      viewModel.pvaStats.apiUsagePercent > 60 ? .appWarning : .appSuccess)

            HStack(spacing: 16) {
                Label("\(viewModel.pvaStats.totalVenuesInDB) venues", systemImage: "building.2")
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
                Label("\(viewModel.pvaStats.venuesPendingScan) pending scan", systemImage: "hourglass")
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
                Label("\(viewModel.pvaStats.venuesClosed) closed", systemImage: "xmark.circle")
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    // MARK: - Pending Deals Alert

    private var pendingDealsAlert: some View {
        NavigationLink(destination: AdminDealsView().environmentObject(viewModel)) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.appWarning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.pendingDeals.count) deal\(viewModel.pendingDeals.count == 1 ? "" : "s") awaiting review")
                        .font(.appSubheadline.weight(.semibold))
                        .foregroundColor(.appText)
                    Text("Tap to review and approve")
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.appSubtext)
            }
            .padding(16)
            .background(Color.appWarning.opacity(0.1))
            .cornerRadius(AppConstants.cardCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius)
                    .stroke(Color.appWarning.opacity(0.3), lineWidth: 1)
            )
        }
    }

    // MARK: - Quick Links

    private var quickLinks: some View {
        VStack(spacing: 0) {
            AdminNavRow(icon: "person.3.fill", title: "User Management", subtitle: "\(viewModel.totalUsers) users", color: .appPrimary) {
                AdminUsersView().environmentObject(viewModel)
            }
            Divider().padding(.horizontal, 16)
            AdminNavRow(icon: "building.2.fill", title: "Venue Management", subtitle: "\(viewModel.totalVenues) venues", color: Color(hex: "#5856D6")) {
                AdminVenuesView().environmentObject(viewModel)
            }
            Divider().padding(.horizontal, 16)
            AdminNavRow(icon: "tag.fill", title: "Deal Management", subtitle: "\(viewModel.pendingDeals.count) pending", color: .appAccent) {
                AdminDealsView().environmentObject(viewModel)
            }
            Divider().padding(.horizontal, 16)
            AdminNavRow(icon: "gearshape.2.fill", title: "PVA Controls", subtitle: "Progressive Venue Addition", color: Color(hex: "#FF6B6B")) {
                AdminPVAView().environmentObject(viewModel).environmentObject(authService)
            }
            Divider().padding(.horizontal, 16)
            AdminNavRow(icon: "chart.bar.fill", title: "Analytics", subtitle: "Usage & performance", color: Color(hex: "#4CAF50")) {
                AdminAnalyticsView().environmentObject(viewModel)
            }
            Divider().padding(.horizontal, 16)
            AdminNavRow(icon: "list.bullet.rectangle", title: "Search Logs", subtitle: "Recent PVA searches", color: Color(hex: "#8E44AD")) {
                AdminSearchLogsView().environmentObject(viewModel)
            }
        }
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}

// MARK: - Admin Stat Card
struct AdminStatCard: View {
    let title: String
    let value: String
    let trend: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.12))
                    .cornerRadius(8)
                Spacer()
            }

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.appText)

            Text(title)
                .font(.appCaption.weight(.medium))
                .foregroundColor(.appSubtext)

            Text(trend)
                .font(.appCaption2)
                .foregroundColor(color)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}

// MARK: - Admin Nav Row
struct AdminNavRow<Destination: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.12))
                    .cornerRadius(8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.appSubheadline.weight(.medium)).foregroundColor(.appText)
                    Text(subtitle).font(.appCaption).foregroundColor(.appSubtext)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appSubtext)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}
