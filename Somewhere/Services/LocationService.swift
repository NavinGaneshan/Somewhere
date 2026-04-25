import Foundation
import CoreLocation
import Combine
import UIKit

// MARK: - Location Error
enum LocationError: LocalizedError {
    case permissionDenied
    case permissionRestricted
    case locationUnavailable
    case timeout

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Location access denied. Please enable it in Settings to find deals near you."
        case .permissionRestricted:
            return "Location access is restricted on this device."
        case .locationUnavailable:
            return "Unable to determine your location. Please try again."
        case .timeout:
            return "Location request timed out. Please try again."
        }
    }
}

// MARK: - Location Service
@MainActor
class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    @Published var userLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isLocating = false
    @Published var locationError: LocationError?

    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var locationUpdateTimer: Timer?

    // Default location (Atlanta, GA 30309) as fallback for previews
    static let defaultLocation = CLLocation(latitude: 33.7890, longitude: -84.3880)

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50  // Update when moved 50m
        authorizationStatus = locationManager.authorizationStatus
    }

    var hasPermission: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var currentLocation: CLLocation? {
        userLocation ?? locationManager.location
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdatingLocation() {
        guard hasPermission else {
            requestPermission()
            return
        }
        locationManager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
    }

    /// One-shot location fetch with timeout
    func getCurrentLocation(timeout: TimeInterval = 10) async throws -> CLLocation {
        // Return cached location if recent enough (< 60 seconds old)
        if let cached = locationManager.location,
           abs(cached.timestamp.timeIntervalSinceNow) < 60 {
            return cached
        }

        guard hasPermission else {
            switch authorizationStatus {
            case .denied: throw LocationError.permissionDenied
            case .restricted: throw LocationError.permissionRestricted
            default:
                requestPermission()
                throw LocationError.permissionDenied
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                MainActor.assumeIsolated { [weak self] in
                    guard let self = self else {
                        continuation.resume(throwing: LocationError.locationUnavailable)
                        return
                    }

                    self.locationContinuation = continuation
                    self.isLocating = true
                    self.locationManager.requestLocation()

                    // Timeout
                    self.locationUpdateTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self = self, let c = self.locationContinuation else { return }
                            c.resume(throwing: LocationError.timeout)
                            self.locationContinuation = nil
                            self.isLocating = false
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self = self, let c = self.locationContinuation else { return }
                c.resume(throwing: CancellationError())
                self.locationContinuation = nil
                self.isLocating = false
                self.locationUpdateTimer?.invalidate()
                self.locationUpdateTimer = nil
            }
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Distance helpers

    func distance(to location: CLLocation) -> CLLocationDistance? {
        userLocation?.distance(from: location)
    }

    func distanceMiles(to coordinate: CLLocationCoordinate2D) -> Double? {
        guard let userLocation = userLocation else { return nil }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return userLocation.distance(from: target) * 0.000621371
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.userLocation = location
            self.isLocating = false
            self.locationUpdateTimer?.invalidate()

            if let continuation = self.locationContinuation {
                continuation.resume(returning: location)
                self.locationContinuation = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.isLocating = false
            self.locationUpdateTimer?.invalidate()

            let locationError: LocationError
            if let clError = error as? CLError {
                switch clError.code {
                case .denied: locationError = .permissionDenied
                default: locationError = .locationUnavailable
                }
            } else {
                locationError = .locationUnavailable
            }

            self.locationError = locationError
            if let continuation = self.locationContinuation {
                continuation.resume(throwing: locationError)
                self.locationContinuation = nil
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                self.startUpdatingLocation()
            }
        }
    }
}

// MARK: - Coordinate helpers
extension CLLocationCoordinate2D {
    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        location.distance(from: other.location)
    }

    func distanceMiles(to other: CLLocationCoordinate2D) -> Double {
        distance(to: other) * 0.000621371
    }

    /// Bounding box for a radius (in miles)
    func boundingBox(radiusMiles: Double) -> (minLat: Double, maxLat: Double, minLng: Double, maxLng: Double) {
        let radiusMeters = radiusMiles * 1609.34
        let latDelta = radiusMeters / 111_320
        let lngDelta = radiusMeters / (111_320 * cos(latitude * .pi / 180))
        return (
            minLat: latitude - latDelta,
            maxLat: latitude + latDelta,
            minLng: longitude - lngDelta,
            maxLng: longitude + lngDelta
        )
    }
}
