import SwiftUI

struct SignUpView: View {
    @StateObject private var viewModel = AuthViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    enum Field { case name, email, password, confirm }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("Create Account")
                        .font(.appTitle)
                        .foregroundColor(.appText)
                    Text("Join Somewhere to save and share deals")
                        .font(.appSubheadline)
                        .foregroundColor(.appSubtext)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                // Form
                VStack(spacing: 16) {
                    // Success message
                    if let success = viewModel.successMessage {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.appSuccess)
                            Text(success).font(.appFootnote).foregroundColor(.appSuccess)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.appSuccess.opacity(0.1))
                        .cornerRadius(10)
                    }

                    // Error message
                    if let error = viewModel.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.appError)
                            Text(error).font(.appFootnote).foregroundColor(.appError)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.appError.opacity(0.1))
                        .cornerRadius(10)
                    }

                    AuthTextField(
                        placeholder: "Full Name",
                        text: $viewModel.displayName,
                        icon: "person"
                    )
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .email }

                    AuthTextField(
                        placeholder: "Email",
                        text: $viewModel.email,
                        icon: "envelope",
                        keyboardType: .emailAddress,
                        autocapitalization: .never,
                        isValid: viewModel.email.isEmpty || viewModel.email.isValidEmail
                    )
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }

                    AuthSecureField(
                        placeholder: "Password (min. 8 characters)",
                        text: $viewModel.password,
                        icon: "lock"
                    )
                    .focused($focusedField, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .confirm }

                    AuthSecureField(
                        placeholder: "Confirm Password",
                        text: $viewModel.confirmPassword,
                        icon: "lock.fill"
                    )
                    .focused($focusedField, equals: .confirm)
                    .submitLabel(.done)
                    .onSubmit {
                        focusedField = nil
                        Task { await viewModel.signUp() }
                    }

                    if viewModel.passwordMismatch {
                        HStack {
                            Image(systemName: "exclamationmark.circle").foregroundColor(.appError)
                            Text("Passwords don't match").font(.appCaption).foregroundColor(.appError)
                            Spacer()
                        }
                    }

                    // Password strength
                    if !viewModel.password.isEmpty {
                        PasswordStrengthView(password: viewModel.password)
                    }

                    Button {
                        focusedField = nil
                        Task { await viewModel.signUp() }
                    } label: {
                        HStack {
                            if viewModel.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Create Account").font(.appHeadline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(viewModel.isSignUpValid ? Color.appPrimary : Color.gray.opacity(0.4))
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .disabled(!viewModel.isSignUpValid || viewModel.isLoading)
                }

                // Google Sign In
                VStack(spacing: 16) {
                    HStack {
                        Rectangle().frame(height: 1).foregroundColor(.appDivider)
                        Text("or").font(.appCaption).foregroundColor(.appSubtext).padding(.horizontal, 12)
                        Rectangle().frame(height: 1).foregroundColor(.appDivider)
                    }

                    Button {
                        Task { await viewModel.signInWithGoogle() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "g.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(Color(hex: "#4285F4"))
                            Text("Continue with Google").font(.appHeadline).foregroundColor(.appText)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.appSurface)
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appDivider, lineWidth: 1))
                    }
                }

                // Terms
                Text("By creating an account, you agree to our Terms of Service and Privacy Policy.")
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: viewModel.successMessage) { msg in
            if msg != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Password Strength View
struct PasswordStrengthView: View {
    let password: String

    private var strength: Int {
        var score = 0
        if password.count >= 8 { score += 1 }
        if password.count >= 12 { score += 1 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { score += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
        if password.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*()")) != nil { score += 1 }
        return min(score, 4)
    }

    private var strengthLabel: String {
        switch strength {
        case 0, 1: return "Weak"
        case 2: return "Fair"
        case 3: return "Good"
        default: return "Strong"
        }
    }

    private var strengthColor: Color {
        switch strength {
        case 0, 1: return .appError
        case 2: return .appWarning
        case 3: return Color(hex: "#27AE60")
        default: return .appSuccess
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .frame(height: 4)
                        .foregroundColor(index < strength ? strengthColor : Color.appDivider)
                }
            }
            Text("Password strength: \(strengthLabel)")
                .font(.appCaption)
                .foregroundColor(strengthColor)
        }
    }
}
