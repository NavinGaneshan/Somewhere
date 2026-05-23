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
    // Display — Fraunces (editorial serif)
    static let appLargeTitle = Font.custom("Fraunces-Light", size: 42, relativeTo: .largeTitle)
    static let appTitle = Font.custom("Fraunces-Light", size: 28, relativeTo: .title)
    static let appTitle2 = Font.custom("Fraunces-Light", size: 22, relativeTo: .title2)
    static let appTitle3 = Font.custom("Fraunces-Light", size: 20, relativeTo: .title3)
    static let appQuote = Font.custom("Fraunces-Italic", size: 17, relativeTo: .headline)

    // UI — Inter Tight
    static let appHeadline    = Font.custom("InterTight-SemiBold", size: 15, relativeTo: .headline)
    static let appBody        = Font.custom("InterTight-Regular",  size: 15, relativeTo: .body)
    static let appCallout     = Font.custom("InterTight-Regular",  size: 16, relativeTo: .callout)
    static let appFootnote    = Font.custom("InterTight-Regular",  size: 13, relativeTo: .footnote)

    // Subheadline weight variants (13 pt) — use these instead of .appSubheadline.weight(...)
    static let appSubheadline         = Font.custom("InterTight-Regular",  size: 13, relativeTo: .subheadline)
    static let appSubheadlineMedium   = Font.custom("InterTight-Medium",   size: 13, relativeTo: .subheadline)
    static let appSubheadlineSemiBold = Font.custom("InterTight-SemiBold", size: 13, relativeTo: .subheadline)
    static let appSubheadlineBold     = Font.custom("InterTight-Bold",     size: 13, relativeTo: .subheadline)

    // Caption weight variants (11 pt) — use these instead of .appCaption.weight(...)
    static let appCaption         = Font.custom("InterTight-Medium",   size: 11, relativeTo: .caption)
    static let appCaptionSemiBold = Font.custom("InterTight-SemiBold", size: 11, relativeTo: .caption)
    static let appCaptionBold     = Font.custom("InterTight-Bold",     size: 11, relativeTo: .caption)

    // Caption2 weight variants (11 pt)
    static let appCaption2         = Font.custom("InterTight-Regular",  size: 11, relativeTo: .caption2)
    static let appCaption2SemiBold = Font.custom("InterTight-SemiBold", size: 11, relativeTo: .caption2)

    // Mono — for time, coords, micro-labels
    static let appMono = Font.system(.caption, design: .monospaced)
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

// MARK: - Venue Photo View
/// Loads Google Places photos with the X-Ios-Bundle-Identifier header set,
/// which is required by the iOS-app restriction on the Places API key.
/// SwiftUI's `AsyncImage` can't customize the request, so we do the fetch ourselves.
struct VenuePhotoView: View {
    let photoReference: String?
    let maxWidth: CGFloat

    @State private var uiImage: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else if didFail || photoReference == nil {
                placeholderView
            } else {
                placeholderView.overlay(ProgressView().tint(.gray))
            }
        }
        .task(id: photoReference) {
            await load()
        }
    }

    private func load() async {
        uiImage = nil
        didFail = false

        guard let ref = photoReference,
              let url = PlacesService.shared.photoURL(reference: ref, maxWidth: Int(maxWidth)) else {
            didFail = true
            return
        }

        var request = URLRequest(url: url)
        if let bundleId = Bundle.main.bundleIdentifier {
            request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               http.statusCode == 200,
               let image = UIImage(data: data) {
                self.uiImage = image
            } else {
                didFail = true
            }
        } catch {
            didFail = true
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
