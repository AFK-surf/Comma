import SwiftUI

/// Move and Scale, as iOS offers for a contact photo: the photo under a circle, dragged and pinched until the
/// circle holds what the member wants. A pinch zooms about the fingers, a double tap zooms in on what it touches
/// or back out, and a flick carries on as a scroll view's would. The photo always covers the circle; let go past
/// an edge or past the zoom's limits and it settles back.
struct AvatarCropView: View {
    let image: UIImage
    /// The chosen square, in the image's points.
    let choose: (CGRect) -> Void
    let cancel: () -> Void
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// The gestures in progress. Plain state rather than gesture state, so a release animates from where the
    /// fingers left the photo instead of first jumping back.
    @State private var pinch: CGFloat = 1
    /// Where the pinch started, from the middle of the screen, which stays under the fingers as it zooms.
    @State private var anchor: CGSize = .zero
    @State private var drag: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxZoom: CGFloat = 5
    /// How far a double tap zooms in.
    private static let tapZoom: CGFloat = 2.5

    var body: some View {
        GeometryReader { proxy in
            let crop = Crop(image: image.size, area: proxy.size)
            let live = liveZoom
            let shown = crop.shown(zoom: live)
            let moved = crop.bounded(CGSize(width: anchor.width + (offset.width - anchor.width) * pinch + drag.width,
                                            height: anchor.height + (offset.height - anchor.height) * pinch
                                                + drag.height), zoom: live, soft: true)
            ZStack {
                Image(uiImage: image).resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(moved)
                    .accessibilityHidden(true)
                // The world outside the circle dims, the way the system's Move and Scale shows it.
                Rectangle().fill(.black.opacity(0.55))
                    .reverseMask { Circle().frame(width: crop.circle, height: crop.circle) }
                    .allowsHitTesting(false)
                Circle().stroke(.white.opacity(0.5), lineWidth: 1)
                    .frame(width: crop.circle, height: crop.circle)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(SimultaneousGesture(moving(crop), scaling(crop, area: proxy.size)))
            .simultaneousGesture(zoomingByTap(crop, area: proxy.size))
            .accessibilityElement()
            .accessibilityLabel(Text("Photo"))
            .accessibilityZoomAction { action in
                setZoom(zoom * (action.direction == .zoomIn ? 1.5 : 1 / 1.5), about: .zero, crop: crop)
            }
            .overlay(alignment: .bottom) { controls(crop) }
        }
        .background(.black)
        .overlay(alignment: .top) {
            Text("Move and Scale").font(.body.weight(.medium)).foregroundStyle(.white).padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
        }
        .statusBarHidden()
        .environment(\.colorScheme, .dark)
    }

    private func controls(_ crop: Crop) -> some View {
        HStack {
            Button("Cancel", action: cancel)
            Spacer()
            Button("Choose") { choose(crop.square(zoom: zoom, offset: offset)) }.fontWeight(.semibold)
        }
        .font(.body).foregroundStyle(.white)
        .padding(.horizontal, 24).padding(.bottom, 16)
        .buttonStyle(TactileButtonStyle())
    }

    /// The zoom under the fingers, resisting past its limits.
    private var liveZoom: CGFloat {
        let raw = zoom * pinch
        if raw < 1 { return 1 - (1 - raw) * 0.3 }
        if raw > Self.maxZoom { return Self.maxZoom + (raw - Self.maxZoom) * 0.3 }
        return raw
    }

    private var settle: Animation { CommaMotion.settle(reduced: reduceMotion) }

    private func moving(_ crop: Crop) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag = $0.translation }
            .onEnded { value in
                // In the photo's own scale while a pinch carries on, so the photo stays under the fingers; a
                // flick carries it on where a scroll view's deceleration would.
                let moved = CGSize(width: offset.width + (value.translation.width + Self.carry(value.velocity.width)) / pinch,
                                   height: offset.height + (value.translation.height + Self.carry(value.velocity.height)) / pinch)
                withAnimation(settle) {
                    drag = .zero
                    offset = crop.bounded(moved, zoom: zoom, soft: false)
                }
            }
    }

    private func scaling(_ crop: Crop, area: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinch == 1 { anchor = Self.fromMiddle(value.startLocation, in: area) }
                pinch = value.magnification
            }
            .onEnded { value in setZoom(zoom * value.magnification, about: anchor, crop: crop) }
    }

    /// Zooms in on the point tapped, or back out to the whole photo when already zoomed.
    private func zoomingByTap(_ crop: Crop, area: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in
            let point = Self.fromMiddle(value.location, in: area)
            setZoom(zoom > 1.01 ? 1 : Self.tapZoom, about: point, crop: crop)
        }
    }

    /// Zooms about `point`, from the middle of the screen, keeping what is there in place, within the zoom's
    /// limits.
    private func setZoom(_ next: CGFloat, about point: CGSize, crop: Crop) {
        let bounded = min(Self.maxZoom, max(1, next))
        let ratio = bounded / zoom
        let scaled = CGSize(width: point.width + (offset.width - point.width) * ratio,
                            height: point.height + (offset.height - point.height) * ratio)
        withAnimation(settle) {
            pinch = 1
            anchor = .zero
            zoom = bounded
            offset = crop.bounded(scaled, zoom: bounded, soft: false)
        }
    }

    private static func fromMiddle(_ point: CGPoint, in area: CGSize) -> CGSize {
        CGSize(width: point.x - area.width / 2, height: point.y - area.height / 2)
    }

    /// How much further a flick at `velocity` points per second carries, with UIScrollView's fast deceleration.
    private static func carry(_ velocity: CGFloat) -> CGFloat { velocity / 1000 * 0.99 / (1 - 0.99) }
}

/// The geometry of Move and Scale: a circle 16 points in from the narrower side, and the photo filling it at
/// zoom 1.
private struct Crop {
    let image: CGSize
    let circle: CGFloat
    private let fill: CGFloat

    init(image: CGSize, area: CGSize) {
        self.image = image
        circle = max(1, min(area.width, area.height) - 32)
        fill = image.width > 0 && image.height > 0 ? max(circle / image.width, circle / image.height) : 1
    }

    func shown(zoom: CGFloat) -> CGSize { CGSize(width: image.width * fill * zoom, height: image.height * fill * zoom) }

    /// `offset` kept where the photo still covers the circle; `soft` lets it stretch past, resisting.
    func bounded(_ offset: CGSize, zoom: CGFloat, soft: Bool) -> CGSize {
        let size = shown(zoom: zoom)
        return CGSize(width: limit(offset.width, (size.width - circle) / 2, soft: soft),
                      height: limit(offset.height, (size.height - circle) / 2, soft: soft))
    }

    /// The circle's square in the image's points.
    func square(zoom: CGFloat, offset: CGSize) -> CGRect {
        let scale = fill * zoom
        let size = shown(zoom: zoom)
        return CGRect(x: (size.width / 2 - offset.width - circle / 2) / scale,
                      y: (size.height / 2 - offset.height - circle / 2) / scale,
                      width: circle / scale, height: circle / scale)
    }

    private func limit(_ value: CGFloat, _ reach: CGFloat, soft: Bool) -> CGFloat {
        let reach = max(0, reach)
        guard abs(value) > reach else { return value }
        let past = abs(value) - reach
        let kept = soft ? past * circle * 0.55 / (circle + 0.55 * past) : 0
        return (reach + kept) * (value < 0 ? -1 : 1)
    }
}

private extension View {
    /// Shows this view everywhere except where `shape` draws.
    func reverseMask<Shape: View>(@ViewBuilder _ shape: () -> Shape) -> some View {
        mask { Rectangle().overlay { shape().blendMode(.destinationOut) }.compositingGroup() }
    }
}
