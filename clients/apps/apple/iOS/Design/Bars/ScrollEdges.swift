import SwiftUI

// MARK: - Scroll edges

extension View {
    @ViewBuilder func pinnedTopBar<Bar: View>(@ViewBuilder bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .top, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self.safeAreaInset(edge: .top, spacing: 0, content: bar)
        }
    }

    /// Content scrolls under a transparent top that blurs it progressively, like the desktop
    /// `ScrollArea edgeEffect="blur"`: Home, the transcript and every titled page. iOS 26 provides the soft
    /// scroll edge. Earlier systems get a matching material that fades out below the bar where the bar is
    /// transparent (Home, the transcript); without `overlaysMaterial`, a page's bar draws its own background.
    @ViewBuilder func progressiveTopEdge(overlaysMaterial: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else if overlaysMaterial {
            self.overlay(alignment: .top) {
                GeometryReader { geometry in
                    Rectangle().fill(.ultraThinMaterial)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                     .init(color: .black, location: 0.45),
                                                     .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: geometry.safeAreaInsets.top + 28)
                        .offset(y: -geometry.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}
