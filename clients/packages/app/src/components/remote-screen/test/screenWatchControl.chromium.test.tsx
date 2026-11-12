import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import type { ScreenViewEvent } from "@comma/core-client";
import { act, cleanup, fireEvent, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { installUiClock } from "@comma/ui/clock";
import { createVirtualUiClock, type VirtualUiClock } from "@comma/ui/clock/virtual";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { openMeshScreenStream } from "../meshScreenStream";
import { ScreenStreamPanel } from "../ScreenStreamPanel";
import { ScreenStreamStage, type ScreenStreamSource } from "../ScreenStreamStage";
import { ScreenStreamWindow } from "../ScreenStreamWindow";
import type { ScreenStreamInput } from "../screenStreamInput";
import { fakeDeviceCapabilities, fakePhone } from "./fakeScreenDevice";

vi.mock("../meshScreenStream", async (original) => ({
  ...(await original<typeof import("../meshScreenStream")>()),
  openMeshScreenStream: vi.fn(),
}));
// The real view over the mesh, for the tests that decode what a fake station sends.
const { openMeshScreenStream: realMeshStream } =
  await vi.importActual<typeof import("../meshScreenStream")>("../meshScreenStream");

const core = createScriptedCore({ values: () => undefined });
let clock: VirtualUiClock;
let restore: () => void;
let sent: ScreenStreamInput[] = [];
let sources = 0;

const settle = async () => {
  for (let i = 0; i < 50; i++) await Promise.resolve();
};
const fakeSource = (): ScreenStreamSource => ({
  key: `workspace\ndevice\nwatch-${(sources += 1)}`,
  view: { open: () => new Promise(() => undefined), send: () => undefined },
});

beforeEach(() => {
  sent = [];
  clock = createVirtualUiClock();
  restore = installUiClock(clock);
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    queueMicrotask(() => peer.onState("live"));
    return { send: (input) => void sent.push(input), close: () => undefined };
  });
});
afterEach(() => {
  cleanup();
  restore();
});

async function panel(source = fakeSource()) {
  const view = render(
    core.wrap(
      <div style={{ display: "flex", width: 720, height: 480 }}>
        <ScreenStreamPanel
          active
          appName="Safari"
          initialTarget="display"
          source={source}
        />
      </div>
    )
  );
  await act(settle);
  return {
    view,
    video: view.container.querySelector("video")!,
    stage: view.container.querySelector<HTMLElement>(".comma-remote-screen-stage")!,
    control: screen.getByRole("button", { name: "Control" }),
    hint: screen.getByTestId("remote-screen-watch-hint"),
  };
}

const said = (hint: HTMLElement) => hint.getAttribute("data-shown") === "true";

it("answers a press on a watched picture on the picture and at Control, once, and sends nothing", async () => {
  const { video, control, hint } = await panel();
  expect(getComputedStyle(video).cursor).toBe("not-allowed");
  expect(said(hint)).toBe(false);

  fireEvent.pointerDown(video, { button: 0, pointerType: "mouse" });
  fireEvent.pointerUp(video, { button: 0, pointerType: "mouse" });
  expect(said(hint)).toBe(true);
  expect(hint).toHaveTextContent("Watching only · Switch to Control to use it");
  expect(control).toHaveAttribute("data-attention");

  // It goes by itself; pressed again soon after, it does not come back.
  act(() => clock.advance(3000));
  expect(said(hint)).toBe(false);
  expect(control).not.toHaveAttribute("data-attention");
  fireEvent.pointerDown(video, { button: 0, pointerType: "mouse" });
  expect(said(hint)).toBe(false);

  // Much later it may say so again.
  act(() => clock.advance(30_000));
  fireEvent.pointerDown(video, { button: 0, pointerType: "mouse" });
  expect(said(hint)).toBe(true);
  expect(sent).toEqual([]);
});

it("answers typing on a watched picture once it was pressed, but not a shortcut", async () => {
  const { view, video, hint } = await panel();
  fireEvent.pointerDown(video, { button: 0, pointerType: "mouse" });
  const keys = view.container.querySelector("textarea")!;
  expect(document.activeElement).toBe(keys);
  act(() => clock.advance(30_000));

  fireEvent.keyDown(keys, { key: "k", code: "KeyK", metaKey: true });
  expect(said(hint)).toBe(false);
  fireEvent.keyDown(keys, { key: "a", code: "KeyA" });
  expect(said(hint)).toBe(true);
  expect(sent).toEqual([]);
});

it("does not answer a key held down or what an input method is composing", async () => {
  const { view, video, hint } = await panel();
  fireEvent.pointerDown(video, { button: 0, pointerType: "mouse" });
  const keys = view.container.querySelector("textarea")!;
  act(() => clock.advance(30_000));

  fireEvent.keyDown(keys, { key: "a", code: "KeyA", repeat: true });
  expect(said(hint)).toBe(false);
  fireEvent.keyDown(keys, { key: "n", code: "KeyN", isComposing: true });
  expect(said(hint)).toBe(false);
  fireEvent.keyDown(keys, { key: "a", code: "KeyA", keyCode: 229 });
  expect(said(hint)).toBe(false);
  fireEvent.keyDown(keys, { key: "a", code: "KeyA" });
  expect(said(hint)).toBe(true);
});

it("marks Control round the picture without moving the picture, and drops the hint", async () => {
  const { video, control, stage, hint } = await panel();
  fireEvent.pointerDown(video, { button: 0, pointerType: "mouse" });
  const watched = video.getBoundingClientRect();
  const watchedLine = getComputedStyle(stage).borderTopColor;

  fireEvent.click(control);
  await act(settle);
  await Promise.all(stage.getAnimations().map((animation) => animation.finished));

  expect(said(hint)).toBe(false);
  expect(getComputedStyle(video).cursor).not.toBe("not-allowed");
  expect(getComputedStyle(stage).borderTopColor).not.toBe(watchedLine);
  const driven = video.getBoundingClientRect();
  expect([driven.x, driven.y, driven.width, driven.height]).toEqual([
    watched.x,
    watched.y,
    watched.width,
    watched.height,
  ]);
});

it("answers a press on a watched device, its input sending nothing", async () => {
  const source = {
    ...fakeSource(),
    capabilities: fakeDeviceCapabilities(fakePhone),
  };
  const onInput = vi.fn();
  const view = render(
    core.wrap(
      <div style={{ width: 720, height: 480 }}>
        <ScreenStreamStage
          control={false}
          onState={() => undefined}
          source={source}
          state="live"
          target="display"
          watching={{ hint: "Watching only", shown: false, onInput }}
        />
      </div>
    )
  );
  await act(settle);
  const video = view.container.querySelector("video")!;
  expect(getComputedStyle(video).cursor).toBe("not-allowed");
  fireEvent.pointerDown(video, { button: 0, pointerType: "touch", pointerId: 1 });
  expect(onInput).toHaveBeenCalledOnce();
  expect(sent).toEqual([]);
});

it("does not call a stage's picture watched where a press on it means something else", async () => {
  const view = render(
    core.wrap(
      <ScreenStreamStage
        control={false}
        onState={() => undefined}
        source={fakeSource()}
        state="live"
        target="display"
      />
    )
  );
  await act(settle);
  const video = view.container.querySelector("video")!;
  expect(getComputedStyle(video).cursor).not.toBe("not-allowed");
  expect(view.queryByTestId("remote-screen-watch-hint")).toBeNull();
});

function meshSource() {
  const emitted: ((event: ScreenViewEvent) => void)[] = [];
  const source: ScreenStreamSource = {
    ...fakeSource(),
    view: {
      open: (_options, emit, signal) => {
        emitted.push(emit);
        return new Promise((_resolve, reject) => {
          signal.addEventListener("abort", () => reject(new Error("cancelled")));
        });
      },
      send: vi.fn(),
    },
  };
  return { source, emit: (event: ScreenViewEvent) => emitted.at(-1)!(event) };
}

it("says why when the computer will not be driven, on the picture and in the toolbar", async () => {
  vi.mocked(openMeshScreenStream).mockImplementation(realMeshStream);
  const decoder = vi
    .spyOn(VideoDecoder, "isConfigSupported")
    .mockImplementation(async (config) => ({ supported: true, config }));
  const { source, emit } = meshSource();
  const { control, hint, view } = await panel(source);
  act(() => emit({ type: "open", view: 1 }));
  act(() => emit({ type: "state", state: { control: false, switches: true } }));
  fireEvent.click(control);
  await act(settle);

  act(() =>
    emit({
      type: "state",
      state: {
        control: false,
        refused: "only one who may drive this computer may do that",
      },
    })
  );
  await act(settle);

  expect(said(hint)).toBe(true);
  expect(hint).toHaveTextContent("Read-only members can only watch.");
  expect(control).toHaveAttribute("aria-pressed", "false");
  expect(view.container.querySelector(".comma-remote-screen-line")).toHaveTextContent(
    "Read-only members can only watch."
  );
  decoder.mockRestore();
});

it("draws the screen's pointer as an arrow while watching, in its shape while driving", async () => {
  vi.mocked(openMeshScreenStream).mockImplementation(realMeshStream);
  const decoder = vi
    .spyOn(VideoDecoder, "isConfigSupported")
    .mockImplementation(async (config) => ({ supported: true, config }));
  const { source, emit } = meshSource();
  const { control, view } = await panel(source);
  act(() => emit({ type: "open", view: 1 }));
  act(() =>
    emit({
      type: "state",
      state: {
        control: false,
        switches: true,
        cursor: { x: 0.5, y: 0.5, shape: "pointer" },
      },
    })
  );
  const shape = () =>
    view.container
      .querySelector("[data-testid=remote-screen-pointer] svg")!
      .getAttribute("data-shape");
  expect(shape()).toBe("default");
  fireEvent.click(control);
  await act(settle);
  expect(shape()).toBe("pointer");
  decoder.mockRestore();
});

it("says why on a card filling the screen when the computer will not be driven", async () => {
  vi.mocked(openMeshScreenStream).mockImplementation(realMeshStream);
  const decoder = vi
    .spyOn(VideoDecoder, "isConfigSupported")
    .mockImplementation(async (config) => ({ supported: true, config }));
  const { source, emit } = meshSource();
  const view = render(
    core.wrap(
      <ScreenStreamWindow
        appName="Safari"
        deckKey="refused"
        onClose={() => undefined}
        source={source}
      />
    )
  );
  await act(settle);
  const card = document.body.querySelector<HTMLElement>("section.comma-remote-screen")!;
  const full = vi
    .spyOn(Document.prototype, "fullscreenElement", "get")
    .mockReturnValue(card);
  act(() => void document.dispatchEvent(new Event("fullscreenchange")));
  act(() => emit({ type: "open", view: 1 }));
  act(() => emit({ type: "state", state: { control: false, switches: true } }));
  // (a card is kept hidden until its first picture)
  const control = card.querySelector('button[aria-label="Control"]')!;
  fireEvent.click(control);
  await act(settle);
  expect(control).toHaveAttribute("aria-pressed", "true");

  act(() =>
    emit({
      type: "state",
      state: {
        control: false,
        refused: "only one who may drive this computer may do that",
      },
    })
  );
  await act(settle);

  const hint = view.getByTestId("remote-screen-watch-hint");
  expect(said(hint)).toBe(true);
  expect(hint).toHaveTextContent("Read-only members can only watch.");
  expect(control).toHaveAttribute("aria-pressed", "false");
  full.mockRestore();
  decoder.mockRestore();
});
