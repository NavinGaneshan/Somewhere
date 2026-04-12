import Foundation
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn

// MARK: - Auth Error
enum AuthError: LocalizedError {
    case invalidEmail
    case weakPassword
    case emailAlreadyInUse
    case wrongPassword
    case userNotFound
    case networkError
    case googleSignInFailed
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail: return "Please enter a valid email address."
        case .weakPassword: return "Password must be at least 8 characters."
        case .emailAlreadyInUse: return "An account with this email already exists."
        case .wrongPassword: return "Incorrect password. Please try again."
        case .userNotFound: return "No account found with this email."
        case .networkError: return "Network error. Please check your connection."
        case .googleSignInFailed: return "Google sign-in failed. Please try again."
        case .unknown(let msg): return msg
        }
    }

    static func from(_ error: Error) -> AuthError {
        let nsError = error as NSError
        switch AuthErrorCode(rawValue: nsError.code) {
        case .invalidEmail: return .invalidEmail
        case .weakPassword: return .weakPassword
        case .emailAlreadyInUse: return .emailAlreadyInUse
        case .wrongPassword: return .wrongPassword
        case .userNotFound: return .userNotFound
        case .networkError: return .networkError
        default: return .unknown(error.localizedDescription)
        }
    }
}

// MARK: - Auth Service
@MainActor
class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var currentUser: AppUser?
    @Published var firebaseUser: FirebaseAuth.User?
    @Published var isLoading = false
    @Published var isAuthenticated = false

    private let db = Firestore.firestore()
    private var authStateListener: AuthStateDidChangeListenerHandle?

    private init() {
        setupAuthListener()
    }

    deinit {
        if let listener = authStateListener {
            Auth.auth().removeStateDidChangeListener(listener)
        }
    }

    private func setupAuthListener() {
        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.firebaseUser = user
                if let user = user {
                    self?.isAuthenticated = true
                    await self?.fetchOrCreateUserProfile(firebaseUser: user)
                } else {
                    self?.isAuthenticated = false
                    self?.currentUser = nil
                }
            }
        }
    }

    // MARK: - Email/Password Auth

    func signIn(email: String, password: String) async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            await fetchOrCreateUserProfile(firebaseUser: result.user)
        } catch {
            throw AuthError.from(error)
        }
    }

    func signUp(email: String, password: String, displayName: String) async throws {
        isLoading = true
        defer { isLoading = false }

        guard password.count >= 8 else { throw AuthError.weakPassword }

        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            let changeRequest = result.user.createProfileChangeRequest()
            changeRequest.displayName = displayName
            try await changeRequest.commitChanges()

            let user = AppUser.create(
                uid: result.user.uid,
                email: email,
                displayName: displayName,
                photoURL: nil,
                provider: .email
            )
            try await saveUserProfile(user)
            self.currentUser = user

            // Send verification email
            try? await result.user.sendEmailVerification()
        } catch {
            throw AuthError.from(error)
        }
    }

    func resetPassword(email: String) async throws {
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
        } catch {
            throw AuthError.from(error)
        }
    }

    func signOut() throws {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            currentUser = nil
            isAuthenticated = false
        } catch {
            throw AuthError.from(error)
        }
    }

    // MARK: - Google Sign In

    func signInWithGoogle(presenting viewController: UIViewController) async throws {
        isLoading = true
        defer { isLoading = false }

        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else {
            throw AuthError.unknown("Google client ID not configured.")
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: viewController)
            guard
                let idToken = result.user.idToken?.tokenString
            else {
                throw AuthError.googleSignInFailed
            }
            let accessToken = result.user.accessToken.tokenString
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
            let authResult = try await Auth.auth().signIn(with: credential)

            let profile = result.user.profile
            var appUser = AppUser.create(
                uid: authResult.user.uid,
                email: profile?.email ?? "",
                displayName: profile?.name ?? "",
                photoURL: profile?.imageURL(withDimension: 200)?.absoluteString,
                provider: .google
            )

            // Preserve existing role if user already exists
            if let existing = try? await fetchUserProfile(uid: authResult.user.uid) {
                appUser.role = existing.role
                appUser.dealsSubmitted = existing.dealsSubmitted
                appUser.dealsApproved = existing.dealsApproved
                appUser.searchCount = existing.searchCount
                appUser.createdAt = existing.createdAt
                appUser.favoriteVenueIds = existing.favoriteVenueIds
            }

            try await saveUserProfile(appUser)
            self.currentUser = appUser
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.googleSignInFailed
        }
    }

    // MARK: - Profile Management

    func fetchOrCreateUserProfile(firebaseUser: FirebaseAuth.User) async {
        do {
            if let user = try await fetchUserProfile(uid: firebaseUser.uid) {
                // Update last active
                var updated = user
                updated.lastActiveAt = Timestamp()
                try? await updateUserField(uid: user.id, field: "lastActiveAt", value: Timestamp())
                self.currentUser = updated
            } else {
                // Create profile for existing Firebase user
                let newUser = AppUser.create(
                    uid: firebaseUser.uid,
                    email: firebaseUser.email ?? "",
                    displayName: firebaseUser.displayName ?? "",
                    photoURL: firebaseUser.photoURL?.absoluteString,
                    provider: .email
                )
                try? await saveUserProfile(newUser)
                self.currentUser = newUser
            }
        } catch {
            print("Error fetching user profile: \(error)")
        }
    }

    func fetchUserProfile(uid: String) async throws -> AppUser? {
        let doc = try await db.collection("users").document(uid).getDocument()
        guard doc.exists, let data = doc.data() else { return nil }
        return try? Firestore.Decoder().decode(AppUser.self, from: data)
    }

    func saveUserProfile(_ user: AppUser) async throws {
        try await db.collection("users").document(user.id).setData(user.toFirestore(), merge: true)
    }

    func updateUserField(uid: String, field: String, value: Any) async throws {
        try await db.collection("users").document(uid).updateData([field: value])
    }

    func updateDisplayName(_ name: String) async throws {
        guard let uid = firebaseUser?.uid else { return }
        let changeRequest = firebaseUser?.createProfileChangeRequest()
        changeRequest?.displayName = name
        try await changeRequest?.commitChanges()
        try await updateUserField(uid: uid, field: "displayName", value: name)
        currentUser?.displayName = name
    }

    func deleteAccount() async throws {
        guard let uid = firebaseUser?.uid else { return }
        try await firebaseUser?.delete()
        try await db.collection("users").document(uid).delete()
        currentUser = nil
        isAuthenticated = false
    }

    // MARK: - Admin helpers

    var isAdmin: Bool {
        currentUser?.role == .admin
    }

    var isModerator: Bool {
        currentUser?.role == .moderator || isAdmin
    }

    var canAccessAdmin: Bool {
        currentUser?.role.canAccessAdmin ?? false
    }
}
