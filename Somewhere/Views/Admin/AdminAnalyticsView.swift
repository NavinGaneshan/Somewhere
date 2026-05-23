import SwiftUI
import Charts

struct AdminAnalyticsView: View {
    @EnvironmentObject var viewModel: AdminViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 7-day summary
                sevenDaySummary

                // Category breakdown
                categoryBreakdown

                // PVA efficiency
                pvaEfficiency
            }
            .padding(16)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Analytics")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 7-Day Summary

    private var sevenDaySummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Last 7 Days")
                .font(.appHeadline)
                .foregroundColor(.appText)

            HStack(spacing: 12) {
                AnalyticsCard(
                    title: "New Venues",
                    value: "\(viewModel.newVenuesLast7Days)",
                    icon: "building.2.fill",
                    color: Color(hex: "#5856D6")
                )
                AnalyticsCard(
                    title: "New Deals",
                    value: "\(viewModel.newDealsLast7Days)",
                    icon: "tag.fill",
                    color: .appAccent
                )
                AnalyticsCard(
                    title: "Active Users",
                    value: "\(viewModel.activeUsersLast7Days)",
                    icon: "person.3.fill",
                    color: .appPrimary
                )
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    // MARK: - Category Breakdown

    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Deal Categories")
                .font(.appHeadline)
                .foregroundColor(.appText)

            let drinkDeals = viewModel.allDeals.filter { $0.category == .drinks }.count
            let foodDeals = viewModel.allDeals.filter { $0.category == .food }.count
            let activityDeals = viewModel.allDeals.filter { $0.category == .activity }.count
            let total = max(drinkDeals + foodDeals + activityDeals, 1)

            VStack(spacing: 12) {
                CategoryBar(category: .drinks, count: drinkDeals, total: total)
                CategoryBar(category: .food, count: foodDeals, total: total)
                CategoryBar(category: .activity, count: activityDeals, total: total)
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    // MARK: - PVA Efficiency

    private var pvaEfficiency: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PVA Efficiency")
                .font(.appHeadline)
                .foregroundColor(.appText)

            let totalVenues = max(viewModel.pvaStats.totalVenuesInDB, 1)
            let scannedPct = Double(viewModel.pvaStats.venuesScanned) / Double(totalVenues)
            let closedPct = Double(viewModel.pvaStats.venuesClosed) / Double(totalVenues)
            let pendingPct = Double(viewModel.pvaStats.venuesPendingScan) / Double(totalVenues)

            VStack(spacing: 14) {
                PVAMetricRow(
                    label: "Venues Scanned",
                    value: viewModel.pvaStats.venuesScanned,
                    total: totalVenues,
                    percent: scannedPct,
                    color: .appSuccess
                )
                PVAMetricRow(
                    label: "Pending Scan",
                    value: viewModel.pvaStats.venuesPendingScan,
                    total: totalVenues,
                    percent: pendingPct,
                    color: .appWarning
                )
                PVAMetricRow(
                    label: "Permanently Closed",
                    value: viewModel.pvaStats.venuesClosed,
                    total: totalVenues,
                    percent: closedPct,
                    color: .appError
                )

                Divider()

                HStack {
                    Label("API Budget", systemImage: "network")
                        .font(.appSubheadline)
                        .foregroundColor(.appText)
                    Spacer()
                    Text(String(format: "%.0f%%", viewModel.pvaStats.apiUsagePercent))
                        .font(.appSubheadlineBold)
                        .foregroundColor(viewModel.pvaStats.apiUsagePercent > 80 ? .appError : .appText)
                }
                ProgressView(value: viewModel.pvaStats.apiUsagePercent / 100)
                    .tint(viewModel.pvaStats.apiUsagePercent > 80 ? .appError : .appPrimary)
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}

// MARK: - Supporting Views

struct AnalyticsCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.12))
                .cornerRadius(10)

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.appText)

            Text(title)
                .font(.appCaption)
                .foregroundColor(.appSubtext)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.appBackground)
        .cornerRadius(12)
    }
}

struct CategoryBar: View {
    let category: DealCategory
    let count: Int
    let total: Int

    private var percentage: Double { Double(count) / Double(total) }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: category.icon)
                    .foregroundColor(category.uiColor)
                Text(category.displayName)
                    .font(.appSubheadline)
                    .foregroundColor(.appText)
                Spacer()
                Text("\(count)")
                    .font(.appSubheadlineBold)
                    .foregroundColor(category.uiColor)
                Text(String(format: "(%.0f%%)", percentage * 100))
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(category.uiColor.opacity(0.15))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(category.uiColor)
                        .frame(width: geo.size.width * percentage, height: 8)
                }
            }
            .frame(height: 8)
        }
    }
}

struct PVAMetricRow: View {
    let label: String
    let value: Int
    let total: Int
    let percent: Double
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.appSubheadline)
                    .foregroundColor(.appText)
                Spacer()
                Text("\(value) / \(total)")
                    .font(.appCaptionSemiBold)
                    .foregroundColor(color)
            }
            ProgressView(value: percent).tint(color)
        }
    }
}
