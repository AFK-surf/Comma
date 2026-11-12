import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import type { ScreenViewEvent } from "@comma/core/contract";
import { act, cleanup, fireEvent, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { useState } from "react";
import { afterEach, expect, it, onTestFinished, vi } from "vitest";
import { installUiClock, uiClock } from "@comma/ui/clock";
import { createVirtualUiClock } from "@comma/ui/clock/virtual";
import { bitrateText } from "../screenStreamStats";
import { openMeshScreenStream, type ScreenViewMessage } from "../meshScreenStream";
import { holdScreenStream, type HeldScreenStreamView } from "../remoteScreenStream";
import type { ScreenStreamState } from "../meshScreenStream";
import { ScreenStreamPanel } from "../ScreenStreamPanel";
import { ScreenStreamStage, type ScreenStreamSource } from "../ScreenStreamStage";
import { ScreenStreamWindow } from "../ScreenStreamWindow";
import { keepScreenControl } from "../screenWindows";
import { fakeDeviceCapabilities, fakePhone } from "./fakeScreenDevice";
import { DESCRIPTION, FRAMES, bytes } from "./h264Frames";

afterEach(cleanup);

// Everything a test waits on says it changed here: the view asked, a frame shown, the page changed. A wait has no
// deadline of its own: the test job's hang guard is the only bound.
let waiting: (() => void)[] = [];
const changed = () => {
  const woken = waiting;
  waiting = [];
  for (const wake of woken) wake();
};
async function until(what: () => boolean) {
  while (!what()) await new Promise<void>((resolve) => waiting.push(resolve));
}

const nothing = () => undefined;
const failed = (code: string, message: string) =>
  Object.assign(new Error(message), { code });

/** A station's view in the page: what it was told, and frames to give it. */
function viewing(options: { framesOnOpen?: boolean } = {}) {
  let emit: (event: ScreenViewEvent) => void = nothing;
  let reject: (error: Error) => void = nothing;
  const said: [number, ScreenViewMessage][] = [];
  const open = vi.fn(
    (
      onEvent: (event: ScreenViewEvent) => void,
      signal: AbortSignal,
      _codecs?: readonly string[],
      _control?: boolean
    ) =>
      new Promise((_, no) => {
        emit = onEvent;
        reject = no;
        changed();
        signal.addEventListener("abort", () => no(failed("cancelled", "cancelled")));
        if (options.framesOnOpen) frames();
      })
  );
  const started = () => until(() => open.mock.calls.length > 0);
  function frames() {
    emit({ type: "open", view: 7 });
    // (as a station does first: Watch, and that it switches on the open view)
    emit({ type: "state", state: { control: false, switches: true } });
    emit({
      type: "config",
      codec: "h264",
      width: 64,
      height: 48,
      description: DESCRIPTION,
    });
    FRAMES.forEach((frame, at) =>
      emit({ type: "video", key: at === 0, ts: (at + 1) * 1000, data: bytes(frame) })
    );
  }
  return {
    open,
    said,
    started,
    frames,
    emit: (event: ScreenViewEvent) => emit(event),
    send: (view: number, message: ScreenViewMessage) => {
      said.push([view, message]);
      changed();
    },
    reject: (error: Error) => reject(error),
  };
}

/** The last frame shown: only its output acknowledges the newest frame. */
const decodedAll = (view: ReturnType<typeof viewing>) =>
  view.said.some(
    ([, message]) => "ack" in message && message.ack === FRAMES.length * 1000
  );

function meshSource(view: ReturnType<typeof viewing>, key: string): ScreenStreamSource {
  return {
    key,
    view: {
      open: (_request, onEvent, signal) => view.open(onEvent, signal),
      send: view.send,
    },
  };
}

it("decodes real frames with WebCodecs, shows them as a stream, and acknowledges each", async () => {
  const view = viewing();
  const states: string[] = [];
  const media: MediaStream[] = [];
  const peer = openMeshScreenStream({
    open: view.open,
    send: view.send,
    onStream: (stream) => media.push(stream),
    onState: (state) => states.push(state),
    onFailure: () => undefined,
    onUnavailable: () => expect.unreachable("this page decodes"),
  });
  await view.started();
  view.frames();
  await until(() => decodedAll(view));
  // Each frame acknowledged; the older of two inside the decoder is let go, acknowledged before it is shown.
  const acks = view.said.map(([, message]) => ("ack" in message ? message.ack : -1));
  expect([...new Set(acks)].toSorted((a, b) => a - b)).toEqual(
    FRAMES.map((_, at) => (at + 1) * 1000)
  );
  expect(states).toEqual(["live"]);

  const video = document.createElement("video");
  video.muted = true;
  video.srcObject = media[0]!;
  document.body.append(video);
  void video.play().catch(() => undefined);
  peer.send({ type: "move", x: 0.5, y: 0.5, mods: [] });
  expect(view.said.at(-1)).toEqual([
    7,
    { input: { type: "move", x: 0.5, y: 0.5, mods: [] } },
  ]);
  peer.close();
  video.remove();
});

it("switches Watch and Control on the open view, where the station says it does, and keeps the picture", async () => {
  const view = viewing();
  const refused: string[] = [];
  const peer = openMeshScreenStream({
    open: view.open,
    send: view.send,
    onStream: nothing,
    onState: nothing,
    onFailure: nothing,
    onRefused: (why) => refused.push(why),
    onUnavailable: () => expect.unreachable("this page decodes"),
  });
  await view.started();
  expect(view.open.mock.calls[0]![3]).toBe(false);
  view.frames();
  // Asked before the station says it switches: told once it does.
  expect(peer.control!(true)).toBe(true);
  view.emit({ type: "state", state: { control: false, switches: true } });
  await until(() => view.said.some(([, message]) => "control" in message));
  expect(peer.control!(false)).toBe(true);
  expect(view.said.filter(([, message]) => "control" in message)).toEqual([
    [7, { control: true }],
    [7, { control: false }],
  ]);
  view.emit({
    type: "state",
    state: { control: false, refused: "this view only looks" },
  });
  expect(refused).toEqual(["this view only looks"]);
  expect(view.open).toHaveBeenCalledOnce();
  peer.close();
});

it("a station from before takes Control only as a view opens: the switch says so", async () => {
  const view = viewing();
  const peer = openMeshScreenStream({
    open: view.open,
    send: view.send,
    onStream: nothing,
    onState: nothing,
    onFailure: nothing,
    onUnavailable: () => expect.unreachable("this page decodes"),
  });
  await view.started();
  view.emit({ type: "open", view: 7 });
  view.emit({ type: "state", state: { control: false } });
  expect(peer.control!(true)).toBe(false);
  expect(view.said.some(([, message]) => "control" in message)).toBe(false);
  peer.close();
});

it("a switch asked while the view opens, on a station from before, is said lost", async () => {
  const view = viewing();
  const lost = vi.fn();
  const peer = openMeshScreenStream({
    open: view.open,
    send: view.send,
    onStream: nothing,
    onState: nothing,
    onFailure: nothing,
    onSwitchLost: lost,
    onUnavailable: () => expect.unreachable("this page decodes"),
  });
  await view.started();
  expect(peer.control!(true)).toBe(true);
  view.emit({ type: "open", view: 7 });
  view.emit({ type: "state", state: { control: false } });
  expect(lost).toHaveBeenCalledOnce();
  expect(view.said.some(([, message]) => "control" in message)).toBe(false);
  peer.close();
});

it("shows a still screen's last frame to a holder that comes to the stream later", async () => {
  const view = viewing();
  const shown = (held: { media: MediaStream | null }) => {
    const video = document.createElement("video");
    video.muted = true;
    video.addEventListener("resize", changed);
    video.srcObject = held.media;
    document.body.append(video);
    void video.play().catch(() => undefined);
    return video;
  };
  const options = { target: "app", control: false, background: undefined } as const;
  const source = meshSource(view, "still");
  let media: MediaStream | null = null;
  const first = holdScreenStream({ source, ...options }, (held) => {
    media = held.media;
    changed();
  });
  await view.started();
  view.frames();
  await until(() => decodedAll(view));
  const before = shown({ media });
  first.release();
  before.remove();

  // No frame comes after this: only what the stream kept can show.
  let late: HTMLVideoElement | undefined;
  const second = holdScreenStream({ source, ...options }, (held) => {
    late = shown(held);
  });
  await until(() => late!.videoWidth > 0);
  expect([late!.videoWidth, late!.videoHeight]).toEqual([64, 48]);
  second.release();
  late!.remove();
});

it.each(["unsupported", "unknown_call"])(
  "goes another way where the mesh is not the way (%s), before anything was shown",
  async (code) => {
    const view = viewing();
    const unavailable = vi.fn(changed);
    const failure = vi.fn();
    openMeshScreenStream({
      open: view.open,
      send: view.send,
      onStream: () => undefined,
      onState: () => undefined,
      onFailure: failure,
      onUnavailable: unavailable,
    });
    await view.started();
    view.reject(failed(code, "no such views"));
    await until(() => unavailable.mock.calls.length > 0);
    expect(unavailable).toHaveBeenCalledOnce();
    expect(failure).not.toHaveBeenCalled();
  }
);

it("shows why a screen failed, in the card rather than nowhere, and tries again when asked", async () => {
  const view = viewing();
  const core = createScriptedCore({ values: () => undefined });
  const source = meshSource(view, "workspace\\ndevice\\nfailing");
  function Stage() {
    const [state, setState] = useState<ScreenStreamState>("connecting");
    return (
      <ScreenStreamStage
        control={false}
        onState={setState}
        source={source}
        state={state}
        target="app"
      />
    );
  }
  const page = render(core.wrap(<Stage />));
  const shown = new MutationObserver(changed);
  shown.observe(document.body, { childList: true, subtree: true });
  await view.started();
  view.reject(failed("forbidden", "its access is not Full"));
  await until(() => screen.queryByRole("alert") !== null);
  const alert = screen.getByRole("alert");
  expect(alert.textContent).toContain("its access is not Full");

  alert.querySelector("button")!.click();
  await until(() => view.open.mock.calls.length === 2);
  await until(() => screen.queryByRole("alert") === null);
  shown.disconnect();
  page.unmount();
});

it("shows a capture refusal after live video and waits for a person's retry", async () => {
  const clock = createVirtualUiClock();
  const restore = installUiClock(clock);
  onTestFinished(restore);
  const view = viewing();
  const source = meshSource(view, "native-capture-refused");
  const core = createScriptedCore({ values: () => undefined });
  function Stage() {
    const [state, setState] = useState<ScreenStreamState>("connecting");
    return (
      <ScreenStreamStage
        control={false}
        onState={setState}
        source={source}
        state={state}
        target="app"
      />
    );
  }
  const page = render(core.wrap(<Stage />));
  await view.started();
  view.frames();
  await until(() => decodedAll(view));
  const reason = "Screen sharing was stopped.";
  await act(async () => view.reject(failed("screen_refused", reason)));
  const alert = screen.getByRole("alert");
  expect(alert.textContent).toContain(reason);
  await act(async () => clock.advance(60_000));
  expect(view.open).toHaveBeenCalledTimes(1);
  alert.querySelector("button")!.click();
  await until(() => view.open.mock.calls.length === 2);
  page.unmount();
});

it("opens one view of a device, at its picture's size: none first at no size, which the station counts too", async () => {
  // A station lets one person view so many screens at once, and a view the page has let go of holds its place until
  // the page's stream lets it go and the station hears so: one view per device opened, not two a moment apart.
  const clock = createVirtualUiClock();
  onTestFinished(installUiClock(clock));
  const view = viewing();
  const asked: {
    maxWidth: number | undefined;
    maxHeight: number | undefined;
    signal: AbortSignal;
  }[] = [];
  const core = createScriptedCore({ values: () => undefined });
  const source: ScreenStreamSource = {
    ...meshSource(view, "workspace\\ndevice\\nsimulator:A\\n1"),
    capabilities: fakeDeviceCapabilities(fakePhone),
    view: {
      open: (request, onEvent, signal) => {
        asked.push({
          maxWidth: request.maxWidth,
          maxHeight: request.maxHeight,
          signal,
        });
        return view.open(onEvent, signal);
      },
      send: view.send,
    },
  };
  const page = render(
    core.wrap(
      <div style={{ width: 400, height: 600, display: "flex" }}>
        <ScreenStreamStage
          control={false}
          onState={nothing}
          source={source}
          state="connecting"
          target="app"
        />
      </div>
    )
  );
  await view.started();
  // The first view it opens is already at the device's size.
  expect(asked[0]!.maxWidth).toBeGreaterThan(0);
  expect(asked[0]!.maxHeight).toBe(asked[0]!.maxWidth);
  // And it stays: past the time a stream with no holder is kept for, it is not let go of for another.
  act(() => clock.advance(5000));
  expect(asked[0]!.signal.aborted).toBe(false);
  expect(asked).toHaveLength(1);
  page.unmount();
});

it("comes back by itself when a view goes after it showed, on the same stream", async () => {
  const view = viewing();
  const opened: ((error: Error) => void)[] = [];
  const states: string[] = [];
  const media: MediaStream[] = [];
  const peer = openMeshScreenStream({
    open: (onEvent, signal) =>
      new Promise((_resolve, reject) => {
        opened.push(reject);
        changed();
        void view.open(onEvent, signal).catch(reject);
      }),
    send: view.send,
    onStream: (stream) => media.push(stream),
    onState: (state) => {
      states.push(state);
      changed();
    },
    onFailure: () => expect.unreachable("it comes back"),
    onUnavailable: () => expect.unreachable("this page decodes"),
  });
  await until(() => opened.length === 1);
  await view.started();
  view.frames();
  // All of them decoded: a frame still in the decoder would say "live" after the view went.
  await until(() => decodedAll(view));
  opened[0]!(Object.assign(new Error("connection lost"), { code: "unreachable" }));
  await until(() => opened.length === 2);
  // It says so while it is at it, and the picture stays.
  expect(states).toEqual(["live", "connecting"]);
  expect(media).toHaveLength(1);
  peer.close();
});

it("says once that a page whose decoder never says whether it can cannot show a screen, and does not try again", async () => {
  const check = VideoDecoder.isConfigSupported;
  VideoDecoder.isConfigSupported = () => new Promise(() => undefined);
  try {
    const codes: (string | undefined)[] = [];
    const states: string[] = [];
    const peer = openMeshScreenStream({
      open: () => expect.unreachable("no view without a decoder"),
      send: () => undefined,
      onStream: () => undefined,
      onState: (state) => states.push(state),
      onFailure: (_message, code) => {
        codes.push(code);
        changed();
      },
      onUnavailable: () => expect.unreachable("not a way the mesh lacks"),
    });
    await until(() => codes.length > 0);
    expect(codes).toEqual(["decoder_unsupported"]);
    expect(states).toEqual(["failed"]);
    peer.close();
  } finally {
    VideoDecoder.isConfigSupported = check;
  }
});

// What the person sees named is what is driven: the stream Control opens asks for that app, not what is frontmost by then.
it("asks for the app it found, by name, for every later stream of the source", async () => {
  const view = viewing();
  const asked: { apps?: readonly string[] | undefined; control: boolean }[] = [];
  const key = "pinned";
  const source: ScreenStreamSource = {
    ...meshSource(view, key),
    view: {
      open: (request, onEvent, signal) => {
        asked.push({ apps: request.apps, control: request.control });
        changed();
        return view.open(onEvent, signal);
      },
      send: view.send,
    },
  };
  const views: HeldScreenStreamView[] = [];
  const watching = holdScreenStream(
    { source, target: "app", control: false, background: undefined },
    (held) => {
      views.push(held);
      changed();
    }
  );
  await until(() => asked.length === 1);
  await view.started();
  expect(asked[0]).toEqual({ apps: undefined, control: false });
  view.emit({ type: "state", state: { apps: ["Calculator"], windows: 1 } });
  await until(() => views.at(-1)?.target !== undefined);
  expect(views.at(-1)?.target).toEqual({ apps: ["Calculator"], windows: 1 });

  const driving = holdScreenStream(
    { source, target: "app", control: true, background: undefined },
    () => undefined
  );
  await until(() => asked.length === 2);
  expect(asked[1]).toEqual({ apps: ["Calculator"], control: true });
  watching.release();
  driving.release();
});

// A still screen sends no frame, so only a station that says it is alive can be heard going silent.
it("is not live once a station that says it is alive goes silent, and is again when it speaks", async () => {
  const view = viewing();
  const states: string[] = [];
  const peer = openMeshScreenStream({
    open: view.open,
    send: view.send,
    onStream: nothing,
    onState: (state) => {
      states.push(state);
      changed();
    },
    onFailure: nothing,
    onUnavailable: () => expect.unreachable("this page decodes"),
  });
  await view.started();
  view.frames();
  await until(() => decodedAll(view));
  view.emit({ type: "state", state: { alive: true } });
  await until(() => states.at(-1) === "connecting");
  expect(states).toEqual(["live", "connecting"]);
  view.emit({ type: "state", state: { alive: true } });
  await until(() => states.at(-1) === "live");
  peer.close();
});

it("does not call a still screen dead when its station never says it is alive", async () => {
  const view = viewing();
  const states: string[] = [];
  const later = vi.spyOn(uiClock, "now");
  const peer = openMeshScreenStream({
    open: view.open,
    send: view.send,
    onStream: nothing,
    onState: (state) => {
      states.push(state);
      changed();
    },
    onFailure: nothing,
    onUnavailable: () => expect.unreachable("this page decodes"),
  });
  await view.started();
  view.frames();
  await until(() => decodedAll(view));
  // Long past the silence that would count from a station that says it is alive.
  const start = uiClock.now();
  later.mockImplementation(() => start + 60_000);
  const tick = await new Promise<void>((resolve) => uiClock.after(1500, resolve));
  expect(tick).toBeUndefined();
  expect(states).toEqual(["live"]);
  later.mockRestore();
  peer.close();
});

it("tries again by itself after giving up, and not after a refusal", async () => {
  const after = vi.spyOn(uiClock, "after");
  const waits = () => after.mock.calls.filter(([ms]) => ms === 30_000);
  const run = async (code: string, message = code) => {
    const view = viewing();
    const before = waits().length;
    let opens = 0;
    const source: ScreenStreamSource = {
      ...meshSource(view, `again-${code}`),
      view: {
        open: () => {
          opens++;
          changed();
          return Promise.reject(failed(code, message));
        },
        send: view.send,
      },
    };
    const views: HeldScreenStreamView[] = [];
    const held = holdScreenStream(
      { source, target: "display", control: false, background: undefined },
      (one) => {
        views.push(one);
        changed();
      }
    );
    await until(() => views.at(-1)?.state === "failed");
    const armed = waits().slice(before);
    const again = armed[0]?.[1] as (() => void) | undefined;
    const opened = opens;
    again?.();
    if (again) await until(() => opens === opened + 1);
    // It said nothing of trying: what it shows, and Try again, stayed.
    const shown = views.at(-1)?.state;
    held.release();
    return { armed: armed.length, shown };
  };
  // A view that never showed fails at once with a code that is not "not here".
  expect(await run("upstream_unavailable")).toEqual({ armed: 1, shown: "failed" });
  expect((await run("forbidden")).armed).toBe(0);
  expect((await run("http_503", "App was not found: Calculator")).armed).toBe(0);
  after.mockRestore();
});

it("goes on waiting while it tries again by itself", async () => {
  const after = vi.spyOn(uiClock, "after");
  const waits = () => after.mock.calls.filter(([ms]) => ms === 30_000);
  const view = viewing();
  const codes = ["upstream_unavailable", "unreachable"];
  let opens = 0;
  const source: ScreenStreamSource = {
    ...meshSource(view, "again-unreachable"),
    view: {
      open: () => {
        const code = codes[opens++] ?? "unreachable";
        changed();
        return Promise.reject(failed(code, "The mesh did not reach that computer."));
      },
      send: view.send,
    },
  };
  const views: HeldScreenStreamView[] = [];
  const held = holdScreenStream(
    { source, target: "display", control: false, background: undefined },
    (one) => {
      views.push(one);
      changed();
    }
  );
  await until(() => views.at(-1)?.state === "failed");
  expect(views.at(-1)?.failure).toBe("upstream_unavailable");
  const armed = waits().length;
  const again = waits().at(-1)?.[1] as () => void;
  again();
  await until(() => opens === 2);
  await until(() => waits().length === armed + 1);
  expect(views.at(-1)?.state).toBe("failed");
  held.release();
  after.mockRestore();
});

it("does not hold on to a locked Mac's loginwindow as the app it found", async () => {
  const view = viewing();
  const asked: (readonly string[] | undefined)[] = [];
  const source: ScreenStreamSource = {
    ...meshSource(view, "locked"),
    view: {
      open: (request, onEvent, signal) => {
        asked.push(request.apps);
        changed();
        return view.open(onEvent, signal);
      },
      send: view.send,
    },
  };
  const views: HeldScreenStreamView[] = [];
  const watching = holdScreenStream(
    { source, target: "app", control: false, background: undefined },
    (held) => {
      views.push(held);
      changed();
    }
  );
  await until(() => asked.length === 1);
  await view.started();
  view.emit({ type: "state", state: { apps: ["loginwindow"], windows: 0 } });
  await until(() => views.at(-1)?.target !== undefined);
  const again = holdScreenStream(
    { source, target: "app", control: true, background: undefined },
    () => undefined
  );
  await until(() => asked.length === 2);
  expect(asked[1]).toBeUndefined();
  watching.release();
  again.release();
});

it("while it says locked it looks again with nothing pinned, unseen, until a real app is named", async () => {
  const after = vi.spyOn(uiClock, "after");
  const looks = () => after.mock.calls.filter(([ms]) => ms === 5_000);
  const look = () => (looks().at(-1)![1] as () => void)();
  const view = viewing();
  const asked: (readonly string[] | undefined)[] = [];
  const source: ScreenStreamSource = {
    ...meshSource(view, "locked-look"),
    view: {
      open: (request, onEvent, signal) => {
        asked.push(request.apps);
        changed();
        return view.open(onEvent, signal);
      },
      send: view.send,
    },
  };
  const core = createScriptedCore();
  const page = render(
    core.wrap(<ScreenStreamPanel active appName={undefined} source={source} />)
  );
  await until(() => asked.length === 1);
  view.frames();
  await untilPage(() => panel().getAttribute("data-state") === "live");

  // Locked, more than once: said, not driven, no picture, and no sign of the new streams.
  for (const round of [1, 2]) {
    view.emit({ type: "state", state: { apps: ["loginwindow"], windows: 0 } });
    await untilPage(() => panel().textContent?.includes("locked") === true);
    expect(panel().textContent).not.toContain("loginwindow");
    expect(controlOf().hasAttribute("disabled")).toBe(true);
    expect(hidden()).toBe(true);
    expect(looks().length).toBe(round);
    look();
    await until(() => asked.length === round + 1);
    expect(asked[round]).toBeUndefined();
    expect(panel().getAttribute("data-state")).toBe("live");
    expect(panel().textContent).toContain("locked");
  }

  // Unlocked: the app comes with nobody touching anything, and looking stops.
  view.emit({ type: "state", state: { apps: ["Calculator"], windows: 1 } });
  await untilPage(() => panel().textContent?.includes("Calculator") === true);
  expect(panel().textContent).not.toContain("locked");
  expect(hidden()).toBe(false);
  expect(controlOf().hasAttribute("disabled")).toBe(false);
  expect(pressed("Control")).toBe(false);
  expect(looks().length).toBe(2);

  // Control goes on the open view: no stream anew, and no look.
  view.emit({ type: "open", view: 7 });
  view.emit({ type: "state", state: { control: false, switches: true } });
  controlOf().click();
  await until(() => view.said.some(([, message]) => "control" in message));
  expect(view.said.filter(([, message]) => "control" in message).at(-1)).toEqual([
    7,
    { control: true },
  ]);
  expect(asked).toHaveLength(3);
  expect(looks().length).toBe(2);
  page.unmount();

  // What was pinned is the real app: the next stream asks for it.
  const again = render(
    core.wrap(<ScreenStreamPanel active appName={undefined} source={source} />)
  );
  await until(() => asked.length === 4);
  expect(asked[3]).toEqual(["Calculator"]);
  again.unmount();
  after.mockRestore();
});

/** The card filling the screen, which is where it can be driven. */
function fillTheScreen(card: () => HTMLElement) {
  Object.defineProperty(document, "fullscreenElement", {
    configurable: true,
    get: card,
  });
  document.dispatchEvent(new Event("fullscreenchange"));
  return () => {
    Reflect.deleteProperty(document, "fullscreenElement");
    document.dispatchEvent(new Event("fullscreenchange"));
  };
}

it("the card over the mesh is driven only with a named app, and goes to Watch and looks again when locked", async () => {
  const after = vi.spyOn(uiClock, "after");
  const looks = () => after.mock.calls.filter(([ms]) => ms === 5_000);
  const view = viewing();
  const asked: { apps: readonly string[] | undefined; control: boolean }[] = [];
  const source: ScreenStreamSource = {
    ...meshSource(view, "card-locked"),
    view: {
      open: (request, onEvent, signal) => {
        asked.push({ apps: request.apps, control: request.control });
        changed();
        return view.open(onEvent, signal);
      },
      send: view.send,
    },
  };
  const core = createScriptedCore();
  const page = render(
    core.wrap(
      <ScreenStreamWindow
        appName={undefined}
        deckKey="card-locked"
        onClose={nothing}
        source={source}
      />
    )
  );
  await until(() => asked.length === 1);
  view.frames();
  await untilPage(() => screen.queryByTestId("remote-screen") !== null);
  const leave = fillTheScreen(card);
  await untilPage(() => screen.queryByRole("button", { name: "Control" }) !== null);
  expect(controlOf().hasAttribute("disabled")).toBe(true);

  // Locked with nothing named: not driven, no picture, and it says so.
  view.emit({ type: "state", state: { apps: ["loginwindow"], windows: 0 } });
  await untilPage(() => card().textContent?.includes("locked") === true);
  expect(controlOf().hasAttribute("disabled")).toBe(true);
  expect(shown()).toBe(false);
  (looks().at(-1)![1] as () => void)();
  await until(() => asked.length === 2);
  expect(asked[1]).toEqual({ apps: undefined, control: false });

  // A real app: named, on Watch, until a person presses Control.
  view.emit({ type: "state", state: { apps: ["Calculator"], windows: 1 } });
  await untilPage(() => !controlOf().hasAttribute("disabled"));
  expect(card().textContent).toContain("Calculator");
  expect(controlOf().getAttribute("aria-pressed")).toBe("false");
  expect(shown()).toBe(true);
  expect(asked.at(-1)?.control).toBe(false);

  // Control on the open view; locked while driven, Control goes, and no stream that looks again carries it.
  view.emit({ type: "open", view: 7 });
  view.emit({ type: "state", state: { control: false, switches: true } });
  const opens = asked.length;
  const switched = () =>
    view.said
      .filter(([, message]) => "control" in message)
      .map(([, message]) => message);
  controlOf().click();
  await until(() => switched().length === 1);
  expect(switched()).toEqual([{ control: true }]);
  const lookedBefore = looks().length;
  view.emit({ type: "state", state: { apps: ["loginwindow"], windows: 0 } });
  await untilPage(() => controlOf().getAttribute("aria-pressed") === "false");
  await until(() => switched().length === 2);
  expect(switched()[1]).toEqual({ control: false });
  expect(asked).toHaveLength(opens);
  expect(looks().length).toBe(lookedBefore);
  leave();
  page.unmount();
  after.mockRestore();
});

it("a look that finds no app looks again, and one that cannot reach the computer says so", async () => {
  const after = vi.spyOn(uiClock, "after");
  const looks = () => after.mock.calls.filter(([ms]) => ms === 5_000);
  const run = async (code: string, message: string) => {
    const view = viewing();
    const before = looks().length;
    let opens = 0;
    const source: ScreenStreamSource = {
      ...meshSource(view, `look-${code}`),
      view: {
        open: (_request, onEvent, signal) => {
          opens++;
          changed();
          return opens === 1
            ? view.open(onEvent, signal)
            : Promise.reject(failed(code, message));
        },
        send: view.send,
      },
    };
    const views: HeldScreenStreamView[] = [];
    const held = holdScreenStream(
      { source, target: "app", control: false, background: undefined },
      (one) => {
        views.push(one);
        changed();
      }
    );
    await view.started();
    view.frames();
    await until(() => views.at(-1)?.state === "live");
    view.emit({ type: "state", state: { apps: ["loginwindow"], windows: 0 } });
    await until(() => looks().length === before + 1);
    (looks().at(-1)![1] as () => void)();
    await until(() => opens === 2);
    await until(
      () => looks().length === before + 2 || views.at(-1)?.state === "failed"
    );
    const last = views.at(-1);
    held.release();
    return {
      armed: looks().length - before,
      state: last?.state,
      target: last?.target,
    };
  };
  expect(await run("http_503", "App was not found: ")).toMatchObject({
    armed: 2,
    state: "live",
  });
  expect(await run("upstream_unavailable", "upstream_unavailable")).toEqual({
    armed: 1,
    state: "failed",
    target: undefined,
  });
  after.mockRestore();
});

const controlOf = () => screen.getByRole("button", { name: "Control" });
const card = () => screen.getByTestId("remote-screen");
const shown = () =>
  getComputedStyle(card().querySelector("video")!).visibility !== "hidden";
const panel = () => screen.getByTestId("remote-screen-panel");
const hidden = () =>
  getComputedStyle(panel().querySelector("video")!).visibility === "hidden";
const pressed = (name: string) =>
  screen.getByRole("button", { name }).getAttribute("aria-pressed") === "true";
/** Until the page shows it: the page changing is what is waited on, with no deadline of its own. */
async function untilPage(what: () => boolean) {
  while (!what())
    await new Promise<void>((resolve) => {
      const seen = new MutationObserver(() => {
        seen.disconnect();
        resolve();
      });
      seen.observe(document.body, {
        attributes: true,
        childList: true,
        subtree: true,
        characterData: true,
      });
    });
}

it("over the mesh an unnamed app cannot be driven until it is named, and the toggle takes Control off", async () => {
  const core = createScriptedCore();
  const view = viewing();
  const page = render(
    core.wrap(
      <ScreenStreamPanel
        active
        appName={undefined}
        source={meshSource(view, "mesh-named")}
      />
    )
  );
  await view.started();
  expect(controlOf().hasAttribute("disabled")).toBe(true);
  view.emit({ type: "state", state: { apps: ["Calculator"], windows: 1 } });
  await untilPage(() => !controlOf().hasAttribute("disabled"));
  expect(screen.getByTestId("remote-screen-panel").textContent).toContain("Calculator");
  controlOf().click();
  await untilPage(() => pressed("Control"));
  screen.getByRole("button", { name: "Desktop" }).click();
  await untilPage(() => !pressed("Control"));
  page.unmount();
});

it("a screen moved in Control stays in Watch where Control is not allowed, and a lock takes Control off", async () => {
  const core = createScriptedCore();
  const view = viewing();
  // The place it left (its window) was in Control; this one renders before that one's cleanup.
  const left = keepScreenControl("moved-page", true);
  const page = render(
    core.wrap(
      <ScreenStreamPanel
        active
        appName={undefined}
        controlKey="moved-page"
        source={meshSource(view, "mesh-moved")}
      />
    )
  );
  left();
  await view.started();
  // No app named yet: nothing to drive.
  expect(controlOf().hasAttribute("disabled")).toBe(true);
  expect(pressed("Control")).toBe(false);
  view.emit({ type: "state", state: { apps: ["loginwindow"], windows: 0 } });
  await untilPage(() => panel().textContent?.includes("locked") === true);
  expect(pressed("Control")).toBe(false);
  // Unlocked, it stays in Watch: the lock took the person's Control.
  view.emit({ type: "state", state: { apps: ["Calculator"], windows: 1 } });
  await untilPage(() => !controlOf().hasAttribute("disabled"));
  expect(pressed("Control")).toBe(false);
  expect(view.said.some(([, message]) => "control" in message && message.control)).toBe(
    false
  );
  page.unmount();
});

const playing = (video: HTMLVideoElement) =>
  new Promise<void>((resolve) => {
    if (video.videoWidth > 0) resolve();
    else video.addEventListener("loadedmetadata", () => resolve(), { once: true });
  });

it("draws the station's pointer in its shape, and while this device's mouse drives the picture that mouse takes the shape", async () => {
  const core = createScriptedCore();
  const view = viewing();
  const page = render(
    core.wrap(
      <ScreenStreamStage
        control
        onState={nothing}
        source={meshSource(view, "mesh-pointer")}
        state="live"
        target="display"
      />
    )
  );
  await view.started();
  view.frames();
  const video = page.container.querySelector("video")!;
  await playing(video);
  const pointer = page.container.querySelector<HTMLElement>(
    "[data-testid=remote-screen-pointer]"
  )!;
  const drawn = () => !pointer.hasAttribute("hidden");
  const shape = () => pointer.querySelector("svg")!.getAttribute("data-shape");
  expect(drawn()).toBe(false);

  // Where the station says, over the picture (fitted in the element, as the picture is), in the arrow.
  view.emit({
    type: "state",
    state: { cursor: { x: 0.5, y: 0.25, shape: "default" } },
  });
  await untilPage(drawn);
  expect(shape()).toBe("default");
  const box = video.getBoundingClientRect();
  const at = pointer.getBoundingClientRect();
  expect(at.left).toBeCloseTo(box.left + box.width / 2, 0);
  // Over a text field: the text cursor.
  view.emit({ type: "state", state: { cursor: { x: 0.5, y: 0.25, shape: "text" } } });
  await untilPage(() => shape() === "text");

  // The mouse over the picture it drives: no pointer drawn, the mouse shown in the screen's shape.
  fireEvent.pointerEnter(video);
  await untilPage(() => !drawn());
  expect(video.style.cursor).toBe("text");
  // The mouse gone from the picture: drawn again.
  fireEvent.pointerLeave(video);
  await untilPage(drawn);
  // Hidden on the screen: neither.
  view.emit({ type: "state", state: { cursor: { x: 0.5, y: 0.25, shape: "none" } } });
  await untilPage(() => !drawn());
  expect(video.style.cursor).toBe("none");
  page.unmount();
});

it("opens the view's figures from the toolbar's bars: what the station says, the picture, the route", async () => {
  const core = createScriptedCore();
  const view = viewing();
  const page = render(
    core.wrap(
      <ScreenStreamPanel
        active
        appName="Calculator"
        source={meshSource(view, "mesh-stats")}
        via="direct"
      />
    )
  );
  await view.started();
  view.frames();
  view.emit({
    type: "state",
    state: {
      video: {
        capture: "ScreenCaptureKit",
        encoder: "hardware, low latency, H264_ConstrainedBaseline_AutoLevel",
        hardware: true,
      },
      latency: { frame: 23, before: 9 },
    },
  });
  await untilPage(() => panel().getAttribute("data-state") === "live");
  // The figures read each second on the UI clock: a test clock here, stepped.
  const clock = createVirtualUiClock();
  onTestFinished(installUiClock(clock));
  screen.getByRole("button", { name: "Connection" }).click();
  await untilPage(() => screen.queryByTestId("remote-screen-stats-panel") !== null);
  const figures = screen.getByTestId("remote-screen-stats-panel");
  const row = (name: string) =>
    [...figures.querySelectorAll("dl > div")]
      .find((r) => r.querySelector("dt")?.textContent === name)
      ?.querySelector("dd")?.textContent;
  expect(row("Frame latency")).toBe("23 ms");
  expect(row("Capture to sent")).toBe("9 ms");
  expect(row("Route")).toBe("Direct");
  expect(row("Resolution")).toBe("64×48");
  expect(row("Codec")).toBe("H.264");
  expect(row("Capture")).toBe("ScreenCaptureKit");
  expect(row("Encoder")).toBe("Hardware");
  // Frames and bits a second: what came over the second the figures were open.
  // (none before its first second: left out, not a dash)
  expect(row("Frame rate")).toBeUndefined();
  FRAMES.forEach((frame, at) =>
    view.emit({
      type: "video",
      key: at === 0,
      ts: (at + 10) * 1000,
      data: bytes(frame),
    })
  );
  act(() => clock.advance(1000));
  await untilPage(() => row("Frame rate") !== undefined);
  expect(row("Frame rate")).toBe(String(FRAMES.length));
  const bits = FRAMES.reduce((sum, frame) => sum + bytes(frame).byteLength * 8, 0);
  expect(row("Bandwidth")).toBe(bitrateText(bits));
  page.unmount();
});
