import SwiftUI

struct DealRowView: View {
    let deal: Deal
    let onVote: (String, Bool) -> Void
    @State private var hasVoted = false
    @State private var showingSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                // Category badge
                categoryBadge

                VStack(alignment: .leading, spacing: 4) {
                    // Title
                    HStack {
                        Text(deal.title)
                            .font(.appSubheadline.weight(.semibold))
                            .foregroundColor(.appText)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer()

                        // Active indicator
                        if deal.isActiveNow {
                            HStack(spacing: 3) {
                                Circle().fill(Color.activeGreen).frame(width: 5, height: 5)
                                Text("Active").font(.system(size: 10, weight: .bold)).foregroundColor(.activeGreen)
                            }
                        }
                    }

                    // Description
                    Text(deal.description)
                        .font(.appCaption)
                        .foregroundColor(.appSubtext)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Time/days row
            HStack(spacing: 10) {
                Label(deal.formattedTimeRange, systemImage: "clock")
                    .font(.appCaption.weight(.medium))
                    .foregroundColor(.appText)

                Text("·").foregroundColor(.appDivider)

                Text(deal.formattedDays)
                    .font(.appCaption.weight(.medium))
                    .foregroundColor(.appText)

                Spacer()

                sourceLabel
            }

            // Votes + More row
            HStack(spacing: 12) {
                // Upvote
                Button {
                    guard !hasVoted else { return }
                    hasVoted = true
                    onVote(deal.id, true)
                    HapticFeedback.impact(.light)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hasVoted ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.system(size: 13))
                        Text("\(deal.upvotes)")
                            .font(.appCaption)
                    }
                    .foregroundColor(hasVoted ? .appPrimary : .appSubtext)
                }

                // Downvote
                Button {
                    guard !hasVoted else { return }
                    hasVoted = true
                    onVote(deal.id, false)
                    HapticFeedback.impact(.light)
                } label: {
                    Image(systemName: "hand.thumbsdown")
                        .font(.system(size: 13))
                        .foregroundColor(.appSubtext)
                }

                Spacer()

                if deal.isVerified {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.appSuccess)
                        Text("Verified")
                            .font(.appCaption2)
                            .foregroundColor(.appSuccess)
                    }
                }

                // "More" button — only shown when there's a source to display
                if deal.sourceURL != nil {
                    Button {
                        showingSource = true
                        HapticFeedback.impact(.light)
                    } label: {
                        Text("More")
                            .font(.appCaption2.weight(.semibold))
                            .foregroundColor(.appPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.appPrimary.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .sheet(isPresented: $showingSource) {
            if let urlString = deal.sourceURL {
                DealSourceSheet(deal: deal, sourceURLString: urlString)
            }
        }
    }

    private var categoryBadge: some View {
        Text(deal.category.icon)
            .font(.system(size: 20))
            .frame(width: 36, height: 36)
            .background(deal.category.uiColor.opacity(0.12))
            .cornerRadius(8)
    }

    private var sourceLabel: some View {
        Group {
            switch deal.source {
            case .photo:
                Label("Photo", systemImage: "camera.fill")
            case .website:
                Label("Web", systemImage: "safari")
            case .userContributed:
                Label("User", systemImage: "person.fill")
            case .automated:
                Label("Auto", systemImage: "cpu")
            case .manual:
                EmptyView()
            }
        }
        .font(.system(size: 10))
        .foregroundColor(.appSubtext.opacity(0.7))
    }
}

// MARK: - Deal Source Sheet

struct DealSourceSheet: View {
    let deal: Deal
    let sourceURLString: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var sourceURL: URL? { URL(string: sourceURLString) }

    private var isImageSource: Bool {
        let lower = sourceURLString.lowercased()
        return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") ||
               lower.hasSuffix(".png") || lower.hasSuffix(".webp") ||
               lower.hasSuffix(".gif") || lower.contains("place/photo") ||
               lower.contains("googleusercontent")
    }

    private var displayDomain: String {
        URL(string: sourceURLString)?.host ?? sourceURLString
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Deal header recap
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(deal.category.icon).font(.system(size: 22))
                            Text(deal.title)
                                .font(.appHeadline)
                                .foregroundColor(.appText)
                            Spacer()
                        }
                        Text(deal.formattedTimeRange + "  ·  " + deal.formattedDays)
                            .font(.appCaption)
                            .foregroundColor(.appSubtext)
                    }
                    .padding(16)
                    .background(Color.appSurface)
                    .cornerRadius(AppConstants.cardCornerRadius)

                    // Source content
                    if isImageSource {
                        imageSourceView
                    } else {
                        webSourceView
                    }
                }
                .padding(16)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var imageSourceView: some View {
        VStack(spacing: 12) {
            if let url = sourceURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(AppConstants.cardCornerRadius)
                    case .failure:
                        sourceUnavailablePlaceholder
                    case .empty:
                        ProgressView()
                            .frame(height: 200)
                    @unknown default:
                        EmptyView()
                    }
                }
            }

            openInBrowserButton
        }
    }

    private var webSourceView: some View {
        VStack(spacing: 12) {
            // Domain pill
            HStack(spacing: 8) {
                Image(systemName: "safari.fill")
                    .foregroundColor(.appPrimary)
                Text(displayDomain)
                    .font(.appSubheadline.weight(.medium))
                    .foregroundColor(.appText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(14)
            .background(Color.appSurface)
            .cornerRadius(AppConstants.cardCornerRadius)

            // Full URL (truncated, selectable)
            Text(sourceURLString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.appSubtext)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.appSurface)
                .cornerRadius(8)

            openInBrowserButton
        }
    }

    private var openInBrowserButton: some View {
        Button {
            if let url = sourceURL { openURL(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "safari")
                Text("Open in Browser")
                    .font(.appSubheadline.weight(.semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.appPrimary)
            .cornerRadius(AppConstants.cardCornerRadius)
        }
        .disabled(sourceURL == nil)
    }

    private var sourceUnavailablePlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.slash")
                .font(.system(size: 36))
                .foregroundColor(.appSubtext)
            Text("Image unavailable")
                .font(.appCaption)
                .foregroundColor(.appSubtext)
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
        .background(Color.appSurface)
        .cornerRadius(AppConstants.cardCornerRadius)
    }
}
