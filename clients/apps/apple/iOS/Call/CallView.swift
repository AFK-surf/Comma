import AVKit
import CommaCore
import SwiftUI
import UIKit

/// The call's status line: what is happening, the running duration, or how it ended.
struct CallStatus: View {
    let call: CallController

    var body: some View {
        if let connectedAt = call.connectedAt, call.phase == .connected, !call.endingRequested {
            Text(timerInterval: connectedAt...Date.distantFuture, countsDown: false).monospacedDigit()
        } else {
            Text(label)
        }
    }

    private var label: LocalizedStringKey {
        switch call.phase {
        case .ended, .failed:
            switch call.notice {
            case .microphone?: return "Allow microphone access in Settings, then try again."
            case .output?: return "Could not change audio output."
            case nil: break
            }
            guard call.phase == .failed else { return Self.ended(call) }
            switch call.result {
            case .busy?, .unavailable?: return "Call not connected"
            case .disabled?: return "Voice calls are disabled for this workspace."
            case .interrupted?: return "Call interrupted"
            default: return "Call failed"
            }
        case .ending: return "Ending…"
        default: return call.endingRequested ? "Ending…" : "Calling…"
        }
    }

    private static func ended(_ call: CallController) -> LocalizedStringKey {
        guard let start = call.connectedAt, let end = call.endedAt else { return "Call ended" }
        return "\(CallDuration.format(end.timeIntervalSince(start))) · Call ended"
    }
}

// MARK: Page

/// Laid out at the window's full size by `CallSurfaceController`, which passes the safe area in.
struct CallPage: View {
    let call: CallController
    let insets: EdgeInsets

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { call.expanded = false } label: {
                    CallSymbol("arrow.down.right.and.arrow.up.left", size: 20)
                        .foregroundStyle(CommaTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel("Minimize call")
                .accessibilityIdentifier("minimizeCall")
                Spacer()
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 24)
            CallAvatar(level: call.agentLevel, size: 112)
            Text(verbatim: "Comma")
                .font(.title3.weight(.semibold))
                .foregroundStyle(CommaTheme.textPrimary)
                .padding(.top, 28)
            CallStatus(call: call)
                .font(.body)
                .foregroundStyle(CommaTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 32)
                .accessibilityIdentifier("callStatus")
            Spacer(minLength: 24)
            HStack(alignment: .top, spacing: 0) {
                CallMuteButton(call: call, style: .page).frame(maxWidth: .infinity)
                CallEndButton(call: call, style: .page).frame(maxWidth: .infinity)
                CallOutputButton(call: call, style: .page).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .padding(insets)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CommaTheme.bgPrimary)
        .accessibilityAction(.escape) { call.expanded = false }
        .onTapGesture { if !call.busy { call.dismiss() } }
    }
}

// MARK: Bubble

/// The bubble's avatar over the call's duration. `CallSurfaceController` draws its background and takes its taps.
struct CallBubbleFace: View {
    let call: CallController

    var body: some View {
        VStack(spacing: 6) {
            CallAvatarSmall(level: call.agentLevel)
            if let start = call.connectedAt {
                Text(timerInterval: start...(call.endedAt ?? Date.distantFuture), countsDown: false)
                    .monospacedDigit()
            } else {
                Text(verbatim: "0:00")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .multilineTextAlignment(.center)
        .foregroundStyle(CommaTheme.textPrimary)
        .padding(.horizontal, 4)
        .frame(width: CallSurfaceController.bubbleSize.width, height: CallSurfaceController.bubbleSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Expand call")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { call.expanded = true }
        .accessibilityIdentifier("callBubble")
    }
}

private struct CallAvatarSmall: View {
    let level: Double
    var body: some View {
        ZStack {
            CallRipples(level: level, size: 34, spread: 0.6)
            Circle().fill(CommaTheme.bgTertiary).frame(width: 34, height: 34)
            CommaMark(size: 18).foregroundStyle(CommaTheme.textPrimary)
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

// MARK: Controls

private enum CallControlStyle { case page, card }

private enum CallControlSize { static let page: CGFloat = 80 }

/// A round glass control: an 80 pt circle with its label under it on the page, a 40 pt circle on the card.
/// End is red glass; a control that is on (muted, on the speaker) is dark glass.
private struct CallControl<Glyph: View>: View {
    let style: CallControlStyle
    let label: LocalizedStringKey
    let active: Bool
    let destructive: Bool
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        let side: CGFloat = style == .page ? CallControlSize.page : 40
        VStack(spacing: 8) {
            glyph()
                .foregroundStyle(foreground)
                .frame(width: side, height: side)
                .commaGlass(in: Circle(), interactive: true, tint: tint)
                .contentShape(Circle())
            if style == .page {
                Text(label).font(.footnote).foregroundStyle(CommaTheme.textSecondary).lineLimit(1)
            }
        }
    }

    private var tint: Color? {
        if destructive { return Color(.systemRed) }
        return active ? CommaTheme.textPrimary : nil
    }

    private var foreground: Color {
        if destructive { return .white }
        return active ? CommaTheme.bgPrimary : CommaTheme.textPrimary
    }
}

private struct CallMuteButton: View {
    let call: CallController
    let style: CallControlStyle

    var body: some View {
        Button { Task { await call.setMuted(!call.muted) } } label: {
            CallControl(style: style, label: "Mute", active: call.muted, destructive: false) {
                CallSymbol(call.muted ? "mic.slash.fill" : "mic.fill", size: style == .page ? 30 : 17)
            }
        }
        .buttonStyle(GlassButtonStyle(scale: 0.92))
        .disabled(!call.busy)
        .accessibilityLabel(call.muted ? Text("Unmute") : Text("Mute"))
        .accessibilityIdentifier("muteCall")
    }
}

private struct CallEndButton: View {
    let call: CallController
    let style: CallControlStyle

    var body: some View {
        Button { call.hangUp() } label: {
            CallControl(style: style, label: "End", active: false, destructive: true) {
                CallSymbol("phone.down.fill", size: style == .page ? 32 : 17)
            }
        }
        .buttonStyle(GlassButtonStyle(scale: 0.92))
        .disabled(!call.busy)
        .opacity(call.busy ? 1 : 0.4)
        .accessibilityLabel("End call")
        .accessibilityIdentifier("endCall")
    }
}

/// Speaker on or off. With a headset or Bluetooth device the same button opens the system's route picker,
/// which lists every output the call can use.
private struct CallOutputButton: View {
    let call: CallController
    let style: CallControlStyle

    var body: some View {
        let control = CallControl(style: style, label: label, active: call.output == .speaker, destructive: false) {
            CallSymbol(glyph, size: style == .page ? 30 : 17)
        }
        Group {
            if call.externalOutputs {
                control.overlay(alignment: .top) {
                    RoutePicker().frame(width: style == .page ? CallControlSize.page : 40, height: style == .page ? CallControlSize.page : 40)
                }
            } else {
                Button { call.setSpeaker(call.output != .speaker) } label: { control }
                    .buttonStyle(GlassButtonStyle(scale: 0.92))
            }
        }
        .disabled(!call.busy)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(call.output == .speaker ? .isSelected : [])
        .accessibilityIdentifier("callOutput")
    }

    private var label: LocalizedStringKey {
        switch call.output {
        case .bluetooth: "Bluetooth"
        case .headphones: "Headphones"
        case .phone: call.externalOutputs ? "iPhone" : "Speaker"
        default: "Speaker"
        }
    }

    private var glyph: String {
        switch call.output {
        case .bluetooth: "airpods"
        case .headphones: "headphones"
        case .phone: call.externalOutputs ? "iphone" : "speaker.wave.2.fill"
        default: "speaker.wave.2.fill"
        }
    }
}

/// The system route picker, invisible over the output button so its own glyph does not show.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.backgroundColor = .clear
        return picker
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

// MARK: Chat bar

/// The router chat's Call button: starts a call, or opens the one in progress. Filled while a call is live.
struct CallToolbarButton: View {
    let call: CallController

    var body: some View {
        Button { Task { await call.start() } } label: {
            CallSymbol(call.busy ? "phone.fill" : "phone", size: 17)
                .foregroundStyle(call.busy ? .white : CommaTheme.textPrimary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(call.busy ? CommaTheme.brandSolid : .clear))
        }
        .accessibilityLabel("Call")
        .accessibilityValue(call.busy ? Text("Call in progress") : Text(verbatim: ""))
        .accessibilityIdentifier("startCall")
    }
}
