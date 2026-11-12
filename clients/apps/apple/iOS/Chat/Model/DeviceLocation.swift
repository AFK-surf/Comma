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
/// `agentLocationRequests`, in any conversation): with location allowed in the system, the phone sends its position and
/// the person is not asked. A request that cannot be read stays on its card, which asks them. Nothing here keeps a
/// position.
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

    init(core: any CoreAPI) { self.core = core }

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
                for request in requests { self.answer(request) }
            }
        }
    }

    private func answer(_ request: Own) {
        guard DeviceLocation.allowed, tried.insert(request.id).inserted else { return }
        reading.insert(request.id)
        Task {
            defer { reading.remove(request.id) }
            guard let position = try? await DeviceLocation().read() else { return }
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
