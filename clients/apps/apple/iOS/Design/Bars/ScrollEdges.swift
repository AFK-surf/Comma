import SwiftUI

// MARK: - Scroll edges

extension View {
    /// A bar floating over scrolling content, which blurs progressively from just above the bar to the
    /// screen edge. The system soft edge mostly fades to the background and leaves text readable.
    /// `wash` is the colour behind the content, so the blurred edge settles into it instead of greying.
    /// Without `isPresented` the bar and its blur give their space back to the content.
    func floatingBottomBar<Bar: View>(wash: Color = CommaTheme.bgPrimary, isPresented: Bool = true,
                                      @ViewBuilder _ bar: () -> Bar) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if isPresented {
                // Full width, so the blur reaches both screen edges whatever width the bar keeps.
                bar().frame(maxWidth: .infinity).background {
                    ProgressiveBlur(wash: wash)
                        .padding(.top, -24)
                        .ignoresSafeArea(.container, edges: [.bottom, .horizontal])
                }
                // Under a keyboard, its transparent top corners show what lies behind it: the blur's settled tone
                // (about 245) carries on there instead of the page's white.
                .background(alignment: .bottom) {
                    CommaTheme.bgWindow.frame(height: 0)
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                        .ignoresSafeArea(.container, edges: .horizontal)
                }
            }
        }
    }

    /// The foot of a tab's pages, under the system tab bar: a blur that builds from just above the bar (or above
    /// `accessory`, such as Home's status switcher, which sits just above the bar) to the screen edge, as under the
    /// custom bar before. It lies over the tab's navigation stack, so it covers every page pushed in it, and the
    /// keyboard leaves it where it is.
    func tabBottom<Accessory: View>(wash: Color, @ViewBuilder accessory: () -> Accessory) -> some View {
        overlay(alignment: .bottom) {
            accessory()
                .frame(maxWidth: .infinity)
                .background {
                    ProgressiveBlur(wash: wash)
                        .padding(.top, -24)
                        .ignoresSafeArea(.container, edges: [.bottom, .horizontal])
                }
                .ignoresSafeArea(.keyboard)
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

/// A blur that strengthens toward the bottom edge. Two thin materials stack, the second masked in lower, so
/// the blur builds up instead of a single flat layer starting at one line. Blurred bubbles and text average to
/// grey, so a wash of the background colour keeps the edge light. Each layer costs a backdrop pass on every
/// scrolled frame: the third layer this used to have moved the band by at most 1.3 levels per channel on
/// average, while a single layer would move it by up to 3.6 in dark mode.
private struct ProgressiveBlur: View {
    let wash: Color
    private static let starts: [CGFloat] = [0, 0.3]

    var body: some View {
        ZStack {
            ForEach(Self.starts, id: \.self) { start in
                Rectangle().fill(.ultraThinMaterial)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: start),
                                                 .init(color: .black, location: start + 0.4)],
                                         startPoint: .top, endPoint: .bottom))
            }
            LinearGradient(stops: [.init(color: wash.opacity(0), location: 0.1),
                                   .init(color: wash.opacity(0.75), location: 0.7)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
