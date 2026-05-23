import SwiftUI

struct LoginView: View {
    @StateObject private var viewModel = AuthViewModel()
    @State private var showingSignUp = false
    @State private var showingForgotPassword = false
    @FocusState private var focusedField: Field?

    enum Field { case email, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    headerSection
                        .padding(.top, 60)
                        .padding(.bottom, 40)

                    // Form
                    formSection
                        .padding(.horizontal, 24)

                    // Divider
                    dividerSection
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)

                    // Social sign-in
                    socialSection
                        .padding(.horizontal, 24)

                    // Sign up link
                    signUpLink
                        .padding(.top, 32)
                        .padding(.bottom, 40)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationDestination(isPresented: $showingSignUp) {
                SignUpView()
            }
            .sheet(isPresented: $showingForgotPassword) {
                ForgotPasswordView(email: $viewModel.email)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.linearGradient(
                    colors: [Color.appPrimary, Color.appAccent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            Text("Somewhere")
                .font(.appLargeTitle)
                .foregroundColor(.appText)

            Text("Find happy hour deals near you")
                .font(.appSubheadline)
                .foregroundColor(.appSubtext)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Form

    private var formSection: some View {
        VStack(spacing: 16) {
            // Error message
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.appError)
                    Text(error)
                        .font(.appFootnote)
                        .foregroundColor(.appError)
                    Spacer()
                }
                .padding(12)
                .background(Color.appError.opacity(0.1))
                .cornerRadius(10)
            }

            // Email field
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

            // Password field
            AuthSecureField(
                placeholder: "Password",
                text: $viewModel.password,
                icon: "lock"
            )
            .focused($focusedField, equals: .password)
            .submitLabel(.done)
            .onSubmit {
                focusedField = nil
                Task { await viewModel.signIn() }
            }

            // Forgot password
            HStack {
                Spacer()
                Button("Forgot password?") {
                    showingForgotPassword = true
                }
                .font(.appFootnote)
                .foregroundColor(.appPrimary)
            }
            .padding(.top, -4)

            // Sign in button
            Button {
                focusedField = nil
                Task { await viewModel.signIn() }
            } label: {
                HStack {
                    if viewModel.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Sign In")
                            .font(.appHeadline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(viewModel.isSignInValid ? Color.appPrimary : Color.gray.opacity(0.4))
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .disabled(!viewModel.isSignInValid || viewModel.isLoading)
        }
    }

    // MARK: - Divider

    private var dividerSection: some View {
        HStack {
            Rectangle().frame(height: 1).foregroundColor(.appDivider)
            Text("or").font(.appCaption).foregroundColor(.appSubtext).padding(.horizontal, 12)
            Rectangle().frame(height: 1).foregroundColor(.appDivider)
        }
    }

    // MARK: - Social

    private var socialSection: some View {
        Button {
            Task { await viewModel.signInWithGoogle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "g.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Color(hex: "#4285F4"))
                Text("Continue with Google")
                    .font(.appHeadline)
                    .foregroundColor(.appText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.appSurface)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.appDivider, lineWidth: 1)
            )
        }
        .disabled(viewModel.isLoading)
    }

    // MARK: - Sign Up Link

    private var signUpLink: some View {
        HStack {
            Text("Don't have an account?")
                .font(.appSubheadline)
                .foregroundColor(.appSubtext)
            Button("Sign up") {
                showingSignUp = true
            }
            .font(.appSubheadlineSemiBold)
            .foregroundColor(.appPrimary)
        }
    }
}

// MARK: - Reusable Auth Text Field
struct AuthTextField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences
    var isValid: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(isValid ? .appSubtext : .appError)
                .frame(width: 20)
            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .font(.appBody)
                .foregroundColor(.appText)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.appSurface)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isValid ? Color.appDivider : Color.appError, lineWidth: 1)
        )
    }
}

// MARK: - Reusable Secure Field
struct AuthSecureField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.appSubtext)
                .frame(width: 20)
            Group {
                if isVisible {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .font(.appBody)
            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .foregroundColor(.appSubtext)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color.appSurface)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.appDivider, lineWidth: 1)
        )
    }
}
