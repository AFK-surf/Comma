import CommaCore
import SwiftUI

struct WatchCallView: View {
    @Bindable var call: WatchCallController

    var body: some View {
        GeometryReader { geometry in
            callContent(height: geometry.size.height)
                .overlay(alignment: .bottom) {
                    controls
                        .disabled(call.phase == .ending)
                        .padding(.bottom, 4)
                }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .interactiveDismissDisabled(call.phase.isLive)
    }

    @ViewBuilder
    private func callContent(height: CGFloat) -> some View {
        if #available(watchOS 26.0, *) {
            scrollContent(height: height)
                .scrollEdgeEffectHidden(for: .bottom)
        } else {
            scrollContent(height: height)
        }
    }

    private func scrollContent(height: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 4) {
                Spacer(minLength: 0)
                CallAvatar(level: call.agentLevel, size: min(64, max(28, (height - 124) / 1.5)))
                Text("Comma").font(.headline)
                Group {
                    if call.phase == .connected, let start = call.connectedAt {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false).monospacedDigit()
                    } else {
                        Text(status)
                    }
                }
                .font(.footnote)
                .foregroundStyle(CommaTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("callStatus")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: max(0, height - 72))
            // Scrollable clearance, not a footer background or a smaller scroll viewport.
            .padding(.bottom, 72)
        }
        .scrollIndicators(.hidden)
    }

    private var controls: some View {
        ZStack {
            // The primary action stays on the screen center, independent of the leading button.
            if call.phase.isLive {
                control(symbol: "phone.down.fill", label: "End call", size: 60,
                        destructive: true, identifier: "endCall") { call.hangUp() }
                control(symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                        label: call.muted ? "Unmute" : "Mute", size: 40, active: call.muted,
                        identifier: "muteCall") { call.toggleMute() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                control(symbol: "phone.fill", label: "Call again", size: 60, identifier: "retryCall") {
                    Task { await call.start() }
                }
                control(symbol: "xmark", label: "Done", size: 40, identifier: "dismissCall") {
                    call.presented = false
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
    }

    private func control(symbol: String, label: LocalizedStringKey, size: CGFloat, active: Bool = false,
                         destructive: Bool = false, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CallSymbol(symbol, size: size == 60 ? 24 : 18)
                .foregroundStyle(destructive ? .white : active ? CommaTheme.bgPrimary : CommaTheme.textPrimary)
                .frame(width: size, height: size)
                .commaGlass(in: Circle(), interactive: true,
                            tint: destructive ? CommaTheme.errorPrimary : active ? CommaTheme.textPrimary : nil)
                .frame(width: max(44, size), height: max(44, size))
                .contentShape(Circle())
        }
        .buttonStyle(GlassButtonStyle(scale: 0.92))
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var status: LocalizedStringKey {
        if call.microphoneDenied { return "Allow microphone access in Settings, then try again." }
        switch call.phase {
        case .ending: return "Ending…"
        case .ended: return "Call ended"
        case .failed:
            switch call.result {
            case .busy, .unavailable: return "Call not connected"
            case .disabled: return "Voice calls are disabled for this workspace."
            case .credentialsExpired: return "Sign in again to call."
            default: return "Call interrupted"
            }
        default: return "Calling…"
        }
    }
}
