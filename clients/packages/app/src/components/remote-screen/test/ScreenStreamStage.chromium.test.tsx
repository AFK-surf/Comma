import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { act, cleanup, fireEvent, render } from "@comma/test-utils/render";
import type { ScreenViewEvent } from "@comma/core-client";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, expect, it, vi } from "vitest";
import { openMeshScreenStream } from "../meshScreenStream";
import { ScreenStreamStage, type ScreenStreamSource } from "../ScreenStreamStage";
import { ScreenStreamWindow } from "../ScreenStreamWindow";

vi.mock("../meshScreenStream", async (original) => ({
  ...(await original<typeof import("../meshScreenStream")>()),
  openMeshScreenStream: vi.fn(),
}));
// The real view over the mesh, for the tests that decode what a fake station sends.
const { openMeshScreenStream: realMeshStream } =
  await vi.importActual<typeof import("../meshScreenStream")>("../meshScreenStream");

afterEach(cleanup);

const settle = async () => {
  for (let i = 0; i < 50; i++) await Promise.resolve();
};

const metadata = (video: HTMLVideoElement) =>
  new Promise<void>((resolve) => {
    if (video.videoWidth > 0) resolve();
    else video.addEventListener("loadedmetadata", () => resolve(), { once: true });
  });

it("moves a playing stream to a new place without a new connection", async () => {
  const opened: Parameters<typeof openMeshScreenStream>[0][] = [];
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    opened.push(peer);
    return { send: () => undefined, close: () => undefined };
  });
  const source: ScreenStreamSource = {
    key: "workspace\ndevice\nmoved",
    view: { open: () => new Promise(() => undefined), send: () => undefined },
  };
  const core = createScriptedCore({ values: () => undefined });
  const place = (onShape: (ratio: number) => void) =>
    core.wrap(
      <ScreenStreamStage
        control={false}
        onShape={onShape}
        onState={() => undefined}
        source={source}
        state="live"
        target="app"
      />
    );

  const canvas = document.createElement("canvas");
  canvas.width = 400;
  canvas.height = 200;
  canvas.getContext("2d")!.fillRect(0, 0, 400, 200);
  const media = canvas.captureStream(0);
  const card = render(place(() => undefined));
  opened[0]!.onStream(media);
  opened[0]!.onState("live");
  await metadata(card.container.querySelector("video")!);
  card.unmount();

  const shapes: number[] = [];
  const panel = render(place((ratio) => shapes.push(ratio)));
  const moved = panel.container.querySelector("video")!;
  await metadata(moved);

  expect(opened).toHaveLength(1);
  expect(moved.srcObject).toBe(media);
  expect(shapes.at(-1)).toBe(2);
});

it("shows a card whose stream failed, says why and opens it anew on Try again", () => {
  const opened: Parameters<typeof openMeshScreenStream>[0][] = [];
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    opened.push(peer);
    return { send: () => undefined, close: () => undefined };
  });
  const source: ScreenStreamSource = {
    key: "workspace\ndevice\nfailing",
    view: { open: () => new Promise(() => undefined), send: () => undefined },
  };
  const core = createScriptedCore({ values: () => undefined });
  const view = render(
    core.wrap(
      <ScreenStreamWindow
        appName="Safari"
        deckKey="failing"
        onClose={() => undefined}
        source={source}
      />
    )
  );
  expect(view.queryByTestId("remote-screen")).toBeNull();
  act(() => {
    opened[0]!.onFailure?.("The computer is offline");
    opened[0]!.onState("failed");
  });
  view.getByTestId("remote-screen");
  expect(view.getByRole("alert").textContent).toContain("The computer is offline");

  fireEvent.click(view.getByRole("button", { name: "Try again" }));

  expect(opened).toHaveLength(2);
  view.getByTestId("remote-screen");
});

it("lets go of what is held when control ends", () => {
  const send = vi.fn();
  vi.mocked(openMeshScreenStream).mockReturnValue({ send, close: () => undefined });
  const source: ScreenStreamSource = {
    key: "workspace\ndevice\nholding",
    view: { open: () => new Promise(() => undefined), send: () => undefined },
  };
  const core = createScriptedCore({ values: () => undefined });
  const stage = (control: boolean) =>
    core.wrap(
      <ScreenStreamStage
        control={control}
        onState={() => undefined}
        source={source}
        state="live"
        target="app"
      />
    );
  const view = render(stage(true));
  const video = view.container.querySelector("video")!;
  const keys = view.container.querySelector("textarea")!;
  video.setPointerCapture = () => undefined;
  fireEvent.pointerDown(video, { button: 0 });
  fireEvent.keyDown(keys, { key: "a", code: "KeyA" });
  fireEvent.keyDown(keys, { key: "b", code: "KeyB" });
  fireEvent.keyUp(keys, { key: "b", code: "KeyB" });
  send.mockClear();

  view.rerender(stage(false));

  expect(send.mock.calls.map(([input]) => [input.type, input.code])).toEqual([
    ["up", undefined],
    ["keyup", "KeyA"],
  ]);
});

it("sends a computer what an IME composed and a paste as text, and a key of another layout with what it types", () => {
  const send = vi.fn();
  vi.mocked(openMeshScreenStream).mockReturnValue({ send, close: () => undefined });
  const source: ScreenStreamSource = {
    key: "workspace\ndevice\ntyping",
    view: { open: () => new Promise(() => undefined), send: () => undefined },
  };
  const core = createScriptedCore({ values: () => undefined });
  const view = render(
    core.wrap(
      <ScreenStreamStage
        control
        onState={() => undefined}
        source={source}
        state="live"
        target="display"
      />
    )
  );
  const video = view.container.querySelector("video")!;
  const keys = view.container.querySelector("textarea")!;
  video.setPointerCapture = () => undefined;
  // A press takes the keys there.
  fireEvent.pointerDown(video, { button: 0 });
  expect(document.activeElement).toBe(keys);
  send.mockClear();

  fireEvent.keyDown(keys, {
    key: "Process",
    code: "KeyN",
    keyCode: 229,
    isComposing: true,
  });
  keys.dispatchEvent(
    new CompositionEvent("compositionend", { bubbles: true, data: "中文输入" })
  );
  const paste = new DataTransfer();
  paste.setData("text/plain", "pasted 文字");
  keys.dispatchEvent(
    new ClipboardEvent("paste", {
      bubbles: true,
      cancelable: true,
      clipboardData: paste,
    })
  );
  // ⌘V is the paste above, not a key.
  fireEvent.keyDown(keys, { key: "v", code: "KeyV", metaKey: true });
  fireEvent.keyDown(keys, { key: "é", code: "Quote" });

  expect(send.mock.calls.map(([input]) => input)).toEqual([
    { type: "text", text: "中文输入" },
    { type: "text", text: "pasted 文字" },
    { type: "keydown", code: "Quote", key: "é", mods: [] },
  ]);
});

it("sends the last pointer move before a press, never dropping it", () => {
  const send = vi.fn();
  vi.mocked(openMeshScreenStream).mockReturnValue({ send, close: () => undefined });
  const source: ScreenStreamSource = {
    key: "workspace\ndevice\nmoving",
    view: { open: () => new Promise(() => undefined), send: () => undefined },
  };
  const core = createScriptedCore({ values: () => undefined });
  const view = render(
    core.wrap(
      <ScreenStreamStage
        control
        onState={() => undefined}
        source={source}
        state="live"
        target="display"
      />
    )
  );
  const video = view.container.querySelector("video")!;
  video.setPointerCapture = () => undefined;
  // (the picture has no size here: every point is its corner)
  for (let i = 0; i < 3; i++) fireEvent.pointerMove(video, { clientX: i, clientY: i });
  fireEvent.pointerDown(video, { button: 0 });
  expect(send.mock.calls.map(([input]) => input.type)).toEqual(["move", "down"]);
});

it("opens this device's input method by the last press on the picture, at the picture's lower left before any press", async () => {
  const send = vi.fn();
  const opened: Parameters<typeof openMeshScreenStream>[0][] = [];
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    opened.push(peer);
    return { send, close: () => undefined };
  });
  const source: ScreenStreamSource = {
    key: "workspace\ndevice\nime-place",
    view: { open: () => new Promise(() => undefined), send: () => undefined },
  };
  const core = createScriptedCore({ values: () => undefined });
  const view = render(
    <div style={{ width: 600, height: 400 }}>
      {core.wrap(
        <ScreenStreamStage
          control
          onState={() => undefined}
          source={source}
          state="live"
          target="display"
        />
      )}
    </div>
  );
  // A 2:1 picture in a 3:2 stage: fitted 600×300, 50 px above and below it.
  const canvas = document.createElement("canvas");
  canvas.width = 400;
  canvas.height = 200;
  canvas.getContext("2d")!.fillRect(0, 0, 400, 200);
  act(() => {
    opened[0]!.onStream(canvas.captureStream(0));
    opened[0]!.onState("live");
  });
  const video = view.container.querySelector("video")!;
  const keys = view.container.querySelector("textarea")!;
  video.setPointerCapture = () => undefined;
  await metadata(video);
  const stage = video.getBoundingClientRect();
  const caret = () => {
    const box = keys.getBoundingClientRect();
    return { x: box.left - stage.left, y: box.top - stage.top, height: box.height };
  };

  expect(caret()).toEqual({ x: 0, y: 350, height: 20 });

  fireEvent.pointerDown(video, {
    button: 0,
    clientX: stage.left + 240,
    clientY: stage.top + 130,
  });
  expect(document.activeElement).toBe(keys);
  expect(caret()).toEqual({ x: 240, y: 130, height: 20 });
});

it("pastes an image only onto the screen it was pasted on, not one opened while the image was read", async () => {
  vi.mocked(openMeshScreenStream).mockImplementation(realMeshStream);
  const opened: ((event: ScreenViewEvent) => void)[] = [];
  const send = vi.fn();
  const decoder = vi
    .spyOn(VideoDecoder, "isConfigSupported")
    .mockImplementation(async (config) => ({ supported: true, config }));
  const source = (key: string): ScreenStreamSource => ({
    key,
    view: {
      open: (_options, emit, signal) =>
        new Promise((_resolve, reject) => {
          opened.push(emit);
          signal.addEventListener("abort", () => reject(new Error("cancelled")));
        }),
      send: (...args) => send(...args),
    },
  });
  const core = createScriptedCore({ values: () => undefined });
  const stage = (s: ScreenStreamSource) =>
    core.wrap(
      <ScreenStreamStage
        control
        source={s}
        state="live"
        target="display"
        onState={() => undefined}
      />
    );
  const view = render(stage(source("paste-a")));
  await act(settle);
  act(() => opened[0]!({ type: "open", view: 1, clipboard: ["png"] }));
  let finish!: (bytes: ArrayBuffer) => void;
  const read = vi
    .spyOn(Blob.prototype, "arrayBuffer")
    .mockImplementation(
      () => new Promise<ArrayBuffer>((resolve) => (finish = resolve))
    );
  const data = new DataTransfer();
  data.items.add(
    new File([new Uint8Array([1, 2, 3])], "image.png", { type: "image/png" })
  );
  act(() =>
    view.container.querySelector("textarea")!.dispatchEvent(
      new ClipboardEvent("paste", {
        bubbles: true,
        cancelable: true,
        clipboardData: data,
      })
    )
  );
  expect(read).toHaveBeenCalledOnce();
  view.rerender(stage(source("paste-b")));
  await act(settle);
  expect(opened).toHaveLength(2);
  act(() => opened[1]!({ type: "open", view: 2, clipboard: ["png"] }));
  send.mockClear();
  await act(async () => {
    finish(new Uint8Array([1, 2, 3]).buffer);
    await settle();
  });
  expect(send.mock.calls.filter(([, message]) => "clipboard" in message)).toEqual([]);
  read.mockRestore();
  decoder.mockRestore();
});
