import Foundation
import FirebaseFirestore

// MARK: - User Role
enum UserRole: String, Codable, CaseIterable {
    case user = "user"
    case contributor = "contributor"   // trusted user, deals auto-approved
    case moderator = "moderator"
    case admin = "admin"

    var displayName: String {
        switch self {
        case .user: return "User"
        case .contributor: return "Contributor"
        case .moderator: return "Moderator"
        case .admin: return "Admin"
        }
    }

    var canAccessAdmin: Bool {
        self == .admin || self == .moderator
    }

    var canApproveDeals: Bool {
        self == .admin || self == .moderator || self == .contributor
    }
}

// MARK: - Auth Provider
enum AuthProvider: String, Codable {
    case email = "email"
    case google = "google"
    case apple = "apple"
}

// MARK: - App User
struct AppUser: Codable, Identifiable {
    @DocumentID var firestoreId: String?
    var id: String                     // Firebase Auth UID
    var email: String
    var displayName: String
    var photoURL: String?
    var role: UserRole
    var authProvider: AuthProvider
    var isEmailVerified: Bool
    var isBanned: Bool
    var dealsSubmitted: Int
    var dealsApproved: Int
    var searchCount: Int
    var lastSearchLocation: GeoPoint?
    var lastActiveAt: Timestamp?
    var createdAt: Timestamp
    var updatedAt: Timestamp
    var fcmToken: String?              // Push notification token
    var preferredSearchRadius: Double  // miles, default 1.0
    var favoriteVenueIds: [String]
    var blockedVenueIds: [String]

    var initials: String {
        let parts = displayName.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }

    var contributionScore: Int {
        dealsApproved * 10 + dealsSubmitted
    }
}

// MARK: - AppUser + Firestore
extension AppUser {
    static func create(
        uid: String,
        email: String,
        displayName: String,
        photoURL: String?,
        provider: AuthProvider
    ) -> AppUser {
        AppUser(
            id: uid,
            email: email,
            displayName: displayName.isEmpty ? email.components(separatedBy: "@").first ?? "User" : displayName,
            photoURL: photoURL,
            role: .user,
            authProvider: provider,
            isEmailVerified: provider != .email,
            isBanned: false,
            dealsSubmitted: 0,
            dealsApproved: 0,
            searchCount: 0,
            lastSearchLocation: nil,
            lastActiveAt: Timestamp(),
            createdAt: Timestamp(),
            updatedAt: Timestamp(),
            fcmToken: nil,
            preferredSearchRadius: 1.0,
            favoriteVenueIds: [],
            blockedVenueIds: []
        )
    }

    func toFirestore() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "email": email,
            "displayName": displayName,
            "role": role.rawValue,
            "authProvider": authProvider.rawValue,
            "isEmailVerified": isEmailVerified,
            "isBanned": isBanned,
            "dealsSubmitted": dealsSubmitted,
            "dealsApproved": dealsApproved,
            "searchCount": searchCount,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "preferredSearchRadius": preferredSearchRadius,
            "favoriteVenueIds": favoriteVenueIds,
            "blockedVenueIds": blockedVenueIds
        ]
        if let photoURL = photoURL { dict["photoURL"] = photoURL }
        if let lastSearchLocation = lastSearchLocation { dict["lastSearchLocation"] = lastSearchLocation }
        if let lastActiveAt = lastActiveAt { dict["lastActiveAt"] = lastActiveAt }
        if let fcmToken = fcmToken { dict["fcmToken"] = fcmToken }
        return dict
    }
}

// MARK: - Admin User Summary (for admin dashboard listing)
struct AdminUserSummary: Identifiable {
    let user: AppUser
    var id: String { user.id }
    var recentSearches: Int = 0
    var recentDealsAdded: Int = 0
}
