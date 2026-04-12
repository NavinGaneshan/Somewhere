import SwiftUI

struct DealRowView: View {
    let deal: Deal
    let onVote: (String, Bool) -> Void
    @State private var hasVoted = false

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
                                Circle().fill(.activeGreen).frame(width: 5, height: 5)
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
                // Time range
                Label(deal.formattedTimeRange, systemImage: "clock")
                    .font(.appCaption.weight(.medium))
                    .foregroundColor(.appText)

                Text("·")
                    .foregroundColor(.appDivider)

                // Days
                Text(deal.formattedDays)
                    .font(.appCaption.weight(.medium))
                    .foregroundColor(.appText)

                Spacer()

                // Source badge
                sourceLabel
            }

            // Votes row
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
