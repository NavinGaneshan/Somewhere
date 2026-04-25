import SwiftUI

struct AdminSearchLogsView: View {
    @EnvironmentObject var viewModel: AdminViewModel

    var body: some View {
        List {
            if viewModel.searchLogs.isEmpty && !viewModel.isLoading {
                Text("No search logs yet. Any pull-to-refresh on Home will generate one.")
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
                    .listRowBackground(Color.clear)
            }

            ForEach(viewModel.searchLogs, id: \.id) { log in
                SearchLogRow(log: log)
            }
        }
        .navigationTitle("Search Logs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.loadSearchLogs()
        }
        .overlay {
            if viewModel.isLoading && viewModel.searchLogs.isEmpty {
                ProgressView()
            }
        }
        .task {
            if viewModel.searchLogs.isEmpty {
                await viewModel.loadSearchLogs()
            }
        }
    }
}

struct SearchLogRow: View {
    let log: SearchLog

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundColor(.appSubtext)
                Text(timeFormatter.string(from: log.timestamp.dateValue()))
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
                Spacer()
                if log.apiCallsMade > 0 {
                    Text("\(log.apiCallsMade) API call\(log.apiCallsMade == 1 ? "" : "s")")
                        .font(.appCaption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appAccent.opacity(0.15))
                        .foregroundColor(.appAccent)
                        .cornerRadius(8)
                }
            }

            Text(String(format: "%.4f, %.4f  ·  %.1f mi radius", log.latitude, log.longitude, log.radius))
                .font(.appCaption.weight(.medium))
                .foregroundColor(.appText)

            HStack(spacing: 12) {
                Label("+\(log.newVenuesFound) new", systemImage: "building.2.fill")
                    .foregroundColor(log.newVenuesFound > 0 ? .appSuccess : .appSubtext)
                Label("\(log.cellsSearched.count) cells", systemImage: "square.grid.3x3")
                    .foregroundColor(.appSubtext)
                Label(String(format: "%.1fs", log.searchDuration), systemImage: "timer")
                    .foregroundColor(.appSubtext)
            }
            .font(.appCaption2)
        }
        .padding(.vertical, 4)
    }
}
