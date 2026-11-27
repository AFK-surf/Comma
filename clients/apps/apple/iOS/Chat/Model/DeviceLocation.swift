import CoreLocation
import Foundation
import Observation

/// This device's position, read once: when the person chooses to share it, which asks the system's location permission
/// first, or for `AgentLocationAnswers` once the system allows it. The person may grant only an approximate position.
/// Nothing here keeps a position.
@MainActor
final class DeviceLocation: NSObject, CLLocationManagerDelegate {
    struct Position: Sendable {
        let latitude: Double
        let longitude: Double
        let accuracy: Double?
    }

    enum Failure: Error { case denied, unavailable }

    /// Whether the system lets this app read a position, so a read asks nothing.
    static var allowed: Bool {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<Position, Error>?

    /// The position now, within the system's own bound on one read.
    func read() async throws -> Position {
        try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
            advance()
        }
    }

    /// Reads once allowed, asks while undecided, fails when refused.
    private func advance() {
        guard waiting != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: finish(.failure(Failure.denied))
        }
    }

    private func finish(_ result: Result<Position, Error>) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(with: result)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { advance() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let position = Position(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                accuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil)
        MainActor.assumeIsolated { finish(.success(position)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated { finish(.failure(denied ? Failure.denied : Failure.unavailable)) }
    }
}

/// Answers the location requests the person's own messages led to while the app is open (the core's
/// `agentLocationRequests`, in any conversation): while the person shares their location (Settings › Share location, or
/// Always share on a card) and the system allows it, the phone sends its position and the person is not asked. Otherwise,
/// or when the position cannot be read, the request stays on its card, which asks them. Nothing here keeps a position.
@MainActor @Observable
final class AgentLocationAnswers {
    private struct Own: Sendable {
        let id: String
        let group: String
        let conversation: String
    }

    /// The requests this phone is reading its position for now: their cards only say so.
    private(set) var reading: Set<String> = []

    @ObservationIgnored private let core: any CoreAPI
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var tried: Set<String> = []
    /// The requests still waiting, as the core last said.
    @ObservationIgnored private var waiting: [Own] = []
    /// Whether the person shares their location now.
    @ObservationIgnored private let shared: () -> Bool

    init(core: any CoreAPI, shared: @escaping () -> Bool) {
        self.core = core
        self.shared = shared
    }

    /// Sharing was turned on or off: a request still waiting may be answered now.
    func sharingChanged() {
        for request in waiting { answer(request) }
    }

    func setForeground(_ visible: Bool) {
        guard visible else {
            following?.cancel()
            following = nil
            // Back in the app, a request still waiting is tried again.
            tried = []
            return
        }
        guard following == nil else { return }
        let updates = core.subscribe(["topic": "agentLocationRequests"], read: Self.requests)
        following = Task { [weak self] in
            for await value in updates {
                guard let self else { return }
                guard case .value(let requests) = value else { continue }
                self.tried.formIntersection(requests.map(\.id))
                self.waiting = requests
                for request in requests { self.answer(request) }
            }
        }
    }

    private func answer(_ request: Own) {
        guard shared(), DeviceLocation.allowed, tried.insert(request.id).inserted else { return }
        reading.insert(request.id)
        Task {
            defer { reading.remove(request.id) }
            // Sharing may have been turned off while the phone read its position.
            guard let position = try? await DeviceLocation().read(), shared() else { return }
            var params: [String: Any] = ["group": request.group, "conversation": request.conversation,
                                         "request": request.id, "latitude": position.latitude,
                                         "longitude": position.longitude]
            if let accuracy = position.accuracy { params["accuracy"] = accuracy }
            // Answered elsewhere or refused: the card shows how it stands.
            _ = try? await core.call("agentRequests.shareLocation", params)
        }
    }

    private nonisolated static func requests(_ value: Any?) -> [Own] {
        (value as? NSDictionary)?.objects("requests").compactMap { json in
            guard let id = json["id"] as? String, let group = json["group"] as? String,
                  let conversation = json["conversation"] as? String else { return nil }
            return Own(id: id, group: group, conversation: conversation)
        } ?? []
    }
}

/// Settings › Share location: while it is on and the app is in front, this phone follows its position and gives each
/// reading to the core (`locationSharing.report`), which sends the newest with each message. Leaving the front gives
/// the core `null`, so no position outlives the time the phone could follow the person. Turning it on asks the
/// system's permission first and stays off when the person refuses.
@MainActor @Observable
final class LocationSharing: NSObject, CLLocationManagerDelegate {
    /// The core's `locationSharing` value; nil until it is read.
    private(set) var enabled: Bool?
    /// The system refused Comma location: the row says where to allow it.
    private(set) var denied = false

    @ObservationIgnored private let core: any CoreAPI
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var updating = false
    /// Told each time [enabled] changes.
    @ObservationIgnored var onChange: (() -> Void)?

    init(core: any CoreAPI) {
        self.core = core
        super.init()
        manager.delegate = self
        // A neighbourhood is enough for "nearby"; the phone wakes the radio only as the person moves.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
    }

    func setForeground(_ visible: Bool) {
        foreground = visible
        if visible, following == nil {
            let updates = core.subscribe(["topic": "locationSharing"]) { ($0 as? NSDictionary)?["enabled"] as? Bool }
            following = Task { [weak self] in
                for await value in updates {
                    guard let self, case .value(let on) = value else { continue }
                    self.enabled = on ?? false
                    self.follow()
                    self.onChange?()
                }
            }
        } else if !visible {
            following?.cancel()
            following = nil
        }
        follow()
    }

    /// The person's switch. On asks the system first; a refusal leaves it off.
    func set(_ on: Bool) async {
        denied = false
        if on {
            do { _ = try await DeviceLocation().read() } catch DeviceLocation.Failure.denied {
                denied = true
                return
            } catch {}
        }
        enabled = on
        _ = try? await core.call("locationSharing.set", ["enabled": on])
        follow()
        onChange?()
    }

    /// Follows the position exactly while sharing is on, the system allows it and the app is in front.
    private func follow() {
        let want = foreground && enabled == true && DeviceLocation.allowed
        guard want != updating else { return }
        updating = want
        if want {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
            report(nil)
        }
    }

    private func report(_ location: CLLocation?) {
        var params: [String: Any] = ["position": NSNull()]
        if let location {
            var position: [String: Any] = [
                "latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude,
                "readAt": Int((location.timestamp.timeIntervalSince1970 * 1000).rounded()),
            ]
            if location.horizontalAccuracy >= 0 { position["accuracy"] = location.horizontalAccuracy }
            params["position"] = position
        }
        Task { _ = try? await core.call("locationSharing.report", params) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { if updating { report(location) } }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { follow() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
