import SwiftUI

struct FilterSheetView: View {
    @Binding var filter: SearchFilter
    let onApply: (SearchFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var localFilter: SearchFilter = .default

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Quick Filters
                    filterSection("Quick Filters") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(TimeFilter.allCases) { timeFilter in
                                QuickFilterButton(
                                    title: timeFilter.displayName,
                                    icon: timeFilter.icon,
                                    isSelected: localFilter.timeFilter == timeFilter
                                ) {
                                    localFilter.timeFilter = timeFilter
                                    if timeFilter == .now {
                                        localFilter.showOnlyActiveNow = true
                                    } else {
                                        localFilter.showOnlyActiveNow = false
                                    }
                                }
                            }
                        }
                    }

                    // Deal Categories
                    filterSection("Deal Type") {
                        HStack(spacing: 10) {
                            ForEach(DealCategory.allCases) { cat in
                                CategoryToggleButton(
                                    category: cat,
                                    isSelected: localFilter.categories.contains(cat)
                                ) {
                                    if localFilter.categories.contains(cat) {
                                        localFilter.categories.remove(cat)
                                    } else {
                                        localFilter.categories.insert(cat)
                                    }
                                }
                            }
                            Spacer()
                        }
                    }

                    // Days of Week
                    filterSection("Days") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                            ForEach(DayOfWeek.allCases) { day in
                                DayToggleButton(
                                    day: day,
                                    isSelected: localFilter.selectedDays.contains(day)
                                ) {
                                    if localFilter.selectedDays.contains(day) {
                                        localFilter.selectedDays.remove(day)
                                    } else {
                                        localFilter.selectedDays.insert(day)
                                    }
                                }
                            }
                        }
                    }

                    // Custom Time Range
                    if localFilter.timeFilter == .custom {
                        filterSection("Custom Time Range") {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("From").font(.appCaption).foregroundColor(.appSubtext)
                                    TimePickerField(time: $localFilter.customStartTime)
                                }
                                Text("to").font(.appSubheadline).foregroundColor(.appSubtext)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("To").font(.appCaption).foregroundColor(.appSubtext)
                                    TimePickerField(time: $localFilter.customEndTime)
                                }
                                Spacer()
                            }
                        }
                    }

                    // Venue Types
                    filterSection("Venue Type") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(VenueCategory.allCases) { cat in
                                VenueCategoryButton(
                                    category: cat,
                                    isSelected: localFilter.venueCategories.contains(cat)
                                ) {
                                    if localFilter.venueCategories.contains(cat) {
                                        localFilter.venueCategories.remove(cat)
                                    } else {
                                        localFilter.venueCategories.insert(cat)
                                    }
                                }
                            }
                        }
                    }

                    // Location Override
                    filterSection("Location") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundColor(.appPrimary)
                                TextField("City, zip, or leave empty for current", text: $localFilter.locationQuery)
                                    .font(.appSubheadline)
                                    .textInputAutocapitalization(.words)
                                    .autocorrectionDisabled()
                                    .submitLabel(.done)
                                if !localFilter.locationQuery.isEmpty {
                                    Button {
                                        localFilter.locationQuery = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.appSubtext)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(Color.appSurface)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appDivider, lineWidth: 1))
                            Text("Overrides device location when set. Examples: \"Atlanta, GA\", \"30309\".")
                                .font(.appCaption)
                                .foregroundColor(.appSubtext)
                        }
                    }

                    // Search Radius
                    filterSection("Search Radius") {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Within \(String(format: "%.1f", localFilter.searchRadius)) miles")
                                    .font(.appSubheadline)
                                    .foregroundColor(.appText)
                                Spacer()
                            }
                            Slider(
                                value: $localFilter.searchRadius,
                                in: AppConstants.minSearchRadiusMiles...AppConstants.maxSearchRadiusMiles,
                                step: 0.25
                            )
                            .tint(.appPrimary)
                            HStack {
                                Text("\(String(format: "%.2g", AppConstants.minSearchRadiusMiles)) mi")
                                Spacer()
                                Text("\(String(format: "%.0f", AppConstants.maxSearchRadiusMiles)) mi")
                            }
                            .font(.appCaption)
                            .foregroundColor(.appSubtext)
                        }
                    }

                    // Sort Options
                    filterSection("Sort By") {
                        HStack(spacing: 8) {
                            ForEach(SortOption.allCases) { option in
                                Button {
                                    localFilter.sortOption = option
                                } label: {
                                    Text(option.displayName)
                                        .font(.appCaption.weight(.medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(localFilter.sortOption == option ? Color.appPrimary : Color.appSurface)
                                        .foregroundColor(localFilter.sortOption == option ? .white : .appText)
                                        .cornerRadius(20)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 20)
                                                .stroke(localFilter.sortOption == option ? Color.clear : Color.appDivider, lineWidth: 1)
                                        )
                                }
                            }
                        }
                    }

                    // Additional Options
                    filterSection("Options") {
                        VStack(spacing: 12) {
                            Toggle(isOn: $localFilter.showOnlyVerified) {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.seal.fill").foregroundColor(.appSuccess)
                                    Text("Verified deals only").font(.appSubheadline)
                                }
                            }
                            .tint(.appPrimary)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset") {
                        localFilter = .default
                    }
                    .foregroundColor(.appError)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply") {
                        onApply(localFilter)
                        dismiss()
                    }
                    .font(.appHeadline)
                    .foregroundColor(.appPrimary)
                }
            }
        }
        .onAppear { localFilter = filter }
    }

    private func filterSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.appHeadline)
                .foregroundColor(.appText)
            content()
        }
    }
}

// MARK: - Filter Buttons

struct QuickFilterButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.appCaption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? Color.appPrimary : Color.appSurface)
            .foregroundColor(isSelected ? .white : .appText)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.clear : Color.appDivider, lineWidth: 1)
            )
        }
    }
}

struct CategoryToggleButton: View {
    let category: DealCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(category.icon).font(.system(size: 16))
                Text(category.displayName).font(.appCaption.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? category.uiColor : Color.appSurface)
            .foregroundColor(isSelected ? .white : .appText)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? Color.clear : Color.appDivider, lineWidth: 1)
            )
        }
    }
}

struct DayToggleButton: View {
    let day: DayOfWeek
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(String(day.shortName.prefix(1)))
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(isSelected ? Color.appPrimary : Color.appSurface)
                .foregroundColor(isSelected ? .white : .appText)
                .clipShape(Circle())
                .overlay(Circle().stroke(isSelected ? Color.clear : Color.appDivider, lineWidth: 1))
        }
    }
}

struct VenueCategoryButton: View {
    let category: VenueCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(category.icon).font(.system(size: 18))
                Text(category.displayName).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.appPrimary.opacity(0.15) : Color.appSurface)
            .foregroundColor(isSelected ? .appPrimary : .appText)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.appPrimary : Color.appDivider, lineWidth: 1)
            )
        }
    }
}

struct TimePickerField: View {
    @Binding var time: String

    var body: some View {
        Text(time.formattedTime)
            .font(.appSubheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.appSurface)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appDivider, lineWidth: 1))
    }
}
