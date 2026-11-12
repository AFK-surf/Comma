/* eslint-disable unicorn/require-post-message-target-origin -- TestPort models MessagePort, which has no target origin. */
import { CoreError } from "@comma/core-client";
import {
  act,
  render as baseRender,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { stubProperty } from "@comma/test-utils/stub-property";
import type { ReactElement, ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MiniAppFrame, MiniAppFrameKeeper } from "../MiniAppFrame";

class TestPort extends EventTarget {
  peer?: TestPort;
  sent: { data: unknown; transfer?: unknown[] }[] = [];
  postMessage(data: unknown, transfer?: unknown[]) {
    this.sent.push({ data, ...(transfer ? { transfer } : {}) });
    this.peer?.dispatchEvent(new MessageEvent("message", { data }));
  }
  start() {}
  close() {}
}
class TestChannel {
  port1 = new TestPort();
  port2 = new TestPort();
  constructor() {
    this.port1.peer = this.port2;
    this.port2.peer = this.port1;
  }
}

const info = {
  session: "mas-1",
  app: {
    id: "a1",
    name: "Habit tracker",
    author: { name: "Ada" },
    status: "active",
    capabilities: ["identity.basic", "notifications"],
    egress: ["api.open-meteo.com"],
    grants: [],
  },
  version: 2,
  digest: "d",
  guest: false,
  viewer: { id: "v", name: "Ada", avatarUrl: null, guest: false },
  capabilities: ["identity.basic", "notifications"],
  grants: [],
  storage: ["device"],
};

let invoke: (params: { op: string; args?: unknown; confirmed?: boolean }) => unknown;
let core: ReturnType<typeof createScriptedCore>;
function render(ui: ReactElement) {
  return baseRender(ui, {
    wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
  });
}

beforeEach(() => {
  invoke = () => ({ status: "done", value: null });
  core = createScriptedCore({
    calls: (name, params) => {
      if (name === "miniApps.session.open") return info;
      if (name === "miniApps.bundle")
        return {
          digest: "d",
          files: [
            {
              path: "index.html",
              mime: "text/html",
              data: new TextEncoder().encode("<p>"),
            },
          ],
        };
      if (name === "miniApps.invoke") return invoke(params as { op: string });
      if (name === "miniApps.grant") return { grants: ["identity.basic"] };
      return null;
    },
  });
  vi.stubGlobal("MessageChannel", TestChannel);
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

/** The frame says it is ready, from `source`; the port the host handed over, if it did. */
function ready(frame: HTMLIFrameElement, source: MessageEventSource | null) {
  let port: TestPort | undefined;
  let init: unknown;
  vi.spyOn(frame.contentWindow!, "postMessage").mockImplementation(((
    data: { type: string; init?: unknown },
    _target: string,
    ports?: TestPort[]
  ) => {
    if (data.type !== "comma-app:init") return;
    init = data.init;
    port = ports?.[0];
  }) as typeof window.postMessage);
  act(() =>
    window.dispatchEvent(
      new MessageEvent("message", { source, data: { type: "comma-app:ready" } })
    )
  );
  return { port: () => port, init: () => init };
}

const results = (port: TestPort) =>
  port.sent.map((s) => s.data as { type: string }).filter((d) => d.type === "result");

describe("an app's host", () => {
  it("delegates only the session's declared hardware capabilities without changing the sandbox origin", async () => {
    core = createScriptedCore({
      calls: (name) => {
        if (name === "miniApps.session.open")
          return { ...info, capabilities: ["usb", "bluetooth", "microphone"] };
        if (name === "miniApps.bundle") return { digest: "d", files: [] };
        return null;
      },
    });
    render(<MiniAppFrame appId="a1" via={{ workspace: "wsp" }} />);
    const frame = await screen.findByTestId("mini-app-frame");
    expect(frame.getAttribute("allow")).toBe("usb *; bluetooth *");
    expect(frame.getAttribute("sandbox")).toBe("allow-scripts allow-forms");
    expect(new URL(frame.getAttribute("src")!).pathname).toBe("/app-runtime/");
  });
  it("hands its port only to its own frame, then the app's files", async () => {
    render(<MiniAppFrame appId="a1" via={{ workspace: "wsp" }} />);
    const frame = (await screen.findByTestId("mini-app-frame")) as HTMLIFrameElement;
    expect(frame.getAttribute("sandbox")).toBe("allow-scripts allow-forms");
    expect(frame.getAttribute("allow")).toBe("");
    expect(frame.getAttribute("referrerpolicy")).toBe("no-referrer");
    expect(screen.getByText("Habit tracker")).toBeTruthy();
    // Who made the app is at the foot of the chrome's own menu.
    act(() => screen.getByRole("button", { name: "App actions" }).click());
    expect(await screen.findByText("Ada")).toBeTruthy();

    // Another window (this one, or any other frame) gets nothing.
    const stranger = ready(frame, window);
    expect(stranger.port()).toBeUndefined();

    const own = ready(frame, frame.contentWindow);
    expect(own.port()).toBeDefined();
    expect(own.init()).toMatchObject({
      app: { id: "a1", name: "Habit tracker", version: 2 },
      // identity.basic is not granted: no viewer.
      viewer: null,
      capabilities: ["identity.basic", "notifications"],
      storage: ["device"],
    });
    const host = own.port()!.peer!;
    await waitFor(() =>
      expect(host.sent.some((s) => (s.data as { type: string }).type === "files")).toBe(
        true
      )
    );
    const files = host.sent.find((s) => (s.data as { type: string }).type === "files")!;
    expect((files.data as { files: { path: string }[] }).files[0]!.path).toBe(
      "index.html"
    );
    // Its bytes are transferred to the frame.
    expect((files.transfer![0] as ArrayBuffer).byteLength).toBe(3);
  });

  it("asks the viewer on the grant sheet, then calls again", async () => {
    invoke = () => ({ status: "grant", capability: "identity.basic" });
    render(<MiniAppFrame appId="a1" via={{ workspace: "wsp" }} />);
    const frame = (await screen.findByTestId("mini-app-frame")) as HTMLIFrameElement;
    const own = ready(frame, frame.contentWindow);
    const app = own.port()!;
    act(() => app.postMessage({ type: "call", id: 1, op: "viewer", args: {} }));
    const sheet = await screen.findByTestId("mini-app-grant-sheet");
    expect(sheet.textContent).toContain("your name and picture");
    expect(screen.getByTestId("mini-app-grant-egress").textContent).toContain(
      "api.open-meteo.com"
    );
    invoke = () => ({ status: "done", value: { id: "v", name: "Ada" } });
    act(() => screen.getByRole("button", { name: /^Allow/ }).click());
    await waitFor(() =>
      expect(results(app.peer!)).toContainEqual({
        type: "result",
        id: 1,
        ok: true,
        value: { id: "v", name: "Ada" },
      })
    );
    expect(core.sentTo("miniApps.grant")).toEqual([
      { session: "mas-1", capability: "identity.basic" },
    ]);
    // The frame learns its new grants.
    expect(app.peer!.sent.map((s) => s.data)).toContainEqual({
      type: "grants",
      grants: ["identity.basic"],
    });
  });

  it("says a denied grant is denied", async () => {
    invoke = () => ({ status: "grant", capability: "notifications" });
    render(<MiniAppFrame appId="a1" via={{ workspace: "wsp" }} />);
    const frame = (await screen.findByTestId("mini-app-frame")) as HTMLIFrameElement;
    const app = ready(frame, frame.contentWindow).port()!;
    act(() =>
      app.postMessage({ type: "call", id: 7, op: "notify", args: { title: "x" } })
    );
    await screen.findByTestId("mini-app-grant-sheet");
    act(() => screen.getByRole("button", { name: /Don't allow/ }).click());
    await waitFor(() =>
      expect(results(app.peer!)).toContainEqual(
        expect.objectContaining({
          id: 7,
          ok: false,
          error: expect.objectContaining({ code: "denied" }),
        })
      )
    );
    expect(core.sentTo("miniApps.grant")).toEqual([]);
  });

  it("creates a Task only after the viewer confirms it in host UI", async () => {
    invoke = (params) =>
      params.confirmed
        ? { status: "done", value: { created: true } }
        : {
            status: "confirm",
            capability: "tasks.create",
            op: "tasks.propose",
            args: { text: "Plan my week" },
          };
    render(<MiniAppFrame appId="a1" via={{ workspace: "wsp" }} />);
    const frame = (await screen.findByTestId("mini-app-frame")) as HTMLIFrameElement;
    const app = ready(frame, frame.contentWindow).port()!;
    act(() =>
      app.postMessage({
        type: "call",
        id: 3,
        op: "tasks.propose",
        args: { text: "Plan my week" },
      })
    );
    expect((await screen.findByTestId("mini-app-confirm-detail")).textContent).toBe(
      "Plan my week"
    );
    expect(core.sentTo("miniApps.invoke")).toHaveLength(1);
    act(() => screen.getByRole("button", { name: /Create Task/ }).click());
    await waitFor(() =>
      expect(results(app.peer!)).toContainEqual({
        type: "result",
        id: 3,
        ok: true,
        value: { created: true },
      })
    );
    expect(core.sentTo("miniApps.invoke")[1]).toMatchObject({ confirmed: true });

    // A cancel answers the app without a Task.
    act(() =>
      app.postMessage({
        type: "call",
        id: 4,
        op: "tasks.propose",
        args: { text: "Plan my week" },
      })
    );
    await screen.findByTestId("mini-app-confirm-detail");
    act(() => screen.getByRole("button", { name: /Cancel/ }).click());
    await waitFor(() =>
      expect(results(app.peer!)).toContainEqual({
        type: "result",
        id: 4,
        ok: true,
        value: { created: false },
      })
    );
    expect(core.sentTo("miniApps.invoke")).toHaveLength(3);
  });

  it("records the microphone in the host and streams its samples to the app until it stops", async () => {
    invoke = (params) => ({ status: "host", op: params.op, args: params.args });
    const track = Object.assign(new EventTarget(), {
      stop: vi.fn(),
      label: "USB Audio",
      getSettings: () => ({ deviceId: "usb" }),
    });
    const media = { getTracks: () => [track], getAudioTracks: () => [track] };
    const getUserMedia = vi.fn(async () => media);
    stubProperty(navigator, "mediaDevices", { value: { getUserMedia } });
    const processor = Object.assign(new EventTarget(), {
      connect: vi.fn(),
      disconnect: vi.fn(),
    });
    const close = vi.fn(async () => undefined);
    vi.stubGlobal(
      "AudioContext",
      class {
        sampleRate = 48_000;
        destination = {};
        createMediaStreamSource = () => ({ connect: vi.fn(), disconnect: vi.fn() });
        createScriptProcessor = () => processor;
        close = close;
      }
    );
    render(<MiniAppFrame appId="a1" via={{ workspace: "wsp" }} />);
    const frame = (await screen.findByTestId("mini-app-frame")) as HTMLIFrameElement;
    const app = ready(frame, frame.contentWindow).port()!;
    act(() =>
      app.postMessage({
        type: "call",
        id: 5,
        op: "microphone.start",
        args: { deviceId: "usb" },
      })
    );
    await waitFor(() =>
      expect(results(app.peer!)).toContainEqual({
        type: "result",
        id: 5,
        ok: true,
        value: {
          stream: 1,
          sampleRate: 48_000,
          device: { id: "usb", name: "USB Audio" },
        },
      })
    );
    // The chosen input, raw: no echo cancellation, noise suppression or gain.
    expect(getUserMedia).toHaveBeenCalledWith({
      audio: expect.objectContaining({
        deviceId: { exact: "usb" },
        echoCancellation: false,
        autoGainControl: false,
      }),
    });
    const chunk = Float32Array.from([0.25, -0.25]);
    act(() => {
      processor.dispatchEvent(
        Object.assign(new Event("audioprocess"), {
          inputBuffer: { getChannelData: () => chunk },
        })
      );
    });
    const streamed = app.peer!.sent.find(
      (s) => (s.data as { type: string }).type === "stream"
    )!;
    expect(streamed.data).toEqual({ type: "stream", stream: 1, data: chunk });
    // The samples are a copy, transferred to the frame.
    expect(streamed.transfer).toHaveLength(1);

    act(() =>
      app.postMessage({
        type: "call",
        id: 6,
        op: "microphone.stop",
        args: { stream: 1 },
      })
    );
    await waitFor(() => expect(track.stop).toHaveBeenCalled());
    expect(close).toHaveBeenCalled();
  });

  it("lists the audio inputs and tells the app when they change", async () => {
    invoke = (params) => ({ status: "host", op: params.op, args: params.args });
    const usb = { kind: "audioinput", deviceId: "usb", label: "USB Audio" };
    let devices: { kind: string; deviceId: string; label: string }[] = [
      { kind: "audioinput", deviceId: "", label: "" },
      { kind: "videoinput", deviceId: "", label: "" },
    ];
    const getUserMedia = vi.fn(async () => {
      // The page may use the microphone now: the browser shows the inputs.
      devices = [{ kind: "audioinput", deviceId: "mac", label: "MacBook Microphone" }];
      return { getTracks: () => [{ stop: vi.fn() }] };
    });
    const mediaDevices = Object.assign(new EventTarget(), {
      getUserMedia,
      enumerateDevices: vi.fn(async () => devices),
    });
    stubProperty(navigator, "mediaDevices", { value: mediaDevices });
    render(<MiniAppFrame appId="a1" via={{ workspace: "wsp" }} />);
    const frame = (await screen.findByTestId("mini-app-frame")) as HTMLIFrameElement;
    const app = ready(frame, frame.contentWindow).port()!;
    act(() =>
      app.postMessage({ type: "call", id: 5, op: "microphone.devices", args: {} })
    );
    await waitFor(() =>
      expect(results(app.peer!)).toContainEqual({
        type: "result",
        id: 5,
        ok: true,
        value: { devices: [{ id: "mac", name: "MacBook Microphone" }] },
      })
    );
    expect(getUserMedia).toHaveBeenCalledOnce();

    act(() =>
      app.postMessage({ type: "call", id: 6, op: "microphone.watch", args: {} })
    );
    await waitFor(() =>
      expect(results(app.peer!)).toContainEqual({
        type: "result",
        id: 6,
        ok: true,
        value: { stream: 1, devices: [{ id: "mac", name: "MacBook Microphone" }] },
      })
    );
    devices = [...devices, usb];
    act(() => {
      mediaDevices.dispatchEvent(new Event("devicechange"));
    });
    await waitFor(() =>
      expect(app.peer!.sent.map((s) => s.data)).toContainEqual({
        type: "stream",
        stream: 1,
        data: [
          { id: "mac", name: "MacBook Microphone" },
          { id: "usb", name: "USB Audio" },
        ],
      })
    );
    // The labels show without asking for the microphone again.
    expect(getUserMedia).toHaveBeenCalledOnce();

    act(() =>
      app.postMessage({
        type: "call",
        id: 7,
        op: "microphone.stop",
        args: { stream: 1 },
      })
    );
    await waitFor(() =>
      expect(results(app.peer!)).toContainEqual({
        type: "result",
        id: 7,
        ok: true,
        value: null,
      })
    );
    // A stopped watch no longer listens.
    const listed = mediaDevices.enumerateDevices.mock.calls.length;
    act(() => {
      mediaDevices.dispatchEvent(new Event("devicechange"));
    });
    expect(mediaDevices.enumerateDevices).toHaveBeenCalledTimes(listed);
  });

  it("reads the clipboard only after the viewer confirms each read", async () => {
    invoke = (params) =>
      params.confirmed
        ? { status: "host", op: "clipboard.read", args: {} }
        : {
            status: "confirm",
            capability: "clipboard.read",
            op: "clipboard.read",
            args: {},
          };
    const readText = vi.fn(async () => "pasted");
    stubProperty(navigator, "clipboard", { value: { readText } });
    render(<MiniAppFrame appId="a1" via={{ workspace: "wsp" }} />);
    const frame = (await screen.findByTestId("mini-app-frame")) as HTMLIFrameElement;
    const app = ready(frame, frame.contentWindow).port()!;
    act(() => app.postMessage({ type: "call", id: 8, op: "clipboard.read", args: {} }));
    const cancel = await screen.findByRole("button", { name: /Cancel/ });
    act(() => cancel.click());
    await waitFor(() =>
      expect(results(app.peer!)).toContainEqual(
        expect.objectContaining({
          id: 8,
          ok: false,
          error: expect.objectContaining({ code: "denied" }),
        })
      )
    );
    expect(readText).not.toHaveBeenCalled();

    act(() => app.postMessage({ type: "call", id: 9, op: "clipboard.read", args: {} }));
    const paste = await screen.findByRole("button", { name: /Paste/ });
    act(() => paste.click());
    await waitFor(() =>
      expect(results(app.peer!)).toContainEqual({
        type: "result",
        id: 9,
        ok: true,
        value: { text: "pasted" },
      })
    );
  });

  it("replaces the frame when the app is paused", async () => {
    invoke = () => ({ status: "error", code: "app_paused", message: "paused" });
    render(<MiniAppFrame appId="a1" via={{ workspace: "wsp" }} />);
    const frame = (await screen.findByTestId("mini-app-frame")) as HTMLIFrameElement;
    const app = ready(frame, frame.contentWindow).port()!;
    act(() =>
      app.postMessage({ type: "call", id: 2, op: "storage.app.get", args: {} })
    );
    await screen.findByTestId("mini-app-notice-paused");
    expect(screen.queryByTestId("mini-app-frame")).toBeNull();
    expect(screen.getByText("This app is paused")).toBeTruthy();
  });

  it("shows a paused app paused when it opens, still naming the app and its maker", async () => {
    core = createScriptedCore({
      calls: (name) => {
        if (name === "miniApps.session.open")
          throw new CoreError({ code: "app_paused", message: "" });
        return null;
      },
      values: (topic) =>
        topic.topic === "miniApp" && topic.app === "a1"
          ? { status: "ready", app: info.app, versions: [], link: null, error: null }
          : undefined,
    });
    render(<MiniAppFrame appId="a1" via={{ workspace: "wsp" }} />);
    await screen.findByTestId("mini-app-notice-paused");
    const chrome = screen.getByTestId("mini-app-chrome");
    await waitFor(() => expect(chrome.textContent).toContain("Habit tracker"));
    act(() => within(chrome).getByRole("button", { name: "App actions" }).click());
    expect(await screen.findByText("Ada")).toBeTruthy();
  });
});

const keptView = (account: string) => (
  <MiniAppFrameKeeper account={account}>
    <MiniAppFrame appId="a1" keepKey="wsp/a1@2" via={{ workspace: "wsp" }} />
  </MiniAppFrameKeeper>
);

describe("a kept app", () => {
  // jsdom has no moveBefore; insertBefore moves the node the same way here (no document to keep).
  beforeEach(() => {
    stubProperty(Element.prototype, "moveBefore", {
      value(this: Element, node: Node, child: Node | null) {
        this.insertBefore(node, child);
      },
    });
  });

  it("shows that it stopped when the account switches while it is on screen", async () => {
    const { rerender } = render(keptView("ada"));
    await screen.findByTestId("mini-app-frame");

    rerender(keptView("bob"));
    await screen.findByTestId("mini-app-notice-stopped");
    expect(screen.queryByTestId("mini-app-frame")).toBeNull();
  });
});
