import SwiftUI
import FirebaseCore
import FirebaseAppCheck
import GoogleSignIn

@main
struct SomewhereApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var authService = AuthService.shared
    @StateObject private var locationService = LocationService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
                .environmentObject(locationService)
                .preferredColorScheme(.light)  // Support dark mode later
        }
    }
}
