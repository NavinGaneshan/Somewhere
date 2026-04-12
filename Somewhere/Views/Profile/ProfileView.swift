import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    @State private var showingSignOutAlert = false
    @State private var showingDeleteAlert = false
    @State private var isEditingName = false
    @State private var newDisplayName = ""
    @State private var userDeals: [Deal] = []
    @State private var isLoading = false

    private var user: AppUser? { authService.currentUser }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Profile header
                profileHeader

                // Stats
                statsSection

                // My Deals
                myDealsSection

                // Settings
                settingsSection

                // Sign out / Delete
                accountActions
            }
            .padding(16)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadUserDeals() }
        .alert("Sign Out", isPresented: $showingSignOutAlert) {
            Button("Sign Out", role: .destructive) {
                authService.currentUser.map { _ in
                    let vm = AuthViewModel()
                    vm.signOut()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        VStack(spacing: 16) {
            // Avatar
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.appPrimary, .appAccent], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 80, height: 80)

                if let photoURL = user?.photoURL, let url = URL(string: photoURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        EmptyView()
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                } else {
                    Text(user?.initials ?? "?")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                }

                // Role badge
                if let role = user?.role, role != .user {
                    Text(role.displayName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.appAccent)
                        .cornerRadius(10)
                        .offset(y: 38)
                }
            }
            .padding(.bottom, 8)

            // Name
            if isEditingName {
                HStack {
                    TextField("Display Name", text: $newDisplayName)
                        .font(.appTitle3)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        Task {
                            try? await authService.updateDisplayName(newDisplayName)
                            isEditingName = false
                        }
                    }
                    .foregroundColor(.appPrimary)

                    Button("Cancel") {
                        isEditingName = false
                    }
                    .foregroundColor(.appSubtext)
                }
            } else {
                HStack(spacing: 8) {
                    Text(user?.displayName ?? "User")
                        .font(.appTitle3)
                        .foregroundColor(.appText)
                    Button {
                        newDisplayName = user?.displayName ?? ""
                        isEditingName = true
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.appSubtext)
                    }
                }
            }

            Text(user?.email ?? "")
                .font(.appSubheadline)
                .foregroundColor(.appSubtext)

            // Auth provider badge
            if let provider = user?.authProvider {
                HStack(spacing: 4) {
                    Image(systemName: provider == .google ? "g.circle.fill" : "envelope.fill")
                        .font(.system(size: 12))
                    Text(provider == .google ? "Signed in with Google" : "Email Account")
                        .font(.appCaption)
                }
                .foregroundColor(.appSubtext)
            }
        }
        .padding(20)
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 0) {
            statItem(label: "Deals Added", value: "\(user?.dealsSubmitted ?? 0)")
            Divider().frame(height: 40)
            statItem(label: "Approved", value: "\(user?.dealsApproved ?? 0)")
            Divider().frame(height: 40)
            statItem(label: "Score", value: "\(user?.contributionScore ?? 0)")
        }
        .padding(.vertical, 16)
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.appPrimary)
            Text(label)
                .font(.appCaption)
                .foregroundColor(.appSubtext)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - My Deals

    private var myDealsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("My Submitted Deals", systemImage: "tag.fill")
                .font(.appHeadline)
                .foregroundColor(.appText)

            if isLoading {
                ProgressView().padding()
            } else if userDeals.isEmpty {
                Text("You haven't submitted any deals yet.")
                    .font(.appSubheadline)
                    .foregroundColor(.appSubtext)
                    .padding(.vertical, 8)
            } else {
                ForEach(userDeals.prefix(5)) { deal in
                    UserDealRow(deal: deal)
                }
            }
        }
        .padding(16)
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(spacing: 0) {
            SettingsRow(icon: "bell.fill", title: "Notifications", color: .appAccent) {}
            Divider().padding(.horizontal, 16)
            SettingsRow(icon: "location.fill", title: "Location Settings", color: .appPrimary) {
                LocationService.shared.openSettings()
            }
            Divider().padding(.horizontal, 16)
            SettingsRow(icon: "questionmark.circle.fill", title: "Help & Support", color: Color(hex: "#5856D6")) {
                if let url = URL(string: "mailto:\(AppConstants.supportEmail)") {
                    UIApplication.shared.open(url)
                }
            }
            Divider().padding(.horizontal, 16)
            SettingsRow(icon: "doc.text.fill", title: "Privacy Policy", color: .appSubtext) {}
        }
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    // MARK: - Account Actions

    private var accountActions: some View {
        VStack(spacing: 12) {
            Button {
                showingSignOutAlert = true
            } label: {
                Label("Sign Out", systemImage: "arrow.right.square")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.appSurface)
                    .foregroundColor(.appError)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appError.opacity(0.3), lineWidth: 1))
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: - Data Loading

    private func loadUserDeals() {
        guard let userId = user?.id else { return }
        isLoading = true
        Task {
            do {
                let snapshot = try await FirestoreService.shared.dealsRef
                    .whereField("createdBy", isEqualTo: userId)
                    .order(by: "createdAt", descending: true)
                    .limit(to: 5)
                    .getDocuments()
                userDeals = snapshot.documents.compactMap { try? $0.data(as: Deal.self) }
            } catch {}
            isLoading = false
        }
    }
}

// MARK: - Supporting Views

struct UserDealRow: View {
    let deal: Deal

    var body: some View {
        HStack(spacing: 10) {
            Text(deal.category.icon)
                .font(.system(size: 20))
                .frame(width: 36, height: 36)
                .background(deal.category.uiColor.opacity(0.12))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(deal.venueName).font(.appCaption.weight(.semibold)).foregroundColor(.appText)
                Text(deal.title).font(.appCaption).foregroundColor(.appSubtext).lineLimit(1)
            }

            Spacer()

            dealStatusBadge(deal.status)
        }
        .padding(.vertical, 6)
    }

    private func dealStatusBadge(_ status: DealStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .active: return ("Active", .appSuccess)
            case .pending: return ("Pending", .appWarning)
            case .rejected: return ("Rejected", .appError)
            case .expired: return ("Expired", .appSubtext)
            case .unverified: return ("Unverified", .appSubtext)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .cornerRadius(10)
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.1))
                    .cornerRadius(8)
                Text(title)
                    .font(.appSubheadline)
                    .foregroundColor(.appText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.appSubtext)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}
