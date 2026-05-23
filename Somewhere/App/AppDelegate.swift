import UIKit
import FirebaseCore
import FirebaseAppCheck
import GoogleSignIn

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Use debug App Check provider on simulator/debug builds so DeviceCheck errors
        // don't block Firestore. Production builds use DeviceCheck automatically.
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #endif

        // Initialize Firebase
        FirebaseApp.configure()

        // Configure Google Sign-In
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String {
            let config = GIDConfiguration(clientID: clientID)
            GIDSignIn.sharedInstance.configuration = config
        }

        // Restore previous Google Sign-In
        GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
            // Firebase Auth listener handles the rest
        }

        // Apply Fraunces + Inter Tight to navigation bar titles via UINavigationBarAppearance
        let inkColor = UIColor(red: 0.098, green: 0.086, blue: 0.075, alpha: 1)
        let largeTitleFont = UIFont(name: "Fraunces-Light", size: 34) ?? UIFont.systemFont(ofSize: 34, weight: .light)
        let inlineTitleFont = UIFont(name: "InterTight-SemiBold", size: 17) ?? UIFont.systemFont(ofSize: 17, weight: .semibold)

        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [.font: largeTitleFont, .foregroundColor: inkColor]
        appearance.titleTextAttributes = [.font: inlineTitleFont, .foregroundColor: inkColor]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance

        return true
    }

    // Handle Google Sign-In URL callback
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }

    // Push notification registration
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Forward to Firebase for FCM
        // Auth.auth().setAPNSToken(deviceToken, type: .unknown)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Handle Firebase Auth phone verification (if used)
        // if Auth.auth().canHandleNotification(userInfo) {
        //     completionHandler(.noData)
        //     return
        // }
        completionHandler(.noData)
    }
}
