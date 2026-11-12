import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { act, cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { installFullscreenWindowRegions } from "@comma/ui/components/window-regions/fullscreenWindowRegions";
import type { CSSProperties } from "react";
import { afterEach, expect, it, onTestFinished, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { openMeshScreenStream } from "../meshScreenStream";
import { ScreenStreamPanel } from "../ScreenStreamPanel";
import type { ScreenStreamSource } from "../ScreenStreamStage";

vi.mock("../meshScreenStream", () => ({ openMeshScreenStream: vi.fn() }));

afterEach(async () => {
  if (document.fullscreenElement) await document.exitFullscreen();
  cleanup();
});

/** Until the page shows it: the page changing is what is waited on. */
async function untilPage(what: () => boolean) {
  while (!what())
    await new Promise<void>((resolve) => {
      const seen = new MutationObserver(() => {
        seen.disconnect();
        resolve();
      });
      seen.observe(document.body, { attributes: true, childList: true, subtree: true });
    });
}

/**
 * The window app region a press at this point meets, as Electron works it
 * out: every box (and its ::before and ::after) that has a region, in
 * document order, at its place in the window, the last one over the point
 * deciding. The top layer does not take part: the boxes under a full screen
 * element keep their regions. A press on "drag" never reaches the page.
 */
function regionAt(x: number, y: number) {
  let region = "none";
  for (const element of document.querySelectorAll("*")) {
    const box = element.getBoundingClientRect();
    if (x < box.left || x > box.right || y < box.top || y > box.bottom) continue;
    for (const pseudo of [null, "::before", "::after"]) {
      const own = getComputedStyle(element, pseudo).getPropertyValue(
        "-webkit-app-region"
      );
      if (own === "drag" || own === "no-drag") region = own;
    }
  }
  return region;
}

it("opens the figures from the bars of a panel filling the screen over the window bar's drag region", async () => {
  const opened: Parameters<typeof openMeshScreenStream>[0][] = [];
  vi.mocked(openMeshScreenStream).mockImplementation((peer) => {
    opened.push(peer);
    return { send: () => undefined, close: () => undefined };
  });
  const source: ScreenStreamSource = {
    key: "workspace\ndevice\nfull-stats",
    view: { open: () => new Promise(() => undefined), send: () => undefined },
  };
  const core = createScriptedCore({ values: () => undefined });
  // What the app installs at its root (CommaApp).
  onTestFinished(installFullscreenWindowRegions(document));
  // The app's shell: a drag surface, the screen page in a no-drag side panel
  // on the right, and the window bar's drag region along the top, after it.
  const view = render(
    core.wrap(
      <div className="comma-app-shell" style={{ position: "fixed", inset: 0 }}>
        <section
          style={
            {
              position: "absolute",
              top: 44,
              right: 0,
              bottom: 0,
              width: 480,
              display: "flex",
              WebkitAppRegion: "no-drag",
            } as CSSProperties
          }
        >
          <ScreenStreamPanel active appName="Safari" source={source} />
        </section>
        <div
          className="comma-window-titlebar-region"
          style={{ position: "absolute", top: 0, left: 0, right: 0, height: 44 }}
        />
      </div>
    )
  );
  const canvas = document.createElement("canvas");
  canvas.width = 400;
  canvas.height = 200;
  canvas.getContext("2d")!.fillRect(0, 0, 400, 200);
  act(() => {
    opened[0]!.onStream(canvas.captureStream(0));
    opened[0]!.onState("live");
  });

  await userEvent.click(view.getByRole("button", { name: "Full screen" }));
  // The panel says it fills the screen once the browser says so.
  await untilPage(
    () => view.queryByRole("button", { name: "Exit full screen" }) !== null
  );
  const filling = document.fullscreenElement!;
  expect(filling).toBe(view.getByTestId("remote-screen-panel"));

  // Each control on the bar takes its press: none lies on a drag region.
  const bar = filling.querySelector("header")!;
  const lost = [...bar.querySelectorAll("button")].flatMap((button) => {
    const box = button.getBoundingClientRect();
    const region = regionAt(box.x + box.width / 2, box.y + box.height / 2);
    return region === "drag"
      ? [button.getAttribute("aria-label") ?? button.textContent]
      : [];
  });
  expect(lost).toEqual([]);

  await userEvent.click(view.getByRole("button", { name: "Connection" }));
  await untilPage(
    () => document.querySelector("[data-testid=remote-screen-stats-panel]") !== null
  );
  const figures = document.querySelector<HTMLElement>(
    "[data-testid=remote-screen-stats-panel]"
  )!;
  // Drawn: inside what fills the screen (the top layer draws nothing else), and on top where it is.
  expect(filling.contains(figures)).toBe(true);
  const box = figures.getBoundingClientRect();
  const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
  expect(figures.contains(hit)).toBe(true);
  expect(regionAt(box.x + box.width / 2, box.y + box.height / 2)).not.toBe("drag");
});
