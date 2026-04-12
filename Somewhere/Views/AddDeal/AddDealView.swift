import SwiftUI
import PhotosUI

struct AddDealView: View {
    @StateObject private var viewModel = AddDealViewModel()
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSource: DealSourceOption = .photo
    @State private var showingSuccessAlert = false

    enum DealSourceOption: String, CaseIterable {
        case photo = "Scan Photo"
        case website = "Scan Website"
        case manual = "Enter Manually"

        var icon: String {
            switch self {
            case .photo: return "camera.fill"
            case .website: return "safari.fill"
            case .manual: return "square.and.pencil"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection

                // Source selector
                sourcePicker

                // Source-specific input
                switch selectedSource {
                case .photo:
                    PhotoScanSection(viewModel: viewModel)
                case .website:
                    WebScanSection(viewModel: viewModel)
                case .manual:
                    EmptyView()
                }

                // Venue selector
                venueSection

                // Deal form (shown after scan or for manual)
                if viewModel.selectedVenue != nil || selectedSource == .manual {
                    DealFormSection(viewModel: viewModel)
                }

                // Submit button
                if viewModel.selectedVenue != nil {
                    submitButton
                }

                // Success/error messages
                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error)
                }
            }
            .padding(16)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Add a Deal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { dismiss() }
                    .foregroundColor(.appSubtext)
            }
        }
        .alert("Deal Submitted!", isPresented: $showingSuccessAlert) {
            Button("Add Another") { viewModel.resetForm() }
            Button("Done") { dismiss() }
        } message: {
            Text(viewModel.successMessage ?? "Your deal has been submitted.")
        }
        .onChange(of: viewModel.successMessage) { msg in
            if msg != nil { showingSuccessAlert = true }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.linearGradient(
                    colors: [Color.appPrimary, Color.appAccent],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Text("Share a Happy Hour Deal")
                .font(.appTitle3)
                .foregroundColor(.appText)
            Text("Scan a photo, website, or enter details manually")
                .font(.appSubheadline)
                .foregroundColor(.appSubtext)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Source Picker

    private var sourcePicker: some View {
        HStack(spacing: 0) {
            ForEach(DealSourceOption.allCases, id: \.self) { option in
                Button {
                    withAnimation {
                        selectedSource = option
                        viewModel.scanResult = nil
                        viewModel.webScanResult = nil
                    }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: option.icon)
                            .font(.system(size: 18))
                        Text(option.rawValue)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedSource == option ? Color.appPrimary : Color.appSurface)
                    .foregroundColor(selectedSource == option ? .white : .appText)
                }
                if option != DealSourceOption.allCases.last {
                    Divider().frame(height: 44)
                }
            }
        }
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appDivider, lineWidth: 1))
    }

    // MARK: - Venue Section

    private var venueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Venue", systemImage: "building.2.fill")
                .font(.appHeadline)
                .foregroundColor(.appText)

            if let venue = viewModel.selectedVenue {
                SelectedVenueRow(venue: venue) {
                    viewModel.selectedVenue = nil
                }
            } else {
                Button {
                    viewModel.showVenueSearch = true
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.appSubtext)
                        Text("Search for a venue...")
                            .foregroundColor(.appSubtext)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundColor(.appSubtext)
                    }
                    .padding(14)
                    .background(Color.appSurface)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appDivider, lineWidth: 1))
                }
            }
        }
        .sheet(isPresented: $viewModel.showVenueSearch) {
            VenueSearchSheet(viewModel: viewModel)
        }
    }

    // MARK: - Submit Button

    private var submitButton: some View {
        Button {
            Task { await viewModel.submitDeal() }
        } label: {
            HStack {
                if viewModel.isLoading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Submit Deal")
                        .font(.appHeadline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(viewModel.isFormValid ? Color.appPrimary : Color.gray.opacity(0.4))
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .disabled(!viewModel.isFormValid || viewModel.isLoading)
    }
}

// MARK: - Photo Scan Section
struct PhotoScanSection: View {
    @ObservedObject var viewModel: AddDealViewModel
    @State private var showingImageSourceMenu = false
    @State private var showingCamera = false
    @State private var cameraImage: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Scan Menu or Sign", systemImage: "camera.fill")
                .font(.appHeadline)
                .foregroundColor(.appText)

            if let image = viewModel.selectedImage {
                // Show scanned image
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .cornerRadius(12)

                    Button {
                        viewModel.selectedImage = nil
                        viewModel.scanResult = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.3), radius: 2)
                    }
                    .padding(8)
                }

                // Scan results
                if viewModel.isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Extracting deals from image...")
                            .font(.appSubheadline)
                            .foregroundColor(.appSubtext)
                    }
                    .padding(12)
                    .background(Color.appSurface)
                    .cornerRadius(10)
                } else if let result = viewModel.scanResult {
                    if result.extractedDeals.isEmpty {
                        Label("No deals detected. Fill in manually below.", systemImage: "info.circle")
                            .font(.appCaption)
                            .foregroundColor(.appSubtext)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(result.extractedDeals.count) deal\(result.extractedDeals.count == 1 ? "" : "s") detected")
                                .font(.appCaption.weight(.semibold))
                                .foregroundColor(.appSuccess)
                            ForEach(result.extractedDeals.indices, id: \.self) { idx in
                                let deal = result.extractedDeals[idx]
                                ExtractedDealRow(deal: deal) {
                                    viewModel.applyScanResult(deal)
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.appSuccess.opacity(0.08))
                        .cornerRadius(10)
                    }
                }
            } else {
                // Upload buttons
                HStack(spacing: 12) {
                    PhotosPicker(selection: $viewModel.imageItem, matching: .images) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                            .font(.appSubheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.appSurface)
                            .foregroundColor(.appPrimary)
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appPrimary, lineWidth: 1))
                    }
                    .onChange(of: viewModel.imageItem) { _ in
                        Task { await viewModel.loadImageFromPicker() }
                    }

                    Button {
                        showingCamera = true
                    } label: {
                        Label("Camera", systemImage: "camera")
                            .font(.appSubheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.appPrimary)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
            }
        }
        .sheet(isPresented: $showingCamera) {
            CameraView(image: $viewModel.selectedImage) {
                Task { await viewModel.scanPhoto() }
            }
        }
    }
}

// MARK: - Web Scan Section
struct WebScanSection: View {
    @ObservedObject var viewModel: AddDealViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Scan Website", systemImage: "safari.fill")
                .font(.appHeadline)
                .foregroundColor(.appText)

            HStack {
                TextField("https://venue-website.com", text: $viewModel.websiteURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.appBody)
                    .padding(.leading, 12)

                Button {
                    Task { await viewModel.scanWebsite() }
                } label: {
                    Text("Scan")
                        .font(.appCaption.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.appPrimary)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.trailing, 8)
                .disabled(viewModel.websiteURL.isEmpty || viewModel.isScanning)
            }
            .frame(height: 48)
            .background(Color.appSurface)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appDivider, lineWidth: 1))

            if viewModel.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning website for deals...")
                        .font(.appSubheadline)
                        .foregroundColor(.appSubtext)
                }
            } else if let result = viewModel.webScanResult {
                if result.extractedDeals.isEmpty {
                    Label("No deals found. Fill in manually below.", systemImage: "info.circle")
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)
                } else {
                    Text("\(result.extractedDeals.count) deal\(result.extractedDeals.count == 1 ? "" : "s") found")
                        .font(.appCaption.weight(.semibold))
                        .foregroundColor(.appSuccess)
                }
            }
        }
    }
}

// MARK: - Deal Form Section
struct DealFormSection: View {
    @ObservedObject var viewModel: AddDealViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Deal Details", systemImage: "tag.fill")
                .font(.appHeadline)
                .foregroundColor(.appText)

            // Title
            VStack(alignment: .leading, spacing: 6) {
                Text("Deal Title *").font(.appSubheadline.weight(.medium))
                TextField("e.g. $2 Draft Beers, Half-Price Appetizers", text: $viewModel.title)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.appSurface)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appDivider, lineWidth: 1))
            }

            // Description
            VStack(alignment: .leading, spacing: 6) {
                Text("Description *").font(.appSubheadline.weight(.medium))
                ZStack(alignment: .topLeading) {
                    if viewModel.description.isEmpty {
                        Text("Describe the deal in detail...")
                            .font(.appBody)
                            .foregroundColor(.appSubtext)
                            .padding(12)
                    }
                    TextEditor(text: $viewModel.description)
                        .frame(minHeight: 80)
                        .font(.appBody)
                        .padding(8)
                }
                .background(Color.appSurface)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appDivider, lineWidth: 1))
            }

            // Category
            VStack(alignment: .leading, spacing: 6) {
                Text("Category *").font(.appSubheadline.weight(.medium))
                HStack(spacing: 10) {
                    ForEach(DealCategory.allCases) { cat in
                        Button {
                            viewModel.selectedCategory = cat
                        } label: {
                            HStack(spacing: 6) {
                                Text(cat.icon)
                                Text(cat.displayName).font(.appCaption.weight(.medium))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(viewModel.selectedCategory == cat ? cat.uiColor : Color.appSurface)
                            .foregroundColor(viewModel.selectedCategory == cat ? .white : .appText)
                            .cornerRadius(20)
                        }
                    }
                }
            }

            // Days
            VStack(alignment: .leading, spacing: 6) {
                Text("Available Days *").font(.appSubheadline.weight(.medium))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                    ForEach(DayOfWeek.allCases) { day in
                        Button {
                            if viewModel.selectedDays.contains(day) {
                                viewModel.selectedDays.remove(day)
                            } else {
                                viewModel.selectedDays.insert(day)
                            }
                        } label: {
                            Text(String(day.shortName.prefix(1)))
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .background(viewModel.selectedDays.contains(day) ? Color.appPrimary : Color.appSurface)
                                .foregroundColor(viewModel.selectedDays.contains(day) ? .white : .appText)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(viewModel.selectedDays.contains(day) ? Color.clear : Color.appDivider, lineWidth: 1))
                        }
                    }
                }
            }

            // Time Range
            VStack(alignment: .leading, spacing: 6) {
                Text("Time Range *").font(.appSubheadline.weight(.medium))
                HStack(spacing: 12) {
                    TimeWheelPicker(label: "Start", time: $viewModel.startTime)
                    Text("to").font(.appSubheadline).foregroundColor(.appSubtext)
                    TimeWheelPicker(label: "End", time: $viewModel.endTime)
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }
}

// MARK: - Supporting Views

struct SelectedVenueRow: View {
    let venue: Venue
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VenuePhotoView(photoReference: venue.photoReference, maxWidth: 44)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(venue.name).font(.appSubheadline.weight(.semibold))
                Text(venue.address).font(.appCaption).foregroundColor(.appSubtext).lineLimit(1)
            }
            Spacer()
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.appSubtext)
            }
        }
        .padding(12)
        .background(Color.appSurface)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appPrimary.opacity(0.3), lineWidth: 1))
    }
}

struct ExtractedDealRow: View {
    let deal: ExtractedDeal
    let onApply: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(deal.title).font(.appCaption.weight(.semibold)).foregroundColor(.appText)
                Text(deal.suggestedDays.map { $0.shortName }.joined(separator: ", ") +
                     " · " + deal.suggestedStartTime.formattedTime + " – " + deal.suggestedEndTime.formattedTime)
                    .font(.system(size: 10))
                    .foregroundColor(.appSubtext)
            }
            Spacer()
            Button("Use") {
                onApply()
                HapticFeedback.impact(.light)
            }
            .font(.appCaption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.appPrimary)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .padding(10)
        .background(Color.appSurface)
        .cornerRadius(8)
    }
}

struct VenueSearchSheet: View {
    @ObservedObject var viewModel: AddDealViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AuthTextField(
                    placeholder: "Search venues...",
                    text: $viewModel.venueSearchQuery,
                    icon: "magnifyingglass"
                )
                .padding(16)
                .onChange(of: viewModel.venueSearchQuery) { query in
                    Task { await viewModel.searchVenues(query: query) }
                }

                if viewModel.isSearchingVenues {
                    ProgressView().padding()
                } else if viewModel.venueSearchResults.isEmpty && !viewModel.venueSearchQuery.isEmpty {
                    Text("No venues found").font(.appSubheadline).foregroundColor(.appSubtext).padding()
                } else {
                    List(viewModel.venueSearchResults) { venue in
                        Button {
                            viewModel.selectedVenue = venue
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                VenuePhotoView(photoReference: venue.photoReference, maxWidth: 40)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(venue.name).font(.appSubheadline.weight(.medium)).foregroundColor(.appText)
                                    Text(venue.address).font(.appCaption).foregroundColor(.appSubtext).lineLimit(1)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Select Venue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct TimeWheelPicker: View {
    let label: String
    @Binding var time: String
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            VStack(spacing: 2) {
                Text(label).font(.system(size: 10)).foregroundColor(.appSubtext)
                Text(time.formattedTime)
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundColor(.appText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.appBackground)
                    .cornerRadius(8)
            }
        }
        .sheet(isPresented: $showingPicker) {
            TimePickerSheet(time: $time)
                .presentationDetents([.height(300)])
        }
    }
}

struct TimePickerSheet: View {
    @Binding var time: String
    @Environment(\.dismiss) private var dismiss

    var dateBinding: Binding<Date> {
        Binding(
            get: {
                let parts = time.split(separator: ":").compactMap { Int($0) }
                var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                components.hour = parts.first ?? 16
                components.minute = parts.count > 1 ? parts[1] : 0
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let h = Calendar.current.component(.hour, from: date)
                let m = Calendar.current.component(.minute, from: date)
                time = String(format: "%02d:%02d", h, m)
            }
        )
    }

    var body: some View {
        VStack {
            DatePicker("", selection: dateBinding, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.appPrimary)
        }
        .padding()
    }
}

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    let onCapture: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true)
            parent.onCapture()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.appError)
            Text(message).font(.appFootnote).foregroundColor(.appError)
            Spacer()
        }
        .padding(12)
        .background(Color.appError.opacity(0.1))
        .cornerRadius(10)
    }
}
