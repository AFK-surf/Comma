import SwiftUI
import CommaCore

extension ContentBlock {
    var conversationID: String? { fields["conversation_id"]?.string }
    var title: String? { fields["title"]?.string }
    var displayName: String? { fields["display_name"]?.string ?? fields["filename"]?.string ?? fields["name"]?.string }
    var summary: String? { fields["summary"]?.string }
}

struct TaskStatusLabel: View {
    let status: String
    var body: some View {
        let bucket = TaskBucket(status: status)
        HStack(spacing: 6) {
            TaskStatusIcon(bucket: bucket, size: 14)
            Text(bucket.label).font(.system(size: 13, weight: .medium)).foregroundStyle(CommaTheme.textTertiary)
        }
    }
}

/// Compact task row for the Watch list.
struct TaskRow: View {
    let task: Conversation
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TaskStatusIcon(bucket: task.bucket, size: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                Text(task.bucket.label).font(.system(size: 12)).foregroundStyle(CommaTheme.textQuaternary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A failure that stays where it happened, next to what it is about, as the desktop's inline item card: a part of a
/// page that could not load, a field that could not save, a device setting that needs attention. The glyph carries
/// the error colour and the words stay in the text colour, as on the app's toast, which reports passing failures.
struct InlineError: View {
    let message: String
    var retry: (() -> Void)?
    var dismiss: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility text sizes the buttons move under the message, which keeps the full width.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CentralIcon("central-circle-x-fill", size: 16, relativeTo: .subheadline)
                    .foregroundStyle(CommaTheme.errorPrimary)
                    // Centred on the first line's capitals instead of standing on its baseline.
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + $0.height / 3 }
                    .accessibilityLabel("Error")
                Text(message).font(.subheadline).foregroundStyle(CommaTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if retry != nil || dismiss != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let retry {
                        Button("Retry", action: retry).font(.subheadline.weight(.semibold))
                            .foregroundStyle(CommaTheme.brandSolid)
                    }
                    if let dismiss {
                        Button(action: dismiss) {
                            CentralIcon("icon-cross-small", size: 24, relativeTo: .subheadline)
                                .foregroundStyle(CommaTheme.textTertiary)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + $0.height / 5 }
                                // A finger-sized target without making the card taller.
                                .contentShape(Rectangle().inset(by: -10))
                        }
                        .accessibilityLabel("Dismiss")
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(CommaTheme.bgTertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

extension View {
    @ViewBuilder func selectableMessageText() -> some View {
        #if os(iOS)
        self.textSelection(.enabled)
        #else
        self
        #endif
    }
}
