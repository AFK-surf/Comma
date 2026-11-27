import SwiftUI
import UIKit

// A device drawn flat round its picture, as the desktop's stage draws it (ScreenDeviceFrame.tsx): an iOS Simulator in its
// case as Xcode has it on the computer (screenCase.ts), once its pictures have come; else a plain body that goes round
// the screen at one thickness, its corners the panel's. An iPhone Duo is drawn in 3D instead (`DuoStageView`).

/// What a listed device says of how it looks (`devices.listScreens`'s `capabilities`): its screen's panels, and the
/// case of each where its computer has Xcode's.
struct DeviceLook: Hashable, Sendable {
    /// A panel of the screen: its size and each corner's radius as a share of its width, top left and round it.
    struct Panel: Hashable, Sendable {
        let width: Double
        let height: Double
        let corners: [Double]
        /// Each corner as CSS's `superellipse(k)`, where its mask says it; none: circles.
        let shapes: [Double]?
    }

    /// A button of the case, where it rests in its panel's frame and the way it goes in (`dx`, `dy`); `front`: on the
    /// case's face (a home button), not behind it.
    struct Button: Hashable, Sendable {
        let name: String
        let rect: CGRect
        let dx: Double
        let dy: Double
        let front: Bool
    }

    /// A panel's case: `key` names its pictures, `screen` is where the picture goes in `frame`.
    struct Case: Hashable, Sendable {
        let key: String
        let width: Double
        let height: Double
        let frame: CGSize
        let screen: CGRect
        /// Each corner's radius, a share of the panel's width (none where its mask says them: `reach`).
        let corners: [Double]
        /// Each corner's radius from its mask, a share of the screen's short side; none where not known.
        let reach: [Double]?
        /// Each corner's `superellipse(k)` from its mask, in the same order; none where not known.
        let shapes: [Double]?
        let buttons: [Button]
    }

    let panels: [Panel]
    let cases: [Case]

    static let none = DeviceLook(panels: [], cases: [])

    /// A corner a panel does not say, as a share of its width (useDeviceScreenSource.ts `DEFAULT_CORNER`).
    static let defaultCorner = 0.035

    init(panels: [Panel], cases: [Case]) { self.panels = panels; self.cases = cases }

    init(_ capabilities: NSDictionary?) {
        guard let capabilities else { self = .none; return }
        panels = capabilities.objects("panels").compactMap { row in
            guard let width = row.double("width"), let height = row.double("height"), width > 0, height > 0 else { return nil }
            let curves = row.objects("curves")
            let corners: [Double] = curves.count == 4
                ? curves.map { $0.double("reach") ?? 0 }
                : ((row["corners"] as? [NSNumber])?.map(\.doubleValue) ?? [])
            return Panel(width: width, height: height, corners: corners,
                         shapes: curves.count == 4 ? curves.map { $0.double("k") ?? 1 } : nil)
        }
        cases = capabilities.objects("chrome").compactMap { row in
            guard let key = row.string("key"), let width = row.double("width"), let height = row.double("height"),
                  let frame = row.object("frame"), let fw = frame.double("width"), let fh = frame.double("height"),
                  let screen = row.object("screen"), let rect = Self.rect(screen), fw > 0, fh > 0 else { return nil }
            let curves = row.objects("curves")
            return Case(
                key: key, width: width, height: height, frame: CGSize(width: fw, height: fh), screen: rect,
                corners: (row["corners"] as? [NSNumber])?.map(\.doubleValue) ?? [],
                reach: curves.count == 4 ? curves.map { $0.double("reach") ?? 0 } : nil,
                shapes: curves.count == 4 ? curves.map { $0.double("k") ?? 1 } : nil,
                buttons: row.objects("buttons").compactMap { button in
                    guard let name = button.string("name"), let rect = Self.rect(button) else { return nil }
                    return Button(name: name, rect: rect, dx: button.double("dx") ?? 0, dy: button.double("dy") ?? 0,
                                  front: button.bool("front"))
                })
        }
    }

    private static func rect(_ row: NSDictionary) -> CGRect? {
        guard let x = row.double("x"), let y = row.double("y"), let width = row.double("width"),
              let height = row.double("height") else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A panel's case as it stands now (screenCase.ts `screenCaseOf`), in its own points, turned as its picture is.
struct DeviceCaseLayout: Equatable {
    let panel: Int
    let key: String
    /// Quarters clockwise its pictures are turned.
    let turn: Int
    let frame: CGSize
    let screen: CGRect
    /// How far in each of the picture's corners is under the case, top left and round it as it stands.
    let corners: [Double]
    /// Each corner's `superellipse(k)`, as `corners`; none: circles.
    let shapes: [Double]?
    let buttons: [DeviceLook.Button]

    /// How much of a panel's corner is cut off the square picture under the case (`CASE_CORNER_SHARE`).
    private static let cornerShare = 0.8

    /// The case of the panel a picture of `ratio` (its width over its height) is of, standing `orientation` degrees
    /// clockwise while that is a way the picture can stand; none where no panel has its shape.
    static func of(_ cases: [DeviceLook.Case], ratio: Double, orientation: Int?) -> DeviceCaseLayout? {
        guard ratio > 0 else { return nil }
        let shape = Self.shape(ratio, 1)
        var best = -1
        var off = 0.01
        for (index, panel) in cases.enumerated() where panel.width > 0 && panel.height > 0 {
            let away = abs(shape - Self.shape(panel.width, panel.height))
            if away < off { off = away; best = index }
        }
        guard best >= 0 else { return nil }
        let panel = cases[best]
        let lying = (panel.width > panel.height) != (ratio > 1)
        let said = ((((orientation ?? 0) / 90) % 4) + 4) % 4
        let turn = (said % 2 == 1) == lying ? said : lying ? 1 : 0
        let fw = panel.frame.width, fh = panel.frame.height
        let rect = { (r: CGRect) in Self.turned(r, fw, fh, turn) }
        let screen = rect(panel.screen)
        let short = Double(min(screen.width, screen.height))
        let corner = { (i: Int) -> Double in
            let at = (i + 4 - turn) % 4
            if let reach = panel.reach { return reach[at] * short }
            return panel.corners.count == 4 ? panel.corners[at] * short * cornerShare : 0
        }
        return DeviceCaseLayout(
            panel: best, key: panel.key, turn: turn,
            frame: turn % 2 == 1 ? CGSize(width: fh, height: fw) : CGSize(width: fw, height: fh),
            screen: screen, corners: (0 ..< 4).map(corner),
            shapes: panel.shapes.map { k in (0 ..< 4).map { k[($0 + 4 - turn) % 4] } },
            buttons: panel.buttons.map { button in
                let (dx, dy) = Self.turnedWay(button.dx, button.dy, turn)
                return DeviceLook.Button(name: button.name, rect: rect(button.rect), dx: dx, dy: dy, front: button.front)
            })
    }

    private static func shape(_ width: Double, _ height: Double) -> Double { min(width, height) / max(width, height) }

    /// The rect `r` of a `w`×`h` frame, the frame turned `turn` quarters clockwise (`turnedCaseRect`).
    static func turned(_ r: CGRect, _ w: CGFloat, _ h: CGFloat, _ turn: Int) -> CGRect {
        switch turn {
        case 1: CGRect(x: h - r.minY - r.height, y: r.minX, width: r.height, height: r.width)
        case 2: CGRect(x: w - r.minX - r.width, y: h - r.minY - r.height, width: r.width, height: r.height)
        case 3: CGRect(x: r.minY, y: w - r.minX - r.width, width: r.height, height: r.width)
        default: r
        }
    }

    private static func turnedWay(_ dx: Double, _ dy: Double, _ turn: Int) -> (Double, Double) {
        switch turn {
        case 1: (-dy, dx)
        case 2: (-dx, -dy)
        case 3: (dy, -dx)
        default: (dx, dy)
        }
    }
}

/// A panel's case pictures turned as it stands: the case with the panel's shape cut out, and each button at rest.
struct DeviceCasePictures {
    let body: UIImage
    let buttons: [String: UIImage]
}

/// The case pictures each computer's devices have, asked once each and kept while the app runs: they are the same
/// whoever asks, and a device has a few panels and four ways to stand.
@MainActor enum DeviceCasePictureStore {
    private static var came: [String: DeviceCasePictures] = [:]
    /// The asks under way: a second ask for the same pictures waits for the first instead of returning without them.
    private static var asking: [String: Task<Void, Never>] = [:]

    static func key(_ scope: WorkspaceSettingsScope, _ device: String, _ layout: DeviceCaseLayout) -> String {
        [String(ObjectIdentifier(scope.store).hashValue), scope.workspace.id, device, layout.key, String(layout.turn)]
            .joined(separator: "\n")
    }

    static func came(_ key: String) -> DeviceCasePictures? { came[key] }

    /// Asks the computer for the panel's pictures turned as it stands (`devices.screenDeviceChrome`), unless they came.
    /// An ask while another for the same pictures is under way waits for that one. A failure may be asked again.
    static func ask(_ scope: WorkspaceSettingsScope, device: String, screen: String, layout: DeviceCaseLayout) async {
        let key = key(scope, device, layout)
        guard came[key] == nil else { return }
        if let under = asking[key] { return await under.value }
        let task = Task { @MainActor in
            defer { asking[key] = nil }
            guard let answer = try? await scope.call("devices.screenDeviceChrome", [
                "device": device, "screen": screen, "panel": layout.panel, "turn": layout.turn,
            ]), let object = answer.object, let body = image(object.string("body")) else { return }
            var buttons: [String: UIImage] = [:]
            for (name, value) in object.object("buttons") ?? [:] {
                if let name = name as? String, let up = image((value as? NSDictionary)?.string("up")) { buttons[name] = up }
            }
            came[key] = DeviceCasePictures(body: body, buttons: buttons)
        }
        asking[key] = task
        await task.value
    }

    private static func image(_ base64: String?) -> UIImage? {
        base64.flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) }
    }
}

/// Where a flat device goes in its stage: the picture's place, and what goes round it.
struct DeviceFrameLayout {
    enum Body {
        /// A plain body `bezel` round the screen.
        case plain(CGRect)
        /// The case's box, its points `scale` of the stage's each.
        case cased(CGRect, scale: CGFloat)
    }

    let picture: CGRect
    /// The picture's corner radii, top left and round it.
    let corners: [CGFloat]
    /// Each corner's `superellipse(k)`, as `corners`; none: circles.
    let shapes: [Double]?
    let body: Body?

    /// The body's thickness round the screen (styles.css `--comma-remote-screen-device-bezel`: `--spacing-md`).
    static let bezel: CGFloat = 8

    /// The device in `size`: in its case where `cased` is given, else in a plain body round its picture, its corners
    /// its closest panel's or, where it says none, the default; a bare stage while it has no shape yet.
    static func of(look: DeviceLook, picture: CGSize, cased: DeviceCaseLayout?, in size: CGSize) -> DeviceFrameLayout {
        guard picture.width > 0, picture.height > 0, size.width > 0, size.height > 0 else {
            return DeviceFrameLayout(picture: CGRect(origin: .zero, size: size), corners: [0, 0, 0, 0], shapes: nil, body: nil)
        }
        if let cased {
            let box = fit(cased.frame, in: size, inset: 0)
            let scale = box.width / cased.frame.width
            let screen = CGRect(x: box.minX + cased.screen.minX * scale, y: box.minY + cased.screen.minY * scale,
                                width: cased.screen.width * scale, height: cased.screen.height * scale)
            return DeviceFrameLayout(picture: screen, corners: cased.corners.map { CGFloat($0) * scale },
                                     shapes: cased.shapes, body: .cased(box, scale: scale))
        }
        let ratio = Double(picture.width / picture.height)
        let panel = look.panels.min { off($0, ratio) < off($1, ratio) }
        let screen = fit(picture, in: size, inset: bezel)
        // A corner's radius is a share of the panel's own width: the picture's height where it lies across the panel.
        let lying = panel.map { ($0.width > $0.height) != (ratio > 1) } ?? false
        let across = lying ? screen.height : screen.width
        let said = panel?.corners.contains(where: { $0 > 0 }) == true
        let shares = said ? panel!.corners : Array(repeating: DeviceLook.defaultCorner, count: 4)
        // (the panel's corners stand as the picture does: a quarter round where it lies across it)
        let turned = lying ? [shares[3], shares[0], shares[1], shares[2]] : shares
        let shapes = (said ? panel?.shapes : nil).map { lying ? [$0[3], $0[0], $0[1], $0[2]] : $0 }
        return DeviceFrameLayout(picture: screen, corners: turned.map { CGFloat($0) * across }, shapes: shapes,
                                 body: .plain(screen.insetBy(dx: -bezel, dy: -bezel)))
    }

    /// How far a panel's shape is from a picture's, either way up (screenDevice.ts `screenDeviceShape`).
    private static func off(_ panel: DeviceLook.Panel, _ ratio: Double) -> Double {
        let long = { (r: Double) in max(r, 1 / r) }
        return abs(log(long(panel.width / panel.height) / long(ratio)))
    }

    /// `content`'s shape at its largest in `size` with `inset` round it, centred.
    private static func fit(_ content: CGSize, in size: CGSize, inset: CGFloat) -> CGRect {
        let room = CGSize(width: max(0, size.width - 2 * inset), height: max(0, size.height - 2 * inset))
        let scale = min(room.width / content.width, room.height / content.height)
        let width = content.width * scale, height = content.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// What goes round a flat device's picture, behind and over it: its plain body, or its case and buttons.
struct DeviceFrameBehind: View {
    let layout: DeviceFrameLayout
    let cased: DeviceCaseLayout?
    let pictures: DeviceCasePictures?

    var body: some View {
        switch layout.body {
        case .plain(let rect)?:
            let outline = DeviceCornersShape(corners: layout.corners.map { $0 + DeviceFrameLayout.bezel }, shapes: layout.shapes)
            outline
                .fill(CommaTheme.deviceBody)
                .overlay { outline.stroke(CommaTheme.borderPrimary, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.08), radius: 8, y: 6)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        case .cased(let box, let scale)?:
            if let cased, let pictures { buttons(cased, pictures, front: false, box: box, scale: scale) }
        case nil:
            EmptyView()
        }
    }

    func buttons(_ cased: DeviceCaseLayout, _ pictures: DeviceCasePictures, front: Bool, box: CGRect, scale: CGFloat) -> some View {
        ForEach(cased.buttons.filter { $0.front == front }, id: \.name) { button in
            if let image = pictures.buttons[button.name] {
                Image(uiImage: image).resizable()
                    .frame(width: button.rect.width * scale, height: button.rect.height * scale)
                    // (at rest: Xcode's normal place, inward from where its rollover shows it)
                    .offset(x: box.minX + (button.rect.minX + button.dx * button.rect.width) * scale,
                            y: box.minY + (button.rect.minY + button.dy * button.rect.height) * scale)
            }
        }
    }
}

/// The case over the picture, its panel's shape cut out of it, and its front buttons (a home button) on it.
struct DeviceFrameOver: View {
    let layout: DeviceFrameLayout
    let cased: DeviceCaseLayout?
    let pictures: DeviceCasePictures?

    var body: some View {
        if case .cased(let box, let scale)? = layout.body, let cased, let pictures {
            Image(uiImage: pictures.body).resizable()
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            DeviceFrameBehind(layout: layout, cased: cased, pictures: pictures)
                .buttons(cased, pictures, front: true, box: box, scale: scale)
        }
    }
}

/// A rect with each corner drawn as CSS's `corner-shape: superellipse(k)` draws it on its radius (top left and round it):
/// the curve `|x|^p + |y|^p = 1`, `p` = 2^k. `k` 1 is a circle, as with no `shapes`.
struct DeviceCornersShape: Shape {
    let corners: [CGFloat]
    let shapes: [Double]?

    func path(in rect: CGRect) -> Path {
        let at = { (i: Int) -> CGFloat in corners.indices.contains(i) ? max(0, corners[i]) : 0 }
        // (radii that meet are scaled down together, as CSS does)
        let fit = min(1, rect.width / max(at(0) + at(1), at(3) + at(2), 0.0001),
                      rect.height / max(at(0) + at(3), at(1) + at(2), 0.0001))
        let r = (0 ..< 4).map { at($0) * fit }
        let p = (0 ..< 4).map { pow(2, shapes?.indices.contains($0) == true ? shapes![$0] : 1) }
        var path = Path()
        // Each corner from its start on one edge to its end on the next, clockwise from the top left's.
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX + r[0], y: rect.minY + r[0]), -1, -1),
            (CGPoint(x: rect.maxX - r[1], y: rect.minY + r[1]), 1, -1),
            (CGPoint(x: rect.maxX - r[2], y: rect.maxY - r[2]), 1, 1),
            (CGPoint(x: rect.minX + r[3], y: rect.maxY - r[3]), -1, 1),
        ]
        let steps = 24
        for (i, (centre, sx, sy)) in corners.enumerated() {
            for step in 0 ... steps {
                // From the corner's start round to its end: along the edge before it, then the one after.
                let t = Double(step) / Double(steps) * .pi / 2
                let (u, v): (Double, Double) = switch i {
                case 0: (cos(t), sin(t))
                case 1: (sin(t), cos(t))
                case 2: (cos(t), sin(t))
                default: (sin(t), cos(t))
                }
                let e = 2 / p[i]
                let x = centre.x + sx * r[i] * CGFloat(pow(u, e))
                let y = centre.y + sy * r[i] * CGFloat(pow(v, e))
                let point = CGPoint(x: x, y: y)
                if i == 0, step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        return path
    }
}
