import Foundation
import CoreLocation
import FirebaseFirestore

// MARK: - Venue Category
enum VenueCategory: String, Codable, CaseIterable, Identifiable {
    case bar = "bar"
    case restaurant = "restaurant"
    case brewery = "brewery"
    case winery = "winery"
    case lounge = "lounge"
    case sportsBar = "sports_bar"
    case other = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bar: return "Bar"
        case .restaurant: return "Restaurant"
        case .brewery: return "Brewery"
        case .winery: return "Winery"
        case .lounge: return "Lounge"
        case .sportsBar: return "Sports Bar"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .bar:        return "wineglass"
        case .restaurant: return "fork.knife"
        case .brewery:    return "mug.fill"
        case .winery:     return "wineglass.fill"
        case .lounge:     return "sparkles"
        case .sportsBar:  return "sportscourt.fill"
        case .other:      return "mappin"
        }
    }
}

// MARK: - Venue Scan Status
enum VenueScanStatus: String, Codable {
    case pending = "pending"
    case scanning = "scanning"
    case scanned = "scanned"
    case failed = "failed"
    case noDeals = "no_deals"
}

// MARK: - Venue Model
struct Venue: Codable, Identifiable, Equatable {
    @DocumentID var firestoreId: String?
    var id: String
    var name: String
    var address: String
    var city: String
    var state: String
    var zipCode: String
    var latitude: Double
    var longitude: Double
    var placeId: String           // Google Places ID
    var phone: String?
    var website: String?
    var instagramHandle: String?   // e.g. "thelocalatl" (no leading @)
    var facebookURL: String?       // full URL, e.g. "https://www.facebook.com/thelocalatl"
    var category: VenueCategory
    var isPermanentlyClosed: Bool
    var scanStatus: VenueScanStatus
    var lastScanned: Timestamp?
    var lastVerified: Timestamp?
    var dealCount: Int
    var rating: Double?
    var priceLevel: Int?          // 1-4 ($ to $$$$)
    var photoReference: String?
    var createdAt: Timestamp
    var updatedAt: Timestamp
    var createdBy: String?        // userId of who added it
    var searchCellIds: [String]   // PVA grid cell IDs this venue belongs to

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var formattedAddress: String {
        [address, city, state, zipCode]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var priceLevelString: String {
        guard let level = priceLevel else { return "" }
        return String(repeating: "$", count: level)
    }

    func distance(from userLocation: CLLocation) -> CLLocationDistance {
        location.distance(from: userLocation)
    }

    func distanceMiles(from userLocation: CLLocation) -> Double {
        distance(from: userLocation) * 0.000621371
    }

    func formattedDistance(from userLocation: CLLocation) -> String {
        let miles = distanceMiles(from: userLocation)
        if miles < 0.1 {
            let feet = Int(distance(from: userLocation) * 3.28084)
            return "\(feet) ft"
        } else if miles < 10 {
            return String(format: "%.1f mi", miles)
        } else {
            return String(format: "%.0f mi", miles)
        }
    }

    // Apple Maps navigation URL
    var appleMapsURL: URL? {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return URL(string: "maps://?q=\(encodedName)&ll=\(latitude),\(longitude)")
    }

    // Google Maps navigation URL
    var googleMapsURL: URL? {
        URL(string: "comgooglemaps://?q=\(latitude),\(longitude)&zoom=16")
    }

    static func == (lhs: Venue, rhs: Venue) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Venue + Firestore
extension Venue {
    static func fromFirestore(_ data: [String: Any], id: String) -> Venue? {
        guard
            let name = data["name"] as? String,
            let address = data["address"] as? String,
            let latitude = data["latitude"] as? Double,
            let longitude = data["longitude"] as? Double,
            let placeId = data["placeId"] as? String,
            let categoryRaw = data["category"] as? String,
            let category = VenueCategory(rawValue: categoryRaw)
        else { return nil }

        return Venue(
            id: id,
            name: name,
            address: address,
            city: data["city"] as? String ?? "",
            state: data["state"] as? String ?? "",
            zipCode: data["zipCode"] as? String ?? "",
            latitude: latitude,
            longitude: longitude,
            placeId: placeId,
            phone: data["phone"] as? String,
            website: data["website"] as? String,
            instagramHandle: data["instagramHandle"] as? String,
            facebookURL: data["facebookURL"] as? String,
            category: category,
            isPermanentlyClosed: data["isPermanentlyClosed"] as? Bool ?? false,
            scanStatus: VenueScanStatus(rawValue: data["scanStatus"] as? String ?? "") ?? .pending,
            lastScanned: data["lastScanned"] as? Timestamp,
            lastVerified: data["lastVerified"] as? Timestamp,
            dealCount: data["dealCount"] as? Int ?? 0,
            rating: data["rating"] as? Double,
            priceLevel: data["priceLevel"] as? Int,
            photoReference: data["photoReference"] as? String,
            createdAt: data["createdAt"] as? Timestamp ?? Timestamp(),
            updatedAt: data["updatedAt"] as? Timestamp ?? Timestamp(),
            createdBy: data["createdBy"] as? String,
            searchCellIds: data["searchCellIds"] as? [String] ?? []
        )
    }

    func toFirestore() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "address": address,
            "city": city,
            "state": state,
            "zipCode": zipCode,
            "latitude": latitude,
            "longitude": longitude,
            "placeId": placeId,
            "category": category.rawValue,
            "isPermanentlyClosed": isPermanentlyClosed,
            "scanStatus": scanStatus.rawValue,
            "dealCount": dealCount,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "searchCellIds": searchCellIds
        ]
        if let phone = phone { dict["phone"] = phone }
        if let website = website { dict["website"] = website }
        if let instagramHandle = instagramHandle { dict["instagramHandle"] = instagramHandle }
        if let facebookURL = facebookURL { dict["facebookURL"] = facebookURL }
        if let lastScanned = lastScanned { dict["lastScanned"] = lastScanned }
        if let lastVerified = lastVerified { dict["lastVerified"] = lastVerified }
        if let rating = rating { dict["rating"] = rating }
        if let priceLevel = priceLevel { dict["priceLevel"] = priceLevel }
        if let photoReference = photoReference { dict["photoReference"] = photoReference }
        if let createdBy = createdBy { dict["createdBy"] = createdBy }
        return dict
    }
}
