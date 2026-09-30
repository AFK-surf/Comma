@_exported import CUShared
import Foundation

public enum ComputerUseCLIError: Error, CustomStringConvertible, Equatable {
    case helpRequested
    case missingSubcommand
    case missingValue(String)
    case unknownSubcommand(String)
    case unknownPermissionAction(String)
    case unexpectedArgument(String)
    case invalidInteger(flag: String, value: String)
    case invalidDouble(flag: String, value: String)

    public var description: String {
        switch self {
        case .helpRequested:
            ComputerUseCLI.usage
        case .missingSubcommand:
            "missing subcommand"
        case let .missingValue(flag):
            "missing value for \(flag)"
        case let .unknownSubcommand(command):
            "unknown subcommand: \(command)"
        case let .unknownPermissionAction(action):
            "unknown permissions action: \(action)"
        case let .unexpectedArgument(value):
            "unexpected argument: \(value)"
        case let .invalidInteger(flag, value):
            "invalid integer for \(flag): \(value)"
        case let .invalidDouble(flag, value):
            "invalid number for \(flag): \(value)"
        }
    }
}

public enum PermissionAction: Equatable, Sendable {
    /// Open the unified authorization window in the daemon. Non-blocking —
    /// the CLI returns immediately after the window is requested and the
    /// user drives the flow from there; poll with `.status`.
    case openUI
    /// Report the current TCC status for both required panes.
    case status
}

public enum ComputerUseCLICommand: Equatable {
    case listApps
    case getAppState(app: String, windowTitle: String?)
    case click(snapshotID: String, elementIndex: Int?, x: Double?, y: Double?)
    case typeText(snapshotID: String, text: String, elementIndex: Int?)
    case setValue(snapshotID: String, elementIndex: Int, value: String)
    case pressKey(snapshotID: String, key: String)
    case scroll(snapshotID: String, elementIndex: Int, direction: String, pages: Int)
    case performSecondaryAction(snapshotID: String, elementIndex: Int, action: String)
    case drag(snapshotID: String, fromX: Double, fromY: Double, toX: Double, toY: Double)
    case permissions(PermissionAction)
}

public enum ComputerUseCLI {
    public static let usage = """
    usage:
      <binary> start                                             # start the daemon (.app)
      <binary> stop                                              # stop the running daemon
      <binary> status                                            # report daemon status
      <binary> permissions                                       # open authorization window (non-blocking)
      <binary> permissions status                                # report TCC status for required panes
      <binary> list-apps
      <binary> get-app-state --app <name-or-bundle-id> [--window-title <substring>]
      <binary> click --snapshot-id <id> [--element-index <n> | --x <px> --y <px>]
      <binary> type-text --snapshot-id <id> --text <text> [--element-index <n>]
      <binary> set-value --snapshot-id <id> --element-index <n> --value <value>
      <binary> press-key --snapshot-id <id> --key <combo>
      <binary> scroll --snapshot-id <id> --element-index <n> --direction <up|down|left|right> [--pages <n>]
      <binary> perform-secondary-action --snapshot-id <id> --element-index <n> --action <label>
      <binary> drag --snapshot-id <id> --from-x <px> --from-y <px> --to-x <px> --to-y <px>

    required permissions:
      accessibility, screen-recording

    notes:
      - Action subcommands require the daemon to be running; start it first with `start`.
      - get-app-state writes a snapshot file and screenshot, then returns a new snapshot id.
      - Action commands validate the snapshot fingerprint first; if the UI changed, they fail with a stale-state message.
      - click/drag coordinates are screenshot pixel coordinates from the snapshot image.
    """

    /// Help text rendered for agents coming in through the ComputerUse tool.
    /// Agents call `ComputerUse(action=<name>, args={...})`; the bridge turns
    /// snake_case keys into --kebab-case CLI flags, so this reference uses
    /// the snake_case form the agent sees.
    public static let agentUsage = """
    background mode actions. Call ComputerUse(action=<name>, thinking=<short step>, args={<key>: <value>, …}):

    Progress updates
      Keep progress explicit by passing top-level thinking in the same
      ComputerUse call as each state-changing action. Re-run get-app-state
      so the action uses a fresh snapshot. Background mode has no separate
      HUD thinking action, so do not use action=thinking here.

    Inspection
      list-apps            (no args) — running apps with pid + bundle id.
      get-app-state        app:string (name or bundle id), window_title?:string
                           — captures a snapshot (screenshot + accessibility
                           tree), returns a snapshot_id you reference below.

    Element actions (all require snapshot_id from get-app-state)
      click                snapshot_id:string, element_index?:int
                           OR snapshot_id, x:int, y:int (screenshot coords).
      type-text            snapshot_id, text:string, element_index?:int
      set-value            snapshot_id, element_index:int, value:string
      press-key            snapshot_id, key:string (e.g. "cmd+a")
      scroll               snapshot_id, element_index:int,
                           direction:"up"|"down"|"left"|"right", pages?:int
      perform-secondary-action
                           snapshot_id, element_index:int, action:string
      drag                 snapshot_id, from_x:int, from_y:int, to_x:int,
                           to_y:int

    Workflow
      1. get-app-state to obtain a snapshot_id and its screenshot.
      2. Use the screenshot to locate what you want; prefer element_index
         (resilient to pixel shifts) over raw x/y.
      3. Re-run get-app-state between actions — snapshot_ids become stale
         as soon as the UI changes and actions will reject stale ids.

    Background mode runs alongside the user: no app hiding, no dim mask.
    The user's pointer is untouched; a colored border briefly haloes the
    target window after each action.
    """

    public static func parse(arguments: [String]) throws -> ComputerUseCLICommand {
        guard let subcommand = arguments.first else {
            throw ComputerUseCLIError.missingSubcommand
        }

        if subcommand == "--help" || subcommand == "-h" {
            throw ComputerUseCLIError.helpRequested
        }

        if subcommand == "permissions" {
            return try parsePermissions(positional: Array(arguments.dropFirst()))
        }

        let flags = try parseFlags(arguments: Array(arguments.dropFirst()))

        switch subcommand {
        case "list-apps":
            return .listApps
        case "get-app-state":
            return try .getAppState(
                app: requiredString(flags, "--app"),
                windowTitle: flags["--window-title"]
            )
        case "click":
            let snapshotID = try requiredString(flags, "--snapshot-id")
            let elementIndex = try optionalInt(flags, "--element-index")
            let x = try optionalDouble(flags, "--x")
            let y = try optionalDouble(flags, "--y")
            return .click(snapshotID: snapshotID, elementIndex: elementIndex, x: x, y: y)
        case "type-text":
            return try .typeText(
                snapshotID: requiredString(flags, "--snapshot-id"),
                text: requiredString(flags, "--text"),
                elementIndex: optionalInt(flags, "--element-index")
            )
        case "set-value":
            return try .setValue(
                snapshotID: requiredString(flags, "--snapshot-id"),
                elementIndex: requiredInt(flags, "--element-index"),
                value: requiredString(flags, "--value")
            )
        case "press-key":
            return try .pressKey(
                snapshotID: requiredString(flags, "--snapshot-id"),
                key: requiredString(flags, "--key")
            )
        case "scroll":
            return try .scroll(
                snapshotID: requiredString(flags, "--snapshot-id"),
                elementIndex: requiredInt(flags, "--element-index"),
                direction: requiredString(flags, "--direction"),
                pages: optionalInt(flags, "--pages") ?? 1
            )
        case "perform-secondary-action":
            return try .performSecondaryAction(
                snapshotID: requiredString(flags, "--snapshot-id"),
                elementIndex: requiredInt(flags, "--element-index"),
                action: requiredString(flags, "--action")
            )
        case "drag":
            return try .drag(
                snapshotID: requiredString(flags, "--snapshot-id"),
                fromX: requiredDouble(flags, "--from-x"),
                fromY: requiredDouble(flags, "--from-y"),
                toX: requiredDouble(flags, "--to-x"),
                toY: requiredDouble(flags, "--to-y")
            )
        default:
            throw ComputerUseCLIError.unknownSubcommand(subcommand)
        }
    }

    private static func parsePermissions(positional: [String]) throws -> ComputerUseCLICommand {
        guard let action = positional.first else {
            // `permissions` with no arguments means "open the authorization UI".
            return .permissions(.openUI)
        }

        switch action {
        case "status":
            guard positional.dropFirst().isEmpty else {
                throw ComputerUseCLIError.unexpectedArgument(positional.dropFirst().first ?? "")
            }
            return .permissions(.status)
        default:
            throw ComputerUseCLIError.unknownPermissionAction(action)
        }
    }

    private static func parseFlags(arguments: [String]) throws -> [String: String] {
        var index = 0
        var values: [String: String] = [:]

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw ComputerUseCLIError.unexpectedArgument(argument)
            }
            index += 1

            guard index < arguments.count else {
                throw ComputerUseCLIError.missingValue(argument)
            }

            values[argument] = arguments[index]
            index += 1
        }

        return values
    }

    private static func requiredString(_ flags: [String: String], _ flag: String) throws -> String {
        guard let value = flags[flag], value.isEmpty == false else {
            throw ComputerUseCLIError.missingValue(flag)
        }
        return value
    }

    private static func optionalInt(_ flags: [String: String], _ flag: String) throws -> Int? {
        guard let value = flags[flag] else {
            return nil
        }
        guard let intValue = Int(value) else {
            throw ComputerUseCLIError.invalidInteger(flag: flag, value: value)
        }
        return intValue
    }

    private static func requiredInt(_ flags: [String: String], _ flag: String) throws -> Int {
        guard let value = try optionalInt(flags, flag) else {
            throw ComputerUseCLIError.missingValue(flag)
        }
        return value
    }

    private static func optionalDouble(_ flags: [String: String], _ flag: String) throws -> Double? {
        guard let value = flags[flag] else {
            return nil
        }
        guard let doubleValue = Double(value) else {
            throw ComputerUseCLIError.invalidDouble(flag: flag, value: value)
        }
        return doubleValue
    }

    private static func requiredDouble(_ flags: [String: String], _ flag: String) throws -> Double {
        guard let value = try optionalDouble(flags, flag) else {
            throw ComputerUseCLIError.missingValue(flag)
        }
        return value
    }
}
