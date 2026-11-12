import Foundation
import ObjectiveC
import XPC

/// Keys and hardware buttons through the guest's own `dtuhidd`, the way Device Hub's reach it.
///
/// From CoreSimulator 1155.4 (Xcode 27) the guest drops legacy Indigo keys and buttons while the
/// host's send still succeeds, and a person away from the Mac can neither focus a Device Hub window
/// nor see that nothing arrived. `dtuhidd` needs neither: plain XPC dictionaries to its digitizer
/// service, reached from the simulator's bootstrap namespace. The wire format is Meta idb's
/// (FBSimulatorControl/HID, MIT).
final class DTUHIDKeys {
    private static let service = "com.apple.coredevice.feature.remote.hid.digitizer"
    private static let firstVersion = "1155.4"
    /// The probe's send starts the daemon, so its deadline pays for a cold start.
    private static let probeSeconds = 4.0
    /// After its first answer the daemon still opens its device; events inside this go missing.
    private static let openTailMicros: useconds_t = 200_000
    private static let retrySeconds = 30.0
    private static let down: UInt64 = 1
    private static let up: UInt64 = 2

    private typealias Lookup = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>?) -> mach_port_t
    private typealias EndpointFromPort = @convention(c) (mach_port_t, UInt64, UInt64) -> UnsafeMutableRawPointer?
    private typealias EnableSim2Host = @convention(c) (xpc_connection_t) -> Void

    private let device: AnyObject
    private let queue = DispatchQueue(label: "serve-sim.dtuhid")
    private var connection: xpc_connection_t?
    /// Not before this: a runtime without the daemon (an old one on a new Xcode) is not asked at every key.
    private var retryAt = Date.distantPast

    /// None before CoreSimulator 1155.4, where Indigo is still honoured.
    init?(device: AnyObject) {
        guard Self.supported() else { return nil }
        self.device = device
    }

    static func supported() -> Bool {
        let info = NSDictionary(contentsOfFile: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Info.plist")
        guard let version = info?["CFBundleVersion"] as? String else { return false }
        return version.compare(firstVersion, options: .numeric) != .orderedAscending
    }

    /// A USB HID keyboard usage down or up; false when it could not be sent.
    func sendKey(usage: UInt32, down isDown: Bool) -> Bool {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usageCode", UInt64(usage))
        xpc_dictionary_set_uint64(payload, "state", isDown ? Self.down : Self.up)
        return send("IndigoKeyboardButtonEvent", payload)
    }

    /// A hardware button by its HID usage, down or up; false when it could not be sent.
    func sendButton(page: UInt32, usage: UInt32, down isDown: Bool) -> Bool {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usagePage", UInt64(page))
        xpc_dictionary_set_uint64(payload, "usageCode", UInt64(usage))
        xpc_dictionary_set_uint64(payload, "state", isDown ? Self.down : Self.up)
        return send("IndigoButtonEvent", payload)
    }

    /// One finger's contact, "begin", "move" or "end", at x, y 0..1 of the display `target` (0: the device's main one); false
    /// when it could not be sent.
    func sendTouch(type: String, x: Double, y: Double, edge: UInt32, target: UInt32) -> Bool {
        let point = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(point, "x", x)
        xpc_dictionary_set_double(point, "y", y)
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(payload, "pointOne", point)
        xpc_dictionary_set_uint64(payload, "eventType", type == "begin" ? 0 : type == "move" ? 1 : 2)
        xpc_dictionary_set_uint64(payload, "edge", UInt64(edge))
        xpc_dictionary_set_uint64(payload, "target", UInt64(target))
        return send("IndigoDigitizerEvent", payload)
    }

    private func send(_ type: String, _ payload: xpc_object_t) -> Bool {
        if connection == nil && Date() < retryAt { return false }
        guard let connection = connection ?? connect() else {
            retryAt = Date().addingTimeInterval(Self.retrySeconds)
            return false
        }
        xpc_connection_send_message(connection, Self.envelope(type, payload, barrier: false))
        return true
    }

    private static func envelope(_ type: String, _ payload: xpc_object_t, barrier: Bool) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", barrier)
        xpc_dictionary_set_string(message, "featureIdentifier", service)
        xpc_dictionary_set_value(message, "payload", payload)
        return message
    }

    private func connect() -> xpc_connection_t? {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let endpointSym = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
              let enableSym = dlsym(handle, "xpc_connection_enable_sim2host_4sim") else {
            print("[hid] dtuhidd: this macOS lacks the _4sim XPC symbols")
            return nil
        }
        let selector = NSSelectorFromString("lookup:error:")
        guard let cls = object_getClass(device), let imp = class_getMethodImplementation(cls, selector),
              (device as? NSObject)?.responds(to: selector) == true else {
            print("[hid] dtuhidd: SimDevice cannot look up guest services here")
            return nil
        }
        var error: NSError?
        let port = unsafeBitCast(imp, to: Lookup.self)(device, selector, Self.service as NSString, &error)
        guard port != mach_port_t(MACH_PORT_NULL) else {
            print("[hid] dtuhidd: the simulator does not vend it yet: \(error?.localizedDescription ?? "")")
            return nil
        }
        // The endpoint takes the lookup's send right.
        guard let raw = unsafeBitCast(endpointSym, to: EndpointFromPort.self)(port, 0, 0) else {
            print("[hid] dtuhidd: could not make an endpoint")
            return nil
        }
        let created = xpc_connection_create_from_endpoint(unsafeBitCast(raw, to: xpc_endpoint_t.self))
        // Without the sim-to-host mark the daemon sees the peer but never a payload.
        unsafeBitCast(enableSym, to: EnableSim2Host.self)(created)
        xpc_connection_set_target_queue(created, queue)
        xpc_connection_set_event_handler(created) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR, let self else { return }
            // It forgets what is held; the next key connects again.
            if let current = self.connection, current === created { self.connection = nil }
        }
        xpc_connection_resume(created)
        guard probe(created) else {
            xpc_connection_cancel(created)
            print("[hid] dtuhidd: it did not answer")
            return nil
        }
        usleep(Self.openTailMicros)
        connection = created
        return created
    }

    /// A barrier with usage 0 ("no event"), answered without the guest seeing a key: every step
    /// before it succeeds against a daemon that cannot run, and sends to one report no error.
    private func probe(_ connection: xpc_connection_t) -> Bool {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usageCode", 0)
        xpc_dictionary_set_uint64(payload, "state", Self.up)
        let answered = DispatchSemaphore(value: 0)
        var alive = false
        xpc_connection_send_message_with_reply(connection, Self.envelope("IndigoKeyboardButtonEvent", payload, barrier: true), queue) { reply in
            alive = xpc_get_type(reply) != XPC_TYPE_ERROR
            answered.signal()
        }
        return answered.wait(timeout: .now() + Self.probeSeconds) == .success && alive
    }
}
