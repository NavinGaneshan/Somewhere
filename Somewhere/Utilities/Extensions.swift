import SwiftUI
import FirebaseFirestore

// MARK: - View Extensions
extension View {
    func cardStyle(padding: CGFloat = AppConstants.standardPadding) -> some View {
        self
            .padding(padding)
            .background(Color.appSurface)
            .cornerRadius(AppConstants.cardCornerRadius)
            .shadow(color: .black.opacity(0.07), radius: AppConstants.cardShadowRadius, x: 0, y: 2)
    }

    func shimmer(isLoading: Bool) -> some View {
        self.redacted(reason: isLoading ? .placeholder : [])
    }

    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Font Extensions
extension Font {
    static let appLargeTitle = Font.system(size: 34, weight: .bold, design: .rounded)
    static let appTitle = Font.system(size: 28, weight: .bold, design: .rounded)
    static let appTitle2 = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let appTitle3 = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let appHeadline = Font.system(size: 17, weight: .semibold, design: .default)
    static let appBody = Font.system(size: 17, weight: .regular, design: .default)
    static let appCallout = Font.system(size: 16, weight: .regular, design: .default)
    static let appSubheadline = Font.system(size: 15, weight: .regular, design: .default)
    static let appFootnote = Font.system(size: 13, weight: .regular, design: .default)
    static let appCaption = Font.system(size: 12, weight: .regular, design: .default)
    static let appCaption2 = Font.system(size: 11, weight: .regular, design: .default)
}

// MARK: - Date Extensions
extension Date {
    var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    var formattedRelative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var formattedShort: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }
}

extension Timestamp {
    var date: Date { dateValue() }
    var formattedRelative: String { date.formattedRelative }
}

// MARK: - String Extensions
extension String {
    var isValidEmail: Bool {
        let pattern = #"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: self)
    }

    var isValidPassword: Bool {
        count >= 8
    }

    var isValidURL: Bool {
        guard let url = URL(string: self) else { return false }
        return url.scheme != nil && url.host != nil
    }

    func truncated(_ length: Int, trailing: String = "...") -> String {
        count > length ? String(prefix(length)) + trailing : self
    }
}

// MARK: - Double Extensions
extension Double {
    func formattedMiles() -> String {
        if self < 0.1 {
            return "\(Int(self * 5280)) ft"
        } else if self < 10 {
            return String(format: "%.1f mi", self)
        } else {
            return String(format: "%.0f mi", self)
        }
    }
}

// MARK: - Array Extensions
extension Array where Element: Identifiable {
    mutating func update(_ element: Element) {
        if let index = firstIndex(where: { $0.id == element.id }) {
            self[index] = element
        } else {
            append(element)
        }
    }

    mutating func remove(id: Element.ID) {
        removeAll { $0.id == id }
    }
}

// MARK: - DealCategory Color
extension DealCategory {
    var uiColor: Color {
        switch self {
        case .drinks: return .drinkColor
        case .food: return .foodColor
        case .activity: return .activityColor
        }
    }
}

// MARK: - UIApplication extensions
extension UIApplication {
    var keyWindowScene: UIWindowScene? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    var keyWindow: UIWindow? {
        keyWindowScene?.windows.first { $0.isKeyWindow }
    }

    var rootViewController: UIViewController? {
        keyWindow?.rootViewController
    }

    func topViewController() -> UIViewController? {
        var top = rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - AsyncImage placeholder
struct VenuePhotoView: View {
    let photoReference: String?
    let maxWidth: CGFloat

    var body: some View {
        if let ref = photoReference,
           let url = PlacesService.shared.photoURL(reference: ref, maxWidth: Int(maxWidth)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholderView
                case .empty:
                    placeholderView.overlay(ProgressView().tint(.gray))
                @unknown default:
                    placeholderView
                }
            }
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        ZStack {
            Color.gray.opacity(0.15)
            Image(systemName: "fork.knife")
                .font(.system(size: 32))
                .foregroundColor(.gray.opacity(0.5))
        }
    }
}
