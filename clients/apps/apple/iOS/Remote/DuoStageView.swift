import Metal
import QuartzCore
import SceneKit
import SwiftUI
import UIKit

/// An iPhone Duo drawn live in 3D (`Resources/Devices/iphone-duo.usdz`, rigged by `iphone-duo.rig.json`): the station's
/// picture on the screen that is on, the model folded, turned and framed as its posture says, and moved between
/// postures together over `duration`. A finger on the screen that shows is the device's finger while the view drives.
struct DuoStageView: View {
    let session: DeviceScreenSession
    /// How long a move between postures takes.
    var duration: TimeInterval = 0.6
    @State private var holder = DuoStageHolder()
    @State private var finger: CGPoint?
    @State private var movedAt = Date.distantPast
    /// Where a drag that turns the device was last.
    @State private var tiltAt: CGPoint?
    @Environment(\.colorScheme) private var colorScheme

    // A finger's moves reach the device at most this often; its lift carries where it ends.
    private static let moveInterval: TimeInterval = 0.016

    var body: some View {
        DuoSceneView(holder: holder, dark: colorScheme == .dark, decoder: session.textures,
                     posture: session.posture ?? DuoPosture.all[0], turn: session.turn, standing: session.standing, follows: session.follows, screen: session.screenOn,
                     duration: duration)
            .gesture(touch)
            .accessibilityElement()
            .accessibilityLabel(Text("Device screen"))
    }

    private var touch: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard let stage = holder.stage else { return }
                if let last = tiltAt {
                    stage.tilt(by: CGSize(width: value.location.x - last.x, height: value.location.y - last.y))
                    tiltAt = value.location
                    return
                }
                if finger == nil {
                    // A finger that starts off the screen that shows, or while the view only watches, turns the
                    // device a little instead.
                    guard session.control, let at = stage.fraction(at: value.startLocation) else {
                        tiltAt = value.location
                        return
                    }
                    finger = at
                    movedAt = Date()
                    session.send(["t": "pointer", "kind": "down", "x": at.x, "y": at.y, "buttons": 1])
                    return
                }
                guard Date().timeIntervalSince(movedAt) >= Self.moveInterval,
                      let at = stage.fraction(at: value.location) else { return }
                finger = at
                movedAt = Date()
                session.send(["t": "pointer", "kind": "move", "x": at.x, "y": at.y, "buttons": 1])
            }
            .onEnded { value in
                if tiltAt != nil { tiltAt = nil; return }
                guard let last = finger else { return }
                finger = nil
                let at = holder.stage?.fraction(at: value.location) ?? last
                session.send(["t": "pointer", "kind": "up", "x": at.x, "y": at.y, "buttons": 0])
            }
    }
}

/// Where the stage's SceneKit view is kept, for the touches over it.
@MainActor final class DuoStageHolder {
    var stage: DuoStage?
}

private struct DuoSceneView: UIViewRepresentable {
    let holder: DuoStageHolder
    let dark: Bool
    let decoder: ScreenTextureDecoder?
    let posture: DuoPosture
    let turn: Int
    let standing: Int
    let follows: Bool
    let screen: DuoPosture.Screen
    let duration: TimeInterval

    func makeUIView(context: Context) -> SCNView {
        let stage = DuoStage(dark: dark, device: decoder?.device)
        holder.stage = stage
        stage.attach(decoder)
        stage.update(posture: posture, turn: turn, standing: standing, follows: follows, screen: screen, duration: duration)
        return stage.view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        holder.stage?.update(posture: posture, turn: turn, standing: standing, follows: follows, screen: screen, duration: duration)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: ()) {
        (view as? DuoSceneKitView)?.stage?.stop()
    }
}

final class DuoSceneKitView: SCNView {
    weak var stage: DuoStage?

    override func layoutSubviews() {
        super.layoutSubviews()
        MainActor.assumeIsolated { stage?.resized() }
    }
}

/// The SceneKit scene of one stage, and the motion between postures.
@MainActor final class DuoStage {
    let view: DuoSceneKitView
    private let rig = DuoRig.shared
    private let holderNode = SCNNode()
    /// The slight turn a drag off the screens gives the whole device, about the middle of the view.
    private let tiltNode = SCNNode()
    private var tiltRaw = SIMD2<Double>(0, 0)
    /// The turn when a posture move began: it goes back to none over the move.
    private var tiltFrom = SIMD2<Double>(0, 0)
    private let cameraNode = SCNNode()
    private var hinge: SCNNode?
    private var spine: SCNNode?
    private var crease: SCNNode?
    private var innerNodes: [SCNNode] = []
    private var coverNodes: [SCNNode] = []
    /// What a finger is tested against: each screen's triangles, read from the model once (SceneKit's own hit test
    /// finds none of the model's faces), with its screen and its front along its own axes (none for the bending strip).
    private var touchable: [(node: SCNNode, screen: DuoPosture.Screen, front: SIMD3<Float>?, mesh: DuoTouchMesh)] = []
    private let inner = DuoStage.screenMaterial()
    private let cover = DuoStage.screenMaterial()

    /// A long lens: the device reads flat-on with little perspective, as in a product shot.
    static let fieldOfView = 14.0

    private var posture: DuoPosture?
    private var turn = 0
    /// How the device's UI stands, the model with it (`DeviceScreenSession.standing`).
    private var standing = 0
    /// Its picture is its panel's own: the model turns as the device says, with its UI's turn (`DeviceScreenSession.panel`).
    private var follows = false
    private var screen = DuoPosture.Screen.cover
    private var picture: Any?
    private var duration: TimeInterval = 0.6
    /// The pose drawn now, and the move under way.
    private var shown: DuoStagePose?
    private var move: (from: DuoStagePose, to: DuoStagePose, start: CFTimeInterval)?
    private var link: CADisplayLink?
    private var creaseOpening = -1.0
    private var targetKey = ""
    private var aspect = 0.0

    init(dark: Bool, device: MTLDevice?) {
        var options: [String: Any] = [:]
        if let device { options[SCNView.Option.preferredDevice.rawValue] = device }
        view = DuoSceneKitView(frame: .zero, options: options)
        view.stage = self
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60

        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = Self.studio()
        scene.lightingEnvironment.intensity = 1.2
        view.scene = scene

        let camera = SCNCamera()
        camera.fieldOfView = Self.fieldOfView
        camera.projectionDirection = .vertical
        camera.zNear = 0.005
        camera.zFar = 10
        camera.wantsHDR = false
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        // A soft key from above the front right and a dimmer fill from the left, besides the studio's light.
        for (angles, intensity) in [(SIMD3<Float>(-0.7, 0.5, 0), 900.0), (SIMD3<Float>(-0.2, -0.9, 0), 300.0)] {
            let light = SCNLight()
            light.type = .directional
            light.intensity = intensity
            light.color = UIColor(white: 1, alpha: 1)
            let node = SCNNode()
            node.light = light
            node.simdEulerAngles = angles
            scene.rootNode.addChildNode(node)
        }

        scene.rootNode.addChildNode(tiltNode)
        tiltNode.addChildNode(holderNode)
        let name = dark ? "iphone-duo-black" : "iphone-duo"
        if let url = Bundle.main.url(forResource: name, withExtension: "usdz"),
           let model = try? SCNScene(url: url, options: nil),
           let duo = model.rootNode.childNode(withName: "Duo", recursively: true) {
            duo.removeFromParentNode()
            Self.dropEmptyElements(duo)
            Self.polish(duo, light: !dark)
            holderNode.addChildNode(duo)
            hinge = duo.childNode(withName: "Hinge", recursively: true)
            spine = duo.childNode(withName: "SpineHinge", recursively: true)
            func shapes(_ name: String) -> [SCNNode] {
                duo.childNode(withName: name, recursively: true)?.childNodes { node, _ in node.geometry != nil } ?? []
            }
            innerNodes = shapes("ScreenInner_Camera") + shapes("ScreenInner_Cover")
            coverNodes = shapes("ScreenCover")
            // The bending strip is made again at each angle here: its morph targets do not reach SceneKit whole.
            if let strip = shapes("ScreenInner_Crease").first {
                strip.morpher = nil
                strip.skinner = nil
                crease = strip
                innerNodes.append(strip)
            }
            for (nodes, screen, front) in [(innerNodes, DuoPosture.Screen.inner, SIMD3<Float>(0, 0, 1)),
                                           (coverNodes, .cover, SIMD3<Float>(0, 0, -1))] {
                for node in nodes where node !== crease {
                    if let mesh = node.geometry.flatMap(Self.touchMesh) { touchable.append((node, screen, front, mesh)) }
                }
            }
            for node in innerNodes { node.geometry?.materials = [inner] }
            for node in coverNodes { node.geometry?.materials = [cover] }
        }
    }

    /// Takes the decoder's pictures as they come.
    func attach(_ decoder: ScreenTextureDecoder?) {
        guard let decoder else { return }
        decoder.onFrame = { [weak self] texture in self?.show(texture) }
        if let latest = decoder.latest { show(latest) }
    }

    /// A picture for the screen that is on: a Metal texture, or an image.
    func show(_ content: Any) {
        picture = content
        // (only the lit screen's picture changes with each frame)
        (screen == .cover ? cover : inner).emission.contents = content
    }

    /// Only the screen that is on shows the picture; the other stays black glass.
    private func lightScreens() {
        let on = screen == .cover ? cover : inner, off = screen == .cover ? inner : cover
        off.emission.contents = UIColor.black
        off.emission.intensity = 0
        on.emission.contents = picture ?? UIColor.black
        on.emission.intensity = 1
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func update(posture next: DuoPosture, turn nextTurn: Int, standing nextStanding: Int, follows nextFollows: Bool,
                screen nextScreen: DuoPosture.Screen, duration: TimeInterval) {
        self.duration = duration
        if nextScreen != screen || posture == nil {
            screen = nextScreen
            lightScreens()
        }
        turn = nextTurn
        standing = nextStanding
        follows = nextFollows
        (screen == .cover ? cover : inner).emission.contentsTransform = SCNMatrix4(DuoPicture.transform(screen: screen, turn: turn))
        let key = "\(next.id)/\(turnFor(next))"
        guard key != targetKey else { return }
        targetKey = key
        posture = next
        retarget(animated: shown != nil)
    }

    func resized() {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let next = Double(size.width / size.height)
        guard abs(next - aspect) > 0.001 else { return }
        aspect = next
        retarget(animated: false)
    }

    private func target(_ posture: DuoPosture) -> DuoStagePose {
        DuoStagePose.target(posture, turn: turnFor(posture), aspect: aspect > 0 ? aspect : 0.6,
                            fieldOfView: Self.fieldOfView, rig: rig)
    }

    /// The turn the model shows `posture` in: the picture's own, while the device stands so; the posture's until it
    /// does.
    private func turnFor(_ posture: DuoPosture) -> Int {
        follows || posture.landscape == (standing == 90 || standing == 270) ? standing : posture.orientation
    }

    private func retarget(animated: Bool) {
        guard let posture else { return }
        let to = target(posture)
        guard animated, let shown, duration > 0 else {
            move = nil
            apply(to)
            return
        }
        move = (shown, to, CACurrentMediaTime())
        tiltFrom = DuoTilt.angles(tiltRaw)
        tiltRaw = .zero
        if link == nil {
            let link = CADisplayLink(target: DisplayTarget(self), selector: #selector(DisplayTarget.tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    fileprivate func tick() {
        guard let move else { stop(); return }
        let t = (CACurrentMediaTime() - move.start) / duration
        if t >= 1 {
            self.move = nil
            tiltFrom = .zero
            applyTilt(.zero)
            apply(move.to)
            stop()
        } else {
            applyTilt(tiltFrom * (1 - DuoStagePose.ease(t)))
            apply(DuoStagePose.mix(move.from, move.to, t))
        }
    }

    private func apply(_ pose: DuoStagePose) {
        shown = pose
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        holderNode.simdOrientation = simd_quatf(vector: SIMD4<Float>(pose.rotation.vector))
        holderNode.simdPosition = SIMD3<Float>(-pose.center)
        cameraNode.simdPosition = SIMD3(0, 0, Float(pose.distance))
        let fold = Float((180 - pose.opening) * .pi / 180)
        hinge?.simdOrientation = simd_quatf(angle: fold, axis: SIMD3(0, 1, 0))
        spine?.simdOrientation = simd_quatf(angle: fold / 2, axis: SIMD3(0, 1, 0))
        spine?.simdPosition = SIMD3<Float>(rig.spine(at: pose.opening) * 0.001)
        if abs(pose.opening - creaseOpening) > 0.01, let crease, rig.crease(opening: pose.opening).points.count > 1 {
            creaseOpening = pose.opening
            let (geometry, mesh) = Self.creaseGeometry(rig: rig, opening: pose.opening, material: inner)
            crease.geometry = geometry
            touchable.removeAll { $0.node === crease }
            touchable.append((crease, .inner, nil, mesh))
        }
        SCNTransaction.commit()
    }

    /// Turns the device a little more as a finger drags off the screens (`translation` since the last call).
    func tilt(by translation: CGSize) {
        guard move == nil else { return }
        tiltRaw = DuoTilt.accumulate(tiltRaw, by: translation)
        applyTilt(DuoTilt.angles(tiltRaw))
    }

    private func applyTilt(_ angles: SIMD2<Double>) {
        let yaw = simd_quatf(angle: Float(angles.x * .pi / 180), axis: SIMD3(0, 1, 0))
        let pitch = simd_quatf(angle: Float(angles.y * .pi / 180), axis: SIMD3(1, 0, 0))
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        tiltNode.simdOrientation = pitch * yaw
        SCNTransaction.commit()
    }

    /// The picture's fraction under `point` of the view, when the screen that is on is there.
    func fraction(at point: CGPoint) -> CGPoint? {
        let near = SIMD3<Float>(view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0)))
        let far = SIMD3<Float>(view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1)))
        // The nearest screen face toward the camera: the other screen of a closed device lies under this one.
        var best: (t: Float, screen: DuoPosture.Screen, st: SIMD2<Float>)?
        for shape in touchable {
            let inverse = shape.node.presentation.simdWorldTransform.inverse
            let origin = inverse * SIMD4(near, 1), end = inverse * SIMD4(far, 1)
            let direction = SIMD3(end.x, end.y, end.z) - SIMD3(origin.x, origin.y, origin.z)
            if let front = shape.front, simd_dot(front, direction) >= 0 { continue }
            guard let hit = shape.mesh.hit(origin: SIMD3(origin.x, origin.y, origin.z), direction: direction),
                  hit.t < best?.t ?? .infinity else { continue }
            best = (hit.t, shape.screen, hit.st)
        }
        guard let best, best.screen == screen else { return nil }
        let at = DuoPicture.fraction(SIMD2(Double(best.st.x), Double(best.st.y)), screen: screen, turn: turn)
        return CGPoint(x: min(1, max(0, at.x)), y: min(1, max(0, at.y)))
    }

    // MARK: Making

    private static func screenMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        // Lambert: no reflection of the studio over the picture, which washes it out where the screen faces the sky.
        material.lightingModel = .lambert
        material.diffuse.contents = UIColor.black
        material.emission.contents = UIColor.black
        material.emission.wrapS = .clamp
        material.emission.wrapT = .clamp
        material.emission.mipFilter = .none
        return material
    }

    /// A geometry's triangles, positions and texture coordinates, read from its bytes.
    static func touchMesh(_ geometry: SCNGeometry) -> DuoTouchMesh? {
        guard let positions = geometry.sources(for: .vertex).first,
              let coordinates = geometry.sources(for: .texcoord).first else { return nil }
        func floats(_ source: SCNGeometrySource) -> [SIMD3<Float>] {
            guard source.bytesPerComponent == 4, source.usesFloatComponents else { return [] }
            return source.data.withUnsafeBytes { raw in
                (0 ..< source.vectorCount).map { i in
                    var v = SIMD3<Float>(repeating: 0)
                    for c in 0 ..< min(3, source.componentsPerVector) {
                        v[c] = raw.loadUnaligned(fromByteOffset: source.dataOffset + i * source.dataStride + c * 4, as: Float.self)
                    }
                    return v
                }
            }
        }
        // A screen is one convex face whose corners are its vertices in order round it: a fan of them. (Its elements'
        // index bytes are not read: SceneKit lays a face-varying mesh's indices out in channels it does not document,
        // and read as plain triangles they named the wrong corners, so no finger ever met a screen.)
        var triangles: [UInt32] = []
        let corners = UInt32(positions.vectorCount)
        if corners >= 3 { for k in 1 ..< corners - 1 { triangles += [0, k, k + 1] } }
        let mesh = DuoTouchMesh(positions: floats(positions), coordinates: floats(coordinates).map { SIMD2($0.x, $0.y) },
                                triangles: triangles)
        return mesh.positions.isEmpty ? nil : mesh
    }

    /// The bending strip at `opening`: `DuoRig.crease`'s points across, the screen's two rows along the hinge, and the
    /// picture's coordinates where the flat strip has them.
    static func creaseGeometry(rig: DuoRig, opening: Double, material: SCNMaterial) -> (SCNGeometry, DuoTouchMesh) {
        let points = rig.crease(opening: opening).points
        let mm = 0.001
        let rows = [rig.creaseRows.0, rig.creaseRows.1]
        let (u0, v0, u1, v1) = rig.innerUVBox
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], coordinates: [CGPoint] = []
        let last = points.count - 1
        for (k, p) in points.enumerated() {
            let along = simd_normalize(points[min(k + 1, last)] - points[max(k - 1, 0)])
            // Across the strip, out of the screen: +z where it lies flat.
            let normal = SCNVector3(Float(along.y), 0, Float(-along.x))
            let flatX = rig.creaseHalfWidth - 2 * rig.creaseHalfWidth * Double(k) / Double(last)
            for y in rows {
                vertices.append(SCNVector3(Float(p.x * mm), Float(y * mm), Float(p.y * mm)))
                normals.append(normal)
                coordinates.append(CGPoint(x: (flatX - u0) / (u1 - u0), y: 1 - (y - v0) / (v1 - v0)))
            }
        }
        var indices: [UInt16] = []
        for k in 0 ..< last {
            let a = UInt16(k * 2), b = UInt16((k + 1) * 2), c = UInt16((k + 1) * 2 + 1), d = UInt16(k * 2 + 1)
            indices += [a, c, b, a, d, c]
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals),
                                             SCNGeometrySource(textureCoordinates: coordinates)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [material]
        let mesh = DuoTouchMesh(positions: vertices.map { SIMD3<Float>($0) }, coordinates: coordinates.map { SIMD2(Float($0.x), Float($0.y)) },
                                triangles: indices.map(UInt32.init))
        return (geometry, mesh)
    }

    /// A bright photo studio round the model, as an equirectangular picture (the desktop's duoStudio.ts): a white room
    /// with white strip lights and a few thin dark lines, so polished metal reads bright with crisp dark lines along its
    /// rounded edges, as the device's frame does.
    private static func studio() -> UIImage {
        let size = CGSize(width: 2048, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [UIColor(white: 0.98, alpha: 1).cgColor, UIColor(white: 0.89, alpha: 1).cgColor,
                          UIColor(white: 0.63, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            func band(_ rect: CGRect, _ white: CGFloat) {
                cg.setFillColor(UIColor(white: white, alpha: 1).cgColor)
                cg.fill(rect)
            }
            let w = size.width, h = size.height
            for y in [0.30, 0.42, 0.62] { band(CGRect(x: 0, y: h * y, width: w, height: h * 0.02), 0.06) }
            for x in [0.07, 0.33, 0.47, 0.72] { band(CGRect(x: w * x, y: h * 0.12, width: w * 0.016, height: h * 0.6), 0.08) }
            band(CGRect(x: 0, y: h * 0.05, width: w, height: h * 0.04), 1)
            for x in [0.22, 0.60, 0.90] { band(CGRect(x: w * x, y: h * 0.12, width: w * 0.03, height: h * 0.36), 1) }
            band(CGRect(x: 0, y: h * 0.495, width: w, height: h * 0.01), 1)
        }
    }

    /// Leaves out of the model's geometry any element with nothing to draw: SceneKit on iOS reads some of the file's
    /// material subsets as elements without a triangle, and Metal refuses the empty index buffer such an element asks
    /// for (an assertion on a device, where Metal validates).
    private static func dropEmptyElements(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            let elements = geometry.elements
            let kept = elements.indices.filter { elements[$0].primitiveCount > 0 && !elements[$0].data.isEmpty }
            guard kept.count != elements.count else { return }
            #if DEBUG
            print("DuoStage: \(node.name ?? "-") drops \(elements.count - kept.count) empty of \(elements.count) elements")
            #endif
            guard !kept.isEmpty else { node.geometry = nil; return }
            let materials = geometry.materials
            let rebuilt = SCNGeometry(sources: geometry.sources, elements: kept.map { elements[$0] })
            rebuilt.name = geometry.name
            if !materials.isEmpty { rebuilt.materials = kept.map { materials[$0 % materials.count] } }
            node.geometry = rebuilt
        }
    }

    /// The model's metal as polished metal, whatever the file's preview surface said: the frame, keys, lens rings,
    /// camera plate and spine.
    private static func polish(_ root: SCNNode, light: Bool) {
        root.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] {
                let name = material.name ?? ""
                let roughness: CGFloat
                switch name {
                case let n where n.hasPrefix("Frame") || n.hasPrefix("LensRing") || n.hasPrefix("CameraKey"): roughness = 0.05
                case let n where n.hasPrefix("CameraPlate"): roughness = 0.16
                default: continue
                }
                material.lightingModel = .physicallyBased
                material.metalness.contents = 1.0
                material.roughness.contents = roughness
                // The light finish's silver champagne (the desktop's DUO_METAL_LIGHT).
                if light, !name.hasPrefix("CameraPlate") {
                    material.diffuse.contents = UIColor(red: 0.85, green: 0.84, blue: 0.81, alpha: 1)
                }
            }
        }
    }
}

/// CADisplayLink holds its target: this holds the stage weakly instead.
@MainActor private final class DisplayTarget: NSObject {
    weak var stage: DuoStage?

    init(_ stage: DuoStage) { self.stage = stage }

    @objc func tick() { stage?.tick() }
}
