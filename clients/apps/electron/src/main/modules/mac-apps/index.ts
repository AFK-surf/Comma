import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import {
  macAppIds,
  macAppIdSchema,
  type MacAppActivity,
  type MacAppIcons,
  type MacAppId,
  type MacAppItemTarget,
  type MacAppPermissionState,
  type MacAppState,
  type MacAppsSnapshot,
  type MacAppsCalendarEvent,
  type MacAppsCalendarEventsInput,
  type MacAppsCalendarEventsResult,
} from "@comma/native-bridge";
import { z } from "zod";
import { cardInstruction, macAppCards } from "./cards";
import { realMainClock, type MainClock } from "../../clock";
import { McpRemoteError, type InitializeResult } from "./engine";

/**
 * The Mac apps plugins on this Mac. The user turns each app on or off in Plugins;
 * the choice lives only on this Mac, and this service applies it to every MCP
 * client: Salix (through the station's `client_mcp`) and, later, local clients.
 * Turning an app on is also when macOS asks for its permission.
 */

type MacAppRequirement = MacAppState["requirements"][number];

export interface MacAppsProvider {
  state(input: void): Promise<MacAppsSnapshot>;
  setEnabled(input: {
    app: MacAppId;
    enabled: boolean;
  }): Promise<{ enabled: boolean; snapshot: MacAppsSnapshot }>;
  openPrivacySettings(input: { requirement: string }): Promise<{ opened: boolean }>;
  openItem(input: MacAppItemTarget): Promise<{ opened: boolean }>;
  icons(input: void): Promise<MacAppIcons>;
  calendarEvents(
    input: MacAppsCalendarEventsInput
  ): Promise<MacAppsCalendarEventsResult>;
}

export interface MacAppsEngineClient {
  initialize(): Promise<InitializeResult>;
  request(method: string, params: unknown): Promise<unknown>;
  stop(): Promise<void>;
  restartWhenIdle(): Promise<boolean>;
}

export interface MacAppsSwitches {
  enabledApps(): Promise<readonly MacAppId[]>;
  setEnabledApps(apps: readonly MacAppId[]): Promise<void>;
}

interface ToolDescription {
  name: string;
  title?: string;
  annotations?: { readOnlyHint?: boolean; destructiveHint?: boolean };
}

const ACTIVITY_LIMIT = 50;
/** The MCP versions the server's SDK speaks; a client gets its own when it is one. */
const PROTOCOL_VERSIONS = new Set([
  "2024-11-05",
  "2025-03-26",
  "2025-06-18",
  "2025-11-25",
]);
const DRIVE_ROOT_META = "comma/driveRoot";
/** The most events `calendar_list_events` gives in one call. */
const CALENDAR_EVENTS_LIMIT = 200;
const PRIVACY_PANES: Record<string, string> = {
  calendars: "Privacy_Calendars",
  reminders: "Privacy_Reminders",
  contacts: "Privacy_Contacts",
  screen_recording: "Privacy_ScreenCapture",
};
/**
 * Permissions macOS reads into a process once: a grant made while the server
 * runs reaches only a server started after it. Main starts a new server for
 * it, so the user does not have to restart Comma.
 */
const PROCESS_READ_REQUIREMENTS = new Set(["screen_recording"]);
/** How long after the user goes to grant one Main looks for it with new servers. */
const GRANT_WAIT_MS = 10 * 60_000;
/** At most one new server for a grant this often (state() also follows each call). */
const GRANT_RESTART_INTERVAL_MS = 5_000;

export function macAppOf(toolName: string): MacAppId | undefined {
  return macAppIds.find((app) => toolName.startsWith(`${app}_`));
}

export class MacAppsService implements MacAppsProvider {
  readonly #engine: MacAppsEngineClient | undefined;
  readonly #switches: MacAppsSwitches;
  readonly #driveRoot: () => Promise<string | undefined>;
  readonly #openExternal: (url: string) => Promise<void>;
  readonly #onChange: () => void;
  readonly #clock: MainClock;
  #activity: MacAppActivity[] = [];
  #revision = 0;
  #icons: Promise<MacAppIcons> | undefined;
  /** The permissions each app needed when the server last reported them. */
  #requirements = new Map<MacAppId, MacAppRequirement[]>();
  /** Permissions the user went to grant that a running server cannot see yet. */
  #wantedGrants = new Set<string>();
  #wantedUntil = 0;
  #lastGrantRestart = 0;

  constructor(options: {
    /** Undefined on a Mac without the server (not macOS, or a build without it). */
    engine: MacAppsEngineClient | undefined;
    switches: MacAppsSwitches;
    /** The local Comma Drive folder, when Drive is set up. */
    driveRoot: () => Promise<string | undefined>;
    openExternal?: (url: string) => Promise<void>;
    /** Called after the switches or the activity change; publish `state()`. */
    onChange?: () => void;
    clock?: MainClock;
  }) {
    this.#engine = options.engine;
    this.#switches = options.switches;
    this.#driveRoot = options.driveRoot;
    this.#openExternal = options.openExternal ?? (async () => undefined);
    this.#onChange = options.onChange ?? (() => undefined);
    this.#clock = options.clock ?? realMainClock;
  }

  get available() {
    return this.#engine !== undefined;
  }

  /** Every app with its switch, tools and macOS permission state. Never prompts. */
  async state(): Promise<MacAppsSnapshot> {
    const revision = ++this.#revision;
    const engine = this.#engine;
    if (!engine) return { revision, status: "unavailable", apps: [], activity: [] };
    const enabled = new Set(await this.#switches.enabledApps());
    try {
      await this.#restartForWantedGrants(engine);
      const [tools, permissions] = await Promise.all([
        this.#tools(),
        engine.request("comma/permissions", {}),
      ]);
      const report = permissionReport(permissions);
      this.#requirements = report;
      for (const requirements of report.values()) {
        for (const entry of requirements) {
          if (entry.state === "granted") this.#wantedGrants.delete(entry.requirement);
        }
      }
      return {
        revision,
        status: "ready",
        apps: macAppIds.map((id) => ({
          id,
          enabled: enabled.has(id),
          tools: tools
            .filter((tool) => macAppOf(tool.name) === id)
            .map((tool) => ({
              name: tool.name,
              title: tool.title ?? tool.name,
              readOnly: tool.annotations?.readOnlyHint === true,
              destructive: tool.annotations?.destructiveHint === true,
            })),
          requirements: report.get(id) ?? [],
        })),
        activity: [...this.#activity],
      };
    } catch (error) {
      return {
        revision,
        status: "error",
        message: error instanceof Error ? error.message : String(error),
        apps: macAppIds.map((id) => ({
          id,
          enabled: enabled.has(id),
          tools: [],
          requirements: [],
        })),
        activity: [...this.#activity],
      };
    }
  }

  /**
   * Turns an app on or off. Turning it on first asks macOS for the permissions it
   * needs; it stays off when none of its tools could run.
   */
  async setEnabled({ app, enabled }: { app: MacAppId; enabled: boolean }) {
    const engine = this.#engine;
    if (!engine) return { enabled: false, snapshot: await this.state() };
    const current = new Set(await this.#switches.enabledApps());
    if (enabled) {
      // A grant the user made in System Settings since the server started.
      if (
        this.#requirements.get(app)?.some(waitsForNewProcess) &&
        (await engine.restartWhenIdle())
      ) {
        this.#lastGrantRestart = this.#clock.now();
      }
      const report = permissionReport(
        await engine.request("comma/requestPermission", { app })
      );
      const requirements = report.get(app) ?? [];
      this.#requirements.set(app, requirements);
      // macOS sends the user to System Settings for these; a later state()
      // (the window gets focus again) reads them from a new server.
      this.#wantGrants(
        requirements.filter(waitsForNewProcess).map((entry) => entry.requirement)
      );
      const tools = (await this.#tools()).filter((tool) => macAppOf(tool.name) === app);
      if (tools.some((tool) => toolUsable(tool.name, requirements))) {
        current.add(app);
      }
    } else {
      current.delete(app);
    }
    await this.#switches.setEnabledApps(macAppIds.filter((id) => current.has(id)));
    this.#onChange();
    return { enabled: current.has(app), snapshot: await this.state() };
  }

  /** Opens the System Settings pane where the user grants `requirement`. */
  async openPrivacySettings({ requirement }: { requirement: string }) {
    const pane = requirement.startsWith("automation:")
      ? "Privacy_Automation"
      : PRIVACY_PANES[requirement];
    if (!this.#engine || !pane) return { opened: false };
    if (PROCESS_READ_REQUIREMENTS.has(requirement)) this.#wantGrants([requirement]);
    await this.#openExternal(
      `x-apple.systempreferences:com.apple.preference.security?${pane}`
    );
    return { opened: true };
  }

  /**
   * Opens a chat card's item in its app: the reminder, the person, the place;
   * Calendar and Notes open at their start, as macOS gives no link to one item.
   */
  async openItem(target: MacAppItemTarget) {
    if (!this.#engine) return { opened: false };
    const url = itemUrl(target);
    if (!url) return { opened: false };
    await this.#openExternal(url);
    return { opened: true };
  }

  /** The apps' icons as this Mac draws them; read once. */
  icons(): Promise<MacAppIcons> {
    const engine = this.#engine;
    if (!engine) return Promise.resolve({});
    this.#icons ??= engine.request("comma/appIcons", {}).then((result) => {
      const icons =
        isRecord(result) && isRecord(result.icons) ? Object.entries(result.icons) : [];
      return Object.fromEntries(
        icons.flatMap(([key, png]) =>
          typeof png === "string" ? [[key, `data:image/png;base64,${png}`]] : []
        )
      );
    });
    // A failed read is tried again on the next request.
    this.#icons.catch(() => {
      this.#icons = undefined;
    });
    return this.#icons;
  }

  /**
   * A Mini App's `calendar.read`: this Mac's events in a range (at most 366 days), through the same engine tool the
   * Agents use, `calendar_list_events`, at most 200. Only while Calendar is on in Comma; without macOS calendar
   * permission it says `denied` and never prompts.
   */
  async calendarEvents({
    from,
    to,
  }: MacAppsCalendarEventsInput): Promise<MacAppsCalendarEventsResult> {
    const engine = this.#engine;
    if (!engine) return { status: "unavailable" };
    const start = Date.parse(from);
    const end = Date.parse(to);
    if (
      !Number.isFinite(start) ||
      !Number.isFinite(end) ||
      end <= start ||
      end - start > 366 * 86_400_000
    )
      throw new Error("from and to are ISO times at most 366 days apart.");
    if (!(await this.#switches.enabledApps()).includes("calendar"))
      return { status: "off" };
    const name = "calendar_list_events";
    const result = await engine.request("tools/call", {
      name,
      arguments: {
        start: new Date(start).toISOString(),
        end: new Date(end).toISOString(),
        limit: CALENDAR_EVENTS_LIMIT,
      },
      _meta: {},
    });
    this.#record("calendar", name, result);
    if (isRecord(result) && result.isError === true)
      return errorCode(result) === "permission_required"
        ? { status: "denied" }
        : { status: "unavailable" };
    const data = isRecord(result) ? result.structuredContent : undefined;
    const events = isRecord(data) && Array.isArray(data.events) ? data.events : [];
    return {
      status: "ok",
      events: events.slice(0, CALENDAR_EVENTS_LIMIT).flatMap(calendarEvent),
    };
  }

  /**
   * One JSON-RPC message from an MCP client; the reply, or null for a notification.
   * Only the tools of apps turned on are listed or run, whatever the client sends.
   */
  async handleMcp(message: unknown): Promise<Record<string, unknown> | null> {
    const engine = this.#engine;
    if (!isRecord(message) || message.jsonrpc !== "2.0") {
      return rpcError(null, -32600, "Invalid JSON-RPC message.");
    }
    const id = message.id;
    const method = message.method;
    // Notifications (initialized, cancelled) and stray responses need no answer.
    if (id === undefined || id === null || typeof method !== "string") return null;
    if (!engine)
      return rpcError(id, -32603, "The Mac apps are not available on this Mac.");
    const params = isRecord(message.params) ? message.params : {};
    try {
      switch (method) {
        case "initialize": {
          const server = await engine.initialize();
          const requested =
            typeof params.protocolVersion === "string" ? params.protocolVersion : "";
          return rpcResult(id, {
            protocolVersion: PROTOCOL_VERSIONS.has(requested)
              ? requested
              : server.protocolVersion,
            capabilities: { tools: { listChanged: false } },
            serverInfo: server.serverInfo,
          });
        }
        case "ping":
          return rpcResult(id, {});
        case "tools/list": {
          const enabled = new Set(await this.#switches.enabledApps());
          const tools = await this.#tools();
          return rpcResult(id, {
            tools: tools.filter((tool) => {
              const app = macAppOf(tool.name);
              return app !== undefined && enabled.has(app);
            }),
          });
        }
        case "tools/call":
          return rpcResult(id, await this.#call(params));
        default:
          return rpcError(id, -32601, `Method not found: ${method}`);
      }
    } catch (error) {
      if (error instanceof McpRemoteError)
        return rpcError(id, error.code, error.message, error.data);
      return rpcError(
        id,
        -32603,
        error instanceof Error ? error.message : String(error)
      );
    }
  }

  async stop() {
    await this.#engine?.stop();
  }

  #wantGrants(requirements: readonly string[]) {
    if (!requirements.length) return;
    for (const requirement of requirements) this.#wantedGrants.add(requirement);
    this.#wantedUntil = this.#clock.now() + GRANT_WAIT_MS;
  }

  /** A new server, when the user may have granted what the running one cannot see. */
  async #restartForWantedGrants(engine: MacAppsEngineClient) {
    const now = this.#clock.now();
    if (
      this.#wantedGrants.size === 0 ||
      now > this.#wantedUntil ||
      now - this.#lastGrantRestart < GRANT_RESTART_INTERVAL_MS
    )
      return;
    if (await engine.restartWhenIdle()) this.#lastGrantRestart = now;
  }

  async #call(params: Record<string, unknown>) {
    const name = typeof params.name === "string" ? params.name : "";
    const app = macAppOf(name);
    if (!app || !(await this.#switches.enabledApps()).includes(app)) {
      return toolError(
        "plugin_off",
        "The user turned this app off in Comma > Plugins > Mac apps on this Mac. Ask them to turn it on to use it."
      );
    }
    // Main sets _meta: a client cannot point the server at another Drive folder.
    const driveRoot = await this.#driveRoot().catch(() => undefined);
    const result = await this.#engine!.request("tools/call", {
      name,
      arguments: isRecord(params.arguments) ? params.arguments : {},
      _meta: driveRoot ? { [DRIVE_ROOT_META]: driveRoot } : {},
    });
    this.#record(app, name, result);
    return withCards(name, result);
  }

  #record(app: MacAppId, tool: string, result: unknown) {
    const failed = isRecord(result) && result.isError === true;
    const code = failed ? errorCode(result) : undefined;
    this.#activity = [
      {
        at: new Date(this.#clock.now()).toISOString(),
        app,
        tool,
        outcome: code ?? (failed ? "error" : "ok"),
      },
      ...this.#activity,
    ].slice(0, ACTIVITY_LIMIT);
    this.#onChange();
  }

  async #tools(): Promise<ToolDescription[]> {
    const result = await this.#engine!.request("tools/list", {});
    return isRecord(result) && Array.isArray(result.tools)
      ? (result.tools as ToolDescription[])
      : [];
  }
}

const APP_PATHS: Partial<Record<MacAppItemTarget["app"], string>> = {
  calendar: "/System/Applications/Calendar.app",
  notes: "/System/Applications/Notes.app",
};

/** The link that opens an item; only fixed schemes, with ids of the shape its app gives. */
export function itemUrl(target: MacAppItemTarget): string | undefined {
  const id = target.itemId ?? "";
  switch (target.app) {
    case "reminders":
      return /^[A-Fa-f0-9-]{36}$/.test(id)
        ? `x-apple-reminderkit://REMCDReminder/${id}`
        : undefined;
    case "contacts":
      return /^[A-Za-z0-9:_-]{1,128}$/.test(id) ? `addressbook://${id}` : undefined;
    case "maps": {
      const query = `q=${encodeURIComponent(target.title ?? "")}`;
      return target.latitude !== undefined && target.longitude !== undefined
        ? `maps://?${query}&ll=${target.latitude},${target.longitude}`
        : `maps://?${query}`;
    }
    default: {
      const path = APP_PATHS[target.app];
      return path ? `file://${path}` : undefined;
    }
  }
}

/** The result with its chat cards, and how to show them, for the Agent to read. */
function withCards(tool: string, result: unknown) {
  const cards = macAppCards(tool, result);
  if (!cards.length || !isRecord(result) || !Array.isArray(result.content))
    return result;
  return {
    ...result,
    content: [...result.content, { type: "text", text: cardInstruction(cards) }],
  };
}

/** The switches, in a file of this Mac's own. */
export class FileMacAppsSwitches implements MacAppsSwitches {
  readonly #path: string;
  #write = Promise.resolve();

  constructor(path: string) {
    this.#path = path;
  }

  async enabledApps(): Promise<readonly MacAppId[]> {
    try {
      const parsed = switchesFileSchema.safeParse(
        JSON.parse(await readFile(this.#path, "utf8"))
      );
      return parsed.success ? parsed.data.enabled : [];
    } catch {
      // No file yet: every app starts off.
      return [];
    }
  }

  setEnabledApps(apps: readonly MacAppId[]) {
    const write = this.#write.then(async () => {
      await mkdir(dirname(this.#path), { recursive: true, mode: 0o700 });
      const staged = `${this.#path}.${process.pid}.tmp`;
      await writeFile(staged, `${JSON.stringify({ enabled: apps })}\n`, {
        mode: 0o600,
      });
      await rename(staged, this.#path);
    });
    this.#write = write.catch(() => undefined);
    return write;
  }
}

const switchesFileSchema = z.object({ enabled: z.array(macAppIdSchema) });

function waitsForNewProcess(requirement: MacAppRequirement) {
  return (
    PROCESS_READ_REQUIREMENTS.has(requirement.requirement) &&
    requirement.state !== "granted"
  );
}

/** A tool can run when every requirement it depends on is granted. */
export function toolUsable(tool: string, requirements: readonly MacAppRequirement[]) {
  return requirements
    .filter((entry) => entry.tools.length === 0 || entry.tools.includes(tool))
    .every((entry) => entry.state === "granted");
}

function permissionReport(value: unknown): Map<MacAppId, MacAppRequirement[]> {
  const report = new Map<MacAppId, MacAppRequirement[]>();
  const apps =
    isRecord(value) && Array.isArray(value.apps)
      ? value.apps
      : isRecord(value)
        ? [value]
        : [];
  for (const entry of apps) {
    if (!isRecord(entry) || typeof entry.app !== "string") continue;
    const app = macAppIds.find((id) => id === entry.app);
    if (!app || !Array.isArray(entry.requirements)) continue;
    report.set(
      app,
      entry.requirements.filter(isRecord).map((requirement) => ({
        requirement: String(requirement.requirement),
        state: String(requirement.state) as MacAppPermissionState,
        onEnable: requirement.on_enable === true,
        tools: Array.isArray(requirement.tools) ? requirement.tools.map(String) : [],
      }))
    );
  }
  return report;
}

/** Text of at most `max` characters, or undefined when `v` is no text. */
function clipped(v: unknown, max: number): string | undefined {
  return typeof v === "string" ? v.slice(0, max) : undefined;
}

/** An event as an app sees it: no ids, attendees or notes. */
function calendarEvent(value: unknown): MacAppsCalendarEvent[] {
  if (!isRecord(value)) return [];
  const start = clipped(value.start, 64);
  const end = clipped(value.end, 64);
  if (!start || !end) return [];
  const location = clipped(value.location, 1_000);
  return [
    {
      title: clipped(value.title, 1_000) ?? "",
      start,
      end,
      allDay: value.all_day === true,
      ...(location ? { location } : {}),
    },
  ];
}

function errorCode(result: Record<string, unknown>) {
  const structured = result.structuredContent;
  if (!isRecord(structured) || !isRecord(structured.error)) return undefined;
  return typeof structured.error.code === "string" ? structured.error.code : undefined;
}

function toolError(code: string, message: string) {
  const error = { error: { code, message } };
  return {
    content: [{ type: "text", text: JSON.stringify(error) }],
    structuredContent: error,
    isError: true,
  };
}

function rpcResult(id: unknown, result: unknown) {
  return { jsonrpc: "2.0", id, result };
}

function rpcError(id: unknown, code: number, message: string, data?: unknown) {
  return {
    jsonrpc: "2.0",
    id,
    error: { code, message, ...(data === undefined ? {} : { data }) },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
