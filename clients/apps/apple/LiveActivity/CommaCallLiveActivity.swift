import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The voice call outside the app: its duration and an End button, on the Lock Screen and in the Dynamic Island.
struct CommaCallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            CallActivityRow(state: context.state)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Beside the camera only, with nothing below it: the island stays one short capsule.
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    CallActivityIdentity(state: context.state, size: .island)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 8) {
                        CallActivityMute(state: context.state, side: CallActivitySize.island.side)
                        CallActivityEnd(state: context.state, side: CallActivitySize.island.side)
                    }
                }
            } compactLeading: {
                Image(systemName: "phone.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(CommaTheme.successPrimary)
            } compactTrailing: {
                CallActivityStatus(state: context.state, compact: true)
                    .font(.footnote.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "phone.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(CommaTheme.successPrimary)
            }
            .keylineTint(CommaTheme.successPrimary)

        }
    }
}

/// The avatar and the End button share one size; the text beside the avatar scales with it.
private enum CallActivitySize {
    case lockScreen, island

    var side: CGFloat { self == .island ? 46 : 52 }
    var name: Font { self == .island ? .subheadline.weight(.semibold) : .title3.weight(.semibold) }
    var status: Font { self == .island ? .subheadline : .title3 }
}

/// One row, like the system call banner without its second row of controls.
private struct CallActivityRow: View {
    let state: CallActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            CallActivityIdentity(state: state, size: .lockScreen)
            Spacer(minLength: 8)
            CallActivityEnd(state: state, side: CallActivitySize.lockScreen.side)
        }
    }
}

/// The Comma avatar, then the name over the call's duration or status.
private struct CallActivityIdentity: View {
    let state: CallActivityAttributes.ContentState
    let size: CallActivitySize

    var body: some View {
        HStack(spacing: size == .island ? 8 : 12) {
            CallActivityMark(size: size.side)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Comma").font(size.name).foregroundStyle(.white)
                CallActivityStatus(state: state).font(size.status).foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

private struct CallActivityMark: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.14))
            CommaMark(size: size * 0.5).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// The running duration once the agent has spoken; otherwise what is happening.
private struct CallActivityStatus: View {
    let state: CallActivityAttributes.ContentState
    var compact = false

    var body: some View {
        if state.phase == .connected, let connectedAt = state.connectedAt {
            Text(timerInterval: connectedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(compact ? .trailing : .leading)
        } else if compact {
            Text(verbatim: "…")
        } else {
            switch state.phase {
            case .calling: Text("Calling…")
            case .ending: Text("Ending…")
            case .failed: state.connectedAt == nil ? Text("Call not connected") : Text("Call interrupted")
            case .ended, .connected:
                if let start = state.connectedAt, let end = state.endedAt {
                    Text("\(CallDuration.format(end.timeIntervalSince(start))) · Call ended")
                } else {
                    Text("Call ended")
                }
            }
        }
    }
}

private struct CallActivityMute: View {
    let state: CallActivityAttributes.ContentState
    let side: CGFloat

    var body: some View {
        if state.phase == .calling || state.phase == .connected {
            Toggle(isOn: state.muted, intent: ToggleCallMuteIntent()) {
                Text("Mute")
            }
            .toggleStyle(CallActivityMuteStyle(side: side))
        }
    }
}

/// Draw from the Toggle's state so its optimistic feedback does not wait for ActivityKit.
private struct CallActivityMuteStyle: ToggleStyle {
    let side: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: side * 0.42, weight: .medium))
                .contentTransition(.identity)
                .foregroundStyle(configuration.isOn ? Color.black : .white)
                .frame(width: side, height: side)
                .background(Circle().fill(configuration.isOn ? Color.white : .white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(configuration.isOn ? Text("Unmute") : Text("Mute"))
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}

/// Ends the call through `EndCallIntent`, which runs in the app. Gone once the call has ended.
private struct CallActivityEnd: View {
    let state: CallActivityAttributes.ContentState
    let side: CGFloat

    var body: some View {
        if state.phase == .calling || state.phase == .connected {
            Button(intent: EndCallIntent()) {
                Image(systemName: "phone.down.fill").font(.system(size: side * 0.42, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: side, height: side)
                    .background(Circle().fill(Color(.systemRed)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End call")
        }
    }
}
