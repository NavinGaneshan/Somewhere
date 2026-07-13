import Foundation
import CoreLocation

// MARK: - Places Venue (result from Google Places API)
struct PlacesVenue {
    var placeId: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var phone: String?
    var website: String?
    var rating: Double?
    var priceLevel: Int?
    var types: [String]
    var isPermanentlyClosed: Bool
    var photoReference: String?

    var venueCategory: VenueCategory {
        if types.contains("bar") || types.contains("night_club") { return .bar }
        if types.contains("brewery") { return .brewery }
        if types.contains("winery") { return .winery }
        if types.contains("restaurant") || types.contains("food") { return .restaurant }
        return .other
    }
}

// MARK: - Places API Response Models
private struct PlacesResponse: Codable {
    let results: [PlaceResult]
    let nextPageToken: String?
    let status: String
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case results
        case nextPageToken = "next_page_token"
        case status
        case errorMessage = "error_message"
    }
}

private struct PlaceResult: Codable {
    let placeId: String
    let name: String
    let vicinity: String?
    let formattedAddress: String?
    let geometry: PlaceGeometry
    let types: [String]
    let rating: Double?
    let priceLevel: Int?
    let permanentlyClosed: Bool?
    let businessStatus: String?
    let photos: [PlacePhoto]?

    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name, vicinity, geometry, types, rating, photos
        case formattedAddress = "formatted_address"
        case priceLevel = "price_level"
        case permanentlyClosed = "permanently_closed"
        case businessStatus = "business_status"
    }
}

private struct PlaceGeometry: Codable {
    let location: PlaceLocation
}

private struct PlaceLocation: Codable {
    let lat: Double
    let lng: Double
}

private struct PlacePhoto: Codable {
    let photoReference: String
    let height: Int
    let width: Int
    let htmlAttributions: [String]?

    enum CodingKeys: String, CodingKey {
        case photoReference = "photo_reference"
        case height, width
        case htmlAttributions = "html_attributions"
    }

    /// Owner-posted photos (attributed to the business) come first — they're most likely to be menus.
    func ownerScore(venueName: String) -> Int {
        let attrText = (htmlAttributions ?? []).joined().lowercased()
        return (attrText.contains(venueName.lowercased()) || attrText.isEmpty) ? 1 : 0
    }
}

private struct PlaceDetailsResponse: Codable {
    let result: PlaceDetailResult
    let status: String
}

private struct PlaceDetailResult: Codable {
    let placeId: String
    let name: String
    let formattedAddress: String?
    let formattedPhoneNumber: String?
    let website: String?
    let rating: Double?
    let priceLevel: Int?
    let businessStatus: String?
    let photos: [PlacePhoto]?

    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name, website, rating, photos
        case formattedAddress = "formatted_address"
        case formattedPhoneNumber = "formatted_phone_number"
        case priceLevel = "price_level"
        case businessStatus = "business_status"
    }
}

// MARK: - Places Service
class PlacesService {
    static let shared = PlacesService()

    private let session = URLSession.shared
    private var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_PLACES_API_KEY") as? String ?? ""
    }

    private let baseURL = "https://maps.googleapis.com/maps/api/place"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    /// GET the URL with the iOS bundle-identifier header attached.
    /// Google's Places API key is restricted to iOS apps with our bundle ID;
    /// the restriction only passes when the request carries `X-Ios-Bundle-Identifier`.
    /// A plain `session.data(from:)` won't include it — hence REQUEST_DENIED.
    private func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        if let bundleId = Bundle.main.bundleIdentifier {
            request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        return try await session.data(for: request)
    }

    // MARK: - Nearby Search

    /// Search for bars and restaurants near a location
    func searchNearbyVenues(
        location: CLLocationCoordinate2D,
        radiusMeters: Int = 1609,
        pageToken: String? = nil
    ) async throws -> (venues: [PlacesVenue], nextPageToken: String?) {
        var urlString = "\(baseURL)/nearbysearch/json?"
        urlString += "location=\(location.latitude),\(location.longitude)"
        urlString += "&radius=\(radiusMeters)"
        urlString += "&type=bar|restaurant|night_club|brewery"
        urlString += "&key=\(apiKey)"
        if let token = pageToken {
            urlString += "&pagetoken=\(token)"
        }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let (data, _) = try await fetch(url)
        let response = try decoder.decode(PlacesResponse.self, from: data)

        print("PlacesService nearbysearch at \(location.latitude),\(location.longitude) r=\(radiusMeters)m → status=\(response.status) results=\(response.results.count)")
        if let errMsg = response.errorMessage {
            print("PlacesService error_message: \(errMsg)")
        }

        guard response.status == "OK" || response.status == "ZERO_RESULTS" else {
            throw PlacesError.apiError(response.status)
        }

        let venues = response.results.map { result -> PlacesVenue in
            PlacesVenue(
                placeId: result.placeId,
                name: result.name,
                address: result.vicinity ?? result.formattedAddress ?? "",
                latitude: result.geometry.location.lat,
                longitude: result.geometry.location.lng,
                phone: nil,
                website: nil,
                rating: result.rating,
                priceLevel: result.priceLevel,
                types: result.types,
                isPermanentlyClosed: result.businessStatus == "CLOSED_PERMANENTLY" ||
                                     (result.permanentlyClosed ?? false),
                photoReference: result.photos?.first?.photoReference
            )
        }

        return (venues, response.nextPageToken)
    }

    /// Get full details for a single place (phone, website)
    func getPlaceDetails(placeId: String) async throws -> PlacesVenue? {
        let urlString = "\(baseURL)/details/json?place_id=\(placeId)&fields=place_id,name,formatted_address,formatted_phone_number,website,rating,price_level,business_status,photos&key=\(apiKey)"

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let (data, _) = try await fetch(url)
        let response = try decoder.decode(PlaceDetailsResponse.self, from: data)

        guard response.status == "OK" else { return nil }
        let result = response.result

        return PlacesVenue(
            placeId: result.placeId,
            name: result.name,
            address: result.formattedAddress ?? "",
            latitude: 0, longitude: 0, // Not returned by details
            phone: result.formattedPhoneNumber,
            website: result.website,
            rating: result.rating,
            priceLevel: result.priceLevel,
            types: [],
            isPermanentlyClosed: result.businessStatus == "CLOSED_PERMANENTLY",
            photoReference: result.photos?.first?.photoReference
        )
    }

    /// Build photo URL from photo reference
    func photoURL(reference: String, maxWidth: Int = 400) -> URL? {
        URL(string: "\(baseURL)/photo?maxwidth=\(maxWidth)&photoreference=\(reference)&key=\(apiKey)")
    }

    /// Photo references for a place, prioritized by likelihood of being a menu/specials image.
    /// Portrait photos and owner-attributed photos score higher (approximates the Maps "Menu" tab).
    func getPlacePhotoReferences(placeId: String, venueName: String = "", limit: Int = 10) async throws -> [String] {
        let urlString = "\(baseURL)/details/json?place_id=\(placeId)&fields=photos&key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await fetch(url)
        let response = try decoder.decode(PlaceDetailsResponse.self, from: data)
        guard response.status == "OK" else { return [] }
        let photos = response.result.photos ?? []
        return photos
            .sorted { $0.ownerScore(venueName: venueName) > $1.ownerScore(venueName: venueName) }
            .prefix(limit)
            .map { $0.photoReference }
    }

    // MARK: - Text Search (for website scraping target)
    func searchByName(_ name: String, near location: CLLocationCoordinate2D) async throws -> PlacesVenue? {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let urlString = "\(baseURL)/textsearch/json?query=\(encodedName)&location=\(location.latitude),\(location.longitude)&radius=1000&key=\(apiKey)"

        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await fetch(url)
        let response = try decoder.decode(PlacesResponse.self, from: data)

        guard response.status == "OK", let first = response.results.first else { return nil }
        return PlacesVenue(
            placeId: first.placeId,
            name: first.name,
            address: first.formattedAddress ?? first.vicinity ?? "",
            latitude: first.geometry.location.lat,
            longitude: first.geometry.location.lng,
            phone: nil, website: nil,
            rating: first.rating,
            priceLevel: first.priceLevel,
            types: first.types,
            isPermanentlyClosed: first.businessStatus == "CLOSED_PERMANENTLY",
            photoReference: first.photos?.first?.photoReference
        )
    }
}

// MARK: - Places Error
enum PlacesError: LocalizedError {
    case apiError(String)
    case quotaExceeded
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .apiError(let status): return "Places API error: \(status)"
        case .quotaExceeded: return "Google Places API quota exceeded for today."
        case .invalidKey: return "Invalid Google Places API key."
        }
    }
}
