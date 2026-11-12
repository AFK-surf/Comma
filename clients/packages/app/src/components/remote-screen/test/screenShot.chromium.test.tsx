// A screenshot as it is taken: the picture flashes where it shows, the screenshot lies in the stage's corner for five
// seconds and goes, the pointer on it holds it, a press asks about it, and a drag carries it as a file.
import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { installUiClock } from "@comma/ui/clock";
import { createVirtualUiClock, type VirtualUiClock } from "@comma/ui/clock/virtual";
import { act, cleanup, render } from "@comma/test-utils/render";
import { motionDuration } from "@comma/ui/tokens";
import { useState } from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  SCREEN_SHOT_STAYS_MS,
  ScreenShotThumb,
  ScreenShutter,
  type ScreenShot,
} from "../ScreenShot";

let clock: VirtualUiClock;
let restore: () => void;
beforeEach(() => {
  clock = createVirtualUiClock();
  restore = installUiClock(clock);
});
afterEach(() => {
  cleanup();
  restore();
});

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

/** A red PNG the shape of a phone's screen. */
async function png(): Promise<Blob> {
  const canvas = document.createElement("canvas");
  canvas.width = 300;
  canvas.height = 600;
  const draw = canvas.getContext("2d")!;
  draw.fillStyle = "#ff0000";
  draw.fillRect(0, 0, 300, 600);
  return new Promise((resolve) => canvas.toBlob((blob) => resolve(blob!), "image/png"));
}

/** A panel with a stage over a bar, as the screen panel lays them, and the screenshot in it. */
async function shown(props: { onAsk?: () => void; onGone?: () => void } = {}) {
  const shot: ScreenShot = { id: 1, png: await png(), name: "iPhone 2026-11-10.png" };
  const view = render(
    <div
      className="comma-remote-screen-panel"
      data-testid="panel"
      style={{ width: 400, height: 600 }}
    >
      <div className="comma-remote-screen-stage" data-testid="stage" />
      <div style={{ flex: "none", height: 40 }} />
      <ScreenShotThumb
        onAsk={props.onAsk}
        onGone={props.onGone ?? (() => undefined)}
        panel={() => document.querySelector('[data-testid="panel"]')}
        picture={() => null}
        shot={shot}
        stage={() => document.querySelector('[data-testid="stage"]')}
      />
    </div>
  );
  const thumb = () => view.getByTestId("remote-screen-shot");
  // (it is placed once its picture has loaded)
  await untilPage(() => thumb().style.visibility === "");
  return { view, thumb, shot };
}

it("lies in the stage's lower right corner, over the bars under the stage", async () => {
  const { view, thumb } = await shown();
  const stage = view.getByTestId("stage").getBoundingClientRect();
  const lies = thumb().getBoundingClientRect();
  // (a gutter of 16 from the stage's edges; no taller than 128)
  expect(stage.right - lies.right).toBeCloseTo(16, 0);
  expect(stage.bottom - lies.bottom).toBeCloseTo(16, 0);
  expect(lies.height).toBeCloseTo(128, 0);
  expect(lies.width).toBeCloseTo(64, 0);
});

it("stays five seconds, then goes", async () => {
  const onGone = vi.fn();
  const { thumb } = await shown({ onGone });
  act(() => clock.advance(SCREEN_SHOT_STAYS_MS - 1));
  expect(thumb().dataset.leaving).toBeUndefined();
  expect(onGone).not.toHaveBeenCalled();
  act(() => clock.advance(1));
  expect(thumb().dataset.leaving).toBe("true");
  expect(onGone).not.toHaveBeenCalled();
  act(() => clock.advance(motionDuration.pictureInPictureExit));
  expect(onGone).toHaveBeenCalledTimes(1);
});

it("is held by the pointer on it, and stays its five seconds again once the pointer leaves", async () => {
  const onGone = vi.fn();
  const { thumb } = await shown({ onGone });
  act(() => clock.advance(4_000));
  act(() => {
    thumb().dispatchEvent(new PointerEvent("pointerover", { bubbles: true }));
  });
  act(() => clock.advance(60_000));
  expect(thumb().dataset.leaving).toBeUndefined();
  act(() => {
    thumb().dispatchEvent(
      new PointerEvent("pointerout", { bubbles: true, relatedTarget: document.body })
    );
  });
  act(() => clock.advance(SCREEN_SHOT_STAYS_MS - 1));
  expect(thumb().dataset.leaving).toBeUndefined();
  act(() => clock.advance(1 + motionDuration.pictureInPictureExit));
  expect(onGone).toHaveBeenCalledTimes(1);
});

it("is asked about when it is pressed", async () => {
  const onAsk = vi.fn();
  const { view } = await shown({ onAsk });
  view
    .getByRole("button", { name: "Ask Comma: iPhone 2026-11-10.png" })
    .dispatchEvent(new MouseEvent("click", { bubbles: true }));
  expect(onAsk).toHaveBeenCalledTimes(1);
});

it("carries its PNG as a file when it is dragged, and stays while it is", async () => {
  const onGone = vi.fn();
  const { thumb, shot } = await shown({ onGone });
  const carried = new DataTransfer();
  act(() => {
    thumb().dispatchEvent(
      new DragEvent("dragstart", { bubbles: true, dataTransfer: carried })
    );
  });
  expect([...carried.types]).toContain("Files");
  const file = carried.files[0]!;
  expect([file.name, file.type, file.size]).toEqual([
    "iPhone 2026-11-10.png",
    "image/png",
    shot.png.size,
  ]);
  // The drag holds it, however long it takes.
  act(() => clock.advance(60_000));
  expect(thumb().dataset.leaving).toBeUndefined();
  // Dropped on nothing that takes it, it stays its five seconds again.
  act(() => {
    thumb().dispatchEvent(
      new DragEvent("dragend", { bubbles: true, dataTransfer: new DataTransfer() })
    );
  });
  expect(onGone).not.toHaveBeenCalled();
  act(() => clock.advance(SCREEN_SHOT_STAYS_MS + motionDuration.pictureInPictureExit));
  expect(onGone).toHaveBeenCalledTimes(1);
});

/** A panel with a picture in it and a button that takes a screenshot of it. */
function Shutter() {
  const [shot, setShot] = useState(0);
  return (
    <div className="comma-remote-screen-panel" style={{ width: 400, height: 600 }}>
      <video
        muted
        style={{ position: "absolute", left: 50, top: 80, width: 300, height: 400 }}
      />
      <button onClick={() => setShot((count) => count + 1)} type="button">
        Take
      </button>
      <ScreenShutter
        panel={() => document.querySelector(".comma-remote-screen-panel")}
        picture={() => document.querySelector("video")}
        shot={shot}
      />
    </div>
  );
}

it("flashes the picture where it shows, at each press", () => {
  const view = render(<Shutter />);
  const flash = () =>
    view.container.querySelector<HTMLElement>(".comma-remote-screen-shutter");
  const take = () =>
    act(() => {
      view.getByRole("button", { name: "Take" }).click();
    });
  // Nothing was pressed yet.
  expect(flash()).toBeNull();
  take();
  const first = flash()!;
  const at = first.getBoundingClientRect();
  const over = document.querySelector("video")!.getBoundingClientRect();
  expect([at.left, at.top, at.width, at.height]).toEqual([
    over.left,
    over.top,
    over.width,
    over.height,
  ]);
  // The next press flashes anew.
  take();
  expect(flash()).not.toBe(first);
});
