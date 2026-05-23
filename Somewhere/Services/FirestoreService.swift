import Foundation
import FirebaseFirestore
import CoreLocation
import Combine

// MARK: - Firestore Service
/// Central service for all Firestore read/write operations.
class FirestoreService {
    static let shared = FirestoreService()
    let db = Firestore.firestore()

    private init() {}

    // MARK: - Collections
    var venuesRef: CollectionReference { db.collection("venues") }
    var dealsRef: CollectionReference { db.collection("deals") }
    var usersRef: CollectionReference { db.collection("users") }
    var pvaCellsRef: CollectionReference { db.collection("pvaCells") }
    var searchLogsRef: CollectionReference { db.collection("searchLogs") }
    var adminConfigRef: DocumentReference { db.collection("config").document("admin") }
    var pvaConfigRef: DocumentReference { db.collection("config").document("pva") }

    // MARK: - Venue Operations

    func getVenue(id: String) async throws -> Venue? {
        let doc = try await venuesRef.document(id).getDocument()
        guard doc.exists, let data = doc.data() else { return nil }
        return Venue.fromFirestore(data, id: doc.documentID)
    }

    func saveVenue(_ venue: Venue) async throws {
        try await venuesRef.document(venue.id).setData(venue.toFirestore(), merge: true)
    }

    func updateVenueField(id: String, field: String, value: Any) async throws {
        try await venuesRef.document(id).updateData([
            field: value,
            "updatedAt": Timestamp()
        ])
    }

    func markVenueClosed(id: String) async throws {
        try await venuesRef.document(id).updateData([
            "isPermanentlyClosed": true,
            "scanStatus": VenueScanStatus.scanned.rawValue,
            "updatedAt": Timestamp()
        ])
    }

    func deleteVenue(id: String) async throws {
        // Delete venue and all its deals
        let dealsSnapshot = try await dealsRef.whereField("venueId", isEqualTo: id).getDocuments()
        let batch = db.batch()
        for doc in dealsSnapshot.documents {
            batch.deleteDocument(doc.reference)
        }
        batch.deleteDocument(venuesRef.document(id))
        try await batch.commit()
    }

    func getVenuesByPlaceIds(_ placeIds: [String]) async throws -> [Venue] {
        guard !placeIds.isEmpty else { return [] }
        // Firestore "in" queries support up to 30 items
        var venues: [Venue] = []
        let chunks = placeIds.chunked(into: 30)
        for chunk in chunks {
            let snapshot = try await venuesRef
                .whereField("placeId", in: chunk)
                .getDocuments()
            venues += snapshot.documents.compactMap {
                Venue.fromFirestore($0.data(), id: $0.documentID)
            }
        }
        return venues
    }

    /// Fetch venues within a bounding box (approximate geo-query using lat/lng ranges)
    func getVenuesInBounds(
        minLat: Double, maxLat: Double,
        minLng: Double, maxLng: Double
    ) async throws -> [Venue] {
        // Filter only by latitude range — compound range+equality queries require a composite
        // Firestore index that may not exist. Callers filter isPermanentlyClosed in memory.
        let snapshot = try await venuesRef
            .whereField("latitude", isGreaterThanOrEqualTo: minLat)
            .whereField("latitude", isLessThanOrEqualTo: maxLat)
            .limit(to: 500)
            .getDocuments()

        return snapshot.documents
            .compactMap { Venue.fromFirestore($0.data(), id: $0.documentID) }
            .filter { $0.longitude >= minLng && $0.longitude <= maxLng }
    }

    func getVenuesPendingScan(limit: Int = 20) async throws -> [Venue] {
        let snapshot = try await venuesRef
            .whereField("scanStatus", isEqualTo: VenueScanStatus.pending.rawValue)
            .whereField("isPermanentlyClosed", isEqualTo: false)
            .order(by: "createdAt", descending: false)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.compactMap { Venue.fromFirestore($0.data(), id: $0.documentID) }
    }

    /// Returns venues that have never been successfully scanned (pending or failed), up to limit.
    func getVenuesNeedingScan(limit: Int = 50) async throws -> [Venue] {
        let statuses = [VenueScanStatus.pending.rawValue, VenueScanStatus.failed.rawValue]
        let snapshot = try await venuesRef
            .whereField("scanStatus", in: statuses)
            .whereField("isPermanentlyClosed", isEqualTo: false)
            .order(by: "createdAt", descending: false)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.compactMap { Venue.fromFirestore($0.data(), id: $0.documentID) }
    }

    func getVenueCount() async throws -> Int {
        let snapshot = try await venuesRef.count.getAggregation(source: .server)
        return Int(truncating: snapshot.count)
    }

    // MARK: - Deal Operations

    func getDeal(id: String) async throws -> Deal? {
        let doc = try await dealsRef.document(id).getDocument()
        guard doc.exists else { return nil }
        return try? doc.data(as: Deal.self)
    }

    func saveDeal(_ deal: Deal) async throws {
        try await dealsRef.document(deal.id).setData(deal.toFirestore(), merge: true)
    }

    func updateDeal(id: String, data: [String: Any]) async throws {
        var update = data
        update["updatedAt"] = Timestamp()
        try await dealsRef.document(id).updateData(update)
    }

    func deleteDeal(id: String, venueId: String) async throws {
        let batch = db.batch()
        batch.deleteDocument(dealsRef.document(id))
        // Decrement venue dealCount
        batch.updateData(
            ["dealCount": FieldValue.increment(Int64(-1)), "updatedAt": Timestamp()],
            forDocument: venuesRef.document(venueId)
        )
        try await batch.commit()
    }

    func getDealsForVenue(venueId: String) async throws -> [Deal] {
        let snapshot = try await dealsRef
            .whereField("venueId", isEqualTo: venueId)
            .whereField("status", isEqualTo: DealStatus.active.rawValue)
            .order(by: "createdAt", descending: false)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: Deal.self) }
    }

    /// All deals for a venue regardless of status — used in admin venue detail.
    func getAllDealsForVenue(venueId: String) async throws -> [Deal] {
        let snapshot = try await dealsRef
            .whereField("venueId", isEqualTo: venueId)
            .getDocuments()
        // Sort in memory to avoid requiring a composite Firestore index
        return snapshot.documents
            .compactMap { try? $0.data(as: Deal.self) }
            .sorted { $0.createdAt.dateValue() > $1.createdAt.dateValue() }
    }

    /// Get all active deals for venues within bounds (fetched after venue geo-query)
    func getDealsForVenueIds(_ venueIds: [String]) async throws -> [Deal] {
        guard !venueIds.isEmpty else { return [] }
        var deals: [Deal] = []
        let chunks = venueIds.chunked(into: 30)
        for chunk in chunks {
            let snapshot = try await dealsRef
                .whereField("venueId", in: chunk)
                .whereField("status", isEqualTo: DealStatus.active.rawValue)
                .getDocuments()
            deals += snapshot.documents.compactMap { try? $0.data(as: Deal.self) }
        }
        return deals
    }

    func getPendingDeals(limit: Int = 50) async throws -> [Deal] {
        let snapshot = try await dealsRef
            .whereField("status", isEqualTo: DealStatus.pending.rawValue)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: Deal.self) }
    }

    func approveDeal(id: String, venueId: String) async throws {
        let batch = db.batch()
        batch.updateData(
            ["status": DealStatus.active.rawValue, "isVerified": true, "updatedAt": Timestamp()],
            forDocument: dealsRef.document(id)
        )
        batch.updateData(
            ["dealCount": FieldValue.increment(Int64(1)), "updatedAt": Timestamp()],
            forDocument: venuesRef.document(venueId)
        )
        try await batch.commit()
    }

    func rejectDeal(id: String, adminNotes: String) async throws {
        try await dealsRef.document(id).updateData([
            "status": DealStatus.rejected.rawValue,
            "adminNotes": adminNotes,
            "updatedAt": Timestamp()
        ])
    }

    func voteDeal(id: String, upvote: Bool, userId: String) async throws {
        let field = upvote ? "upvotes" : "downvotes"
        try await dealsRef.document(id).updateData([
            field: FieldValue.increment(Int64(1)),
            "updatedAt": Timestamp()
        ])
    }

    // MARK: - PVA Cell Operations

    func getPVACell(id: String) async throws -> PVACell? {
        let doc = try await pvaCellsRef.document(id).getDocument()
        guard doc.exists else { return nil }
        return try? doc.data(as: PVACell.self)
    }

    func savePVACell(_ cell: PVACell) async throws {
        try await pvaCellsRef.document(cell.id).setData(
            try Firestore.Encoder().encode(cell),
            merge: true
        )
    }

    func getStalePVACells(olderThanDays days: Int, limit: Int = 100) async throws -> [PVACell] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let cutoffTimestamp = Timestamp(date: cutoffDate)
        let snapshot = try await pvaCellsRef
            .whereField("lastSearchedAt", isLessThan: cutoffTimestamp)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: PVACell.self) }
    }

    // MARK: - PVA Config

    func getPVAConfig() async throws -> PVAConfig? {
        let doc = try await pvaConfigRef.getDocument()
        guard doc.exists, let data = doc.data() else { return nil }
        return try? Firestore.Decoder().decode(PVAConfig.self, from: data)
    }

    func savePVAConfig(_ config: PVAConfig) async throws {
        try await pvaConfigRef.setData(config.toFirestore(), merge: true)
    }

    func incrementApiCallCount() async throws {
        try await pvaConfigRef.updateData([
            "dailyApiCallCount": FieldValue.increment(Int64(1))
        ])
    }

    // MARK: - Search Logging

    func logSearch(_ log: SearchLog) async throws {
        try await searchLogsRef.document(log.id).setData(
            try Firestore.Encoder().encode(log)
        )
    }

    func getRecentSearchLogs(limit: Int = 100) async throws -> [SearchLog] {
        let snapshot = try await searchLogsRef
            .order(by: "timestamp", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: SearchLog.self) }
    }

    /// Delete all deals belonging to a venue — used before a forced rescan.
    func deleteDealsForVenue(id: String) async throws -> Int {
        let snapshot = try await dealsRef
            .whereField("venueId", isEqualTo: id)
            .getDocuments()
        for doc in snapshot.documents {
            try await doc.reference.delete()
        }
        return snapshot.documents.count
    }

    /// Clear PVA cell records in a bounding box so the area gets re-searched on the next pull.
    func deletePVACellsInBounds(minLat: Double, maxLat: Double, minLng: Double, maxLng: Double) async throws -> Int {
        let snapshot = try await db.collection("pvaCells")
            .whereField("centerLatitude", isGreaterThanOrEqualTo: minLat)
            .whereField("centerLatitude", isLessThanOrEqualTo: maxLat)
            .getDocuments()
        var deleted = 0
        for doc in snapshot.documents {
            let lng = doc.data()["centerLongitude"] as? Double ?? 0
            guard lng >= minLng, lng <= maxLng else { continue }
            try await doc.reference.delete()
            deleted += 1
        }
        return deleted
    }

    /// Delete every document in a collection in batches of 400. Returns total deleted.
    func deleteAllDocuments(in ref: CollectionReference) async throws -> Int {
        var totalDeleted = 0
        while true {
            let snapshot = try await ref.limit(to: 400).getDocuments()
            guard !snapshot.documents.isEmpty else { break }
            let batch = db.batch()
            snapshot.documents.forEach { batch.deleteDocument($0.reference) }
            try await batch.commit()
            totalDeleted += snapshot.documents.count
        }
        return totalDeleted
    }

    // MARK: - User Operations (Admin)

    func getAllUsers(limit: Int = 100) async throws -> [AppUser] {
        let snapshot = try await usersRef
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: AppUser.self) }
    }

    func updateUserRole(uid: String, role: UserRole) async throws {
        try await usersRef.document(uid).updateData([
            "role": role.rawValue,
            "updatedAt": Timestamp()
        ])
    }

    func banUser(uid: String, banned: Bool) async throws {
        try await usersRef.document(uid).updateData([
            "isBanned": banned,
            "updatedAt": Timestamp()
        ])
    }

    func getUserCount() async throws -> Int {
        let snapshot = try await usersRef.count.getAggregation(source: .server)
        return Int(truncating: snapshot.count)
    }

    func getDealCount() async throws -> Int {
        let snapshot = try await dealsRef
            .whereField("status", isEqualTo: DealStatus.active.rawValue)
            .count
            .getAggregation(source: .server)
        return Int(truncating: snapshot.count)
    }

    // MARK: - Real-time listeners

    func listenToDealsForVenue(venueId: String, onChange: @escaping ([Deal]) -> Void) -> ListenerRegistration {
        dealsRef
            .whereField("venueId", isEqualTo: venueId)
            .whereField("status", isEqualTo: DealStatus.active.rawValue)
            .addSnapshotListener { snapshot, _ in
                guard let snapshot = snapshot else { return }
                let deals = snapshot.documents.compactMap { try? $0.data(as: Deal.self) }
                onChange(deals)
            }
    }

    func listenToPendingDeals(onChange: @escaping ([Deal]) -> Void) -> ListenerRegistration {
        dealsRef
            .whereField("status", isEqualTo: DealStatus.pending.rawValue)
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { snapshot, _ in
                guard let snapshot = snapshot else { return }
                let deals = snapshot.documents.compactMap { try? $0.data(as: Deal.self) }
                onChange(deals)
            }
    }
}

// MARK: - Array chunked helper
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
