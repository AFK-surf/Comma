import SwiftUI

/// The live camera in the attachment card: Back, the shutter, and More, which grows Flash and Flip
/// above itself and turns into Close. A capture attaches the photo and closes the panel.
struct CameraPanel: View {
    let back: () -> Void
    let attach: ([AttachmentImage]) -> Void
    @State private var camera = CameraModel()
    @State private var optionsOpen = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            preview
            PanelControls {
                PanelIconButton(icon: "icon-back", label: "Back", action: back)
            } center: {
                shutter
            } trailing: {
                options
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        // Controls on the live image use the dark glass and white glyphs.
        .environment(\.colorScheme, .dark)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder private var preview: some View {
        switch camera.state {
        case .starting, .running:
            ZStack {
                if let session = camera.session { CameraPreview(session: session, attached: camera.run) }
                // Covers the preview until the first frames arrive, then fades away.
                Color(white: 0.12)
                    .opacity(camera.state == .running ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: camera.state)
            }
        case .denied:
            notice("Allow camera access in Settings to take a photo.", settings: true)
        case .unavailable:
            notice("The camera isn’t available on this device.", settings: false)
        }
    }

    private var shutter: some View {
        Button {
            Task { if let image = await camera.capture() { attach([image]) } }
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 3)
                Circle().fill(.white).padding(7)
            }
            .frame(width: 66, height: 66)
            .contentShape(Circle())
        }
        .buttonStyle(TactileButtonStyle(scale: 0.9))
        .disabled(camera.state != .running || camera.capturing)
        .opacity(camera.state == .running ? 1 : 0.4)
        .sensoryFeedback(.impact(weight: .medium), trigger: camera.shots)
        .accessibilityLabel("Take photo")
    }

    /// More opens a column above itself, nearest option first, and becomes the button that folds it.
    private var options: some View {
        VStack(spacing: 16) {
            if optionsOpen {
                PanelIconButton(icon: camera.flashOn ? "icon-flash" : "icon-flash-off",
                                label: camera.flashOn ? "Flash on" : "Flash off", action: camera.toggleFlash)
                    .transition(optionTransition)
                PanelIconButton(icon: "icon-flip-camera", label: "Switch camera") { Task { await camera.flip() } }
                    .transition(optionTransition)
            }
            PanelIconButton(icon: optionsOpen ? "icon-close" : "icon-more",
                            label: optionsOpen ? "Hide camera options" : "Camera options") {
                // A tap carries no momentum, so the column settles without a bounce.
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 1)) {
                    optionsOpen.toggle()
                }
            }
        }
        .disabled(camera.state != .running)
    }

    private var optionTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.5, anchor: .bottom).combined(with: .opacity)
    }

    private func notice(_ text: LocalizedStringKey, settings: Bool) -> some View {
        VStack(spacing: 14) {
            Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            if settings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }.buttonStyle(PanelCapsuleStyle())
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.12))
    }
}
