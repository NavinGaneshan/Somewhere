import SwiftUI

struct AdminUsersView: View {
    @EnvironmentObject var viewModel: AdminViewModel
    @State private var searchQuery = ""
    @State private var selectedRole: UserRole? = nil
    @State private var showBannedOnly = false

    private var filteredUsers: [AppUser] {
        viewModel.users.filter { user in
            if showBannedOnly && !user.isBanned { return false }
            if let role = selectedRole, user.role != role { return false }
            if !searchQuery.isEmpty {
                let q = searchQuery.lowercased()
                return user.displayName.lowercased().contains(q) || user.email.lowercased().contains(q)
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search & filters
            VStack(spacing: 10) {
                AuthTextField(placeholder: "Search users...", text: $searchQuery, icon: "magnifyingglass")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // All
                        FilterChip(label: "All", icon: nil, color: selectedRole == nil ? .appPrimary : .appSubtext) {
                            selectedRole = nil
                        }

                        ForEach(UserRole.allCases, id: \.self) { role in
                            FilterChip(label: role.displayName, icon: nil, color: selectedRole == role ? .appPrimary : .appSubtext) {
                                selectedRole = selectedRole == role ? nil : role
                            }
                        }

                        FilterChip(label: "Banned", icon: "xmark.circle.fill", color: showBannedOnly ? .appError : .appSubtext) {
                            showBannedOnly.toggle()
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.appBackground)

            List {
                ForEach(filteredUsers) { user in
                    AdminUserRow(user: user) { newRole in
                        Task { await viewModel.updateUserRole(userId: user.id, role: newRole) }
                    } onToggleBan: { banned in
                        Task { await viewModel.toggleBanUser(userId: user.id, banned: banned) }
                    }
                }
            }
            .listStyle(.plain)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Users (\(viewModel.totalUsers))")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if viewModel.users.isEmpty {
                Task { await viewModel.loadUsers() }
            }
        }
    }
}

struct AdminUserRow: View {
    let user: AppUser
    let onRoleChange: (UserRole) -> Void
    let onToggleBan: (Bool) -> Void
    @State private var showingActions = false

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(user.isBanned ? Color.appError : Color.appPrimary)
                    .frame(width: 40, height: 40)
                Text(user.initials)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(user.displayName)
                        .font(.appSubheadline.weight(.medium))
                        .foregroundColor(user.isBanned ? .appError : .appText)
                    if user.isBanned {
                        Text("BANNED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.appError)
                            .cornerRadius(4)
                    }
                }
                Text(user.email)
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
                HStack(spacing: 8) {
                    Text(user.role.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.appPrimary)
                    Text("·")
                    Text("Joined \(user.createdAt.formattedRelative)")
                        .font(.appCaption2)
                        .foregroundColor(.appSubtext)
                }
            }

            Spacer()

            // Actions menu
            Menu {
                // Role options
                Menu("Change Role") {
                    ForEach(UserRole.allCases, id: \.self) { role in
                        Button {
                            onRoleChange(role)
                        } label: {
                            Label(role.displayName,
                                  systemImage: user.role == role ? "checkmark" : "")
                        }
                    }
                }

                Divider()

                if user.isBanned {
                    Button("Unban User") { onToggleBan(false) }
                } else {
                    Button("Ban User", role: .destructive) { onToggleBan(true) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.appSubtext)
            }
        }
        .padding(.vertical, 4)
    }
}
