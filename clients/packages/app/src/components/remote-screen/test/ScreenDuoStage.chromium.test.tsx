import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { commands, page } from "vitest/browser";
import type { DuoPosture, DuoPostureId } from "../devices/duoScreens";
import type { ScreenStreamInput } from "../screenStreamInput";
import { openMeshScreenStream } from "../meshScreenStream";
import { ScreenStreamStage, type ScreenStreamSource } from "../ScreenStreamStage";
import { fakeFoldable, fakePicture } from "./fakeScreenDevice";

vi.mock("../meshScreenStream", () => ({ openMeshScreenStream: vi.fn() }));
vi.mock("../../shortcuts/commaAppShortcuts", () => ({
  useOptionalAppShortcutBindings: vi.fn(() => null),
}));

const POSTURES: DuoPosture[] = [
  {
    id: "coverPortrait",
    screen: "cover",
    opening: 0,
    stand: "upright",
    orientation: 0,
    pose: "closed",
  },
  {
    id: "coverLandscape",
    screen: "cover",
    opening: 0,
    stand: "upright",
    orientation: 90,
    pose: "closed",
  },
  {
    id: "tent",
    screen: "cover",
    opening: 75,
    stand: "tent",
    orientation: 90,
    pose: "closed",
  },
  {
    id: "laptop",
    screen: "inner",
    opening: 105,
    stand: "laptop",
    orientation: 180,
    pose: "open",
  },
  {
    id: "innerLandscape",
    screen: "inner",
    opening: 180,
    stand: "upright",
    orientation: 90,
    pose: "open",
  },
  {
    id: "innerPortrait",
    screen: "inner",
    opening: 180,
    stand: "upright",
    orientation: 0,
    pose: "open",
  },
];

const core = createScriptedCore({ values: () => undefined });
let sent: ScreenStreamInput[] = [];
let postures: DuoPostureId[] = [];
let picture: MediaStream;
let canvas: HTMLCanvasElement;
let sources = 0;

beforeEach(() => {
  sent = [];
  postures = [];
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    queueMicrotask(() => {
      peer.onStream(picture);
      peer.onState("live");
    });
    return {
      send: (input) => void sent.push(input),
      setPosture: (posture) => void postures.push(posture),
      close: () => undefined,
    };
  });
});
afterEach(cleanup);

/** An iPhone Duo's source, closed: its cover display's picture. */
function duoSource(): ScreenStreamSource {
  canvas = fakePicture(1398, 2034);
  picture = canvas.captureStream();
  sources += 1;
  return {
    key: `workspace\nduo\n${sources}`,
    view: { open: () => new Promise(() => undefined), send: () => undefined },
    capabilities: {
      input: "touch",
      buttons: ["home", "lock"],
      shapes: fakeFoldable,
      poses: ["closed", "open"],
      postures: POSTURES,
    },
  };
}

const stage = (source: ScreenStreamSource) =>
  core.wrap(
    <div style={{ width: 600, height: 600, display: "flex" }}>
      <ScreenStreamStage
        control
        onState={() => undefined}
        source={source}
        state="live"
        target="app"
      />
    </div>
  );

/** Resolves with the element once the page has it, told by each change to the page: no deadline of its own. */
function appears<T extends Element>(selector: string): Promise<T> {
  return new Promise((resolve) => {
    const now = document.querySelector<T>(selector);
    if (now) return resolve(now);
    const watch = new MutationObserver(() => {
      const found = document.querySelector<T>(selector);
      if (!found) return;
      watch.disconnect();
      resolve(found);
    });
    watch.observe(document.body, { childList: true, subtree: true, attributes: true });
  });
}

/** Resolves once `video` takes `stream`: its load starts as the stream is set. */
function plays(video: HTMLVideoElement, stream: MediaStream): Promise<void> {
  return new Promise((resolve) => {
    if (video.srcObject === stream) return resolve();
    const started = () => {
      if (video.srcObject !== stream) return;
      video.removeEventListener("loadstart", started);
      resolve();
    };
    video.addEventListener("loadstart", started);
  });
}

/** Draws the fixture's picture again until `video` has shown a frame that `what` takes. */
function frameWhere(video: HTMLVideoElement, what: () => boolean): Promise<void> {
  return new Promise((resolve) => {
    const check = () => {
      if (what()) return resolve();
      canvas.getContext("2d")!.drawImage(canvas, 0, 0);
      video.requestVideoFrameCallback(check);
    };
    check();
  });
}

/** The model has loaded and drawn itself at rest (`data-still`), its picture showing. */
async function modelShown() {
  const model = await appears<HTMLCanvasElement>(
    ".comma-remote-screen-duo-canvas[data-still]"
  );
  const shown = await appears<HTMLVideoElement>(
    ".comma-remote-screen-duo-picture video"
  );
  await plays(shown, picture);
  await frameWhere(shown, () => shown.videoWidth > 0);
  return model;
}

const fingers = () =>
  sent.filter(
    (input): input is Extract<ScreenStreamInput, { t: "pointer" }> =>
      "t" in input && input.t === "pointer"
  );

describe("an iPhone Duo", () => {
  it("is moved by its postures, in place of the fold buttons", async () => {
    render(stage(duoSource()));
    await expect
      .element(page.getByTestId("remote-screen-device"))
      .toHaveAttribute("data-posture", "coverPortrait");
    expect(screen.queryByRole("button", { name: "Inner screen" })).toBeNull();
    await expect
      .element(page.getByRole("button", { name: "Outer screen, portrait" }))
      .toHaveAttribute("aria-pressed", "true");

    await page.getByRole("button", { name: "Laptop" }).click();
    expect(postures).toEqual(["laptop"]);
    await expect
      .element(page.getByTestId("remote-screen-device"))
      .toHaveAttribute("data-posture", "laptop");
  });

  it("shows its picture on the model when its postures come after its stream opened", async () => {
    // The listing says the postures later: the stage first shows the device flat, then as the model, with another
    // <video>, which must take the stream already open.
    const source = duoSource();
    const { postures: known, ...flat } = source.capabilities!;
    const { rerender } = render(stage({ ...source, capabilities: flat }));
    await plays(await appears<HTMLVideoElement>("video"), picture);
    expect(known).toBeDefined();
    rerender(stage(source));
    const shown = await appears<HTMLVideoElement>(
      ".comma-remote-screen-duo-picture video"
    );
    await plays(shown, picture);
    await frameWhere(shown, () => shown.videoWidth > 0);
  });

  it("follows its picture's shape on the model's own <video>, mounted after its stream opened", async () => {
    // The picture turns landscape after the model has replaced the flat stage's <video>: the stage stands landscape at
    // once, as the picture that shows now says, not when the replaced <video> gets round to it.
    const source = duoSource();
    const { postures: known, ...flat } = source.capabilities!;
    const { rerender } = render(stage({ ...source, capabilities: flat }));
    const replaced = await appears<HTMLVideoElement>("video");
    await plays(replaced, picture);
    rerender(stage({ ...source, capabilities: { ...flat, postures: known } }));
    const shown = await appears<HTMLVideoElement>(
      ".comma-remote-screen-duo-picture video"
    );
    expect(shown).not.toBe(replaced);
    await expect
      .element(page.getByTestId("remote-screen-device"))
      .toHaveAttribute("data-posture", "coverPortrait");
    // (the replaced <video> no longer hears its stream)
    replaced.srcObject = null;
    canvas.width = 2034;
    canvas.height = 1398;
    await plays(shown, picture);
    await frameWhere(shown, () => shown.videoWidth === 2034);
    await expect
      .element(page.getByTestId("remote-screen-device"))
      .toHaveAttribute("data-posture", "coverLandscape");
  });

  it("takes a press on its screen as a finger where the picture is, and none beside it", async () => {
    render(stage(duoSource()));
    const model = await modelShown();
    const box = model.getBoundingClientRect();
    // Beside the device, at the canvas's corner: nothing.
    await commands.mouseMove(box.left + 4, box.top + 4);
    await commands.mouseDown();
    await commands.mouseUp();
    expect(fingers()).toEqual([]);

    // Its middle is the closed device's, about the cover picture's middle.
    await commands.mouseMove(box.left + box.width / 2, box.top + box.height / 2);
    await commands.mouseDown();
    await commands.mouseUp();
    const [down, up] = fingers();
    expect(down).toMatchObject({ t: "pointer", kind: "down", buttons: 1 });
    expect(Math.abs(down!.x - 0.5)).toBeLessThan(0.1);
    expect(Math.abs(down!.y - 0.5)).toBeLessThan(0.1);
    expect(up).toMatchObject({ t: "pointer", kind: "up", buttons: 0 });
  });
});
