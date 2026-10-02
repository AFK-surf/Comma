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

struct InlineError: View {
    let message: String
    var retry: (() -> Void)?
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Retry", action: retry).font(.system(size: 13, weight: .semibold))
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .foregroundStyle(CommaTheme.errorPrimary)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(CommaTheme.errorPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
