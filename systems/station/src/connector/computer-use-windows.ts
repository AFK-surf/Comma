// Computer Use on Windows: Cua Driver (trycua/cua, MIT), which the desktop app carries as native/windows/cua-driver.exe,
// reached over MCP on its stdio. It reads a window through UI Automation and acts on its elements without bringing the
// app to the front where Windows allows it. The agent sees the same background-mode actions as on macOS: a
// get_app_state snapshot names the window, and actions address its elements by index and return the new state.
// Windows takes input sent to a window behind others from fewer apps than macOS does: when the driver reports that a
// background delivery failed, the action is sent once more in the foreground (the window comes to the front for it
// and the driver gives the front back), and the result says so.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { Effect } from "effect";
import type { DaemonResponse } from "./computer-use.ts";

type Result = Record<string, unknown>;
type Args = Record<string, unknown>;

/** What a snapshot remembers: the window it read and its elements, by the index the agent sees. */
type Snapshot = { pid: number; windowId: number; captureId?: string; elements: Map<number, Element> };
type Element = { token: string; actions: string[]; frame?: { x: number; y: number; w: number; h: number } };

// The model's image limits (Anthropic's long edge): the driver scales the screenshot to fit.
const MAX_IMAGE_DIMENSION = 1568;
const SNAPSHOTS_KEPT = 32;
// The agent cursor in the brand blue (clients/apps/electron/native/windows/cua-driver).
const CURSOR_THEME = "comma.brand";

export type WindowsComputerUseDeps = {
  /** The driver's executable. */
  executable: string;
  /** Where the driver keeps its state (CUA_DRIVER_RS_HOME). */
  home: string;
  /** The cursor themes shipped beside the driver (CUA_DRIVER_CURSOR_THEME_DIR), with Comma's own. */
  cursorThemes: string;
  env: Record<string, string>;
  /** Stores a screenshot as a temporary device image (computer-use.ts). */
  storeImage(response: DaemonResponse): Effect.Effect<Result, Error>;
};

/** A connected driver: one tool call at a time. */
export type DriverConnection = {
  callTool(name: string, args: Args): Promise<{ structured: Result; image?: { data: string; mimeType: string }; text: string; isError: boolean }>;
  close(): Promise<void>;
};

/** Starts the driver and connects to its MCP server. */
export async function connectDriver(deps: Pick<WindowsComputerUseDeps, "executable" | "home" | "cursorThemes" | "env">): Promise<DriverConnection> {
  const transport = new StdioClientTransport({
    command: deps.executable,
    args: ["mcp"],
    env: {
      ...deps.env,
      CUA_DRIVER_RS_HOME: deps.home,
      CUA_DRIVER_CURSOR_THEME_DIR: deps.cursorThemes,
      // The desktop app ships a pinned driver: no telemetry, no update checks of its own.
      CUA_DRIVER_RS_TELEMETRY_ENABLED: "false",
      CUA_DRIVER_RS_UPDATE_CHECK: "0",
    },
    stderr: "ignore",
  });
  const client = new Client({ name: "comma-station", version: "1" });
  await client.connect(transport);
  return {
    async callTool(name, args) {
      const result = (await client.callTool({ name, arguments: args })) as {
        content?: Array<{ type: string; text?: string; data?: string; mimeType?: string }>;
        structuredContent?: Result;
        isError?: boolean;
      };
      const content = result.content ?? [];
      const image = content.find((item) => item.type === "image" && item.data);
      const text = content
        .filter((item) => item.type === "text")
        .map((item) => item.text ?? "")
        .join("\n");
      return {
        structured: result.structuredContent ?? {},
        ...(image ? { image: { data: image.data!, mimeType: image.mimeType ?? "image/png" } } : {}),
        text,
        isError: result.isError === true,
      };
    },
    close: () => client.close(),
  };
}

export function makeWindowsComputerUse(deps: WindowsComputerUseDeps, connect: () => Promise<DriverConnection> = () => connectDriver(deps)) {
  let driver: Promise<DriverConnection> | undefined;
  const snapshots = new Map<string, Snapshot>();
  let sequence = 0;

  const connection = () => (driver ??= connect().catch((error) => ((driver = undefined), Promise.reject(error))));

  const tool = async (name: string, args: Args) => {
    const result = await (await connection()).callTool(name, args);
    if (result.isError) throw new Error(errorText(result));
    return result;
  };

  /** Reads one window: its elements become a snapshot, its screenshot a device image. */
  const state = async (pid: number, windowId: number): Promise<Result> => {
    const read = await tool("get_window_state", {
      pid,
      window_id: windowId,
      tree_format: "both",
      include_screenshot: true,
      max_image_dimension: MAX_IMAGE_DIMENSION,
    });
    const s = read.structured;
    const elements = new Map<number, Element>();
    for (const item of Array.isArray(s.elements) ? (s.elements as Args[]) : []) {
      if (typeof item.element_index !== "number" || typeof item.element_token !== "string") continue;
      const frame = item.screenshot_frame as Element["frame"] | undefined;
      const actions = Array.isArray(item.actions) ? item.actions.filter((action): action is string => typeof action === "string") : [];
      elements.set(item.element_index, { token: item.element_token, actions, ...(frame ? { frame } : {}) });
    }
    const id = `w${++sequence}`;
    snapshots.set(id, { pid, windowId, ...(typeof s.capture_id === "string" ? { captureId: s.capture_id } : {}), elements });
    for (const old of snapshots.keys()) if (snapshots.size > SNAPSHOTS_KEPT) snapshots.delete(old);
    const lines = [
      `Computer Use state (Snapshot: ${id})`,
      `Window: "${String(s.window_title ?? "")}", App: ${String(s.app_name ?? "")} (pid ${pid}).`,
      "<app_state>",
      String(s.tree_markdown ?? "").trimEnd(),
      "</app_state>",
    ];
    if (read.image) {
      const width = Number(s.screenshot_width) || undefined;
      const height = Number(s.screenshot_height) || undefined;
      if (width && height) lines.push(`ScreenshotSize: ${width}x${height}`);
      const stored = await Effect.runPromise(
        deps.storeImage({
          ok: true,
          imageData: Buffer.from(read.image.data, "base64"),
          imageContentType: read.image.mimeType,
          ...(width ? { imageWidth: width } : {}),
          ...(height ? { imageHeight: height } : {}),
        }),
      );
      return { ...stored, text: lines.join("\n") };
    }
    return { ok: true, text: lines.join("\n") };
  };

  const snapshotOf = (args: Args): Snapshot => {
    const id = text(args.snapshot_id);
    if (!id) throw new Error("'snapshot_id' is required; call get_app_state first");
    const snapshot = snapshots.get(id);
    if (!snapshot) throw new Error(`snapshot ${id} is no longer known; call get_app_state again`);
    return snapshot;
  };

  const elementOf = (snapshot: Snapshot, args: Args, required: boolean): Element | undefined => {
    if (args.element_index === undefined || args.element_index === null || args.element_index === "") {
      if (required) throw new Error("'element_index' is required");
      return undefined;
    }
    const index = Number(args.element_index);
    const element = snapshot.elements.get(index);
    if (!element) throw new Error(`element ${index} is not in that snapshot; call get_app_state again`);
    return element;
  };

  const target = (snapshot: Snapshot) => ({ pid: snapshot.pid, window_id: snapshot.windowId });

  /**
   * One action on a snapshot's window, then that window's new state. An action that can be delivered either way goes
   * to the window in the background first, and in the foreground only when the driver says the background failed.
   */
  const act = async (snapshot: Snapshot, name: string, args: Args, delivery: "auto" | "foreground" | "none" = "auto") => {
    let foreground = delivery === "foreground";
    if (delivery === "none") await tool(name, args);
    else if (foreground) await tool(name, { ...args, delivery_mode: "foreground" });
    else if (escalatesToForeground((await tool(name, { ...args, delivery_mode: "background" })).structured)) {
      await tool(name, { ...args, delivery_mode: "foreground" });
      foreground = true;
    }
    const next = await state(snapshot.pid, snapshot.windowId);
    return foreground
      ? { ...next, text: `The app did not take this in the background; it was sent in the foreground (the window came to the front for it).\n${String(next.text)}` }
      : next;
  };

  const getAppState = async (args: Args) => {
    const wanted = text(args.app).trim().toLowerCase();
    if (!wanted) throw new Error("'app' is required");
    const apps = ((await tool("list_apps", {})).structured.apps as Args[] | undefined) ?? [];
    const app = apps.find((entry) => appMatches(entry, wanted));
    if (!app || typeof app.pid !== "number") throw new Error(`app ${JSON.stringify(text(args.app))} is not running; list_apps names the running apps`);
    const listed = ((await tool("list_windows", { pid: app.pid })).structured.windows as Args[] | undefined) ?? [];
    const title = text(args.window_title).trim().toLowerCase();
    const windows = listed.filter((window) => window.minimized !== true && window.is_on_screen !== false);
    const window =
      (title ? windows.find((entry) => text(entry.title).toLowerCase().includes(title)) : undefined) ??
      (title ? undefined : [...windows].sort((a, b) => Number(a.z_index ?? 0) - Number(b.z_index ?? 0))[0]);
    if (!window || typeof window.window_id !== "number")
      throw new Error(title ? `no window of ${text(app.name)} is titled ${JSON.stringify(text(args.window_title))}` : `${text(app.name)} has no open window`);
    return state(app.pid, window.window_id);
  };

  const listApps = async (): Promise<Result> => {
    const apps = ((await tool("list_apps", {})).structured.apps as Args[] | undefined) ?? [];
    const lines = apps.filter((app) => app.running !== false).map((app) => `${text(app.name)} — pid ${String(app.pid)}${app.active ? " [active]" : ""}`);
    return { ok: true, text: lines.join("\n") };
  };

  const run = async (action: string, args: Args): Promise<Result> => {
    switch (action) {
      case "start":
        if (text(args.mode) === "foreground") throw new Error("Windows runs computer use in background mode only");
        // The connection's own session, which every action's cursor is drawn for.
        await tool("start_session", { cursor_theme: { theme_id: CURSOR_THEME } });
        return { ok: true, message: "session started", mode: "background" };
      case "end":
      case "stop":
        snapshots.clear();
        if (driver) await tool("end_session", {}).catch(() => undefined);
        return { ok: true, text: "session stopped" };
      case "status":
      case "permissions_status":
        return { ok: true, text: "Windows needs no permission grants for computer use." };
      case "list_apps":
      case "list_applications":
        return listApps();
      case "get_app_state":
        return getAppState(args);
      case "click": {
        const snapshot = snapshotOf(args);
        const element = elementOf(snapshot, args, false);
        if (element) {
          const expand = clickAction(element);
          if (!expand.action) return act(snapshot, "click", { ...target(snapshot), element_token: element.token });
          // Some menus list ExpandCollapse and refuse it (a Win32 menu bar's). A click sent behind other windows does
          // not open those, and the driver cannot tell: they get a real click in the foreground.
          return act(snapshot, "click", { ...target(snapshot), element_token: element.token, ...expand }).catch(() =>
            act(snapshot, "click", { ...target(snapshot), element_token: element.token }, "foreground"),
          );
        }
        return act(snapshot, "click", { ...target(snapshot), ...point(args, "x", "y"), ...capture(snapshot) });
      }
      case "perform_secondary_action": {
        const snapshot = snapshotOf(args);
        const element = elementOf(snapshot, args, true)!;
        return act(snapshot, "click", { ...target(snapshot), element_token: element.token, action: required(args, "action") });
      }
      case "type_text": {
        const snapshot = snapshotOf(args);
        const element = elementOf(snapshot, args, false);
        return act(snapshot, "type_text", { ...target(snapshot), text: required(args, "text"), ...(element ? { element_token: element.token } : {}) });
      }
      case "set_value": {
        const snapshot = snapshotOf(args);
        const element = elementOf(snapshot, args, true)!;
        return act(snapshot, "set_value", { element_token: element.token, value: text(args.value) }, "none");
      }
      case "press_key": {
        const snapshot = snapshotOf(args);
        const keys = windowsKeys(required(args, "key"));
        return keys.length > 1
          ? act(snapshot, "hotkey", { ...target(snapshot), keys })
          : act(snapshot, "press_key", { ...target(snapshot), key: keys[0] });
      }
      case "scroll": {
        const snapshot = snapshotOf(args);
        const element = elementOf(snapshot, args, true)!;
        const at = element.frame ? { x: element.frame.x + element.frame.w / 2, y: element.frame.y + element.frame.h / 2 } : {};
        const pages = Number(args.pages) > 0 ? Number(args.pages) : 1;
        return act(snapshot, "scroll", { ...target(snapshot), ...at, direction: required(args, "direction"), by: "page", amount: pages });
      }
      case "drag": {
        const snapshot = snapshotOf(args);
        return act(snapshot, "drag", { target: { kind: "window", ...target(snapshot) }, ...point(args, "from_x", "from_y"), ...point(args, "to_x", "to_y") });
      }
      default:
        throw new Error(`unsupported computer_use action ${JSON.stringify(action)} on Windows`);
    }
  };

  /** The `computer_use` method on Windows: failures are results ({ ok: false, error }), as the agent reads them. */
  const call = (action: string, args: Args): Effect.Effect<Result> =>
    Effect.promise(() => run(action, args).catch((error: unknown) => ({ ok: false, error: error instanceof Error ? error.message : String(error) })));

  const shutdown = Effect.promise(async () => {
    const open = driver;
    driver = undefined;
    snapshots.clear();
    if (open) await (await open.catch(() => undefined))?.close().catch(() => undefined);
  });

  return { call, shutdown };
}

const text = (value: unknown) => (typeof value === "string" ? value : typeof value === "number" ? String(value) : "");

function required(args: Args, key: string): string {
  const value = text(args[key]);
  if (!value.trim()) throw new Error(`'${key}' is required`);
  return value;
}

function point(args: Args, xKey: string, yKey: string) {
  const x = Number(args[xKey]);
  const y = Number(args[yKey]);
  if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error(`'${xKey}' and '${yKey}' are required`);
  return { [xKey]: x, [yKey]: y };
}

/** Whether the driver says this delivery failed in the background and the foreground would take it. */
function escalatesToForeground(result: Result): boolean {
  const escalation = result.escalation;
  return Boolean(escalation && typeof escalation === "object" && (escalation as Args).target === "foreground");
}

/** An element without UI Automation's Invoke opens through ExpandCollapse when it has one (a menu, a drop-down). */
function clickAction(element: Element): { action?: "expand" } {
  return !element.actions.includes("invoke") && element.actions.includes("expand") ? { action: "expand" } : {};
}

function capture(snapshot: Snapshot) {
  return snapshot.captureId ? { capture_id: snapshot.captureId } : {};
}

/** An app by its name, its executable or its path, as list_apps reports them. */
function appMatches(app: Args, wanted: string): boolean {
  const names = [text(app.name), text(app.bundle_id), text(app.launch_path)].map((name) => name.toLowerCase());
  const base = (name: string) => name.split(/[\\/]/).pop()!.replace(/\.exe$/, "");
  return names.some((name) => name && (name === wanted || base(name) === wanted.replace(/\.exe$/, "")));
}

/** A key combination as the driver names keys: "cmd" and "command" are Windows' Ctrl, "option" its Alt. */
export function windowsKeys(combo: string): string[] {
  const aliases: Record<string, string> = { cmd: "ctrl", command: "ctrl", control: "ctrl", option: "alt", return: "enter", esc: "escape" };
  return combo
    .split("+")
    .map((key) => key.trim().toLowerCase())
    .filter(Boolean)
    .map((key) => aliases[key] ?? key);
}

function errorText(result: { structured: Result; text: string }): string {
  const error = result.structured.error;
  if (error && typeof error === "object" && typeof (error as Args).message === "string") return (error as Args).message as string;
  if (typeof error === "string") return error;
  return result.text.trim() || "computer_use failed";
}
