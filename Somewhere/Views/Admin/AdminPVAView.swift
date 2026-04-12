import SwiftUI

struct AdminPVAView: View {
    @EnvironmentObject var viewModel: AdminViewModel
    @State private var showingSaveAlert = false

    var body: some View {
        Form {
            // Master switch
            Section {
                Toggle(isOn: $viewModel.pvaConfig.pvaModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable PVA").font(.appSubheadline.weight(.semibold))
                        Text("Progressive Venue Addition system").font(.appCaption).foregroundColor(.appSubtext)
                    }
                }
                .tint(.appPrimary)
            } header: {
                Text("System Status")
            }

            // API Usage
            Section {
                HStack {
                    Text("Daily API Calls")
                    Spacer()
                    Text("\(viewModel.pvaConfig.dailyApiCallCount) / \(viewModel.pvaConfig.maxPlacesApiCallsPerDay)")
                        .foregroundColor(viewModel.pvaConfig.dailyApiCallCount > Int(Double(viewModel.pvaConfig.maxPlacesApiCallsPerDay) * 0.8) ? .appError : .appText)
                        .font(.appSubheadline.weight(.semibold))
                }

                ProgressView(value: Double(viewModel.pvaConfig.dailyApiCallCount) / Double(max(viewModel.pvaConfig.maxPlacesApiCallsPerDay, 1)))
                    .tint(Double(viewModel.pvaConfig.dailyApiCallCount) / Double(max(viewModel.pvaConfig.maxPlacesApiCallsPerDay, 1)) > 0.8 ? .appError : .appPrimary)

                Stepper("Daily Limit: \(viewModel.pvaConfig.maxPlacesApiCallsPerDay)",
                        value: $viewModel.pvaConfig.maxPlacesApiCallsPerDay,
                        in: 100...2000, step: 100)

                Button("Reset Daily Counter") {
                    Task { await viewModel.resetDailyApiCount() }
                }
                .foregroundColor(.appPrimary)
            } header: {
                Text("API Usage")
            } footer: {
                Text("Google Places API calls are counted daily. Reset occurs at midnight UTC.")
            }

            // Grid & Search Settings
            Section {
                HStack {
                    Text("Cell Size")
                    Spacer()
                    Text(String(format: "%.2f mi", viewModel.pvaConfig.cellSizeMiles))
                        .foregroundColor(.appSubtext)
                }

                Slider(value: $viewModel.pvaConfig.cellSizeMiles, in: 0.25...2.0, step: 0.25)
                    .tint(.appPrimary)

                HStack {
                    Text("Search Radius")
                    Spacer()
                    Text(String(format: "%.1f mi", viewModel.pvaConfig.searchRadiusMiles))
                        .foregroundColor(.appSubtext)
                }
                Slider(value: $viewModel.pvaConfig.searchRadiusMiles, in: 0.5...5.0, step: 0.5)
                    .tint(.appPrimary)

                Stepper("Max New Venues/Search: \(viewModel.pvaConfig.maxNewVenuesPerSearch)",
                        value: $viewModel.pvaConfig.maxNewVenuesPerSearch,
                        in: 10...200, step: 10)
            } header: {
                Text("Grid & Search Settings")
            } footer: {
                Text("Smaller cells = more precise coverage but more API calls. Larger cells = cheaper but less precise.")
            }

            // Staleness settings
            Section {
                Stepper("Cell Stale After: \(viewModel.pvaConfig.cellStaleDays) days",
                        value: $viewModel.pvaConfig.cellStaleDays,
                        in: 7...365, step: 7)

                Stepper("Re-verify Venues After: \(viewModel.pvaConfig.venueReverifyDays) days",
                        value: $viewModel.pvaConfig.venueReverifyDays,
                        in: 30...365, step: 30)

                Button("Trigger Venue Re-verification") {
                    Task { await viewModel.triggerPVAReverify() }
                }
                .foregroundColor(.appPrimary)
            } header: {
                Text("Staleness & Verification")
            }

            // Scan settings
            Section {
                Toggle("Auto-Scan New Venue Websites", isOn: $viewModel.pvaConfig.autoScanWebsites)
                    .tint(.appPrimary)
                Toggle("AI Auto-Detection", isOn: $viewModel.pvaConfig.autoScanEnabled)
                    .tint(.appPrimary)

                HStack {
                    Text("Scan Delay")
                    Spacer()
                    Text(String(format: "%.1fs", viewModel.pvaConfig.scanDelaySeconds))
                        .foregroundColor(.appSubtext)
                }
                Slider(value: $viewModel.pvaConfig.scanDelaySeconds, in: 0.5...5.0, step: 0.5)
                    .tint(.appPrimary)

                Stepper("Max Scan Attempts: \(viewModel.pvaConfig.maxScanAttemptsPerVenue)",
                        value: $viewModel.pvaConfig.maxScanAttemptsPerVenue,
                        in: 1...10, step: 1)
            } header: {
                Text("Scanning Settings")
            }

            // User submission settings
            Section {
                Toggle("Allow User Submissions", isOn: $viewModel.pvaConfig.userSubmissionsEnabled)
                    .tint(.appPrimary)
                Toggle("Require Admin Approval", isOn: $viewModel.pvaConfig.requireApprovalForUserDeals)
                    .tint(.appPrimary)
            } header: {
                Text("User Contributions")
            }

            // PVA Stats
            Section {
                LabeledContent("Total Venues", value: "\(viewModel.pvaStats.totalVenuesInDB)")
                LabeledContent("Pending Scan", value: "\(viewModel.pvaStats.venuesPendingScan)")
                LabeledContent("Scanned", value: "\(viewModel.pvaStats.venuesScanned)")
                LabeledContent("Permanently Closed", value: "\(viewModel.pvaStats.venuesClosed)")
            } header: {
                Text("Current Stats")
            }

            // Save
            Section {
                Button {
                    Task { await viewModel.savePVAConfig() }
                } label: {
                    HStack {
                        Spacer()
                        Text("Save Configuration")
                            .font(.appHeadline)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.appPrimary)
            }
        }
        .navigationTitle("PVA Controls")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if let success = viewModel.successMessage {
                VStack {
                    Spacer()
                    Text(success)
                        .font(.appSubheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.appSuccess)
                        .cornerRadius(20)
                        .padding(.bottom, 32)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(), value: viewModel.successMessage)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        viewModel.successMessage = nil
                    }
                }
            }
        }
    }
}
