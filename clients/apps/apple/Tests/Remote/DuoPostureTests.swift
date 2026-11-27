import simd
import XCTest
@testable import Comma

/// The iPhone Duo's 3D stage: where a point of a screen's mesh is in the station's picture (and back), how the hinge's
/// strip bends, and how the model moves between postures.
final class DuoPostureTests: XCTestCase {
    private func assertClose(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, message, file: file, line: line)
    }

    func testCoverFramebufferLiesOnItsMeshUpright() {
        // Mesh (s 0: the hinge, t 0: the device's top) is the closed device's picture as it is.
        assertClose(DuoPicture.fraction(SIMD2(0, 0), screen: .cover, turn: 0), SIMD2(0, 0))
        assertClose(DuoPicture.fraction(SIMD2(1, 1), screen: .cover, turn: 0), SIMD2(1, 1))
        // Turned a quarter clockwise, the hinge's top corner is the picture's top right.
        assertClose(DuoPicture.fraction(SIMD2(0, 0), screen: .cover, turn: 90), SIMD2(1, 0))
    }

    func testInnerFramebufferTopIsTheCameraHalfAndItsRightTheDeviceBottom() {
        // The cover half's edge (s 0) at the device's top (t 0): the picture's bottom left.
        assertClose(DuoPicture.fraction(SIMD2(0, 0), screen: .inner, turn: 0), SIMD2(0, 1))
        // The camera half's edge (s 1) at the device's bottom (t 1): the picture's top right.
        assertClose(DuoPicture.fraction(SIMD2(1, 1), screen: .inner, turn: 0), SIMD2(1, 0))
    }

    func testMeshPointUndoesFractionAndTheTextureTransformAgrees() {
        let points = [SIMD2(0.1, 0.2), SIMD2(0.9, 0.35), SIMD2(0.5, 0.5), SIMD2(0.02, 0.97)]
        for screen in [DuoPosture.Screen.cover, .inner] {
            for turn in [0, 90, 180, 270] {
                let map = DuoPicture.transform(screen: screen, turn: turn)
                for p in points {
                    let at = DuoPicture.fraction(p, screen: screen, turn: turn)
                    assertClose(DuoPicture.meshPoint(at, screen: screen, turn: turn), p, "\(screen) \(turn)")
                    let mapped = map * SIMD4(Float(p.x), Float(p.y), 0, 1)
                    XCTAssertEqual(Double(mapped.x), at.x, accuracy: 1e-6)
                    XCTAssertEqual(Double(mapped.y), at.y, accuracy: 1e-6)
                }
            }
        }
    }

    func testTurnFollowsThePictureShapeAndTheStationsWay() {
        XCTAssertEqual(DuoPicture.turn(orientation: 270, picture: CGSize(width: 2034, height: 1398)), 270)
        XCTAssertEqual(DuoPicture.turn(orientation: nil, picture: CGSize(width: 2034, height: 1398)), 90)
        // The state said a turn before the picture came turned: the picture's shape decides.
        XCTAssertEqual(DuoPicture.turn(orientation: 90, picture: CGSize(width: 1398, height: 2034)), 0)
        XCTAssertEqual(DuoPicture.turn(orientation: 180, picture: CGSize(width: 1398, height: 2034)), 180)
        XCTAssertEqual(DuoPicture.turn(orientation: 90, picture: .zero), 90)
    }

    func testPostureShownFollowsTheStation() {
        let all = DuoPosture.all
        XCTAssertEqual(DuoPosture.standing(pose: "closed", turn: 0, of: all)?.id, "coverPortrait")
        XCTAssertEqual(DuoPosture.standing(pose: "closed", turn: 270, of: all)?.id, "coverLandscape")
        XCTAssertEqual(DuoPosture.standing(pose: "open", turn: 90, of: all)?.id, "innerLandscape")
        XCTAssertEqual(DuoPosture.standing(pose: "book", turn: 0, of: all)?.id, "innerPortrait")
        XCTAssertNil(DuoPosture.standing(pose: nil, turn: 0, of: all))
        // Where the station says the hinge, it tells a laptop from an open device held portrait, a tent from a cover
        // held landscape: chosen on another client, shown here too.
        XCTAssertEqual(DuoPosture.standing(pose: "open", turn: 0, hinge: 105, of: all)?.id, "laptop")
        XCTAssertEqual(DuoPosture.standing(pose: "open", turn: 0, hinge: 180, of: all)?.id, "innerPortrait")
        XCTAssertEqual(DuoPosture.standing(pose: "closed", turn: 90, hinge: 75, of: all)?.id, "tent")
        XCTAssertEqual(DuoPosture.standing(pose: "closed", turn: 90, hinge: 0, of: all)?.id, "coverLandscape")
        // A tent is a closed device in landscape; a laptop an open one in portrait.
        XCTAssertTrue(all[2].matches(pose: "closed", turn: 90))
        XCTAssertFalse(all[2].matches(pose: "open", turn: 90))
        XCTAssertTrue(all[3].matches(pose: "open", turn: 0))
    }

    func testPostureReadsTheCoresRow() {
        let row: NSDictionary = ["id": "tent", "screen": "cover", "opening": 75, "stand": "tent", "orientation": 90, "pose": "closed"]
        XCTAssertEqual(DuoPosture(row), DuoPosture.all[2])
        XCTAssertNil(DuoPosture(["id": "tent", "screen": "side"] as NSDictionary))
    }

    func testCreaseKeepsItsLengthAndMeetsBothScreens() {
        let rig = DuoRig.shared
        for opening in [0.0, 30, 75, 105, 150, 180] {
            let (points, length) = rig.crease(opening: opening)
            XCTAssertEqual(points.count, rig.creaseSegments + 1)
            XCTAssertEqual(length, 2 * rig.creaseHalfWidth, accuracy: 0.05, "opening \(opening)")
            // It leaves the camera half's screen where that screen ends.
            XCTAssertEqual(points[0].x, rig.creaseHalfWidth, accuracy: 1e-6)
            XCTAssertEqual(points[0].y, rig.creaseLift, accuracy: 1e-6)
            // Its points are evenly spaced along it, so the picture does not stretch.
            let steps = zip(points, points.dropFirst()).map { simd_distance($0, $1) }
            XCTAssertLessThan((steps.max() ?? 0) - (steps.min() ?? 0), 0.05, "opening \(opening)")
        }
        // Flat, it lies flat across the hinge.
        let flat = rig.crease(opening: 180).points
        XCTAssertEqual(flat.last!.x, -rig.creaseHalfWidth, accuracy: 1e-6)
        XCTAssertEqual(flat.last!.y, rig.creaseLift, accuracy: 1e-6)
    }

    func testRigLoadsTheSpinePathAndInterpolatesIt() {
        let rig = DuoRig.shared
        XCTAssertEqual(rig.spinePath.count, 13)
        let a = rig.spine(at: 90), b = rig.spine(at: 105), mid = rig.spine(at: 97.5)
        XCTAssertEqual(mid.x, (a.x + b.x) / 2, accuracy: 1e-9)
        XCTAssertEqual(mid.z, (a.z + b.z) / 2, accuracy: 1e-9)
        XCTAssertEqual(rig.spine(at: 200), rig.spine(at: 180))
    }

    func testMoveBetweenPosturesEasesEverythingTogether() {
        let a = DuoStagePose.target(DuoPosture.all[0], turn: 0, aspect: 0.5, fieldOfView: 26)
        let b = DuoStagePose.target(DuoPosture.all[3], turn: 0, aspect: 0.5, fieldOfView: 26)
        XCTAssertEqual(DuoStagePose.mix(a, b, 0), a)
        XCTAssertEqual(DuoStagePose.mix(a, b, 1).opening, b.opening)
        let half = DuoStagePose.mix(a, b, 0.5)
        XCTAssertEqual(half.opening, (a.opening + b.opening) / 2, accuracy: 1e-9)
        XCTAssertEqual(half.distance, (a.distance + b.distance) / 2, accuracy: 1e-9)
        // Eased: a quarter of the time moves less than a quarter of the way.
        XCTAssertLessThan(DuoStagePose.mix(a, b, 0.25).opening, a.opening + (b.opening - a.opening) / 4)
    }

    func testPosturesTurnTheirScreenTowardTheViewer() {
        // The cover display lies on the cover half's back (-z), the inner one on both halves' faces (+z), of which one
        // faces the viewer (a laptop's raised camera half); the hinge turns the cover half.
        for posture in DuoPosture.all {
            let rotation = DuoStagePose.rotation(posture, turn: posture.orientation)
            let theta = (180 - posture.opening) * .pi / 180
            let normal = simd_quatd(angle: theta, axis: SIMD3(0, 1, 0)).act(SIMD3(0, 0, posture.screen == .cover ? -1 : 1))
            let facing = posture.screen == .cover ? rotation.act(normal).z : max(rotation.act(normal).z, rotation.act(SIMD3(0, 0, 1)).z)
            XCTAssertGreaterThan(facing, 0.5, posture.id)
        }
        // A tent's hinge is on top: the hinge's axis lies across the view.
        let tent = DuoStagePose.rotation(DuoPosture.all[2], turn: 90).act(SIMD3(0, 1, 0))
        XCTAssertGreaterThan(abs(tent.x), 0.8)
    }

    func testFramingFitsAWiderViewCloser() {
        let narrow = DuoStagePose.target(DuoPosture.all[4], turn: 90, aspect: 0.45, fieldOfView: 26)
        let wide = DuoStagePose.target(DuoPosture.all[4], turn: 90, aspect: 1.8, fieldOfView: 26)
        XCTAssertLessThan(wide.distance, narrow.distance)
    }

    func testTouchMeshFindsTheTextureCoordinatesUnderARay() {
        // A unit square at z 0, its coordinates its position.
        let mesh = DuoTouchMesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
                                coordinates: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)],
                                triangles: [0, 1, 2, 0, 2, 3])
        let hit = mesh.hit(origin: SIMD3(0.25, 0.75, 2), direction: SIMD3(0, 0, -4))
        XCTAssertEqual(hit?.t ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(hit?.st.x ?? -1, 0.25, accuracy: 1e-6)
        XCTAssertEqual(hit?.st.y ?? -1, 0.75, accuracy: 1e-6)
        XCTAssertNil(mesh.hit(origin: SIMD3(1.5, 0.5, 2), direction: SIMD3(0, 0, -1)))
    }

    /// A drag off the screens turns the device a little: close to the finger for small drags, never past 15° left or
    /// right and 10° up or down however far it goes, and back from a limit as soon as the finger turns back.
    func testATiltFollowsSmallDragsAndNeverPassesItsLimits() {
        var raw = DuoTilt.accumulate(.zero, by: CGSize(width: 20, height: -10))
        let small = DuoTilt.angles(raw)
        XCTAssertEqual(small.x, 20 * DuoTilt.degreesPerPoint, accuracy: 0.1)
        XCTAssertEqual(small.y, -10 * DuoTilt.degreesPerPoint, accuracy: 0.1)
        raw = DuoTilt.accumulate(raw, by: CGSize(width: 5000, height: 5000))
        let far = DuoTilt.angles(raw)
        XCTAssertLessThanOrEqual(far.x, DuoTilt.maxYaw)
        XCTAssertLessThanOrEqual(far.y, DuoTilt.maxPitch)
        XCTAssertGreaterThan(far.x, DuoTilt.maxYaw * 0.95)
        let back = DuoTilt.angles(DuoTilt.accumulate(raw, by: CGSize(width: -300, height: 0)))
        XCTAssertLessThan(back.x, far.x - 1)
    }
}
