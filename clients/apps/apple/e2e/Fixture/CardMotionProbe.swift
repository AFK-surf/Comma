import SwiftUI

/// Measures viewport relayouts while the real card host opens and closes over a scrolling transcript.
struct CardMotionProbe: View {
    @State private var docked = false
    @State private var layouts = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var draft = "Keep this draft"
    private var transcript: some View {
        NavigationStack {
            ScrollView {
                VStack {
                    ForEach(0..<40) { index in
                        Text("History message \(index)").frame(maxWidth: .infinity).frame(height: 60)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .bottom) {
                TextField("Message", text: $draft).padding().accessibilityIdentifier("motionDraft")
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in layouts += 1; viewportHeight = height }
        }
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AppCardHost(bottomInset: docked ? 66 : 0, rounded: docked) { transcript }
                .ignoresSafeArea(.container, edges: .vertical)
        }
        .overlay(alignment: .top) {
            HStack {
                Text("\(layouts)").accessibilityIdentifier("cardViewportLayouts")
                Text("\(viewportHeight)").accessibilityIdentifier("cardViewportHeight")
                Button(docked ? "Close task" : "Open task") { docked.toggle() }
                    .accessibilityIdentifier("toggleMotionTask")
            }
        }
    }
}
