import SwiftUI

struct ForgotPasswordView: View {
    @Binding var email: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = AuthViewModel()
    @FocusState private var isEmailFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                // Icon
                Image(systemName: "lock.rotation")
                    .font(.system(size: 56))
                    .foregroundColor(.appPrimary)
                    .padding(.top, 40)

                // Text
                VStack(spacing: 12) {
                    Text("Reset Password")
                        .font(.appTitle2)
                        .foregroundColor(.appText)
                    Text("Enter your email and we'll send you a link to reset your password.")
                        .font(.appSubheadline)
                        .foregroundColor(.appSubtext)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                // Form
                VStack(spacing: 16) {
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
                        placeholder: "Email address",
                        text: $viewModel.email,
                        icon: "envelope",
                        keyboardType: .emailAddress,
                        autocapitalization: .never,
                        isValid: viewModel.email.isEmpty || viewModel.email.isValidEmail
                    )
                    .focused($isEmailFocused)
                    .onAppear {
                        viewModel.email = email
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            isEmailFocused = true
                        }
                    }

                    Button {
                        isEmailFocused = false
                        Task { await viewModel.sendPasswordReset() }
                    } label: {
                        HStack {
                            if viewModel.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Send Reset Link").font(.appHeadline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(viewModel.email.isValidEmail ? Color.appPrimary : Color.gray.opacity(0.4))
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .disabled(!viewModel.email.isValidEmail || viewModel.isLoading)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.appPrimary)
                }
            }
            .onChange(of: viewModel.successMessage) { msg in
                if msg != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        dismiss()
                    }
                }
            }
        }
    }
}
