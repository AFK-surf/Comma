import { expect, test, type Page } from "@playwright/test";
import {
  installVirtualTime,
  type VirtualTime,
} from "../../../e2e/helpers/virtual-time";

const story =
  "/iframe.html?id=app-components-chat-message-send-motion--spring-playground&viewMode=story";
const flying = '.comma-chat-user-bubble[data-outgoing-presentation="flying"]';

/** Opens the playground on the test clock. */
async function openPlayground(page: Page): Promise<VirtualTime> {
  const clock = await installVirtualTime(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto(story);
  await expect(page.getByTestId("message-send-playground")).toBeVisible();
  return clock;
}

/** Steps to the frame in which the replayed flight starts to play. */
async function stepToFlight(clock: VirtualTime) {
  await clock.advanceUntil(() =>
    document
      .querySelector('.comma-chat-user-bubble[data-outgoing-presentation="flying"]')
      ?.getAnimations()
      .some((animation) => animation.playState === "running")
  );
}

test("slow replay uses one playback rate for the bubble, text and input chrome", async ({
  page,
}) => {
  const clock = await openPlayground(page);
  for (const rate of [0.25, 0.5, 0.75, 1]) {
    await page
      .getByRole("button", {
        name: rate === 1 ? "Replay send" : `Replay ${rate}×`,
        exact: true,
      })
      .click();
    await stepToFlight(clock);
    const timing = await page.locator(flying).evaluate((bubble) => {
      // The flight's own Web Animations, not CSS motion inside the bubble.
      const animations = bubble
        .getAnimations({ subtree: true })
        .filter(
          (animation) =>
            !(animation instanceof CSSAnimation || animation instanceof CSSTransition)
        );
      return {
        rates: animations.map((animation) => animation.playbackRate),
        duration: Number(bubble.getAnimations()[0]!.effect!.getTiming().duration),
      };
    });
    expect(timing.rates.length).toBeGreaterThanOrEqual(2);
    expect(timing.rates.every((value) => value === rate)).toBe(true);
    expect(timing.duration).toBeGreaterThan(850);
    expect(timing.duration).toBeLessThan(950);
    await expect(page.getByTestId("motion-total-duration")).toHaveText(
      `Replay: ${Math.round(timing.duration / rate)} ms (${rate}×)`
    );
    if (rate === 1) {
      // The flight lands in the frame after its duration.
      await clock.advance(timing.duration);
      await expect(page.locator(flying)).toHaveCount(1);
    } else {
      // The next test lands a slowed flight in full; this one only checks
      // that the landing still settles the bubble.
      await page.locator(flying).evaluate((bubble) => {
        for (const animation of bubble.getAnimations({ subtree: true }))
          animation.finish();
      });
    }
    await clock.advanceFrames(2);
    await expect(page.locator(flying)).toHaveCount(0);
    await expect(page.locator(".comma-chat-user-bubble")).toHaveCount(1);
  }
});

test("a quarter-speed replay survives the normal four-second launch expiry", async ({
  page,
}) => {
  const clock = await openPlayground(page);
  await setControl(page, "Position Delay (ms)", 750);
  await page.getByRole("button", { name: "Replay 0.25×", exact: true }).click();
  await stepToFlight(clock);
  const bubble = page.locator(flying);
  const duration = await bubble.evaluate((element) =>
    Number(element.getAnimations()[0]!.effect!.getTiming().duration)
  );
  expect(duration / 0.25).toBeGreaterThan(4_200);
  // The launch expiry timer runs on the same clock as the flight.
  await clock.advance(4_200);
  await expect(bubble).toHaveCount(1);
  await clock.advance(duration / 0.25 - 4_200 + 2 * 16);
  await expect(bubble).toHaveCount(0);
  await expect(page.locator(".comma-chat-user-bubble")).toHaveCount(1);
});

async function setControl(page: Page, name: string, value: number) {
  const input = page.getByRole("textbox", { name, exact: true });
  await input.fill(String(value));
  await input.press("Enter");
}

test("the bubble and text scale together without visible intermediate wrapping", async ({
  page,
}) => {
  const clock = await openPlayground(page);
  await page.getByRole("button", { name: "Multiline", exact: true }).click();
  await page.getByRole("button", { name: "Replay send", exact: true }).click();
  const bubble = page.locator(flying);
  await stepToFlight(clock);
  const frames = await bubble.evaluate((element) => {
    const content = element.querySelector<HTMLElement>(
      ".comma-chat-user-bubble-content"
    )!;
    const animations = element.getAnimations({ subtree: true });
    for (const animation of animations) animation.pause();
    return [0, 40, 70, 90, 100, 110, 160, 250, 400, 650, 800, 900, 1000, 1200].map(
      (time) => {
        for (const animation of animations) animation.currentTime = time;
        const matrix = new DOMMatrixReadOnly(getComputedStyle(element).transform);
        const style = getComputedStyle(content);
        return {
          time,
          x: matrix.a,
          y: matrix.d,
          width: parseFloat(style.width),
          opacity: parseFloat(style.opacity),
          textScale: content.getBoundingClientRect().width / parseFloat(style.width),
        };
      }
    );
  });
  const targetWidth = frames.at(-1)!.width;
  for (const frame of frames) {
    expect(Math.abs(frame.x - frame.y)).toBeLessThan(0.001);
    expect(Math.abs(frame.textScale - frame.x)).toBeLessThan(0.001);
    expect(Math.abs(frame.width - targetWidth)).toBeLessThan(0.5);
  }
  expect(frames.every((frame) => frame.opacity === 1)).toBe(true);
  expect(Math.min(...frames.map((frame) => frame.x))).toBeLessThan(0.72);
  expect(Math.max(...frames.map((frame) => frame.x))).toBeLessThan(1.01);
  expect(frames.at(-1)!.x).toBeCloseTo(1, 3);
});

test("main chat replays the actual bubble with independent width, height and position delays", async ({
  page,
}) => {
  const clock = await openPlayground(page);
  await setControl(page, "Surface Compression ratio", 0);
  await setControl(page, "Width Delay (ms)", 0);
  await setControl(page, "Height Delay (ms)", 300);
  await setControl(page, "Position Delay (ms)", 650);
  // Explicit line breaks produce a different input height and bubble height.
  await page.getByRole("button", { name: "Multiline", exact: true }).click();
  // Let the composer finish growing to the new draft.
  await clock.advance(1_000);
  const composer = page.locator(".comma-chat-composer");
  await expect(composer).toBeInViewport();
  const source = await composer.boundingBox();
  const preview = page.getByRole("region", { name: "Conversation", exact: true });
  const box = await preview.boundingBox();
  expect(source!.y).toBeGreaterThan(box!.y + box!.height / 2);
  expect(source!.y + source!.height).toBeLessThanOrEqual(box!.y + box!.height);
  await page.getByRole("button", { name: "Replay send", exact: true }).click();
  const bubble = page.locator(flying);
  await stepToFlight(clock);
  const samples = await bubble.evaluate((element) => {
    const animations = element.getAnimations({ subtree: true });
    const primary = element.getAnimations()[0]!;
    for (const animation of animations) animation.pause();
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    svg.style.cssText = "position:fixed;width:0;height:0;visibility:hidden";
    svg.append(path);
    document.body.append(svg);
    const sample = (time: number) => {
      for (const animation of animations) animation.currentTime = time;
      const style = getComputedStyle(element);
      // Measure the first closed subpath: the bubble body. The separate
      // tail extends below it and is not part of the composer's height.
      const outline = style.clipPath.match(/^path\("([^"]+)"\)$/)?.[1];
      const body = outline?.match(/^[^zZ]*[zZ]/)?.[0];
      if (!body) throw new Error(`Expected a closed bubble path: ${style.clipPath}`);
      path.setAttribute("d", body);
      const bounds = path.getBBox();
      const transform = new DOMMatrixReadOnly(style.transform);
      return {
        width: bounds.width * transform.a,
        height: bounds.height * transform.d,
        x: transform.m41,
        y: transform.m42,
      };
    };
    const frames = [0, 150, 450, 850].map(sample);
    svg.remove();
    for (const animation of animations) {
      animation.currentTime = Number(primary.effect!.getTiming().duration) - 20;
      animation.play();
    }
    return frames;
  });
  const [start, width, height, position] = samples;
  expect(Math.abs(start!.width - source!.width)).toBeLessThan(1);
  expect(Math.abs(start!.height - source!.height)).toBeLessThan(1);
  expect(start!.width - width!.width).toBeGreaterThan(5);
  expect(Math.abs(width!.height - start!.height)).toBeLessThan(0.5);
  expect(Math.abs(width!.y - start!.y)).toBeLessThan(0.5);
  expect(Math.abs(height!.height - start!.height)).toBeGreaterThan(3);
  expect(Math.abs(height!.y - start!.y)).toBeLessThan(0.5);
  expect(Math.abs(position!.y - start!.y)).toBeGreaterThan(5);
  await clock.advanceFrames(3);
  await expect(bubble).toHaveCount(0);
  await expect(page.locator(".comma-chat-user-bubble")).toHaveCount(1);
});
