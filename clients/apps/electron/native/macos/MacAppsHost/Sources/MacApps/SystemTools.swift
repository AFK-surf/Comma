import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import IOKit.ps
import MCP
import Network

enum SystemTools {
    static let all: [ToolDefinition] = [status, setVolume, setMute, setAppearance, openApp]

    static let status = ToolDefinition(
        app: .system,
        name: "get_status",
        title: "Mac status",
        description: "Reports this Mac's battery, output volume, light or dark appearance and network connection.",
        inputSchema: Schema.object(),
        readOnly: true
    ) { _, _ in
        let output = OutputDevice.current()
        let network = await NetworkState.current()
        return [
            "battery": Battery.current(),
            "volume": output.flatMap { $0.volume() }.map { .int(Int(($0 * 100).rounded())) } ?? .null,
            "muted": output.flatMap { $0.muted() }.map { .bool($0) } ?? .null,
            "appearance": .string(UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? "dark" : "light"),
            "network": network,
        ]
    }

    static let setVolume = ToolDefinition(
        app: .system,
        name: "set_volume",
        title: "Set volume",
        description: "Sets this Mac's output volume, from 0 to 100.",
        inputSchema: Schema.object([
            "volume": Schema.integer("0 to 100.", minimum: 0, maximum: 100),
        ], required: ["volume"]),
        readOnly: false
    ) { arguments, _ in
        let volume = try arguments.int("volume", in: 0...100) ?? 0
        guard let device = OutputDevice.current() else {
            throw ToolFailure("unavailable", "This Mac has no audio output.")
        }
        try device.setVolume(Float32(volume) / 100)
        return ["volume": .int(volume)]
    }

    static let setMute = ToolDefinition(
        app: .system,
        name: "set_mute",
        title: "Mute",
        description: "Mutes or unmutes this Mac's audio output.",
        inputSchema: Schema.object([
            "muted": Schema.boolean("true to mute."),
        ], required: ["muted"]),
        readOnly: false
    ) { arguments, _ in
        guard let muted = try arguments.bool("muted") else {
            throw ToolFailure.invalidArguments("muted", "muted is required.")
        }
        guard let device = OutputDevice.current() else {
            throw ToolFailure("unavailable", "This Mac has no audio output.")
        }
        try device.setMuted(muted)
        return ["muted": .bool(muted)]
    }

    static let setAppearance = ToolDefinition(
        app: .system,
        name: "set_appearance",
        title: "Light or dark",
        description: "Switches this Mac between light and dark appearance.",
        inputSchema: Schema.object([
            "appearance": Schema.string("The appearance to use.", enum: ["light", "dark"]),
        ], required: ["appearance"]),
        readOnly: false,
        requirements: [.automation(BundleID.systemEvents)]
    ) { arguments, context in
        let appearance = try arguments.choice("appearance", ["light", "dark"], default: "light")
        _ = try await context.appleScript.call(
            Scripts.systemEvents, "set_dark_mode", [.flag(appearance == "dark")], target: BundleID.systemEvents)
        return ["appearance": .string(appearance)]
    }

    static let openApp = ToolDefinition(
        app: .system,
        name: "open_app",
        title: "Open app",
        description: "Opens an app on this Mac by name (\"Safari\") or bundle identifier (\"com.apple.Safari\").",
        inputSchema: Schema.object([
            "app": Schema.string("App name or bundle identifier."),
        ], required: ["app"]),
        readOnly: false
    ) { arguments, _ in
        let name = try arguments.requiredString("app")
        guard let url = applicationURL(name) else {
            throw ToolFailure.notFound("No app named \(name) is installed on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return [
            "opened": .bool(true),
            "name": .optional(app.localizedName),
            "bundle_id": .optional(app.bundleIdentifier),
        ]
    }

    static func applicationURL(_ name: String) -> URL? {
        if name.contains("."), !name.lowercased().hasSuffix(".app"),
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
        {
            return url
        }
        let wanted = (name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name).lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            "\(home)/Applications",
        ]
        for folder in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            if let match = entries.first(where: { $0.lowercased() == wanted + ".app" }) {
                return URL(fileURLWithPath: folder).appendingPathComponent(match)
            }
        }
        return nil
    }
}

enum Battery {
    static func current() -> Value {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .null }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            return [
                "percent": .int(current * 100 / maximum),
                "charging": .bool(description[kIOPSIsChargingKey] as? Bool ?? false),
                "on_power_adapter": .bool(description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue),
            ]
        }
        return .null  // A desktop Mac has no battery.
    }
}

struct OutputDevice {
    let id: AudioObjectID

    static func current() -> OutputDevice? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? OutputDevice(id: device) : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    func volume() -> Float32? {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    func muted() -> Bool? {
        var address = Self.address(kAudioDevicePropertyMute)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    func setVolume(_ level: Float32) throws {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = max(0, min(1, level))
        try set(&address, &value, "volume")
        if level > 0, muted() == true { try setMuted(false) }
    }

    func setMuted(_ muted: Bool) throws {
        var address = Self.address(kAudioDevicePropertyMute)
        var value = UInt32(muted ? 1 : 0)
        try set(&address, &value, "mute")
    }

    private func set<T: BitwiseCopyable>(_ address: inout AudioObjectPropertyAddress, _ value: inout T, _ name: String) throws {
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else {
            throw ToolFailure("unavailable", "The current audio output does not allow changing its \(name).")
        }
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
        guard status == noErr else {
            throw ToolFailure("app_error", "The \(name) could not be changed (\(status)).")
        }
    }
}

enum NetworkState {
    static func current() async -> Value {
        let monitor = NWPathMonitor()
        let path: NWPath? = await withCheckedContinuation { continuation in
            let once = Once()
            monitor.pathUpdateHandler = { path in
                if once.claim() { continuation.resume(returning: path) }
            }
            monitor.start(queue: DispatchQueue(label: "mac-apps.network"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
        monitor.cancel()
        guard let path else { return .null }
        let kinds: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.wiredEthernet, "ethernet"), (.cellular, "cellular"), (.other, "other"),
        ]
        return [
            "connected": .bool(path.status == .satisfied),
            "interfaces": .array(kinds.filter { path.usesInterfaceType($0.0) }.map { .string($0.1) }),
            "expensive": .bool(path.isExpensive),
            "constrained": .bool(path.isConstrained),
        ]
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
