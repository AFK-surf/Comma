import { describe, expect, it, vi } from "vitest";
import { connect } from "../android-host";
import {
  DYNAMIC_UI_WIRE_MAX_BYTES,
  nativeWire,
  type DynamicUiHost,
} from "../native-host";

/** A port the app holds the other end of: what the page sent, and a way to send to the page. */
function fakePort() {
  const sent: unknown[] = [];
  let listener: ((event: { data: unknown }) => void) | undefined;
  const port = {
    postMessage: (message: string) => sent.push(JSON.parse(message)),
    addEventListener: (_: "message", next: (event: { data: unknown }) => void) => {
      listener = next;
    },
    start: vi.fn(),
    close: vi.fn(),
  };
  return { port, sent, fromApp: (data: unknown) => listener?.({ data }) };
}

/** The host page's window, a fake runtime frame, and the page connected to them. */
function page() {
  let accept: ((event: MessageEvent) => void) | undefined;
  const window = {
    addEventListener: (_: "message", listener: (event: MessageEvent) => void) => {
      accept = listener;
    },
    removeEventListener: () => {
      accept = undefined;
    },
  };
  let native: ((wire: string) => void) | undefined;
  let started: (() => void) | undefined;
  let failed: ((error: Error) => void) | undefined;
  let run: Promise<void> | undefined;
  const host = {
    start: vi.fn(() => {
      run = new Promise<void>((resolve, reject) => {
        started = resolve;
        failed = reject;
      });
      return run;
    }),
    stop: vi.fn(),
  };
  const install = vi.fn((next: (wire: string) => void) => {
    native = next;
    return host as unknown as DynamicUiHost;
  });
  connect(window, install);
  return {
    host,
    install,
    post: (event: Partial<MessageEvent>) => accept?.(event as MessageEvent),
    get listening() {
      return accept !== undefined;
    },
    frameSays: (wire: string) => native?.(wire),
    started: () => started?.(),
    failed: (error: Error) => failed?.(error),
    /** Settles after the page's own start handler, which was attached first. */
    settled: () =>
      run?.then(
        () => undefined,
        () => undefined
      ),
  };
}

describe("Android Dynamic UI host page", () => {
  it("takes only the app's one port, never one from a frame", () => {
    const view = page();
    const frame = fakePort();
    view.post({
      source: {} as Window,
      data: "comma-native",
      ports: [frame.port as never],
    });
    view.post({ source: null, data: "other", ports: [frame.port as never] });
    view.post({ source: null, data: "comma-native", ports: [] });
    expect(frame.sent).toEqual([]);
    expect(view.listening).toBe(true);

    const app = fakePort();
    view.post({ source: null, data: "comma-native", ports: [app.port as never] });
    expect(app.sent).toEqual([{ kind: "connected" }]);
    // Once connected, the page no longer listens for another port.
    expect(view.listening).toBe(false);
  });

  it("starts the frame once, after the port, and forwards only what the shared host lets through", async () => {
    const view = page();
    const app = fakePort();
    expect(view.install).not.toHaveBeenCalled();
    view.post({ source: null, data: "comma-native", ports: [app.port as never] });
    expect(view.install).not.toHaveBeenCalled();

    app.fromApp(JSON.stringify({ kind: "start", init: { payload: { html: "<p>" } } }));
    app.fromApp(JSON.stringify({ kind: "start", init: { payload: {} } }));
    expect(view.install).toHaveBeenCalledTimes(1);
    expect(view.host.start).toHaveBeenCalledWith({ payload: { html: "<p>" } });
    view.started();
    await view.settled();
    view.frameSays('{"type":"ready"}');
    expect(app.sent).toEqual([
      { kind: "connected" },
      { kind: "started" },
      { kind: "event", wire: '{"type":"ready"}' },
    ]);
  });

  it("reports a frame that does not start, and refuses a start without init", async () => {
    const view = page();
    const app = fakePort();
    view.post({ source: null, data: "comma-native", ports: [app.port as never] });
    app.fromApp("not json");
    app.fromApp(JSON.stringify({ kind: "start", init: [] }));
    expect(view.install).not.toHaveBeenCalled();
    app.fromApp(JSON.stringify({ kind: "start", init: {} }));
    view.failed(Error("Interactive content did not start."));
    await view.settled();
    expect(app.sent.slice(1)).toEqual([
      { kind: "failed", reason: "Interactive content did not start." },
      { kind: "failed", reason: "Interactive content did not start." },
    ]);
  });

  it("stops the frame and sends nothing after stop", async () => {
    const view = page();
    const app = fakePort();
    view.post({ source: null, data: "comma-native", ports: [app.port as never] });
    app.fromApp(JSON.stringify({ kind: "start", init: {} }));
    app.fromApp(JSON.stringify({ kind: "stop" }));
    expect(view.host.stop).toHaveBeenCalledTimes(1);
    expect(app.port.close).toHaveBeenCalled();
    view.started();
    await view.settled();
    view.frameSays('{"type":"ready"}');
    app.fromApp(JSON.stringify({ kind: "start", init: {} }));
    expect(app.sent).toEqual([{ kind: "connected" }]);
    expect(view.install).toHaveBeenCalledTimes(1);
  });
});

describe("runtime messages a phone app receives", () => {
  it("passes the app's message types and drops the rest", () => {
    for (const type of ["request", "open-link", "save", "card-state", "error", "ready"])
      expect(nativeWire({ type, value: 1 })).toBe(JSON.stringify({ type, value: 1 }));
    for (const message of [
      { type: "height", value: 100 },
      { type: "init" },
      { value: 1 },
      null,
      "ready",
      7,
    ])
      expect(nativeWire(message)).toBeUndefined();
  });

  it("drops a message over the size bound, counted in UTF-8", () => {
    const fits = { type: "save", value: "x".repeat(DYNAMIC_UI_WIRE_MAX_BYTES - 40) };
    expect(nativeWire(fits)).toBeDefined();
    // Three bytes a character: under the bound in characters, over it in bytes.
    const wide = { type: "save", value: "界".repeat(DYNAMIC_UI_WIRE_MAX_BYTES / 2) };
    expect(nativeWire(wide)).toBeUndefined();
  });
});
