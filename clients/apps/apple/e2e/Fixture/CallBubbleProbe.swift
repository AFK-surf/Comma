import CommaCore
import SwiftUI

/// Exercises the production call window above app presentations, without a backend or audio session.
struct CallBubbleProbe: View {
    @State private var call: CallController
    @State private var showSheet = false
    @State private var showCover = false
    @State private var taps = 0

    init(store: CommaStore) {
        let call = CallController(store: store)
        call.previewFloatingCall()
        _call = State(initialValue: call)
    }

    var body: some View {
        VStack(spacing: 24) {
            Button("Underlying action") { taps += 1 }.accessibilityIdentifier("underlyingAction")
            Text("\(taps)").accessibilityIdentifier("underlyingTaps")
            Button("Open sheet") { showSheet = true }.accessibilityIdentifier("openCallProbeSheet")
            Button("Open cover") { showCover = true }.accessibilityIdentifier("openCallProbeCover")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CommaTheme.bgPrimary)
        .background { CallWindowHost(call: call).frame(width: 0, height: 0) }
        .sheet(isPresented: $showSheet) {
            Button("Close sheet") { showSheet = false }.accessibilityIdentifier("closeCallProbeSheet")
        }
        .fullScreenCover(isPresented: $showCover) {
            Button("Close cover") { showCover = false }.accessibilityIdentifier("closeCallProbeCover")
        }
    }
}
