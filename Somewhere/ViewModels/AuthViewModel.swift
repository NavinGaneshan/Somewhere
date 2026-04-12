import Foundation
import SwiftUI

@MainActor
class AuthViewModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published var displayName = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var showForgotPassword = false

    private let authService = AuthService.shared

    var isSignInValid: Bool {
        email.isValidEmail && !password.isEmpty
    }

    var isSignUpValid: Bool {
        email.isValidEmail &&
        password.isValidPassword &&
        password == confirmPassword &&
        displayName.count >= 2
    }

    var passwordMismatch: Bool {
        !confirmPassword.isEmpty && password != confirmPassword
    }

    // MARK: - Sign In

    func signIn() async {
        guard isSignInValid else { return }
        isLoading = true
        errorMessage = nil

        do {
            try await authService.signIn(email: email, password: password)
            HapticFeedback.success()
        } catch let error as AuthError {
            errorMessage = error.localizedDescription
            HapticFeedback.error()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Sign Up

    func signUp() async {
        guard isSignUpValid else { return }
        isLoading = true
        errorMessage = nil

        do {
            try await authService.signUp(email: email, password: password, displayName: displayName)
            HapticFeedback.success()
            successMessage = "Account created! Please verify your email."
        } catch let error as AuthError {
            errorMessage = error.localizedDescription
            HapticFeedback.error()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Google Sign In

    func signInWithGoogle() async {
        isLoading = true
        errorMessage = nil

        guard let vc = UIApplication.shared.topViewController() else {
            errorMessage = "Could not present sign-in."
            isLoading = false
            return
        }

        do {
            try await authService.signInWithGoogle(presenting: vc)
            HapticFeedback.success()
        } catch let error as AuthError {
            errorMessage = error.localizedDescription
            HapticFeedback.error()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Forgot Password

    func sendPasswordReset() async {
        guard email.isValidEmail else {
            errorMessage = "Please enter a valid email address."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await authService.resetPassword(email: email)
            successMessage = "Password reset email sent to \(email)."
            HapticFeedback.success()
        } catch let error as AuthError {
            errorMessage = error.localizedDescription
            HapticFeedback.error()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Sign Out

    func signOut() {
        do {
            try authService.signOut()
            resetFields()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetFields() {
        email = ""
        password = ""
        confirmPassword = ""
        displayName = ""
        errorMessage = nil
        successMessage = nil
    }
}
