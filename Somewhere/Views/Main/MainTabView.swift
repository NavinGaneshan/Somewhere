import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var authService: AuthService
    // Owned here at the tab-container level so Discover and Map share the same
    // filter, deals, venues, and last-search location. Each tab used to have its
    // own @StateObject DealsViewModel, which meant changing a filter on Discover
    // did not affect Map, and vice versa.
    @StateObject private var dealsViewModel = DealsViewModel()
    @State private var selectedTab = 0
    @State private var showAddDeal = false

    var body: some View {
        TabView(selection: $selectedTab) {
            // Discover tab
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Discover", systemImage: selectedTab == 0 ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
            }
            .tag(0)

            // Map tab
            NavigationStack {
                MapDealsView()
            }
            .tabItem {
                Label("Map", systemImage: selectedTab == 1 ? "map.fill" : "map")
            }
            .tag(1)

            // Add Deal (center tab)
            Color.clear
                .tabItem {
                    Label("Share", systemImage: "plus.circle.fill")
                }
                .tag(2)

            // Profile tab
            NavigationStack {
                ProfileView()
            }
            .tabItem {
                Label("Profile", systemImage: selectedTab == 3 ? "person.circle.fill" : "person.circle")
            }
            .tag(3)

            // Admin tab (only shown to admins/moderators)
            if authService.canAccessAdmin {
                NavigationStack {
                    AdminDashboardView()
                }
                .tabItem {
                    Label("Admin", systemImage: selectedTab == 4 ? "gauge.with.dots.needle.100percent" : "gauge")
                }
                .tag(4)
            }
        }
        .tint(.appPrimary)
        .environmentObject(dealsViewModel)
        .onChange(of: selectedTab) { tab in
            if tab == 2 {
                showAddDeal = true
                // Reset tab to previous
                selectedTab = 0
            }
        }
        .sheet(isPresented: $showAddDeal) {
            NavigationStack {
                AddDealView()
            }
        }
    }
}
