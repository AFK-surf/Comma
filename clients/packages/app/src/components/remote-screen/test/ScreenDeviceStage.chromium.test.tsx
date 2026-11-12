import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render, screen, within } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { useState, type ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { commands, page, userEvent } from "vitest/browser";
import { useOptionalAppShortcutBindings } from "../../shortcuts/commaAppShortcuts";
import {
  turnScreenDeviceShape,
  type ScreenDeviceShape,
  type ScreenTurn,
} from "../screenDevice";
import type { ScreenStreamInput } from "../screenStreamInput";
import { openMeshScreenStream } from "../meshScreenStream";
import { ScreenStreamStage, type ScreenStreamSource } from "../ScreenStreamStage";
import {
  fakeDeviceCapabilities,
  fakeFoldable,
  fakePhone,
  fakePicture,
  turnFakePicture,
} from "./fakeScreenDevice";

vi.mock("../meshScreenStream", () => ({ openMeshScreenStream: vi.fn() }));
vi.mock("../../shortcuts/commaAppShortcuts", () => ({
  useOptionalAppShortcutBindings: vi.fn(() => null),
}));

const core = createScriptedCore({ values: () => undefined });
let sent: ScreenStreamInput[] = [];
/** Told each time the stage sends something. */
let heard: (() => void)[] = [];
/** Resolves once `what` holds, checked as each input is sent: no deadline of its own. */
async function untilSent(what: () => boolean) {
  while (!what()) await new Promise<void>((resolve) => heard.push(resolve));
}
/** The peer of the stream the stage opened last: its state is the source's. */
let peerNow: Parameters<typeof openMeshScreenStream>[0] | undefined;
let sources = 0;
let picture: MediaStream;
let canvas: HTMLCanvasElement;

beforeEach(() => {
  sent = [];
  vi.mocked(useOptionalAppShortcutBindings).mockReturnValue(null);
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    peerNow = peer;
    const media = picture;
    queueMicrotask(() => {
      peer.onStream(media);
      peer.onState("live");
    });
    return {
      send: (input) => {
        sent.push(input);
        for (const wake of heard.splice(0)) wake();
      },
      close: () => undefined,
    };
  });
});
afterEach(cleanup);

const sourceOf = (
  capabilities: ScreenStreamSource["capabilities"],
  [width, height]: readonly [number, number] = [390, 840]
): ScreenStreamSource => {
  canvas = fakePicture(width, height);
  picture = canvas.captureStream();
  sources += 1;
  return {
    key: `workspace\ndevice\n${sources}`,
    view: { open: () => new Promise(() => undefined), send: () => undefined },
    capabilities,
  };
};

const hosted = (children: ReactNode) =>
  core.wrap(<div style={{ width: 400, height: 600, display: "flex" }}>{children}</div>);

/** The stage last rendered: what it has told of its picture's shape. */
let shaped: ReturnType<typeof shapeRecorder> | undefined;

const stage = (
  source: ScreenStreamSource,
  options: { control?: boolean; onShape?: (ratio: number) => void } = {}
) => {
  const recorder = shapeRecorder();
  shaped = recorder;
  return hosted(
    <ScreenStreamStage
      control={options.control ?? true}
      onShape={(ratio) => {
        recorder.onShape(ratio);
        options.onShape?.(ratio);
      }}
      onState={() => undefined}
      source={source}
      state="live"
      target="app"
    />
  );
};

const repaint = () => canvas.getContext("2d")!.drawImage(canvas, 0, 0);

/** Draws the canvas until a frame of the wanted size has reached the picture. */
const pictureIs = (video: HTMLVideoElement, width: number, height: number) =>
  new Promise<void>((resolve) => {
    const check = () => {
      if (video.videoWidth === width && video.videoHeight === height) {
        resolve();
        return;
      }
      repaint();
      video.requestVideoFrameCallback(check);
    };
    repaint();
    video.requestVideoFrameCallback(check);
  });

/**
 * The picture's first frame has arrived and the stage has taken its shape: the
 * frame can be presented before the video's `resize` event, which a press
 * before it would find with no picture to hold.
 */
const pictureReady = async (container: HTMLElement) => {
  const video = container.querySelector("video")!;
  await pictureIs(video, canvas.width, canvas.height);
  await shaped!.until(canvas.width / canvas.height);
  return video;
};

const deviceLocator = () => page.getByTestId("remote-screen-device");

const deviceTurned = async (turn: number) => {
  await expect.element(deviceLocator()).toHaveAttribute("data-turn", String(turn));
  // (a turn shows as a turn: what follows measures where it comes to rest)
  await Promise.all(
    screen
      .getByTestId("remote-screen-device")
      .getAnimations()
      .map((turning) => turning.finished)
  );
};

/** The frame has taken this panel, standing this way. */
const deviceStands = async (shape: ScreenDeviceShape, turn: ScreenTurn) => {
  await deviceTurned(turn);
  const { width, height } = turnScreenDeviceShape(shape, turn).screen;
  await expect
    .element(deviceLocator())
    .toHaveAttribute(
      "style",
      expect.stringContaining(`--comma-remote-screen-device-ratio: ${width / height}`)
    );
};

const close = (a: number, b: number) => Math.abs(a - b) < 0.001;

/** What the stage tells its host of its shape, and a wait for one ratio. */
function shapeRecorder() {
  let last: number | undefined;
  const waiting: { ratio: number; resolve(): void }[] = [];
  return {
    onShape(ratio: number) {
      last = ratio;
      for (const waiter of waiting.splice(0))
        if (close(waiter.ratio, ratio)) waiter.resolve();
        else waiting.push(waiter);
    },
    until: (ratio: number) =>
      new Promise<void>((resolve) => {
        if (last !== undefined && close(last, ratio)) resolve();
        else waiting.push({ ratio, resolve });
      }),
  };
}

const pressRotate = () => screen.getByRole("button", { name: "Rotate" }).click();

/**
 * Where a point of the picture, in fractions, shows on the page: the picture
 * letterboxed in the screen, worked out here apart from the mapping under test.
 */
function shownAt(video: HTMLVideoElement, x: number, y: number) {
  const box = video.parentElement!.getBoundingClientRect();
  const scale = Math.min(box.width / video.videoWidth, box.height / video.videoHeight);
  const width = video.videoWidth * scale;
  const height = video.videoHeight * scale;
  return {
    x: box.left + (box.width - width) / 2 + x * width,
    y: box.top + (box.height - height) / 2 + y * height,
  };
}

const fingers = () =>
  sent.filter(
    (input): input is Extract<ScreenStreamInput, { t: "pointer" }> =>
      "t" in input && input.t === "pointer"
  );

/** What hears the keys beside a stage's picture: an IME composes in it and a paste lands in it. */
const keysBy = (video: HTMLVideoElement) =>
  video.closest(".comma-remote-screen-stage")!.querySelector("textarea")!;

const press = (element: Element, key: KeyboardEventInit) => {
  const event = new KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    ...key,
  });
  element.dispatchEvent(event);
  return event;
};

const macos = /mac/i.test(navigator.platform);
const primary = macos ? { metaKey: true } : { ctrlKey: true };
const ROTATE = { code: "ArrowRight", ...primary };

const center = (box: DOMRect) => ({
  x: box.left + box.width / 2,
  y: box.top + box.height / 2,
});

const buttonNames = (container: HTMLElement) =>
  within(container.querySelector<HTMLElement>(".comma-remote-screen-device-buttons")!)
    .getAllByRole("button")
    .map((button) => button.getAttribute("aria-label"));

describe("a computer's screen", () => {
  it("shows no device and takes a mouse's pointer, as it always has", async () => {
    const shapes = shapeRecorder();
    const source = sourceOf(undefined, [1280, 800]);
    const { container } = render(stage(source, { onShape: shapes.onShape }));
    const video = await pictureReady(container);
    await shapes.until(1280 / 800);
    const root = container.querySelector(".comma-remote-screen-stage")!;

    expect(video.parentElement).toBe(root);
    expect(root).not.toHaveAttribute("data-device");
    expect(container.querySelector(".comma-remote-screen-device")).toBeNull();
    expect(root.querySelectorAll("button")).toHaveLength(0);

    const { x, y } = center(video.getBoundingClientRect());
    await commands.mouseMove(x, y);
    await commands.mouseDown();
    await commands.mouseUp();
    expect(sent).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ type: "down", button: 0 }),
        expect.objectContaining({ type: "up", button: 0 }),
      ])
    );
    expect(fingers()).toEqual([]);

    // A device's shortcut is one more key to a computer, in its own message.
    sent = [];
    keysBy(video).focus();
    press(keysBy(video), ROTATE);
    expect(sent).toEqual([
      expect.objectContaining({ type: "keydown", code: "ArrowRight" }),
    ]);
  });
});

describe("a device's frame", () => {
  it("draws the frame round a picture on the declared screen", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    await pictureReady(container);
    const frame = screen.getByTestId("remote-screen-device").getBoundingClientRect();
    const shown = container
      .querySelector(".comma-remote-screen-device-screen")!
      .getBoundingClientRect();
    const { screen: inner, corners } = fakePhone[0];

    expect(shown.width / shown.height).toBeCloseTo(inner.width / inner.height, 2);
    // One thickness all round, whatever the screen's size, and each corner round the screen's.
    const bezel = shown.left - frame.left;
    expect(bezel).toBeGreaterThan(0);
    expect(shown.top - frame.top).toBeCloseTo(bezel, 1);
    expect(frame.right - shown.right).toBeCloseTo(bezel, 1);
    expect(frame.bottom - shown.bottom).toBeCloseTo(bezel, 1);
    expect(
      Number.parseFloat(
        getComputedStyle(screen.getByTestId("remote-screen-device")).borderTopLeftRadius
      )
    ).toBeCloseTo((corners[0] / inner.width) * shown.width + bezel, 0);
  });

  it("draws each corner as the superellipse its source says, body and screen alike", async () => {
    const [phone] = fakePhone;
    const curved = [{ ...phone, shapes: [1.4, 1.4, 2, 1] as const }] as const;
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(curved))));
    await pictureReady(container);
    for (const drawn of [
      screen.getByTestId("remote-screen-device"),
      container.querySelector(".comma-remote-screen-device-screen")!,
    ]) {
      const style = getComputedStyle(drawn);
      expect(
        ["top-left", "top-right", "bottom-right", "bottom-left"].map((corner) =>
          style.getPropertyValue(`corner-${corner}-shape`)
        )
      ).toEqual(["superellipse(1.4)", "superellipse(1.4)", "squircle", "round"]);
    }
  });

  it("draws no body for a source with no shape", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(undefined))));
    await pictureReady(container);
    await expect
      .element(deviceLocator())
      .toHaveAttribute(
        "style",
        expect.stringContaining(`--comma-remote-screen-device-ratio: ${390 / 840}`)
      );
    const device = screen.getByTestId("remote-screen-device");
    expect(device).toHaveAttribute("data-body", "false");
    expect(getComputedStyle(device).boxShadow).toBe("none");
    const { width, height } = device.getBoundingClientRect();
    expect(width / height).toBeCloseTo(390 / 840, 2);
  });

  it("takes a foldable's panel from the picture's shape", async () => {
    const { container } = render(
      stage(sourceOf(fakeDeviceCapabilities(fakeFoldable), [1250, 1780]))
    );
    await pictureReady(container);
    const inner = fakeFoldable[1];
    await deviceStands(inner, 0);
    // The inner panel's even corners, where the cover's first differs from its second.
    const { borderTopLeftRadius, borderTopRightRadius } = getComputedStyle(
      container.querySelector(".comma-remote-screen-device-screen")!
    );
    expect(borderTopLeftRadius).toBe(borderTopRightRadius);
    const shown = container
      .querySelector(".comma-remote-screen-device-screen")!
      .getBoundingClientRect();
    expect(shown.width / shown.height).toBeCloseTo(
      inner.screen.width / inner.screen.height,
      2
    );
  });
});

describe("rotation, which the source owns", () => {
  it("tells the source and turns at once with the picture it has, as one element", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    const video = await pictureReady(container);
    const device = screen.getByTestId("remote-screen-device");
    const still = container.querySelector<HTMLCanvasElement>(
      ".comma-remote-screen-still"
    )!;

    pressRotate();
    expect(sent).toEqual([{ t: "device", name: "rotate" }]);
    await deviceTurned(90);
    // The picture it had, on the frame, turned with it: it comes round with the body, by what the body came.
    expect(still.style.transform).toBe("rotate(90deg)");
    expect(still.dataset.holding).toBe("true");
    expect([still.width, still.height]).toEqual([video.videoWidth, video.videoHeight]);
    expect(getComputedStyle(still).transform).not.toBe("none");
    expect(getComputedStyle(video).transform).toBe("none");
    expect(getComputedStyle(still).opacity).toBe("1");

    // The source's own picture replaces it in one go, with nothing between them.
    const replaced = new Promise<number>((resolve) => {
      const watch = new MutationObserver(() => {
        if (still.dataset.holding) return;
        watch.disconnect();
        resolve(video.videoWidth / video.videoHeight);
      });
      watch.observe(still, { attributes: true });
    });
    turnFakePicture(canvas);
    expect(await replaced).toBeCloseTo(840 / 390, 1);
    expect(still.style.transform).toBe("");
    // Gone at once: it does not fade over the picture that replaced it.
    expect(getComputedStyle(still).transitionDuration).toBe("0s");
    expect(getComputedStyle(still).opacity).toBe("0");
    expect(device.dataset.turn).toBe("90");
    const rect = container
      .querySelector(".comma-remote-screen-device-screen")!
      .getBoundingClientRect();
    const { screen: upright } = fakePhone[0];
    expect(rect.width / rect.height).toBeCloseTo(upright.height / upright.width, 2);
  });

  it("holds what showed before a turn nothing pressed: not the new picture in the old frame", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    const video = await pictureReady(container);
    const still = container.querySelector<HTMLCanvasElement>(
      ".comma-remote-screen-still"
    )!;
    // What was kept is of the picture as it stood: one frame of it, presented after it stood.
    await new Promise<void>((resolve) => {
      video.requestVideoFrameCallback(() => resolve());
      canvas.getContext("2d")?.fillRect(0, 0, 1, 1);
    });
    const held = new Promise<number[]>((resolve) => {
      const watch = new MutationObserver(() => {
        if (!still.dataset.holding) return;
        watch.disconnect();
        resolve([still.width, still.height]);
      });
      watch.observe(still, { attributes: true });
    });
    turnFakePicture(canvas);
    expect(await held).toEqual([390, 840]);
    await deviceTurned(90);
  });

  it("turns back from a press that turned nothing, and lets go of the picture", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    await pictureReady(container);
    const still = container.querySelector<HTMLCanvasElement>(
      ".comma-remote-screen-still"
    )!;
    pressRotate();
    await deviceTurned(90);
    const letGo = new Promise<void>((resolve) => {
      const watch = new MutationObserver(() => {
        if (still.dataset.holding) return;
        watch.disconnect();
        resolve();
      });
      watch.observe(still, { attributes: true });
    });
    await letGo;
    await deviceTurned(0);
    expect(still.style.transform).toBe("");
  });

  it.each([
    { turns: 0, orientation: 0, shown: [400, 700] },
    { turns: 1, orientation: 90, shown: [700, 400] },
  ] as const)(
    "touches the picture where it shows, after $turns turns of its source",
    async ({ turns, orientation, shown }) => {
      // Not the screen's shape, so that the picture has bars to be left out.
      const source = sourceOf(fakeDeviceCapabilities(fakePhone), [400, 700]);
      const view = render(stage(source));
      const video = await pictureReady(view.container);
      for (let done = 0; done < turns; done += 1) turnFakePicture(canvas);
      await pictureIs(video, shown[0], shown[1]);
      await deviceTurned(orientation);

      // Near a corner, so that a stale shape lands far from it.
      const at = shownAt(video, 0.2, 0.1);
      await commands.mouseMove(at.x, at.y);
      await commands.mouseDown();
      await commands.mouseUp();

      const [down, up] = fingers();
      expect(down).toMatchObject({ t: "pointer", kind: "down", buttons: 1 });
      expect(down?.x).toBeCloseTo(0.2, 1);
      expect(down?.y).toBeCloseTo(0.1, 1);
      expect(up).toMatchObject({ t: "pointer", kind: "up", buttons: 0 });
    }
  );
});

/** A stage whose state follows its stream's, as the screen's panel keeps it. */
function Followed({ source }: { source: ScreenStreamSource }) {
  const [state, setState] = useState<"connecting" | "live" | "failed">("connecting");
  return (
    <div data-state={state} style={{ display: "contents" }}>
      <ScreenStreamStage
        control
        onShape={(ratio) => shaped?.onShape(ratio)}
        onState={setState}
        source={source}
        state={state}
        target="app"
      />
    </div>
  );
}

describe("a stream that goes and comes back", () => {
  it("keeps the device's last picture, with no word over it, while it connects again", async () => {
    shaped = shapeRecorder();
    const { container } = render(
      hosted(<Followed source={sourceOf(fakeDeviceCapabilities(fakePhone))} />)
    );
    await pictureReady(container);
    const still = container.querySelector<HTMLCanvasElement>(
      ".comma-remote-screen-still"
    )!;

    peerNow!.onState("connecting");
    await expect
      .element(page.elementLocator(container.querySelector("[data-state]")!))
      .toHaveAttribute("data-state", "connecting");
    expect(still.dataset.kept).toBe("true");
    await Promise.all(still.getAnimations().map((fading) => fading.finished));
    expect(Number(getComputedStyle(still).opacity)).toBeGreaterThan(0);
    const status = container.querySelector(".comma-remote-screen-status")!;
    expect(getComputedStyle(status).visibility).toBe("hidden");
  });
});

describe("touch", () => {
  it("drags as moves, and a hover is no touch", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    const video = await pictureReady(container);
    const box = video.getBoundingClientRect();
    const { x, y } = center(box);
    await commands.mouseMove(x, y);
    expect(fingers()).toEqual([]);

    await commands.mouseDown();
    await commands.mouseMove(x, box.top + box.height * 0.8, 5);
    await commands.mouseUp();
    await commands.mouseMove(box.left + 5, box.top + 5);

    const kinds = fingers().map(({ kind }) => kind);
    expect(kinds[0]).toBe("down");
    expect(kinds).toContain("move");
    expect(kinds.at(-1)).toBe("up");
    expect(fingers().filter(({ kind }) => kind === "move")[0]?.buttons).toBe(1);
    expect(sent.some((input) => "type" in input)).toBe(false);
  });

  it("does not touch without control", async () => {
    const { container } = render(
      stage(sourceOf(fakeDeviceCapabilities(fakePhone)), { control: false })
    );
    const video = await pictureReady(container);
    const { x, y } = center(video.getBoundingClientRect());
    await commands.mouseMove(x, y);
    await commands.mouseDown();
    await commands.mouseUp();
    expect(sent).toEqual([]);
  });

  it("lifts a finger still down when the stage goes", async () => {
    const { container, unmount } = render(
      stage(sourceOf(fakeDeviceCapabilities(fakePhone)))
    );
    const video = await pictureReady(container);
    const { x, y } = center(video.getBoundingClientRect());
    await commands.mouseMove(x, y);
    await commands.mouseDown();
    unmount();
    await commands.mouseUp();
    expect(fingers().map(({ kind }) => kind)).toEqual(["down", "up"]);
  });

  it("scrolls with the station's wheel, on the picture as it arrives", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    const video = await pictureReady(container);
    video.dispatchEvent(
      new WheelEvent("wheel", { bubbles: true, cancelable: true, deltaY: 40 })
    );
    await untilSent(() => sent.length > 0);
    expect(sent).toEqual([expect.objectContaining({ t: "wheel", dx: 0, dy: 40 })]);
  });

  // still.fail web/src/screen/input.ts: a wheel that counts in lines is 16 pixels a line, and a frame's wheel is one.
  it("scrolls a line wheel by pixels, a frame's turns summed into one", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    const video = await pictureReady(container);
    for (const deltaY of [3, 2])
      video.dispatchEvent(
        new WheelEvent("wheel", {
          bubbles: true,
          cancelable: true,
          deltaY,
          deltaMode: 1,
        })
      );
    await untilSent(() => sent.length > 0);
    expect(sent).toEqual([expect.objectContaining({ t: "wheel", dx: 0, dy: 80 })]);
  });
});

describe("text", () => {
  it("goes to a device as text: what an IME composed, and a paste", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    const keys = keysBy(await pictureReady(container));
    keys.focus();
    // The IME's own keys go as nothing; what it made goes once, as it ends.
    const composing = press(keys, {
      key: "Process",
      code: "KeyN",
      keyCode: 229,
      isComposing: true,
    });
    keys.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    keys.dispatchEvent(
      new CompositionEvent("compositionend", { bubbles: true, data: "你好" })
    );
    const paste = new DataTransfer();
    paste.setData("text/plain", "粘贴 text");
    const pasted = new ClipboardEvent("paste", {
      bubbles: true,
      cancelable: true,
      clipboardData: paste,
    });
    keys.dispatchEvent(pasted);
    expect(composing.defaultPrevented).toBe(false);
    expect(pasted.defaultPrevented).toBe(true);
    expect(sent).toEqual([
      { t: "text", text: "你好" },
      { t: "text", text: "粘贴 text" },
    ]);
  });

  it("is not sent without control", async () => {
    const { container } = render(
      stage(sourceOf(fakeDeviceCapabilities(fakePhone)), { control: false })
    );
    const keys = keysBy(await pictureReady(container));
    keys.dispatchEvent(
      new CompositionEvent("compositionend", { bubbles: true, data: "你好" })
    );
    expect(sent).toEqual([]);
  });
});

describe("the device's buttons", () => {
  it("shows those declared, and sends each to the device", async () => {
    const { container } = render(
      stage(sourceOf({ input: "touch", buttons: ["home", "volume"] }))
    );
    await pictureReady(container);
    expect(buttonNames(container)).toEqual(["Home", "Volume up", "Volume down"]);

    screen.getByRole("button", { name: "Home" }).click();
    screen.getByRole("button", { name: "Volume down" }).click();
    expect(sent).toEqual([
      { t: "key", kind: "down", key: "h", code: "KeyH", mods: 12 },
      { t: "key", kind: "up", key: "h", code: "KeyH", mods: 12 },
      { t: "device", name: "volume_down" },
    ]);
  });

  it("names a button and its shortcut in its tooltip", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    await pictureReady(container);
    // (a tooltip opens on a hover once the pointer is in use, not after a script's clicks)
    await userEvent.click(page.getByRole("button", { name: "Home" }));
    await userEvent.hover(page.getByRole("button", { name: "Rotate" }));
    const tooltip = page.getByRole("tooltip");
    await expect.element(tooltip).toHaveTextContent("Rotate");
    await expect.element(tooltip).toHaveTextContent("→");
  });
});

/** A PNG of one color, `width`×`height`, in base64: a stand-in for a picture of the case its station makes. */
const png = (width: number, height: number, color: string) => {
  const drawn = document.createElement("canvas");
  drawn.width = width;
  drawn.height = height;
  const context = drawn.getContext("2d")!;
  context.fillStyle = color;
  context.fillRect(0, 0, width, height);
  return drawn.toDataURL("image/png").split(",")[1]!;
};

const presses = (container: HTMLElement) => [
  ...container.querySelectorAll<HTMLElement>(".comma-remote-screen-case-press"),
];

/** A made-up simulator's case round fakePhone's screen: a side button on its right, volume up on its left, a drawn mute. */
const fakeChrome = (asked: number[][]) => ({
  key: `chrome ${(sources += 1)}`,
  panels: [
    {
      key: "phone",
      width: 1170,
      height: 2520,
      frame: { width: 420, height: 880 },
      screen: { x: 15, y: 20, width: 390, height: 840 },
      corners: [0.14, 0.14, 0.14, 0.14],
      buttons: [
        {
          name: "power",
          x: 414,
          y: 200,
          width: 6,
          height: 100,
          dx: -3,
          dy: 0,
          page: 12,
          usage: 48,
        },
        {
          name: "volume-up",
          x: 0,
          y: 180,
          width: 6,
          height: 60,
          dx: 3,
          dy: 0,
          page: 12,
          usage: 233,
        },
        { name: "mute", x: 0, y: 120, width: 6, height: 30, dx: 3, dy: 0 },
      ],
    },
  ],
  pictures: (panel: number, turn: number) => {
    asked.push([panel, turn]);
    return Promise.resolve({
      body: png(42, 88, "#3a3a3c"),
      buttons: {
        power: { up: png(6, 100, "#636366"), down: png(6, 100, "#48484a") },
        "volume-up": { up: png(6, 60, "#636366") },
        mute: { up: png(6, 30, "#636366") },
      },
    });
  },
});

describe("a simulator's case", () => {
  const cased = async (control: boolean, asked: number[][] = []) => {
    const source = sourceOf({
      ...fakeDeviceCapabilities(fakePhone),
      chrome: fakeChrome(asked),
    });
    const { container, rerender } = render(stage(source, { control }));
    const video = await pictureReady(container);
    await expect.element(deviceLocator()).toHaveAttribute("data-case", "true");
    return { container, rerender, video, source };
  };
  const caseButtons = () =>
    sent.filter((input) => "t" in input && input.t === "button");

  it("is drawn round the picture, its buttons pressed where the case has them", async () => {
    const asked: number[][] = [];
    const { container, video } = await cased(true, asked);
    // Upright first, then each other way, for a turn to find them there.
    expect(asked[0]).toEqual([0, 0]);
    // The buttons it has are on the case, not beside it: Lock and the volume up are gone, the rest stay.
    expect(buttonNames(container)).toEqual(["Home", "Volume down", "Rotate"]);
    // A press for each button with a usage (a drawn one has none), beside the picture on its own side, never over it.
    const [power, volumeUp] = presses(container);
    expect(presses(container).map((one) => one.dataset.button)).toEqual([
      "power",
      "volume-up",
    ]);
    const screenBox = video.parentElement!.getBoundingClientRect();
    const device = deviceLocator().element().getBoundingClientRect();
    const powerBox = power!.getBoundingClientRect();
    const volumeBox = volumeUp!.getBoundingClientRect();
    expect(powerBox.left).toBeGreaterThanOrEqual(screenBox.right - 0.5);
    expect(volumeBox.right).toBeLessThanOrEqual(screenBox.left + 0.5);
    // At the chrome's height along the case: 200..300 of its 880 points.
    const along = (box: DOMRect) =>
      (box.top + box.height / 2 - device.top) / device.height;
    expect(along(powerBox)).toBeCloseTo(250 / 880, 2);
    expect(along(volumeBox)).toBeCloseTo(210 / 880, 2);
  });

  it("slides a side button and its hint outward while its press area stays fixed", async () => {
    const { container } = await cased(true);
    const [power] = presses(container);
    const casePicture = container.querySelector<HTMLElement>(
      '.comma-remote-screen-case-button[data-button="power"]'
    )!;
    const hint = power!.firstElementChild as HTMLElement;
    const pressArea = power!.getBoundingClientRect().toJSON();
    const beforePicture = casePicture.getBoundingClientRect().left;
    const beforeHint = hint.getBoundingClientRect().left;
    const { x, y } = center(power!.getBoundingClientRect());
    await commands.mouseMove(x, y);
    const animations = [...hint.getAnimations(), ...casePicture.getAnimations()];
    const fade = animations.find(
      (animation) =>
        animation instanceof CSSTransition && animation.transitionProperty === "opacity"
    )!;
    expect(fade).toBeDefined();
    for (const animation of animations) {
      animation.pause();
      animation.currentTime = Number(animation.effect!.getComputedTiming().endTime) / 2;
    }
    const halfway = Number(getComputedStyle(hint).opacity);
    expect(halfway).toBeGreaterThan(0);
    expect(halfway).toBeLessThan(1);
    expect(hint.getBoundingClientRect().left).toBeGreaterThan(beforeHint);
    expect(casePicture.getBoundingClientRect().left).toBeGreaterThan(beforePicture);
    expect(power!.getBoundingClientRect().toJSON()).toEqual(pressArea);
    for (const animation of animations) animation.finish();
    await expect.element(hint).toHaveStyle({ opacity: "1" });
    expect(hint.getBoundingClientRect().left).toBeGreaterThan(
      deviceLocator().element().getBoundingClientRect().right
    );
    expect(caseButtons()).toEqual([]);
    await commands.mouseMove(0, 0);
    await expect.element(hint).toHaveStyle({ opacity: "0" });
    expect(casePicture.getBoundingClientRect().left).toBeCloseTo(beforePicture, 2);
  });

  it("shows the controls immediately when reduced motion is enabled", async () => {
    await commands.emulateMedia({ reducedMotion: "reduce" });
    const { container } = await cased(true);
    const [power] = presses(container);
    const { x, y } = center(power!.getBoundingClientRect());
    await commands.mouseMove(x, y);
    const hint = power!.firstElementChild as HTMLElement;
    await expect.element(hint).toHaveStyle({ opacity: "1" });
    expect(hint.getAnimations()).toHaveLength(0);
  });

  it("presses the revealed icon and holds its HID usage until release", async () => {
    const { container } = await cased(true);
    const [power] = presses(container);
    const { x, y } = center(power!.firstElementChild!.getBoundingClientRect());
    await commands.mouseMove(x, y);
    await commands.mouseDown();
    await untilSent(() => caseButtons().length === 1);
    expect(power).toHaveAttribute("aria-pressed", "true");
    await commands.mouseUp();
    await untilSent(() => caseButtons().length === 2);
    expect(caseButtons()).toEqual([
      { t: "button", page: 12, usage: 48, down: true },
      { t: "button", page: 12, usage: 48, down: false },
    ]);
  });

  it("is not pressed without control, and a button held is let go of as control goes", async () => {
    const watching = await cased(false);
    expect(presses(watching.container)).toEqual([]);
    expect(caseButtons()).toEqual([]);
    cleanup();

    const { container, rerender, source } = await cased(true);
    const [power] = presses(container);
    const { x, y } = center(power!.getBoundingClientRect());
    await commands.mouseMove(x, y);
    await commands.mouseDown();
    await untilSent(() => caseButtons().length === 1);
    rerender(stage(source, { control: false }));
    await untilSent(() => caseButtons().length === 2);
    await commands.mouseUp();
    expect(caseButtons()).toEqual([
      { t: "button", page: 12, usage: 48, down: true },
      { t: "button", page: 12, usage: 48, down: false },
    ]);
  });

  it("lets go of a button held by its key when the focus leaves it", async () => {
    const { container } = await cased(true);
    const power = presses(container).find((one) => one.dataset.button === "power")!;
    power.focus();
    await userEvent.keyboard("{Enter>}");
    await untilSent(() => caseButtons().length === 1);
    await userEvent.keyboard("{Tab}");
    await userEvent.keyboard("{/Enter}");
    await untilSent(() => caseButtons().length === 2);
    expect(caseButtons()).toEqual([
      { t: "button", page: 12, usage: 48, down: true },
      { t: "button", page: 12, usage: 48, down: false },
    ]);
  });

  it("lets go of a held button when the window loses focus or is hidden", async () => {
    const { container } = await cased(true);
    const [power, volumeUp] = presses(container);
    for (const [target, leave] of [
      [power!, () => window.dispatchEvent(new Event("blur"))],
      [
        volumeUp!,
        () => {
          Object.defineProperty(document, "visibilityState", {
            configurable: true,
            get: () => "hidden",
          });
          document.dispatchEvent(new Event("visibilitychange"));
          delete (document as { visibilityState?: unknown }).visibilityState;
        },
      ],
    ] as const) {
      const sentBefore = caseButtons().length;
      const { x, y } = center(target.getBoundingClientRect());
      await commands.mouseMove(x, y);
      await commands.mouseDown();
      await untilSent(() => caseButtons().length === sentBefore + 1);
      leave();
      await untilSent(() => caseButtons().length === sentBefore + 2);
      await commands.mouseUp();
      expect(caseButtons().at(-1)).toMatchObject({ down: false });
    }
    expect(caseButtons()).toHaveLength(4);
  });

  it("leaves the beside-the-device buttons where there is no case", async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    await pictureReady(container);
    await expect.element(deviceLocator()).toHaveAttribute("data-case", "false");
    expect(buttonNames(container)).toEqual([
      "Home",
      "Lock",
      "Volume up",
      "Volume down",
      "Rotate",
    ]);
    expect(presses(container)).toEqual([]);
  });
});

const takeFirst = (event: KeyboardEvent) => event.preventDefault();

describe("shortcuts", () => {
  const device = async () => {
    const { container } = render(stage(sourceOf(fakeDeviceCapabilities(fakePhone))));
    return pictureReady(container);
  };

  it("press the device's buttons while it is focused", async () => {
    const keys = keysBy(await device());
    keys.focus();
    const event = press(keys, { code: "KeyH", shiftKey: true, ...primary });
    press(keys, { code: "KeyL", ...primary });
    press(keys, { code: "ArrowUp", ...primary });
    press(keys, { code: "ArrowDown", ...primary });
    press(keys, ROTATE);
    expect(event.defaultPrevented).toBe(true);
    expect(sent).toEqual([
      { t: "key", kind: "down", key: "h", code: "KeyH", mods: 12 },
      { t: "key", kind: "up", key: "h", code: "KeyH", mods: 12 },
      { t: "key", kind: "down", key: "l", code: "KeyL", mods: 4 },
      { t: "key", kind: "up", key: "l", code: "KeyL", mods: 4 },
      { t: "device", name: "volume_up" },
      { t: "device", name: "volume_down" },
      { t: "device", name: "rotate" },
    ]);
  });

  it("do nothing when the device is not focused", async () => {
    await device();
    const event = press(document.body, ROTATE);
    expect(event.defaultPrevented).toBe(false);
    expect(sent).toEqual([]);
  });

  it("act once for a held key", async () => {
    const video = await device();
    press(keysBy(video), ROTATE);
    press(keysBy(video), { ...ROTATE, repeat: true });
    expect(sent).toEqual([{ t: "device", name: "rotate" }]);
  });

  it("send another key on as the station's key", async () => {
    const video = await device();
    press(keysBy(video), { key: "a", code: "KeyA", shiftKey: true });
    expect(sent).toEqual([{ t: "key", kind: "down", key: "a", code: "KeyA", mods: 8 }]);
  });

  it("leave a key undeclared to the device, as a key", async () => {
    const { container } = render(
      stage(sourceOf({ input: "touch", buttons: ["home"] }))
    );
    const video = await pictureReady(container);
    press(keysBy(video), ROTATE);
    expect(sent).toEqual([
      expect.objectContaining({ t: "key", kind: "down", code: "ArrowRight" }),
    ]);
  });

  it("do not press a button without control, and stay out of the app's way", async () => {
    const { container } = render(
      stage(sourceOf(fakeDeviceCapabilities(fakePhone)), { control: false })
    );
    const video = await pictureReady(container);
    const event = press(keysBy(video), { code: "KeyL", ...primary });
    expect(event.defaultPrevented).toBe(false);
    expect(sent).toEqual([]);
  });

  it("yield a chord bound in the app to the app", async () => {
    vi.mocked(useOptionalAppShortcutBindings).mockReturnValue({
      "go-search": {
        kind: "chord",
        stroke: {
          code: "KeyL",
          modifiers: { alt: false, control: !macos, meta: macos, shift: false },
        },
      },
    } as unknown as ReturnType<typeof useOptionalAppShortcutBindings>);
    const video = await device();
    const event = press(keysBy(video), { code: "KeyL", ...primary });
    expect(event.defaultPrevented).toBe(false);
    expect(sent).toEqual([]);
  });

  it("yield to an app listener that took the key first", async () => {
    const video = await device();
    window.addEventListener("keydown", takeFirst, true);
    press(keysBy(video), { code: "KeyL", ...primary });
    window.removeEventListener("keydown", takeFirst, true);
    expect(sent).toEqual([]);
  });
});
