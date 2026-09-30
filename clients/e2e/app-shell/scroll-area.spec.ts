import { expect, test, type Page } from "@playwright/test";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import { resolve } from "node:path";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../helpers/built-fixture";

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/scroll-area");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/scroll-area-e2e"),
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
    },
    plugins: [react(), tailwindcss({ optimize: false }), localGroupSelectors()],
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src/index.ts"),
      },
    },
    root: fixtureRoot,
    server: {
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Scroll area fixture server did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

test("scroll area uses overlay scrollbars without layout shift and a single edge effect", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.scrollAreaFixture));
  await expect(page.getByTestId("scroll-area")).toBeVisible();

  await expect
    .poll(() => getScrollAreaSnapshot(page).then((snapshot) => snapshot.hasOverflowY))
    .toBe("true");

  const beforeHover = await getScrollAreaSnapshot(page);

  expect(beforeHover.blurLayerCount).toBe(8);
  expect(beforeHover.edgeEffect).toBe("blur");
  expect(beforeHover.edgeBlur).toBe("true");
  expect(beforeHover.edgeMask).toBe("false");
  expect(beforeHover.edgeStartVisible).toBe("false");
  expect(beforeHover.edgeEndVisible).toBe("true");
  expect(beforeHover.edgeMaskStart).toBe("0px");
  expect(beforeHover.edgeMaskEnd).toBe("0px");
  expect(beforeHover.scrollbarOpacity).toBe("0");

  const verticalScrollbar = page.locator(
    '[data-slot="scroll-area-scrollbar"][data-axis="vertical"]'
  );
  await verticalScrollbar.hover();

  await expect(verticalScrollbar).toHaveCSS("opacity", "1");

  const afterHover = await getScrollAreaSnapshot(page);

  expect(afterHover.viewportClientWidth).toBe(beforeHover.viewportClientWidth);
  expect(afterHover.firstItemWidth).toBe(beforeHover.firstItemWidth);

  await page.evaluate(() => {
    window.scrollAreaFixture?.scrollTo(160);
  });

  await expect
    .poll(() =>
      getScrollAreaSnapshot(page).then((snapshot) => snapshot.edgeStartVisible)
    )
    .toBe("true");

  const middle = await getScrollAreaSnapshot(page);

  expect(middle.edgeStartVisible).toBe("true");
  expect(middle.edgeEndVisible).toBe("true");

  await page.evaluate(() => {
    const viewport = document.querySelector<HTMLElement>(
      "[data-slot='scroll-area-viewport']"
    );
    window.scrollAreaFixture?.scrollTo(
      (viewport?.scrollHeight ?? 0) - (viewport?.clientHeight ?? 0)
    );
  });

  await expect
    .poll(() => getScrollAreaSnapshot(page).then((snapshot) => snapshot.edgeEndVisible))
    .toBe("false");

  const bottom = await getScrollAreaSnapshot(page);

  expect(bottom.edgeStartVisible).toBe("true");
  expect(bottom.edgeEndVisible).toBe("false");
});

test("blur edge effect transitions the backdrop filter intensity", async ({ page }) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.scrollAreaFixture));

  await expect
    .poll(() => getScrollAreaSnapshot(page).then((snapshot) => snapshot.hasOverflowY))
    .toBe("true");

  await page.evaluate(() => {
    window.scrollAreaFixture?.scrollTo(0);
    window.scrollAreaFixture?.setEdgeEffect("none");
  });

  await expect
    .poll(() => getScrollAreaSnapshot(page).then((snapshot) => snapshot.edgeBlur))
    .toBe("false");

  await expect
    .poll(() =>
      getScrollAreaSnapshot(page).then((snapshot) =>
        parseBlurRadius(snapshot.endBlurFilter)
      )
    )
    .toBeLessThan(0.1);
  await expect
    .poll(() => getScrollAreaSnapshot(page).then((snapshot) => snapshot.endBlurSize))
    .toBeLessThan(1);

  // The first edge state settles before the component enables transitions.
  await expect(page.locator('[data-slot="scroll-area-edge-blur-end"]')).toHaveAttribute(
    "data-edge-transition",
    "true"
  );

  // Capture the real CSS transitions when React commits the mode change.
  // Sample their midpoint directly, independent of runner scheduling delays.
  const transitions = await page.evaluateHandle(() => {
    const root = document.querySelector('[data-slot="scroll-area"]')!;
    return new Promise<Animation[]>((resolveAnimations) => {
      const observer = new MutationObserver(() => {
        if (root.getAttribute("data-edge-blur") !== "true") return;
        observer.disconnect();
        const animations = root.getAnimations({ subtree: true }).filter((animation) => {
          const timing = animation.effect?.getTiming();
          return timing?.iterations !== Infinity && Number(timing?.duration) > 0;
        });
        for (const animation of animations) {
          animation.pause();
          animation.currentTime = Number(animation.effect!.getTiming().duration) / 2;
        }
        resolveAnimations(animations);
      });
      observer.observe(root, { attributes: true, attributeFilter: ["data-edge-blur"] });
      window.scrollAreaFixture?.setEdgeEffect("blur");
    });
  });

  const midTransition = await getScrollAreaSnapshot(page);
  const midBlurRadius = parseBlurRadius(midTransition.endBlurFilter);
  const midBlurSize = midTransition.endBlurSize;

  expect(midTransition.edgeBlur).toBe("true");
  expect(midBlurRadius, JSON.stringify(midTransition)).toBeGreaterThan(0.1);
  expect(midBlurRadius).toBeLessThan(13.9);
  expect(midBlurSize).toBeGreaterThan(1);
  expect(midBlurSize).toBeLessThan(55);
  await transitions.evaluate((animations) =>
    animations.forEach((animation) => animation.play())
  );
  await transitions.dispose();

  await expect
    .poll(() =>
      getScrollAreaSnapshot(page).then((snapshot) =>
        parseBlurRadius(snapshot.endBlurFilter)
      )
    )
    .toBeGreaterThan(13.9);
  await expect
    .poll(() => getScrollAreaSnapshot(page).then((snapshot) => snapshot.endBlurSize))
    .toBeGreaterThan(55);
});

test("edge mask transitions stay local to the viewport instead of invalidating message descendants", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.scrollAreaFixture));
  await page.evaluate(() => window.scrollAreaFixture?.setEdgeEffect("mask"));
  const viewportLocator = page.locator('[data-slot="scroll-area-viewport"]');
  await expect(viewportLocator).toHaveCSS("--scroll-area-edge-mask-end", "32px");
  await expect(viewportLocator).toHaveAttribute("data-edge-transition", "true");
  const samples = await page.evaluate(async () => {
    const viewport = document.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    )!;
    const child = viewport.querySelector<HTMLElement>(
      '[data-testid="scroll-area-item"]'
    )!;
    window.scrollAreaFixture?.scrollTo(160);
    const frames: { mask: number; inherited: number; image: string }[] = [];
    const start = performance.now();
    while (performance.now() - start < 650) {
      await new Promise(requestAnimationFrame);
      const style = getComputedStyle(viewport);
      frames.push({
        mask: parseFloat(style.getPropertyValue("--scroll-area-edge-mask-start")),
        inherited: parseFloat(
          getComputedStyle(child).getPropertyValue("--scroll-area-edge-mask-start")
        ),
        image: style.maskImage,
      });
    }
    return frames;
  });
  expect(samples.some(({ mask }) => mask > 0 && mask < 32)).toBe(true);
  expect(samples.at(-1)!.mask).toBe(32);
  expect(samples.every(({ inherited }) => inherited === 0)).toBe(true);
  expect(samples.every(({ image }) => image.includes("linear-gradient"))).toBe(true);
});

test("an area lands its first edge state with its content, then eases for the reader", async ({
  page,
}) => {
  // Listen before the app mounts. A computed-style read here would itself
  // resolve the registered 0px and start the transition under test.
  await page.addInitScript(() => {
    const runs: { area: string | undefined; property: string }[] = [];
    Object.assign(window, { edgeTransitionRuns: runs });
    document.addEventListener(
      "transitionrun",
      (event) => {
        const target = event.target;
        if (
          !(target instanceof HTMLElement) ||
          !/comma-scroll-area__(viewport|edge-blur)/.test(target.className)
        )
          return;
        runs.push({
          area: target.closest<HTMLElement>("[data-testid]")?.dataset.testid,
          property: event.propertyName,
        });
      },
      true
    );
  });
  await page.goto(`${fixtureUrl}?first-edge`);
  const runs = () =>
    page.evaluate(
      () =>
        (
          window as unknown as {
            edgeTransitionRuns: { area: string | undefined; property: string }[];
          }
        ).edgeTransitionRuns
    );

  const transcript = page
    .getByTestId("first-edge-transcript")
    .locator('[data-slot="scroll-area-viewport"]');
  await expect(transcript).toHaveAttribute("data-edge-transition", "true");
  await expect(transcript).toHaveCSS("--scroll-area-edge-mask-start", "32px");
  await expect(transcript).toHaveCSS("--scroll-area-edge-mask-end", "0px");
  const listEdge = page
    .getByTestId("first-edge-list")
    .locator('[data-slot="scroll-area-edge-blur-end"]');
  await expect(listEdge).toHaveAttribute("data-visible", "true");
  await expect(listEdge).toHaveAttribute("data-edge-transition", "true");
  expect(await runs()).toEqual([]);

  // A reader who leaves an edge still gets the eased fade.
  await transcript.hover();
  await page.mouse.wheel(0, -200);
  await expect.poll(runs).toContainEqual({
    area: "first-edge-transcript",
    property: "--scroll-area-edge-mask-end",
  });
});

/**
 * A reveal is one scrollbar fading in. Counted in restyled elements, which a
 * trace reports exactly, it must not grow with the areas nested inside: a
 * transcript holds one per code block and table, and reveals on every wheel.
 */
type TraceEvent = { name: string; args?: { elementCount?: number } };

test("revealing a scrollbar restyles its own area, not the areas nested inside", async ({
  page,
}) => {
  await page.goto(`${fixtureUrl}?nested`);
  const outer = page.getByTestId("nested-outer");
  const scrollbar = outer.locator(
    ':scope > [data-slot="scroll-area-scrollbar"][data-axis="vertical"]'
  );
  await expect(outer).toHaveAttribute("data-has-overflow-y", "true");
  await expect(outer.locator('[data-slot="scroll-area"]')).toHaveCount(60);
  await outer.hover();

  const cdp = await page.context().newCDPSession(page);
  const recalcs: number[] = [];
  cdp.on("Tracing.dataCollected", ({ value }) => {
    for (const event of value as unknown as TraceEvent[]) {
      if (event.name === "UpdateLayoutTree")
        recalcs.push(event.args?.elementCount ?? 0);
    }
  });
  await cdp.send("Tracing.start", {
    transferMode: "ReportEvents",
    traceConfig: { includedCategories: ["devtools.timeline"] },
  });
  await page.mouse.wheel(0, 80);
  await expect(scrollbar).toHaveCSS("opacity", "1");
  // The default hide delay, then the fade out.
  await expect(scrollbar).toHaveCSS("opacity", "0", { timeout: 3_000 });
  const traceComplete = new Promise<void>((done) =>
    cdp.once("Tracing.tracingComplete", () => done())
  );
  await cdp.send("Tracing.end");
  await traceComplete;

  expect(recalcs.length).toBeGreaterThan(0);
  expect(Math.max(...recalcs)).toBeLessThan(30);
});

/**
 * Wheel routing with real input. The browser scrolls every area itself; the
 * only wheel handled from script is an ordinary mouse's vertical wheel over a
 * horizontal area that has something to scroll sideways.
 */
test("a wheel over a nested horizontal area reaches the right scroller without waiting on script", async ({
  page,
}) => {
  await page.goto(`${fixtureUrl}?routing`);

  const viewportOf = (testId: string) =>
    page.getByTestId(testId).locator(':scope > [data-slot="scroll-area-viewport"]');
  const transcript = viewportOf("routing-transcript");
  const fits = viewportOf("routing-block-fits");
  const overflows = viewportOf("routing-block-overflows");
  await expect(page.getByTestId("routing-block-overflows")).toHaveAttribute(
    "data-has-overflow-x",
    "true"
  );
  // Whether the browser had to ask script before scrolling each wheel.
  await page.evaluate(() => {
    const seen: boolean[] = [];
    (window as unknown as { wheelCancelable: boolean[] }).wheelCancelable = seen;
    window.addEventListener("wheel", (event) => seen.push(event.cancelable), {
      passive: true,
    });
  });
  const wheelCancelable = () =>
    page.evaluate(() =>
      (window as unknown as { wheelCancelable: boolean[] }).wheelCancelable.splice(0)
    );
  const scrollTop = () => transcript.evaluate((element) => element.scrollTop);

  // Over a block that fits, a vertical wheel is the transcript's, and nothing
  // on the way could cancel it: the scroll never waits for the main thread.
  await fits.hover();
  await page.mouse.wheel(0, 30);
  await expect.poll(scrollTop).toBe(30);
  expect(await wheelCancelable()).toEqual([false]);

  // Over a block that overflows, the same wheel scrolls the block sideways...
  await overflows.hover();
  await page.mouse.wheel(0, 100);
  await expect
    .poll(() => overflows.evaluate((element) => element.scrollLeft))
    .toBe(100);
  expect(await scrollTop()).toBe(30);
  // ...and once the block is at its end, the wheel is the transcript's again.
  await overflows.evaluate((element) => {
    element.scrollLeft = element.scrollWidth;
  });
  await page.mouse.wheel(0, 40);
  await expect.poll(scrollTop).toBe(70);
});

test("a sideways wheel over a nested column reaches the horizontal board around it", async ({
  page,
}) => {
  await page.goto(`${fixtureUrl}?routing`);

  const viewportOf = (testId: string) =>
    page.getByTestId(testId).locator(':scope > [data-slot="scroll-area-viewport"]');
  const board = viewportOf("routing-board");
  const column = viewportOf("routing-column");
  await expect(page.getByTestId("routing-board")).toHaveAttribute(
    "data-has-overflow-x",
    "true"
  );

  await column.hover();
  await page.mouse.wheel(0, 120);
  await expect.poll(() => column.evaluate((element) => element.scrollTop)).toBe(120);
  // The column took the vertical wheel; the board did not read it as sideways.
  expect(await board.evaluate((element) => element.scrollLeft)).toBe(0);

  await page.mouse.wheel(80, 0);
  await expect.poll(() => board.evaluate((element) => element.scrollLeft)).toBe(80);
});

async function getScrollAreaSnapshot(page: Page) {
  return page.evaluate(() => {
    const snapshot = window.scrollAreaFixture?.getSnapshot();

    if (!snapshot) {
      throw new Error("Scroll area fixture is not ready.");
    }

    return snapshot;
  });
}

function parseBlurRadius(filter: string) {
  const match = /blur\(([-\d.]+)px\)/.exec(filter);

  return match ? Number(match[1]) : 0;
}

test("hover and message append keep style work local without changing pointer behavior", async ({
  page,
}, info) => {
  await page.goto(`${fixtureUrl}?invalidation`);
  const action = page.getByTestId("hover-action");
  await expect(action).toHaveCSS("opacity", "0");
  await expect(page.getByTestId("enabled-label")).toHaveCSS("cursor", "pointer");
  await expect(page.getByTestId("cursor-button").locator("span")).toHaveCSS(
    "cursor",
    "pointer"
  );
  await expect(page.getByTestId("disabled-label")).not.toHaveCSS("cursor", "pointer");
  await expect(page.getByTestId("disabled-parent").locator("span")).toHaveCSS(
    "cursor",
    "text"
  );
  await expect(page.locator("[data-comma-functional-cursor]")).toHaveCSS(
    "cursor",
    "col-resize"
  );

  const cdp = await page.context().newCDPSession(page);
  const counts: number[] = [];
  cdp.on("Tracing.dataCollected", ({ value }) => {
    for (const event of value as unknown as TraceEvent[]) {
      if (event.name === "UpdateLayoutTree") counts.push(event.args?.elementCount ?? 0);
    }
  });
  await cdp.send("Tracing.start", {
    transferMode: "ReportEvents",
    traceConfig: { includedCategories: ["devtools.timeline"] },
  });
  await page.getByTestId("hover-surface").hover();
  await expect(action).toHaveCSS("opacity", "1");
  await page.getByTestId("transcript").evaluate((article) => {
    const span = document.createElement("span");
    span.textContent = "New streamed text";
    article.append(span);
  });
  await page.evaluate(
    () =>
      new Promise<void>((done) =>
        requestAnimationFrame(() => requestAnimationFrame(() => done()))
      )
  );
  const completed = new Promise<void>((done) =>
    cdp.once("Tracing.tracingComplete", () => done())
  );
  await cdp.send("Tracing.end");
  await completed;
  expect(counts.length).toBeGreaterThan(0);
  await info.attach("restyled-elements", {
    body: JSON.stringify(counts),
    contentType: "application/json",
  });
  expect(Math.max(...counts)).toBeLessThan(100);

  await action.focus();
  await page.getByTestId("enabled-label").hover();
  await expect(action).toHaveCSS("opacity", "0.5");
  await page.getByTestId("hover-surface").hover();
  await expect(action).toHaveCSS("opacity", "1");
  await page.getByTestId("enabled-label").click();
  await expect(page.getByTestId("enabled-label").locator("input")).toBeChecked();
  await expect(action).toHaveCSS("opacity", "0");

  await page.evaluate(() => {
    document.documentElement.dataset.commaPointerCursors = "false";
  });
  await expect(page.getByTestId("enabled-label")).toHaveCSS("cursor", "default");
  await expect(page.getByTestId("cursor-button").locator("span")).toHaveCSS(
    "cursor",
    "default"
  );
  await expect(page.locator("[data-comma-functional-cursor]")).toHaveCSS(
    "cursor",
    "col-resize"
  );
});
