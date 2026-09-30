import Foundation

/// Hand-rolled argv → `ForegroundCommand` parser, matching the style of
/// `ComputerUseCLI.parse` so both modes feel consistent on the command
/// line. Each action's flag list lives next to its case so the help text
/// can be regenerated without scanning the whole file.
public enum ForegroundParser {
    public static let usage = """
    foreground actions:
      click --x <px> --y <px> [--button left|right|middle] [--count 1|2|3]
      mouse-down --x <px> --y <px> [--button left|right|middle]
      mouse-up --x <px> --y <px> [--button left|right|middle]
      mouse-move --x <px> --y <px>
      drag --from-x <px> --from-y <px> --to-x <px> --to-y <px> [--button left|right|middle]
      type-text --text <text>
      press-key --key <combo>
      hold-key --key <combo> --seconds <n>
      scroll --x <px> --y <px> --direction <up|down|left|right> [--amount <n>]
      wait --seconds <n>
      screenshot
      screen-size
      cursor-position
      list-applications
      list-windows
      focus --app <name-or-bundle-id>
      zoom --x1 <px> --y1 <px> --x2 <px> --y2 <px>
      thinking --text <message>
    """

    /// Help text rendered for agents coming in through the ComputerUse tool.
    /// The bridge translates the agent's {action, args} JSON into CLI argv
    /// so the keys on this list use snake_case (what the agent writes) while
    /// the CLI help above uses kebab-case (what the CLI user types).
    public static let agentUsage = """
    foreground mode actions. Call ComputerUse(action=<name>, thinking=<short step>, args={<key>: <value>, …}):

    Thinking updates
      Be proactive: pass top-level thinking in the same ComputerUse call as
      every desktop-changing action (click, drag, type-text, press-key,
      hold-key, scroll, focus) and every wait or inspection step:
        ComputerUse(action="click", thinking="<short next step>", args={...})
      Keep text to one concise sentence describing the immediate next step.
      Use action=thinking only when you need to update the HUD without
      performing another action.

    Interaction
      click                x:int, y:int, button?:"left"|"right"|"middle", count?:1|2|3
      mouse-down           x:int, y:int, button?
      mouse-up             x:int, y:int, button?
      mouse-move           x:int, y:int
      drag                 from_x:int, from_y:int, to_x:int, to_y:int, button?
      type-text            text:string
      press-key            key:string (e.g. "cmd+c", "return", "f11")
      hold-key             key:string, seconds:number
      scroll               x:int, y:int, direction:"up"|"down"|"left"|"right", amount?:int
      wait                 seconds:number

    Inspection
      screenshot           (no args) — returns image; coordinates in this
                           image are what click/drag should use.
      zoom                 x1:int, y1:int, x2:int, y2:int — returns a zoomed
                           crop of the same image space.
      screen-size          (no args)
      cursor-position      (no args)
      list-applications    (no args)
      list-windows         (no args)
      focus                app:string — bundle id or localized name.

    Other
      thinking             text:string — updates the on-screen HUD without
                           touching the desktop.

    Coordinate model: x/y are screenshot image-space integers. Always
    screenshot before acting; the HUD dim mask and cursor hiding come up
    automatically on start.
    """

    public static func parse(_ args: [String]) throws -> ForegroundCommand {
        guard let head = args.first else {
            throw ForegroundCLIError.missingSubcommand
        }
        if head == "--help" || head == "-h" {
            throw ForegroundCLIError.helpRequested(usage)
        }
        let rest = Array(args.dropFirst())

        switch head {
        case "click":
            let x = try requireDouble(rest, flag: "--x")
            let y = try requireDouble(rest, flag: "--y")
            let button = optionalString(rest, flag: "--button")
                .flatMap(ForegroundCommand.MouseButton.init(rawValue:)) ?? .left
            let count = optionalInt(rest, flag: "--count") ?? 1
            return .click(x: x, y: y, button: button, count: count)
        case "mouse-down":
            let x = try requireDouble(rest, flag: "--x")
            let y = try requireDouble(rest, flag: "--y")
            let button = optionalString(rest, flag: "--button")
                .flatMap(ForegroundCommand.MouseButton.init(rawValue:)) ?? .left
            return .mouseDown(x: x, y: y, button: button)
        case "mouse-up":
            let x = try requireDouble(rest, flag: "--x")
            let y = try requireDouble(rest, flag: "--y")
            let button = optionalString(rest, flag: "--button")
                .flatMap(ForegroundCommand.MouseButton.init(rawValue:)) ?? .left
            return .mouseUp(x: x, y: y, button: button)
        case "mouse-move":
            return try .mouseMove(
                x: requireDouble(rest, flag: "--x"),
                y: requireDouble(rest, flag: "--y")
            )
        case "drag":
            let fromX = try requireDouble(rest, flag: "--from-x")
            let fromY = try requireDouble(rest, flag: "--from-y")
            let toX = try requireDouble(rest, flag: "--to-x")
            let toY = try requireDouble(rest, flag: "--to-y")
            let button = optionalString(rest, flag: "--button")
                .flatMap(ForegroundCommand.MouseButton.init(rawValue:)) ?? .left
            return .drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY, button: button)
        case "type-text":
            return try .typeText(text: requireString(rest, flag: "--text"))
        case "press-key":
            return try .pressKey(combo: requireString(rest, flag: "--key"))
        case "hold-key":
            return try .holdKey(
                combo: requireString(rest, flag: "--key"),
                seconds: requireDouble(rest, flag: "--seconds")
            )
        case "scroll":
            let x = try requireDouble(rest, flag: "--x")
            let y = try requireDouble(rest, flag: "--y")
            let dirRaw = try requireString(rest, flag: "--direction")
            guard let direction = ForegroundCommand.ScrollDirection(rawValue: dirRaw) else {
                throw ForegroundCLIError.invalidValue(flag: "--direction", value: dirRaw)
            }
            let amount = optionalInt(rest, flag: "--amount") ?? 3
            return .scroll(x: x, y: y, direction: direction, amount: amount)
        case "wait":
            return try .wait(seconds: requireDouble(rest, flag: "--seconds"))
        case "screenshot":
            return .screenshot
        case "screen-size":
            return .screenSize
        case "cursor-position":
            return .cursorPosition
        case "list-applications":
            return .listApplications
        case "list-windows":
            return .listWindows
        case "focus":
            return try .focus(app: requireString(rest, flag: "--app"))
        case "zoom":
            return try .zoom(
                x1: requireDouble(rest, flag: "--x1"),
                y1: requireDouble(rest, flag: "--y1"),
                x2: requireDouble(rest, flag: "--x2"),
                y2: requireDouble(rest, flag: "--y2")
            )
        case "thinking":
            return try .thinking(text: requireString(rest, flag: "--text"))
        default:
            throw ForegroundCLIError.unknownSubcommand(head)
        }
    }

    // MARK: - Flag helpers

    private static func optionalString(_ args: [String], flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex else {
            return nil
        }
        return args[args.index(after: i)]
    }

    private static func requireString(_ args: [String], flag: String) throws -> String {
        guard let v = optionalString(args, flag: flag) else {
            throw ForegroundCLIError.missingValue(flag)
        }
        return v
    }

    private static func optionalDouble(_ args: [String], flag: String) -> Double? {
        optionalString(args, flag: flag).flatMap(Double.init)
    }

    private static func requireDouble(_ args: [String], flag: String) throws -> Double {
        let raw = try requireString(args, flag: flag)
        guard let value = Double(raw) else {
            throw ForegroundCLIError.invalidValue(flag: flag, value: raw)
        }
        return value
    }

    private static func optionalInt(_ args: [String], flag: String) -> Int? {
        optionalString(args, flag: flag).flatMap(Int.init)
    }
}
