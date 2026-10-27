import AppKit
import Foundation

/// An argument passed to an AppleScript handler as an Apple Event descriptor,
/// never spliced into script source.
enum ScriptArgument {
    case text(String)
    case integer(Int)
    case flag(Bool)
    case texts([String])

    var descriptor: NSAppleEventDescriptor {
        switch self {
        case let .text(value): return NSAppleEventDescriptor(string: value)
        case let .integer(value): return NSAppleEventDescriptor(int32: Int32(clamping: value))
        case let .flag(value): return NSAppleEventDescriptor(boolean: value)
        case let .texts(values):
            let list = NSAppleEventDescriptor.list()
            for (index, value) in values.enumerated() {
                list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
            }
            return list
        }
    }
}

/// A plain value read back from an AppleScript result.
enum ScriptValue {
    case text(String)
    case number(Double)
    case flag(Bool)
    case date(Date)
    case list([ScriptValue])
    case missing

    var text: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var number: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    var flag: Bool? {
        if case let .flag(value) = self { return value }
        return nil
    }

    var date: Date? {
        if case let .date(value) = self { return value }
        return nil
    }

    var list: [ScriptValue] {
        if case let .list(values) = self { return values }
        return []
    }

    subscript(index: Int) -> ScriptValue {
        let values = list
        return values.indices.contains(index) ? values[index] : .missing
    }

    init(_ descriptor: NSAppleEventDescriptor) {
        switch descriptor.descriptorType {
        case FourCC.list:
            self = .list((0..<descriptor.numberOfItems).map { index in
                descriptor.atIndex(index + 1).map(ScriptValue.init) ?? .missing
            })
        case FourCC.true: self = .flag(true)
        case FourCC.false: self = .flag(false)
        case FourCC.boolean: self = .flag(descriptor.booleanValue)
        case FourCC.sInt16, FourCC.sInt32: self = .number(Double(descriptor.int32Value))
        case FourCC.sInt64, FourCC.float64, FourCC.float32:
            self = .number(descriptor.doubleValue)
        case FourCC.longDateTime: self = descriptor.dateValue.map(ScriptValue.date) ?? .missing
        case FourCC.null: self = .missing
        case FourCC.type where descriptor.typeCodeValue == FourCC.missingValue: self = .missing
        default: self = descriptor.stringValue.map(ScriptValue.text) ?? .missing
        }
    }
}

enum FourCC {
    static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    static let list = code("list")
    static let `true` = code("true")
    static let `false` = code("fals")
    static let boolean = code("bool")
    static let sInt16 = code("shor")
    static let sInt32 = code("long")
    static let sInt64 = code("comp")
    static let float64 = code("doub")
    static let float32 = code("sing")
    static let longDateTime = code("ldt ")
    static let null = code("null")
    static let type = code("type")
    static let missingValue = code("msng")
    static let appleScriptSuite = code("ascr")
    static let subroutineEvent = code("psbr")
    static let subroutineName = code("snam")
    static let directObject = code("----")
}

/// Runs AppleScript handlers against one app. The app is opened in the background
/// when needed, and the call is refused, not prompted, when Comma lacks Automation
/// permission for it. NSAppleScript is used from the main thread only.
final class AppleScriptRunner: @unchecked Sendable {
    @MainActor private var compiled: [String: NSAppleScript] = [:]

    /// Calls `handler` in `source`, a script whose handlers address `bundleID`.
    /// With `launch: false`, a closed app is reported as `app_not_running`.
    func call(
        _ source: String,
        _ handler: String,
        _ arguments: [ScriptArgument] = [],
        target bundleID: String,
        launch: Bool = true
    ) async throws -> ScriptValue {
        if !TargetApp.isRunning(bundleID) {
            guard launch else {
                throw ToolFailure("app_not_running", "The app is not open on this Mac.")
            }
            try await TargetApp.launch(bundleID)
        }
        let state = Automation.state(bundleID, ask: false)
        guard state == .granted else {
            if state == .unknown {
                throw ToolFailure("app_unavailable", "The app \(bundleID) is not answering.")
            }
            throw ToolFailure.permissionRequired(.automation(bundleID), state)
        }
        do {
            return try await execute(source, handler, arguments)
        } catch let failure as ToolFailure where failure.code == "permission_required" {
            throw ToolFailure.permissionRequired(.automation(bundleID), .denied)
        }
    }

    @MainActor
    func execute(_ source: String, _ handler: String, _ arguments: [ScriptArgument]) throws -> ScriptValue {
        // A call waits here while another script holds the main thread. When its
        // deadline passed meanwhile (withDeadline), its caller was already told
        // it timed out: it does not send a message or make a change after that.
        if Task.isCancelled {
            throw ToolFailure("timeout", "This Mac did not start the call in time. Nothing was changed.")
        }
        let script = try compile(source)
        let event = NSAppleEventDescriptor(
            eventClass: FourCC.appleScriptSuite,
            eventID: FourCC.subroutineEvent,
            targetDescriptor: .null(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: FourCC.subroutineName)
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            parameters.insert(argument.descriptor, at: index + 1)
        }
        event.setParam(parameters, forKeyword: FourCC.directObject)

        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw Self.failure(error) }
        return ScriptValue(result)
    }

    @MainActor
    func compile(_ source: String) throws -> NSAppleScript {
        if let script = compiled[source] { return script }
        guard let script = NSAppleScript(source: source) else {
            throw ToolFailure("app_error", "The AppleScript could not be created.")
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            throw ToolFailure("app_error", "The AppleScript did not compile: \(Self.message(error))")
        }
        compiled[source] = script
        return script
    }

    private static func failure(_ error: NSDictionary) -> ToolFailure {
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let message = Self.message(error)
        switch number {
        case -1743:
            return ToolFailure(
                "permission_required",
                "Comma does not have macOS Automation permission for this app. Ask the user to allow it in Comma > Plugins on this Mac.",
                details: ["state": "denied"])
        case -1728, -1719:
            return ToolFailure.notFound(message)
        case -1712:
            return ToolFailure("timeout", "The app did not answer in time. A change may or may not have been made.")
        default:
            return ToolFailure("app_error", message, details: ["script_error": .int(number)])
        }
    }

    private static func message(_ error: NSDictionary?) -> String {
        (error?[NSAppleScript.errorMessage] as? String) ?? "The app returned an error."
    }
}
