import SwiftUI

// MARK: - App Colors  (dark "Ink" theme)
extension Color {
    static let appPrimary    = Color(hex: "#E87A2C")   // Amber
    static let appAccent     = Color(hex: "#E87A2C")   // Amber
    static let appBackground = Color(hex: "#191613")   // Ink
    static let appSurface    = Color(hex: "#221E1A")   // Dark card
    static let appText       = Color(hex: "#F2ECE0")   // Paper
    static let appSubtext    = Color(hex: "#8C7E72")   // Warm gray
    static let appDivider    = Color(hex: "#2D2824")   // Dark divider
    static let appSuccess    = Color(hex: "#4C7A3E")   // Olive
    static let appWarning    = Color(hex: "#E8A838")   // Warm amber
    static let appError      = Color(hex: "#C0392B")   // Red

    // Category colors
    static let drinkColor    = Color(hex: "#4A90D9")
    static let foodColor     = Color(hex: "#E8A838")
    static let activityColor = Color(hex: "#9B88EE")

    // Active/inactive deal indicator
    static let activeGreen  = Color(hex: "#4C7A3E")   // Olive
    static let inactiveGray = Color(hex: "#5A5248")

    // Design tokens
    static let appCard       = Color(hex: "#221E1A")
    static let appAccentDeep = Color(hex: "#B85E1A")
    static let appMute       = Color(hex: "#5A4E45")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - App Constants
enum AppConstants {
    // App info
    static let appName = "Somewhere"
    static let appTagline = "Find happy hour deals near you"
    static let supportEmail = "support@hhsomewhere.com"

    // Search
    static let defaultSearchRadiusMiles: Double = 1.0
    static let maxSearchRadiusMiles: Double = 5.0
    static let minSearchRadiusMiles: Double = 0.25

    // PVA
    static let pvaCellStaleDays = 30
    static let venueReverifyDays = 90
    static let maxVenuesPerSearch = 50

    // Firestore collection names
    static let venuesCollection = "venues"
    static let dealsCollection = "deals"
    static let usersCollection = "users"
    static let pvaCellsCollection = "pvaCells"
    static let searchLogsCollection = "searchLogs"
    static let configCollection = "config"

    // Cache
    static let venueCacheMinutes: Double = 5
    static let dealCacheMinutes: Double = 5

    // Animation
    static let defaultAnimation = Animation.easeInOut(duration: 0.25)
    static let springAnimation = Animation.spring(response: 0.35, dampingFraction: 0.7)

    // Layout
    static let cardCornerRadius: CGFloat = 16
    static let cardShadowRadius: CGFloat = 4
    static let standardPadding: CGFloat = 16
    static let smallPadding: CGFloat = 8
    static let largePadding: CGFloat = 24

    // Tab bar items
    enum Tab: Int, CaseIterable {
        case discover, map, addDeal, profile
        var title: String {
            switch self {
            case .discover: return "Discover"
            case .map: return "Map"
            case .addDeal: return "Add Deal"
            case .profile: return "Profile"
            }
        }
        var icon: String {
            switch self {
            case .discover: return "magnifyingglass"
            case .map: return "map.fill"
            case .addDeal: return "plus.circle.fill"
            case .profile: return "person.fill"
            }
        }
    }
}

// MARK: - Haptic Feedback
enum HapticFeedback {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Time Helpers
extension String {
    /// Convert "HH:mm" to display string like "4:30 PM"
    var formattedTime: String {
        let parts = split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return self }
        let hour = parts[0], minute = parts[1]
        let period = hour < 12 ? "AM" : "PM"
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return minute == 0 ? "\(displayHour) \(period)" : "\(displayHour):\(String(format: "%02d", minute)) \(period)"
    }
}
