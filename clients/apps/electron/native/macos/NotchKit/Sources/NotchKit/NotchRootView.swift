import SwiftUI

@MainActor
struct NotchRootView: View {
    @State private var model: NotchRuntimeModel
    /// One-shot "absorb" scale pulse driven by `model.pulseToken` — the notch grows
    /// quickly to absorb (e.g. an App Shot warping in), then settles back.
    @State private var pulseScale: CGFloat = 1.0

    init(model: NotchRuntimeModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NotchKitView(
            model: model.packageModel,
            onCompactLeadingSizeChange: model.updateCompactLeadingSize,
            onCompactTrailingSizeChange: model.updateCompactTrailingSize,
            onExpandedLeadingSizeChange: model.updateExpandedLeadingSize,
            onExpandedTrailingSizeChange: model.updateExpandedTrailingSize,
            onExpandedContentSizeChange: model.updateExpandedContentSize
        ) {
            model.scene.compactLeadingSlot
        } compactTrailing: {
            model.scene.compactTrailingSlot
        } expandedLeading: {
            model.scene.expandedLeadingSlot
        } expandedTrailing: {
            model.scene.expandedTrailingSlot
        } expandedContent: {
            model.scene.expandedContent
        }
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scaleEffect(pulseScale, anchor: .top)
        .onChange(of: model.pulseToken) { _, _ in
            // Grow fast to absorb, settle back slower — no overshoot.
            withAnimation(.easeOut(duration: 0.12)) { pulseScale = 1.13 }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                withAnimation(.easeInOut(duration: 0.21)) { pulseScale = 1.0 }
            }
        }
    }
}
