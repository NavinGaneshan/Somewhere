import SwiftUI

struct DealRowView: View {
    let deal: Deal
    let onVote: (String, Bool) -> Void
    @State private var hasVoted = false
    @State private var showingSource = false

    private var hasSource: Bool { deal.sourceURL != nil || deal.imageURL != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Category icon in colored box
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(deal.category.uiColor.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: deal.category.icon)
                    .font(.system(size: 16))
                    .foregroundColor(deal.category.uiColor)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                // Title row
                HStack(alignment: .top, spacing: 4) {
                    Text(deal.title)
                        .font(.appQuote)
                        .foregroundColor(.appPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if deal.isActiveNow {
                        HStack(spacing: 3) {
                            Circle().fill(Color.activeGreen).frame(width: 5, height: 5)
                            Text("Now").font(.system(size: 10, weight: .bold)).foregroundColor(.activeGreen)
                        }
                        .padding(.top, 2)
                    }
                }

                // Description
                Text(deal.description)
                    .font(.appCaption)
                    .foregroundColor(.appSubtext)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Footer tags
                HStack(spacing: 6) {
                    tagPill(deal.formattedTimeRange, icon: "clock")
                    tagPill(deal.formattedDays, icon: "calendar")
                    Spacer(minLength: 0)
                    sourceIcon
                }

                // Votes + More row
                HStack(spacing: 10) {
                    Button {
                        guard !hasVoted else { return }
                        hasVoted = true
                        onVote(deal.id, true)
                        HapticFeedback.impact(.light)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: hasVoted ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.system(size: 12))
                            Text("\(deal.upvotes)")
                                .font(.appCaption)
                        }
                        .foregroundColor(hasVoted ? .appPrimary : .appSubtext)
                    }

                    Button {
                        guard !hasVoted else { return }
                        hasVoted = true
                        onVote(deal.id, false)
                        HapticFeedback.impact(.light)
                    } label: {
                        Image(systemName: "hand.thumbsdown")
                            .font(.system(size: 12))
                            .foregroundColor(.appSubtext)
                    }

                    Spacer()

                    if deal.isVerified && deal.source != .manual && deal.source != .photo {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.appSuccess)
                            Text("Confirmed")
                                .font(.appCaption2)
                                .foregroundColor(.appSuccess)
                        }
                    }

                    if hasSource {
                        Button {
                            showingSource = true
                            HapticFeedback.impact(.light)
                        } label: {
                            Text("More")
                                .font(.appCaption2SemiBold)
                                .foregroundColor(.appPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.appPrimary.opacity(0.1))
                                .cornerRadius(6)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.appBackground.opacity(0.6))
        .cornerRadius(8)
        .sheet(isPresented: $showingSource) {
            let urlString = deal.sourceURL ?? deal.imageURL
            if let urlString {
                DealSourceSheet(deal: deal, sourceURLString: urlString)
            }
        }
    }

    private func tagPill(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon = icon {
                Image(systemName: icon).font(.system(size: 9))
            }
            Text(text).font(.appCaption2)
        }
        .foregroundColor(.appSubtext)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.appDivider.opacity(0.5))
        .cornerRadius(4)
    }

    private var sourceIcon: some View {
        Group {
            switch deal.source {
            case .photo:
                Image(systemName: "camera.fill")
            case .website:
                Image(systemName: "safari")
            case .userContributed:
                Image(systemName: "person.fill")
            case .automated:
                Image(systemName: "cpu")
            case .manual:
                EmptyView()
            }
        }
        .font(.system(size: 9))
        .foregroundColor(.appSubtext.opacity(0.6))
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
               lower.contains("googleusercontent") ||
               lower.contains("firebasestorage.googleapis.com")
    }

    private var isLocalStorageImage: Bool {
        sourceURLString.lowercased().contains("firebasestorage.googleapis.com")
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
                            Image(systemName: deal.category.icon).font(.system(size: 20)).foregroundColor(deal.category.uiColor)
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

            if !isLocalStorageImage {
                openInBrowserButton
            }
        }
    }

    private var webSourceView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "safari.fill")
                    .foregroundColor(.appPrimary)
                Text(displayDomain)
                    .font(.appSubheadlineMedium)
                    .foregroundColor(.appText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(14)
            .background(Color.appSurface)
            .cornerRadius(AppConstants.cardCornerRadius)

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
                Text("Open")
                    .font(.appSubheadlineSemiBold)
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
