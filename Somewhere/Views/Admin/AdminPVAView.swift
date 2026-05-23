import SwiftUI
import CoreLocation

struct AdminPVAView: View {
    @EnvironmentObject var viewModel: AdminViewModel
    @EnvironmentObject var authService: AuthService
    @State private var showingSaveAlert = false
    @State private var rescanLatText = ""
    @State private var rescanLngText = ""
    @State private var rescanRadius: Double = 1.0
    @State private var showingRescanConfirm = false

    @State private var showingNukeConfirm = false
    @State private var showingDedupeConfirm = false

    // Rescan Venue
    @State private var venueSearch = ""
    @State private var venueRescanTarget: Venue?
    @State private var showingVenueRescanConfirm = false

    // Bulk Deal Scan
    @State private var bulkZip = ""
    @State private var bulkRadius: Double = 5.0
    @State private var bulkCenter: CLLocationCoordinate2D?
    @State private var isGeocodingZip = false
    @State private var zipError: String?
    @State private var showingBulkScanConfirm = false

    private var filteredVenues: [Venue] {
        let q = venueSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return viewModel.venues }
        return viewModel.venues.filter {
            $0.name.lowercased().contains(q) || $0.formattedAddress.lowercased().contains(q)
        }
    }

    private func geocodeZip() {
        let zip = bulkZip.trimmingCharacters(in: .whitespaces)
        guard zip.count >= 5 else { bulkCenter = nil; zipError = nil; return }
        isGeocodingZip = true
        zipError = nil
        CLGeocoder().geocodeAddressString(zip) { placemarks, error in
            DispatchQueue.main.async {
                isGeocodingZip = false
                if let coord = placemarks?.first?.location?.coordinate {
                    bulkCenter = coord
                    zipError = nil
                } else {
                    bulkCenter = nil
                    zipError = "ZIP not found"
                }
            }
        }
    }

    var body: some View {
        Form {
            // Master switch
            Section {
                Toggle(isOn: $viewModel.pvaConfig.pvaModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable PVA").font(.appSubheadlineSemiBold)
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
                        .font(.appSubheadlineSemiBold)
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

            // Bulk Deal Scan
            Section {
                HStack {
                    TextField("ZIP code (optional)", text: $bulkZip)
                        .keyboardType(.numberPad)
                        .onChange(of: bulkZip) { _ in geocodeZip() }
                    if isGeocodingZip {
                        ProgressView().scaleEffect(0.8)
                    } else if bulkCenter != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.appSuccess)
                    } else if zipError != nil {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.appError)
                    }
                }

                if let err = zipError {
                    Text(err).font(.appCaption).foregroundColor(.appError)
                }

                if bulkCenter != nil {
                    HStack {
                        Text("Radius")
                        Spacer()
                        Text(String(format: "%.0f mi", bulkRadius))
                            .foregroundColor(.appSubtext)
                    }
                    Slider(value: $bulkRadius, in: 1.0...50.0, step: 1.0)
                        .tint(.appPrimary)
                }

                Button {
                    showingBulkScanConfirm = true
                } label: {
                    Text(bulkCenter != nil ? "Scan Venues Nearby" : "Scan All Unscanned Venues")
                }
                .foregroundColor(.appPrimary)
            } header: {
                Text("Bulk Deal Scan")
            } footer: {
                Text("Scans up to 50 unscanned or failed venues for deals. Leave ZIP blank to scan any location.")
            }

            // Region Refresh
            Section {
                TextField("Latitude", text: $rescanLatText)
                    .keyboardType(.decimalPad)
                TextField("Longitude", text: $rescanLngText)
                    .keyboardType(.decimalPad)
                HStack {
                    Text("Radius")
                    Spacer()
                    Text(String(format: "%.1f mi", rescanRadius))
                        .foregroundColor(.appSubtext)
                }
                Slider(value: $rescanRadius, in: 0.5...10.0, step: 0.5)
                    .tint(.appPrimary)

                Button {
                    showingRescanConfirm = true
                } label: {
                    Text("Refresh Region")
                }
                .foregroundColor(.appPrimary)
                .disabled(Double(rescanLatText) == nil || Double(rescanLngText) == nil)
            } header: {
                Text("Region Refresh")
            } footer: {
                Text("Rescans all existing venues in the area for fresh deals, and queries Google Places to discover any new venues. Runs in background.")
            }

            // Rescan Venue
            Section {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.appSubtext)
                    TextField("Search venues…", text: $venueSearch)
                        .autocorrectionDisabled()
                }

                if viewModel.venues.isEmpty {
                    Text("No venues loaded — open Venues tab first.")
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)
                } else {
                    ForEach(filteredVenues.prefix(30)) { venue in
                        Button {
                            venueRescanTarget = venue
                            showingVenueRescanConfirm = true
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(venue.name)
                                    .font(.appSubheadline)
                                    .foregroundColor(.appText)
                                Text(venue.formattedAddress)
                                    .font(.appCaption)
                                    .foregroundColor(.appSubtext)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if filteredVenues.count > 30 {
                        Text("Showing 30 of \(filteredVenues.count) — type to narrow results.")
                            .font(.appCaption)
                            .foregroundColor(.appSubtext)
                    }
                }
            } header: {
                Text("Rescan Venue")
            } footer: {
                Text("Deletes all existing deals for a venue and kicks off a fresh website + photo scan.")
            }

            // Danger Zone
            Section {
                Button {
                    showingDedupeConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Remove Duplicate Venues")
                    }
                }
                .foregroundColor(.appWarning)

                Button(role: .destructive) {
                    showingNukeConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Delete All Venues & Deals")
                    }
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Deduplication groups venues by Place ID and removes extras, keeping whichever copy has the most deals.")
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
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationTitle("PVA Controls")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Scan unscanned venues?", isPresented: $showingBulkScanConfirm) {
            Button(bulkCenter != nil ? "Scan Next 50 Venues (within \(Int(bulkRadius)) mi of \(bulkZip))" : "Scan Next 50 Venues (any location)") {
                guard let uid = authService.currentUser?.id else { return }
                Task {
                    await viewModel.scanAllUnscannedVenues(
                        userId: uid,
                        center: bulkCenter,
                        radiusMiles: bulkRadius,
                        batchSize: 50
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(bulkCenter != nil
                 ? "Fires background scans for up to 50 unscanned venues within \(Int(bulkRadius)) miles of ZIP \(bulkZip)."
                 : "Fires background scans for up to 50 unscanned venues regardless of location.")
        }
        .confirmationDialog("Refresh this region?", isPresented: $showingRescanConfirm) {
            Button("Refresh Region") {
                guard let lat = Double(rescanLatText),
                      let lng = Double(rescanLngText),
                      let uid = authService.currentUser?.id else { return }
                Task { await viewModel.refreshRegion(latitude: lat, longitude: lng, radiusMiles: rescanRadius, userId: uid) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rescans all existing venues in the area for new deals, and searches Google Places for venues not yet in the database.")
        }
        .confirmationDialog(
            "Rescan \(venueRescanTarget?.name ?? "venue")?",
            isPresented: $showingVenueRescanConfirm
        ) {
            Button("Delete Deals & Rescan") {
                guard let venue = venueRescanTarget,
                      let uid = authService.currentUser?.id else { return }
                Task { await viewModel.rescanVenue(venue, currentUserId: uid) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let venue = venueRescanTarget {
                Text("This will delete all existing deals for \(venue.name) and start a fresh scan. The venue stays in the database.")
            }
        }
        .confirmationDialog("Remove duplicate venues?", isPresented: $showingDedupeConfirm) {
            Button("Remove Duplicates", role: .destructive) {
                Task { await viewModel.deduplicateVenues() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scans all venues, groups by Place ID, and deletes extras (keeping the copy with the most deals). This cannot be undone.")
        }
        .confirmationDialog("Delete ALL venues and deals?", isPresented: $showingNukeConfirm) {
            Button("Delete Everything", role: .destructive) {
                Task { await viewModel.deleteAllVenuesAndDeals() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete every venue and every deal in the database. This cannot be undone.")
        }
        .overlay {
            if let success = viewModel.successMessage {
                VStack {
                    Spacer()
                    Text(success)
                        .font(.appSubheadlineMedium)
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
