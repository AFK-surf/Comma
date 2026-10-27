import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MacAppsEngine } from "../modules/mac-apps/engine";
import type { MacAppId } from "@comma/native-bridge";
import { MacAppsService, type MacAppsEngineClient } from "../modules/mac-apps";

const tools = [
  {
    name: "calendar_list_events",
    title: "List events",
    annotations: { readOnlyHint: true },
  },
  {
    name: "system_set_volume",
    title: "Set volume",
    annotations: { readOnlyHint: false },
  },
  {
    name: "system_set_appearance",
    title: "Light or dark",
    annotations: { readOnlyHint: false },
  },
];

/** MacAppsHost's answers, with permissions per app; records what reached it. */
function fakeEngine(permissions: Record<string, unknown[]> = {}) {
  const calls: Array<{ method: string; params: unknown }> = [];
  const report = (app: string) => ({ app, requirements: permissions[app] ?? [] });
  const engine: MacAppsEngineClient = {
    initialize: async () => ({
      protocolVersion: "2025-06-18",
      serverInfo: { name: "comma-mac-apps", version: "1.0.0" },
      capabilities: { tools: {} },
    }),
    request: async (method, params) => {
      calls.push({ method, params });
      const p = params as Record<string, unknown>;
      if (method === "tools/list") return { tools };
      if (method === "comma/permissions")
        return { apps: Object.keys(permissions).map(report) };
      if (method === "comma/requestPermission") return report(String(p.app));
      return {
        content: [],
        structuredContent: { name: p.name, arguments: p.arguments, meta: p["_meta"] },
      };
    },
    stop: async () => undefined,
    restartWhenIdle: async () => true,
  };
  return { engine, calls };
}

function service(engine: MacAppsEngineClient, enabled: MacAppId[]) {
  let switches = [...enabled];
  const macApps = new MacAppsService({
    engine,
    switches: {
      enabledApps: async () => switches,
      setEnabledApps: async (apps) => {
        switches = [...apps];
      },
    },
    driveRoot: async () => "/Users/someone/Comma Drive",
  });
  let nextId = 1;
  const rpc = (method: string, params: unknown = {}) =>
    macApps.handleMcp({ jsonrpc: "2.0", id: nextId++, method, params });
  return { macApps, rpc, switches: () => switches };
}

describe("Mac apps MCP server in Main", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("lists and runs only the apps the user turned on", async () => {
    const { engine, calls } = fakeEngine();
    const { macApps, rpc } = service(engine, ["calendar"]);

    expect(
      (await rpc("initialize", { protocolVersion: "2025-03-26", capabilities: {} }))
        ?.result
    ).toMatchObject({
      protocolVersion: "2025-03-26",
      serverInfo: { name: "comma-mac-apps" },
    });
    expect(
      await macApps.handleMcp({ jsonrpc: "2.0", method: "notifications/initialized" })
    ).toBeNull();

    const listed = (await rpc("tools/list"))?.result as {
      tools: Array<{ name: string }>;
    };
    expect(listed.tools.map((tool) => tool.name)).toEqual(["calendar_list_events"]);

    const off = await rpc("tools/call", {
      name: "system_set_volume",
      arguments: { volume: 100 },
    });
    expect(off?.result).toMatchObject({
      isError: true,
      structuredContent: { error: { code: "plugin_off" } },
    });
    expect(calls.some((call) => call.method === "tools/call")).toBe(false);

    // Main, not the client, says where Drive is.
    const run = await rpc("tools/call", {
      name: "calendar_list_events",
      arguments: { start: "2026-10-12", end: "2026-10-13" },
      _meta: { "comma/driveRoot": "/etc" },
    });
    expect((run!.result as { structuredContent: unknown }).structuredContent).toEqual({
      name: "calendar_list_events",
      arguments: { start: "2026-10-12", end: "2026-10-13" },
      meta: { "comma/driveRoot": "/Users/someone/Comma Drive" },
    });

    // Permission requests come only from the user's switch, not from MCP clients.
    expect(
      (await rpc("comma/requestPermission", { app: "calendar" }))?.error
    ).toMatchObject({
      code: -32601,
    });
    const state = await macApps.state();
    expect(
      state.status === "ready" &&
        state.activity.map((entry) => [entry.tool, entry.outcome])
    ).toEqual([["calendar_list_events", "ok"]]);
  });

  it("turns an app on only when macOS lets at least one of its tools run", async () => {
    const denied = { state: "denied", on_enable: true };
    const { engine } = fakeEngine({
      calendar: [{ requirement: "calendars", tools: [], ...denied }],
      system: [
        {
          requirement: "automation:com.apple.systemevents",
          tools: ["system_set_appearance"],
          ...denied,
        },
      ],
    });
    const { macApps, switches } = service(engine, []);

    expect((await macApps.setEnabled({ app: "calendar", enabled: true })).enabled).toBe(
      false
    );
    // Volume works without the System Events permission that light/dark needs.
    expect((await macApps.setEnabled({ app: "system", enabled: true })).enabled).toBe(
      true
    );
    expect(switches()).toEqual(["system"]);
    expect((await macApps.setEnabled({ app: "system", enabled: false })).enabled).toBe(
      false
    );
    expect(switches()).toEqual([]);
  });

  it("sees a Screen Recording grant made in System Settings without restarting Comma", async () => {
    // Main's clock (realMainClock) on the test's fake time.
    vi.useFakeTimers();
    // macOS reads Screen Recording into a process when it starts: only a server
    // started after the grant sees it.
    let restarts = 0;
    let grantedAfterRestart = Infinity;
    const engine: MacAppsEngineClient = {
      initialize: async () => ({
        protocolVersion: "2025-06-18",
        serverInfo: { name: "comma-mac-apps", version: "1.0.0" },
        capabilities: { tools: {} },
      }),
      request: async (method) => {
        const report = {
          app: "vision",
          requirements: [
            {
              requirement: "screen_recording",
              state: restarts > grantedAfterRestart ? "granted" : "not_granted",
              on_enable: true,
              tools: ["vision_recognize_screen_text"],
            },
          ],
        };
        if (method === "tools/list")
          return { tools: [{ name: "vision_recognize_screen_text" }] };
        if (method === "comma/permissions") return { apps: [report] };
        return report;
      },
      stop: async () => undefined,
      restartWhenIdle: async () => {
        restarts += 1;
        return true;
      },
    };
    const { macApps, switches } = service(engine, []);

    // macOS sends the user to System Settings; the switch stays off for now.
    expect((await macApps.setEnabled({ app: "vision", enabled: true })).enabled).toBe(
      false
    );
    vi.advanceTimersByTime(30_000);
    grantedAfterRestart = restarts;
    vi.advanceTimersByTime(30_000);

    // Back in Comma, the window's focus reads the state from a new server.
    const state = await macApps.state();
    expect(
      state.status === "ready" && state.apps.find((app) => app.id === "vision")
    ).toMatchObject({ requirements: [{ state: "granted" }] });
    expect((await macApps.setEnabled({ app: "vision", enabled: true })).enabled).toBe(
      true
    );
    expect(switches()).toEqual(["vision"]);

    // Once granted, reading the state starts no more servers.
    const before = restarts;
    vi.advanceTimersByTime(30_000);
    await macApps.state();
    expect(restarts).toBe(before);
  });
});

/** A child process on in-memory pipes, answering like MacAppsHost. */
function fakeChild(answer: (message: { id?: number; method: string }) => unknown) {
  const child = Object.assign(new EventEmitter(), {
    stdin: new PassThrough(),
    stdout: new PassThrough(),
    stderr: new PassThrough(),
  });
  let buffer = "";
  child.stdin.on("data", (chunk: Buffer) => {
    buffer += chunk.toString();
    let index: number;
    while ((index = buffer.indexOf("\n")) >= 0) {
      const message = JSON.parse(buffer.slice(0, index));
      buffer = buffer.slice(index + 1);
      if (message.id === undefined) continue;
      const result = answer(message);
      if (result !== undefined)
        child.stdout.write(
          `${JSON.stringify({ jsonrpc: "2.0", id: message.id, result })}\n`
        );
    }
  });
  return child;
}

/** An engine whose calendar tool answers `answer`. */
function calendarEngine(answer: unknown) {
  const calls: unknown[] = [];
  const engine: MacAppsEngineClient = {
    initialize: async () => ({
      protocolVersion: "2025-06-18",
      serverInfo: { name: "comma-mac-apps", version: "1.0.0" },
      capabilities: { tools: {} },
    }),
    request: async (_method, params) => {
      calls.push(params);
      return answer;
    },
    stop: async () => undefined,
    restartWhenIdle: async () => true,
  };
  return { engine, calls };
}

describe("a Mini App's calendar", () => {
  const range = { from: "2026-10-01T00:00:00Z", to: "2026-10-08T00:00:00Z" };

  it("lists the range's events through the Agents' calendar tool, without ids or notes", async () => {
    const { engine, calls } = calendarEngine({
      content: [],
      structuredContent: {
        events: [
          {
            id: "E1",
            title: "Standup",
            start: "2026-10-02T09:00:00Z",
            end: "2026-10-02T09:15:00Z",
            all_day: false,
            location: "Room 4",
            notes: "private",
          },
        ],
      },
    });
    const { macApps } = service(engine, ["calendar"]);
    expect(await macApps.calendarEvents(range)).toEqual({
      status: "ok",
      events: [
        {
          title: "Standup",
          start: "2026-10-02T09:00:00Z",
          end: "2026-10-02T09:15:00Z",
          allDay: false,
          location: "Room 4",
        },
      ],
    });
    expect(calls[0]).toMatchObject({
      name: "calendar_list_events",
      arguments: { start: "2026-10-01T00:00:00.000Z", end: "2026-10-08T00:00:00.000Z" },
    });
  });

  it("reads nothing while Calendar is off, and says when macOS denies it", async () => {
    const off = calendarEngine({ content: [] });
    expect(await service(off.engine, []).macApps.calendarEvents(range)).toEqual({
      status: "off",
    });
    expect(off.calls).toEqual([]);
    const denied = calendarEngine({
      isError: true,
      content: [],
      structuredContent: { error: { code: "permission_required", message: "" } },
    });
    expect(
      await service(denied.engine, ["calendar"]).macApps.calendarEvents(range)
    ).toEqual({
      status: "denied",
    });
    await expect(
      service(denied.engine, ["calendar"]).macApps.calendarEvents({
        from: "2026-01-01T00:00:00Z",
        to: "2027-02-01T00:00:00Z",
      })
    ).rejects.toThrow();
  });
});

describe("MacAppsHost process", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("fails a request when the server stops, then starts it again", async () => {
    vi.useFakeTimers();
    const started: ReturnType<typeof fakeChild>[] = [];
    const engine = new MacAppsEngine({
      binaryPath: "MacAppsHost",
      spawn: () => {
        const child = fakeChild((message) => {
          if (message.method === "initialize")
            return {
              protocolVersion: "2025-06-18",
              serverInfo: { name: "x", version: "1" },
            };
          if (message.method === "tools/call" && started.length === 1) {
            queueMicrotask(() => child.emit("exit", 1, null));
            return undefined;
          }
          return { ok: started.length };
        });
        started.push(child);
        return child as unknown as ChildProcessWithoutNullStreams;
      },
    });

    await expect(engine.request("tools/call", {})).rejects.toThrow(/stopped/);
    const next = engine.request("tools/call", {});
    await vi.runAllTimersAsync();
    await expect(next).resolves.toEqual({ ok: 2 });
    expect(started).toHaveLength(2);
  });

  it("keeps a server that is answering a request when asked to restart it", async () => {
    vi.useFakeTimers();
    let answerCall: (() => void) | undefined;
    const started: ReturnType<typeof fakeChild>[] = [];
    const engine = new MacAppsEngine({
      binaryPath: "MacAppsHost",
      spawn: () => {
        const child = fakeChild((message) => {
          if (message.method === "initialize")
            return {
              protocolVersion: "2025-06-18",
              serverInfo: { name: "x", version: "1" },
            };
          answerCall = () =>
            child.stdout.write(
              `${JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { ok: true } })}\n`
            );
          return undefined;
        });
        started.push(child);
        return child as unknown as ChildProcessWithoutNullStreams;
      },
    });

    const call = engine.request("tools/call", {});
    await vi.advanceTimersByTimeAsync(0);
    expect(answerCall).toBeDefined();
    expect(await engine.restartWhenIdle()).toBe(false);
    answerCall!();
    await expect(call).resolves.toEqual({ ok: true });
    expect(await engine.restartWhenIdle()).toBe(true);
    expect(started).toHaveLength(1);
  });

  it("gives up on a request the server never answers", async () => {
    vi.useFakeTimers();
    const engine = new MacAppsEngine({
      binaryPath: "MacAppsHost",
      requestTimeoutMs: 1_000,
      spawn: () =>
        fakeChild((message) =>
          message.method === "initialize"
            ? { protocolVersion: "2025-06-18", serverInfo: { name: "x", version: "1" } }
            : undefined
        ) as unknown as ChildProcessWithoutNullStreams,
    });
    const pending = engine.request("tools/call", {});
    const settled = expect(pending).rejects.toThrow(
      /did not answer tools\/call in time/
    );
    await vi.advanceTimersByTimeAsync(1_000);
    await settled;
  });
});

describe("Mac app cards", () => {
  it("hands the Agent a card of the event it made, and how to show it", async () => {
    const event = {
      id: "E1",
      title: "Design review",
      start: "2026-10-20T10:00:00Z",
      end: "2026-10-20T11:00:00Z",
      all_day: false,
      calendar: "Work",
      calendar_color: "#0088ff",
      notes: "not on the card",
    };
    const engine: MacAppsEngineClient = {
      initialize: async () => ({
        protocolVersion: "2025-06-18",
        serverInfo: { name: "comma-mac-apps", version: "1.0.0" },
        capabilities: { tools: {} },
      }),
      request: async (method) =>
        method === "tools/list"
          ? { tools }
          : {
              content: [{ type: "text", text: JSON.stringify({ event }) }],
              structuredContent: { event },
            },
      stop: async () => undefined,
      restartWhenIdle: async () => true,
    };
    const { rpc } = service(engine, ["calendar"]);

    const reply = await rpc("tools/call", {
      name: "calendar_create_event",
      arguments: {},
    });
    const content = (reply!.result as { content: Array<{ text: string }> }).content;
    expect(content).toHaveLength(2);
    expect(content[1]!.text).toContain("im_api.internal.send_message");
    expect(JSON.parse(content[1]!.text.split("\n")[1]!)).toEqual([
      {
        type: "mac_app_item",
        app: "calendar",
        item_id: "E1",
        title: "Design review",
        start: "2026-10-20T10:00:00Z",
        end: "2026-10-20T11:00:00Z",
        calendar: "Work",
        color: "#0088FF",
      },
    ]);
  });

  it("opens an item only by its app's fixed link", async () => {
    const opened: string[] = [];
    const macApps = new MacAppsService({
      engine: fakeEngine().engine,
      switches: { enabledApps: async () => [], setEnabledApps: async () => undefined },
      driveRoot: async () => undefined,
      openExternal: async (url) => {
        opened.push(url);
      },
    });

    await macApps.openItem({
      app: "reminders",
      itemId: "3C8C2A71-84BF-4C87-8EFD-BB4827650D15",
    });
    await macApps.openItem({
      app: "maps",
      title: "Cafe",
      latitude: 35.6,
      longitude: 139.7,
    });
    await macApps.openItem({ app: "calendar", itemId: "E1" });
    expect(await macApps.openItem({ app: "reminders", itemId: "../../etc" })).toEqual({
      opened: false,
    });
    expect(opened).toEqual([
      "x-apple-reminderkit://REMCDReminder/3C8C2A71-84BF-4C87-8EFD-BB4827650D15",
      "maps://?q=Cafe&ll=35.6,139.7",
      "file:///System/Applications/Calendar.app",
    ]);
  });
});
