import Foundation
import SwiftUI
import PhotosUI
import FirebaseFirestore
import FirebaseStorage

@MainActor
class AddDealViewModel: ObservableObject {
    @Published var selectedVenue: Venue?
    @Published var selectedImage: UIImage?
    @Published var imageItem: PhotosPickerItem?
    @Published var websiteURL = ""

    // Deal fields
    @Published var title = ""
    @Published var description = ""
    @Published var selectedCategory: DealCategory = .drinks
    @Published var selectedDays: Set<DayOfWeek> = []
    @Published var startTime = "16:00"
    @Published var endTime = "19:00"

    // State
    @Published var isLoading = false
    @Published var isScanning = false
    @Published var scanResult: PhotoScanResult?
    @Published var webScanResult: WebScanResult?
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var showingImagePicker = false
    @Published var showingCamera = false
    @Published var showVenueSearch = false
    @Published var checkedDealIndices: Set<Int> = []

    // Venue search
    @Published var venueSearchQuery = ""
    @Published var venueSearchResults: [Venue] = []
    @Published var isSearchingVenues = false

    private let firestoreService = FirestoreService.shared
    private let locationService = LocationService.shared
    private let photoScanService = PhotoScanService.shared
    private let webScanService = WebScanService.shared
    private let authService = AuthService.shared
    private let storage = Storage.storage()

    var isFormValid: Bool {
        selectedVenue != nil &&
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !description.trimmingCharacters(in: .whitespaces).isEmpty &&
        !selectedDays.isEmpty
    }

    // MARK: - Photo Scanning

    func scanPhoto() async {
        guard let image = selectedImage else { return }
        isScanning = true
        errorMessage = nil

        do {
            let result = try await photoScanService.scanImage(image, venueName: selectedVenue?.name ?? "")
            scanResult = result
            checkedDealIndices = Set(0..<result.extractedDeals.count)
            if result.extractedDeals.isEmpty {
                errorMessage = "No deals detected. Please fill in the details manually."
            }
        } catch {
            errorMessage = "Scan failed: \(error.localizedDescription)"
        }

        isScanning = false
    }

    func loadImageFromPicker() async {
        guard let item = imageItem else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                selectedImage = image
                await scanPhoto()
            }
        } catch {
            errorMessage = "Could not load image: \(error.localizedDescription)"
        }
    }

    // MARK: - Website Scanning

    func scanWebsite() async {
        guard webScanService.isValidVenueURL(websiteURL) else {
            errorMessage = "Please enter a valid website URL."
            return
        }

        isScanning = true
        errorMessage = nil

        do {
            let result = try await webScanService.scanForDeals(url: websiteURL)
            webScanResult = result
            if let firstDeal = result.extractedDeals.first {
                populateFromExtractedDeal(firstDeal)
            }
            if result.extractedDeals.isEmpty {
                errorMessage = "No deals found on the website. Please fill in details manually."
            }
        } catch {
            errorMessage = "Website scan failed: \(error.localizedDescription)"
        }

        isScanning = false
    }

    // MARK: - Venue Search

    func searchVenues(query: String) async {
        guard query.count >= 2 else {
            venueSearchResults = []
            return
        }

        isSearchingVenues = true
        do {
            // Search local DB first
            let snapshot = try await firestoreService.venuesRef
                .whereField("name", isGreaterThanOrEqualTo: query)
                .whereField("name", isLessThanOrEqualTo: query + "\u{f8ff}")
                .limit(to: 20)
                .getDocuments()
            venueSearchResults = snapshot.documents.compactMap {
                Venue.fromFirestore($0.data(), id: $0.documentID)
            }
        } catch {
            venueSearchResults = []
        }
        isSearchingVenues = false
    }

    // MARK: - Form Population

    func populateFromExtractedDeal(_ deal: ExtractedDeal) {
        title = deal.title
        description = deal.rawText.truncated(500)
        selectedCategory = deal.suggestedCategory
        selectedDays = Set(deal.suggestedDays)
        startTime = deal.suggestedStartTime
        endTime = deal.suggestedEndTime
    }

    func applyScanResult(_ deal: ExtractedDeal) {
        populateFromExtractedDeal(deal)
    }

    // MARK: - Submit Deal

    func submitDeal() async {
        guard let venue = selectedVenue,
              let userId = authService.currentUser?.id else {
            errorMessage = "Please select a venue and sign in."
            return
        }

        guard isFormValid else {
            errorMessage = "Please fill in all required fields."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // Upload image if present
            var imageURL: String? = nil
            if let image = selectedImage {
                imageURL = try await uploadImage(image, venueId: venue.id)
            }

            // Create deal
            let pvaConfig = try? await firestoreService.getPVAConfig()
            let requiresApproval = pvaConfig?.requireApprovalForUserDeals ?? true

            let deal = Deal(
                id: UUID().uuidString,
                venueId: venue.id,
                venueName: venue.name,
                venueAddress: venue.formattedAddress,
                venueLatitude: venue.latitude,
                venueLongitude: venue.longitude,
                title: title.trimmingCharacters(in: .whitespaces),
                description: description.trimmingCharacters(in: .whitespaces),
                category: selectedCategory,
                days: Array(selectedDays),
                startTime: startTime,
                endTime: endTime,
                source: selectedImage != nil ? .photo : (websiteURL.isEmpty ? .manual : .website),
                status: requiresApproval ? .pending : .active,
                isVerified: !requiresApproval,
                upvotes: 0,
                downvotes: 0,
                reportCount: 0,
                imageURL: imageURL,
                sourceURL: websiteURL.isEmpty ? nil : websiteURL,
                createdBy: userId,
                createdByName: authService.currentUser?.displayName,
                createdAt: Timestamp(),
                updatedAt: Timestamp(),
                startDate: nil,
                expiresAt: nil,
                adminNotes: nil
            )

            try await firestoreService.saveDeal(deal)

            // Increment user's deal count
            try? await firestoreService.usersRef.document(userId).updateData([
                "dealsSubmitted": FieldValue.increment(Int64(1))
            ])

            // Update venue deal count if auto-approved
            if !requiresApproval {
                try? await firestoreService.updateVenueField(id: venue.id, field: "dealCount", value: FieldValue.increment(Int64(1)))
            }

            successMessage = requiresApproval
                ? "Deal submitted! It will appear after admin review."
                : "Deal added successfully!"
            HapticFeedback.success()
            resetForm()
        } catch {
            errorMessage = "Failed to submit deal: \(error.localizedDescription)"
            HapticFeedback.error()
        }

        isLoading = false
    }

    func submitCheckedDeals() async {
        guard let venue = selectedVenue,
              let userId = authService.currentUser?.id else {
            errorMessage = "Please select a venue and sign in."
            return
        }

        guard let allDeals = scanResult?.extractedDeals, !allDeals.isEmpty else { return }

        let toSubmit = allDeals.enumerated()
            .filter { checkedDealIndices.contains($0.offset) }
            .map { $0.element }

        guard !toSubmit.isEmpty else {
            errorMessage = "Select at least one deal to add."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let pvaConfig = try? await firestoreService.getPVAConfig()
            let requiresApproval = pvaConfig?.requireApprovalForUserDeals ?? true

            var imageURL: String? = nil
            if let image = selectedImage {
                imageURL = try? await uploadImage(image, venueId: venue.id)
            }

            for extracted in toSubmit {
                let deal = Deal(
                    id: UUID().uuidString,
                    venueId: venue.id,
                    venueName: venue.name,
                    venueAddress: venue.formattedAddress,
                    venueLatitude: venue.latitude,
                    venueLongitude: venue.longitude,
                    title: extracted.title,
                    description: extracted.rawText.truncated(500),
                    category: extracted.suggestedCategory,
                    days: extracted.suggestedDays,
                    startTime: extracted.suggestedStartTime,
                    endTime: extracted.suggestedEndTime,
                    source: .photo,
                    status: requiresApproval ? .pending : .active,
                    isVerified: !requiresApproval,
                    upvotes: 0,
                    downvotes: 0,
                    reportCount: 0,
                    imageURL: imageURL,
                    sourceURL: nil,
                    createdBy: userId,
                    createdByName: authService.currentUser?.displayName,
                    createdAt: Timestamp(),
                    updatedAt: Timestamp(),
                    startDate: nil,
                    expiresAt: nil,
                    adminNotes: nil
                )
                try await firestoreService.saveDeal(deal)
            }

            try? await firestoreService.usersRef.document(userId).updateData([
                "dealsSubmitted": FieldValue.increment(Int64(toSubmit.count))
            ])

            if !requiresApproval {
                try? await firestoreService.updateVenueField(
                    id: venue.id,
                    field: "dealCount",
                    value: FieldValue.increment(Int64(toSubmit.count))
                )
            }

            let n = toSubmit.count
            successMessage = requiresApproval
                ? "\(n) deal\(n == 1 ? "" : "s") submitted for review!"
                : "\(n) deal\(n == 1 ? "" : "s") added!"
            HapticFeedback.success()
            resetForm()
        } catch {
            errorMessage = "Failed to submit: \(error.localizedDescription)"
            HapticFeedback.error()
        }

        isLoading = false
    }

    private func uploadImage(_ image: UIImage, venueId: String) async throws -> String {
        guard !venueId.isEmpty else {
            throw NSError(domain: "StorageError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Venue ID is missing — cannot upload photo."])
        }
        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            throw NSError(domain: "ImageError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not compress image"])
        }

        let imageName = "\(UUID().uuidString).jpg"
        let storageRef = storage.reference().child("deal_photos/\(venueId)/\(imageName)")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        _ = try await storageRef.putDataAsync(imageData, metadata: metadata)
        let downloadURL = try await storageRef.downloadURL()
        return downloadURL.absoluteString
    }

    func resetForm() {
        selectedVenue = nil
        selectedImage = nil
        imageItem = nil
        websiteURL = ""
        title = ""
        description = ""
        selectedCategory = .drinks
        selectedDays = []
        startTime = "16:00"
        endTime = "19:00"
        scanResult = nil
        webScanResult = nil
        checkedDealIndices = []
    }
}
