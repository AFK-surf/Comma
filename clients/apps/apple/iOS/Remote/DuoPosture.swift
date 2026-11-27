import CoreGraphics
import Foundation
import simd
import SwiftUI

/// One way an iPhone Duo is shown and held, as `devices.listScreens` lists it (the core's `screen-postures.ts`): which
/// of its screens shows, how far it opens, how it stands, and the fold its station is told.
struct DuoPosture: Hashable, Sendable, Identifiable {
    enum Screen: String, Sendable { case cover, inner }
    enum Stand: String, Sendable { case upright, tent, laptop }

    let id: String
    let screen: Screen
    /// Degrees: 0 closed, 180 flat.
    let opening: Double
    let stand: Stand
    /// The picture's turn from its screen's own upright (0 portrait, 90 landscape).
    let orientation: Int
    /// The fold the station is told: `closed` or `open`.
    let pose: String

    init(id: String, screen: Screen, opening: Double, stand: Stand, orientation: Int, pose: String) {
        self.id = id; self.screen = screen; self.opening = opening; self.stand = stand
        self.orientation = orientation; self.pose = pose
    }

    init?(_ row: NSDictionary) {
        guard let id = row.string("id"), let screen = row.string("screen").flatMap(Screen.init),
              let opening = row.double("opening"), let stand = row.string("stand").flatMap(Stand.init),
              let pose = row.string("pose") else { return nil }
        self.init(id: id, screen: screen, opening: opening, stand: stand, orientation: row.int("orientation") ?? 0, pose: pose)
    }

    /// The six the core lists, in its order (for a preview without a station).
    static let all = [
        DuoPosture(id: "coverPortrait", screen: .cover, opening: 0, stand: .upright, orientation: 0, pose: "closed"),
        DuoPosture(id: "coverLandscape", screen: .cover, opening: 0, stand: .upright, orientation: 90, pose: "closed"),
        DuoPosture(id: "tent", screen: .cover, opening: 75, stand: .tent, orientation: 90, pose: "closed"),
        DuoPosture(id: "laptop", screen: .inner, opening: 105, stand: .laptop, orientation: 0, pose: "open"),
        DuoPosture(id: "innerLandscape", screen: .inner, opening: 180, stand: .upright, orientation: 90, pose: "open"),
        DuoPosture(id: "innerPortrait", screen: .inner, opening: 180, stand: .upright, orientation: 0, pose: "open"),
    ]

    var landscape: Bool { orientation == 90 || orientation == 270 }

    var title: Text {
        switch id {
        case "coverPortrait": Text("Cover portrait")
        case "coverLandscape": Text("Cover landscape")
        case "tent": Text("Tent")
        case "laptop": Text("Laptop")
        case "innerLandscape": Text("Inner landscape")
        case "innerPortrait": Text("Inner portrait")
        default: Text(verbatim: id)
        }
    }

    var icon: String {
        switch id {
        case "coverLandscape": "iphone.landscape"
        case "tent": PostureGlyph.tent
        case "laptop": "laptopcomputer"
        case "innerLandscape": "rectangle.split.2x1"
        case "innerPortrait": "rectangle.split.1x2"
        default: "iphone"
        }
    }

    /// Whether the device standing as its station says (`pose`, the picture's `turn`) can be this posture.
    func matches(pose: String?, turn: Int) -> Bool {
        guard let pose else { return false }
        let open = pose != "closed"
        return open == (self.pose == "open") && landscape == (turn == 90 || turn == 270)
    }

    /// The posture that shows how the device stands, as its station says, of `postures`: of those its fold and
    /// picture allow, the one whose opening is nearest its `hinge` where the station says it (a tent beside a cover
    /// held landscape, a laptop beside an open device held portrait), else the upright one.
    static func standing(pose: String?, turn: Int, hinge: Int? = nil, of postures: [DuoPosture]) -> DuoPosture? {
        guard pose != nil else { return nil }
        let fits = postures.filter { $0.matches(pose: pose, turn: turn) }
        if let hinge {
            return fits.min { abs($0.opening - Double(hinge)) < abs($1.opening - Double(hinge)) }
        }
        return fits.first { $0.stand == .upright } ?? fits.first
    }
}

/// Where a point of a screen's mesh is in the station's picture, and back. A mesh point is SceneKit's texture
/// coordinate `(s, t)`: `t` 0 at the device's top (the rig's `v` is `1 - t`). The station turns each picture with the
/// device (`systems/station/docs/simulator-screen.md`, "Rotation"): `turn` degrees clockwise from the screen's
/// framebuffer.
enum DuoPicture {
    /// The framebuffers, both portrait: the cover 1398×2034, the inner one 2007×2853.
    static func framebuffer(_ screen: DuoPosture.Screen) -> CGSize {
        screen == .cover ? CGSize(width: 1398, height: 2034) : CGSize(width: 2007, height: 2853)
    }

    /// The picture's turn: landscape when its shape is (the framebuffers are portrait), and which way from what the
    /// station says. Before a picture comes, as the station says.
    static func turn(orientation: Int?, picture: CGSize) -> Int {
        let said = ((orientation ?? 0) % 360 + 360) % 360
        guard picture.width > 0, picture.height > 0 else { return said }
        return picture.width > picture.height ? (said == 270 ? 270 : 90) : (said == 180 ? 180 : 0)
    }

    /// The picture's fraction (x right, y down) at mesh point `st` of `screen`.
    static func fraction(_ st: SIMD2<Double>, screen: DuoPosture.Screen, turn: Int) -> SIMD2<Double> {
        // The cover's framebuffer lies on it as it is (x from the hinge, y down from the top); the inner one's x runs
        // down the hinge and its y across, from the camera half.
        let frame = screen == .cover ? st : SIMD2(st.y, 1 - st.x)
        return rotate(frame, clockwise: turn)
    }

    /// The mesh point of `screen` that shows the picture's fraction `at`: `fraction`'s inverse.
    static func meshPoint(_ at: SIMD2<Double>, screen: DuoPosture.Screen, turn: Int) -> SIMD2<Double> {
        let frame = rotate(at, clockwise: 360 - turn)
        return screen == .cover ? frame : SIMD2(1 - frame.y, frame.x)
    }

    /// `fraction` as the affine map SceneKit's `contentsTransform` applies to texture coordinates.
    static func transform(screen: DuoPosture.Screen, turn: Int) -> simd_float4x4 {
        let origin = fraction(.zero, screen: screen, turn: turn)
        let s = fraction(SIMD2(1, 0), screen: screen, turn: turn) - origin
        let t = fraction(SIMD2(0, 1), screen: screen, turn: turn) - origin
        return simd_float4x4(columns: (SIMD4(Float(s.x), Float(s.y), 0, 0), SIMD4(Float(t.x), Float(t.y), 0, 0),
                                       SIMD4(0, 0, 1, 0), SIMD4(Float(origin.x), Float(origin.y), 0, 1)))
    }

    /// A point of a picture, as fractions, after the picture turns `degrees` clockwise.
    static func rotate(_ p: SIMD2<Double>, clockwise degrees: Int) -> SIMD2<Double> {
        switch (degrees % 360 + 360) % 360 {
        case 90: SIMD2(1 - p.y, p.x)
        case 180: SIMD2(1 - p.x, 1 - p.y)
        case 270: SIMD2(p.y, 1 - p.x)
        default: p
        }
    }
}

/// The model's measurements and its hinge's motion, from `Resources/Devices/iphone-duo.rig.json` (made with the model
/// by `build-iphone-duo.py`). Millimetres, the model's axes: x across the open device (the camera half at +x), y along
/// the hinge with the top at +y, z out of the inner display.
struct DuoRig: Sendable {
    var width = 82.4, height = 117.2, thickness = 5.0
    var pivot = 0.475
    var creaseHalfWidth = 7.9, creaseLift = 0.12, creaseSegments = 18
    var creaseRows: (Double, Double) = (-55.41065217391304, 55.41065217391304)
    var innerUVBox: (Double, Double, Double, Double) = (-78.76760869565217, -55.41065217391304, 78.76760869565217, 55.41065217391304)
    /// The spine's place (x, y, z) at each opening angle the rig keys.
    var spinePath: [(opening: Double, at: SIMD3<Double>)] = []

    static let shared: DuoRig = {
        guard let url = Bundle.main.url(forResource: "iphone-duo.rig", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return DuoRig() }
        return DuoRig(json: data) ?? DuoRig()
    }()

    init() {}

    init?(json data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary else { return nil }
        if let half = root.object("half") {
            width = half.double("width") ?? width; height = half.double("height") ?? height
            thickness = half.double("thickness") ?? thickness
        }
        if let p = root.object("hinge")?.array("pivot") as? [NSNumber], p.count == 3 { pivot = p[2].doubleValue }
        if let crease = root.object("crease") {
            creaseHalfWidth = crease.double("half_width") ?? creaseHalfWidth
            creaseLift = crease.double("lift") ?? creaseLift
            creaseSegments = crease.int("segments") ?? creaseSegments
            if let rows = crease.array("rows") as? [NSNumber], rows.count == 2 { creaseRows = (rows[0].doubleValue, rows[1].doubleValue) }
        }
        if let box = root.object("screens")?.object("inner")?.array("uv_box") as? [NSNumber], box.count == 4 {
            innerUVBox = (box[0].doubleValue, box[1].doubleValue, box[2].doubleValue, box[3].doubleValue)
        }
        if let path = root.object("spine")?.object("path") {
            spinePath = path.compactMap { key, value -> (Double, SIMD3<Double>)? in
                guard let key = key as? String, let opening = Double(key), let at = value as? [NSNumber], at.count == 3 else { return nil }
                return (opening, SIMD3(at[0].doubleValue, at[1].doubleValue, at[2].doubleValue))
            }.sorted { $0.0 < $1.0 }
        }
    }

    /// The spine's place at `opening`, between the rig's keys.
    func spine(at opening: Double) -> SIMD3<Double> {
        guard let first = spinePath.first, let last = spinePath.last else { return SIMD3(0, 0, pivot - 2.45) }
        if opening <= first.opening { return first.at }
        if opening >= last.opening { return last.at }
        let upper = spinePath.firstIndex { $0.opening >= opening } ?? spinePath.count - 1
        let a = spinePath[upper - 1], b = spinePath[upper]
        return simd_mix(a.at, b.at, SIMD3(repeating: (opening - a.opening) / (b.opening - a.opening)))
    }

    /// The inner display's bending strip at `opening` (`crease_curve` in `build-iphone-duo.py`): its points (x, z) from
    /// the camera half's screen edge to the cover half's, evenly spaced along it, and its length. A cubic leaves each
    /// half's screen along it; its handles are solved so its length stays twice the strip's half width.
    func crease(opening: Double) -> (points: [SIMD2<Double>], length: Double) {
        let theta = (180 - opening) * .pi / 180
        let wanted = 2 * creaseHalfWidth
        let a = SIMD2(creaseHalfWidth, creaseLift), da = SIMD2(-1.0, 0)
        let rel = SIMD2(-creaseHalfWidth, creaseLift - pivot)
        let b = SIMD2(rel.x * cos(theta) + rel.y * sin(theta), pivot - rel.x * sin(theta) + rel.y * cos(theta))
        let db = SIMD2(-cos(theta), sin(theta))
        func point(_ h: Double, _ t: Double) -> SIMD2<Double> {
            let p1 = a + da * h, p2 = b - db * h, u = 1 - t
            return a * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + b * (t * t * t)
        }
        func length(_ h: Double, _ n: Int = 240) -> Double {
            var total = 0.0, last = point(h, 0)
            for i in 1 ... n { let next = point(h, Double(i) / Double(n)); total += simd_distance(last, next); last = next }
            return total
        }
        var h = 0.0
        if length(0) < wanted {
            var low = 0.0, high = 4 * wanted
            for _ in 0 ..< 60 {
                let mid = (low + high) / 2
                if length(mid) < wanted { low = mid } else { high = mid }
            }
            h = (low + high) / 2
        }
        let dense = (0 ... 600).map { point(h, Double($0) / 600) }
        var along = [0.0]
        for i in 0 ..< 600 { along.append(along[i] + simd_distance(dense[i], dense[i + 1])) }
        let total = along[600]
        var points: [SIMD2<Double>] = [], j = 0
        for k in 0 ... creaseSegments {
            let want = total * Double(k) / Double(creaseSegments)
            while j < 599, along[j + 1] < want { j += 1 }
            let f = (want - along[j]) / max(along[j + 1] - along[j], 1e-9)
            points.append(simd_mix(dense[j], dense[j + 1], SIMD2(repeating: f)))
        }
        return (points, total)
    }
}

/// How the model stands before the camera at one moment: how far it opens, how it is turned (model to view: x right,
/// y up, z toward the viewer), the point of it at the middle of the view, and how far the camera is from that point.
struct DuoStagePose: Equatable, Sendable {
    var opening: Double
    var rotation: simd_quatd
    /// In view axes, metres.
    var center: SIMD3<Double>
    var distance: Double

    /// `t` from 0 to 1, eased in and out (cubic).
    static func ease(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Between `a` and `b`, `t` from 0 to 1 eased in and out.
    static func mix(_ a: DuoStagePose, _ b: DuoStagePose, _ t: Double) -> DuoStagePose {
        let e = ease(t)
        return DuoStagePose(opening: a.opening + (b.opening - a.opening) * e,
                            rotation: simd_slerp(a.rotation, b.rotation, e),
                            center: simd_mix(a.center, b.center, SIMD3(repeating: e)),
                            distance: a.distance + (b.distance - a.distance) * e)
    }

    /// The pose for `posture` with its picture turned `turn`, framed for a view of `aspect` (width / height) seen
    /// through a vertical field of `fieldOfView` degrees.
    static func target(_ posture: DuoPosture, turn: Int, aspect: Double, fieldOfView: Double, rig: DuoRig = .shared) -> DuoStagePose {
        let rotation = rotation(posture, turn: turn)
        let mm = 0.001
        let theta = (180 - posture.opening) * .pi / 180
        let hinge = simd_quatd(angle: theta, axis: SIMD3(0, 1, 0))
        var points: [SIMD3<Double>] = []
        for x in [0, rig.width] { for y in [-rig.height / 2, rig.height / 2] { for z in [-rig.thickness, 0] {
            points.append(SIMD3(x, y, z) * mm)
            // The cover half, laid out about the hinge's pivot, turned by the fold.
            let local = SIMD3(-x, y, z - rig.pivot)
            points.append((hinge.act(local) + SIMD3(0, 0, rig.pivot)) * mm)
        } } }
        let seen = points.map { rotation.act($0) }
        let low = seen.reduce(SIMD3(repeating: Double.infinity)) { simd_min($0, $1) }
        let high = seen.reduce(SIMD3(repeating: -Double.infinity)) { simd_max($0, $1) }
        let center = (low + high) / 2
        let half = (high - low) / 2
        let vertical = tan(fieldOfView * .pi / 360)
        let horizontal = vertical * max(aspect, 0.1)
        // A margin round it, and the nearest face of it (not its middle) fitted.
        let fit = max(half.x / horizontal, half.y / vertical) * 1.18 + half.z
        return DuoStagePose(opening: posture.opening, rotation: rotation, center: center, distance: fit)
    }

    /// How `posture` turns the model before the viewer (model to view).
    static func rotation(_ posture: DuoPosture, turn: Int) -> simd_quatd {
        func degrees(_ d: Double, _ axis: SIMD3<Double>) -> simd_quatd { simd_quatd(angle: d * .pi / 180, axis: axis) }
        let x = SIMD3(1.0, 0, 0), y = SIMD3(0, 1.0, 0), z = SIMD3(0, 0, 1.0)
        switch posture.stand {
        case .upright:
            // Its picture shows as the station turns it: the cover's framebuffer lies upright on the closed device,
            // the inner one a quarter turn clockwise on the open one. Seen straight on; a drag turns it a little.
            let spin = Double(posture.screen == .cover ? turn : turn + 270)
            return degrees(-spin, z)
        case .tent:
            // On its two outer long edges, the hinge on top, the cover display slanted toward the viewer and its top
            // to the right. Seen a little from above and from its right, so its two halves read as a tent.
            let theta = (180 - posture.opening) * .pi / 180
            let down = simd_normalize(SIMD3(1 - cos(theta), 0, sin(theta)))
            let toward = SIMD3(-down.z, 0, down.x)
            return degrees(8, x) * degrees(-18, y) * simd_quatd(rows: y, -down, toward)
        case .laptop:
            // The cover half (the opening up from the camera half) lies on its back toward the viewer, the camera half
            // stands at its far edge, the top of the device to the left. Seen from above the front.
            let at = posture.opening * .pi / 180
            let along = SIMD3(cos(at), 0, sin(at))
            let up = SIMD3(sin(at), 0, -cos(at))
            return degrees(24, x) * simd_quatd(rows: -y, up, along)
        }
    }
}

/// A screen's triangles, for finding where a finger's ray meets it.
struct DuoTouchMesh: Sendable {
    var positions: [SIMD3<Float>]
    var coordinates: [SIMD2<Float>]
    var triangles: [UInt32]

    /// Where the ray `origin + t * direction` (t from 0) first meets a triangle, either side: its `t` and the texture
    /// coordinates there.
    func hit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (t: Float, st: SIMD2<Float>)? {
        var best: (t: Float, st: SIMD2<Float>)?
        var i = 0
        while i + 2 < triangles.count {
            let a = Int(triangles[i]), b = Int(triangles[i + 1]), c = Int(triangles[i + 2])
            i += 3
            guard a < positions.count, b < positions.count, c < positions.count else { continue }
            // Möller–Trumbore.
            let e1 = positions[b] - positions[a], e2 = positions[c] - positions[a]
            let p = simd_cross(direction, e2)
            let det = simd_dot(e1, p)
            guard abs(det) > 1e-12 else { continue }
            let s = origin - positions[a]
            let u = simd_dot(s, p) / det
            guard u >= 0, u <= 1 else { continue }
            let q = simd_cross(s, e1)
            let v = simd_dot(direction, q) / det
            guard v >= 0, u + v <= 1 else { continue }
            let t = simd_dot(e2, q) / det
            guard t >= 0, t < best?.t ?? .infinity else { continue }
            let st = a < coordinates.count && b < coordinates.count && c < coordinates.count
                ? coordinates[a] * (1 - u - v) + coordinates[b] * u + coordinates[c] * v : .zero
            best = (t, st)
        }
        return best
    }
}

private extension simd_quatd {
    /// The turn that takes the model's axes to the view's: `right`, `up` and `toward` are the model's directions that
    /// end up along the view's x, y and z.
    init(rows right: SIMD3<Double>, _ up: SIMD3<Double>, _ toward: SIMD3<Double>) {
        let matrix = simd_double3x3(rows: [right, up, toward])
        self.init(matrix)
    }
}


/// A slight turn of the whole stage a finger gives by dragging off the screen that shows: it follows the finger closely
/// for small drags and grows ever stiffer toward its limits, which it never passes.
enum DuoTilt {
    /// The most it turns: left and right, and up and down, in degrees.
    static let maxYaw = 25.0
    static let maxPitch = 15.0
    /// Degrees per point of drag while far from the limits.
    static let degreesPerPoint = 0.12

    /// The drag carried so far, in degrees before the limits; kept within three times them so a long drag past a limit
    /// comes back from it at once.
    static func accumulate(_ raw: SIMD2<Double>, by translation: CGSize) -> SIMD2<Double> {
        let next = raw + SIMD2(Double(translation.width), Double(translation.height)) * degreesPerPoint
        return SIMD2(min(max(next.x, -3 * maxYaw), 3 * maxYaw), min(max(next.y, -3 * maxPitch), 3 * maxPitch))
    }

    /// The turn shown for a carried drag: yaw (a drag right turns the device's right side away) and pitch (a drag down
    /// tips its top toward the viewer), in degrees, each within its limit.
    static func angles(_ raw: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(maxYaw * tanh(raw.x / maxYaw), maxPitch * tanh(raw.y / maxPitch))
    }
}
