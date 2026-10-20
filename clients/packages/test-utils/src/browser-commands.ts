import type { BrowserCommand } from "vitest/node";

// Real pointer, keyboard and media input for browser-project tests. They drive
// Playwright's page, so events are trusted and hit-tested like a user's. Test
// coordinates are in the test frame; the frame's offset and scale are applied.

type Mouse = {
  move(x: number, y: number, options?: { steps?: number }): Promise<void>;
  down(options?: { button?: "left" | "right" | "middle" }): Promise<void>;
  up(options?: { button?: "left" | "right" | "middle" }): Promise<void>;
  wheel(deltaX: number, deltaY: number): Promise<void>;
};
type Keyboard = {
  press(key: string, options?: { delay?: number }): Promise<void>;
  down(key: string): Promise<void>;
  up(key: string): Promise<void>;
  type(text: string, options?: { delay?: number }): Promise<void>;
  insertText(text: string): Promise<void>;
};
type Frame = {
  frameElement(): Promise<{
    boundingBox(): Promise<{
      x: number;
      y: number;
      width: number;
      height: number;
    } | null>;
    focus(): Promise<void>;
  }>;
  evaluate<T>(fn: () => T): Promise<T>;
};
type CdpSession = {
  on(event: string, listener: (payload: { value: unknown[] }) => void): void;
  once(event: string, listener: () => void): void;
  send(method: string, params?: Record<string, unknown>): Promise<unknown>;
};
type PlaywrightContext = {
  frame(): Promise<Frame>;
  page: {
    context(): {
      newCDPSession(page: unknown): Promise<CdpSession>;
      grantPermissions(permissions: string[]): Promise<void>;
      clearPermissions(): Promise<void>;
    };
    waitForEvent(
      event: "download"
    ): Promise<{ suggestedFilename(): string; url(): string }>;
    screenshot(options: {
      clip: { x: number; y: number; width: number; height: number };
    }): Promise<{ toString(encoding: "base64"): string }>;
    mouse: Mouse;
    keyboard: Keyboard;
    emulateMedia(options: Record<string, unknown>): Promise<void>;
    viewportSize(): { width: number; height: number } | null;
  };
};

const context = (value: unknown) => value as PlaywrightContext;

// One DevTools session per run. Trace events arrive between Tracing.start and
// Tracing.end and return with Tracing.end, since listeners cannot cross the
// command boundary.
let cdp: CdpSession | undefined;
let traceEvents: unknown[] = [];
let tracing = false;
let cdpPage: unknown;
let lastPointer: unknown;

async function cdpSend(
  ctx: PlaywrightContext,
  method: string,
  params?: Record<string, unknown>
) {
  if (cdpPage !== ctx.page) {
    // Tracing is browser-wide: a trace left on an earlier page's session
    // blocks every later Tracing.start.
    if (cdp && tracing) await endTrace(cdp).catch(() => {});
    cdpPage = ctx.page;
    cdp = await ctx.page.context().newCDPSession(ctx.page);
    cdp.on("Tracing.dataCollected", ({ value }) => traceEvents.push(...value));
  }
  const session = cdp;
  if (!session) throw new Error("No DevTools session");
  // A test that failed mid-trace leaves tracing running for the next one;
  // tracing only stops once Chromium reports the trace complete.
  if (method === "Tracing.start" && tracing) await endTrace(session);
  if (method === "Tracing.start") {
    traceEvents = [];
    const result = await session.send(method, params);
    tracing = true;
    return result;
  }
  if (method !== "Tracing.end") return session.send(method, params);
  await endTrace(session);
  // A trace is browser-wide and can hold tens of MB: only the events the test
  // names (`eventNames`) cross to the browser, where a message that large can
  // drop the test runner's connection.
  const names = params?.eventNames as string[] | undefined;
  if (!names) throw new Error("Tracing.end needs the eventNames the test reads.");
  const events = traceEvents.filter((event) =>
    names.includes((event as { name?: string }).name ?? "")
  );
  traceEvents = [];
  return { events };
}

async function endTrace(session: CdpSession) {
  const complete = new Promise<void>((resolve) =>
    session.once("Tracing.tracingComplete", () => resolve())
  );
  tracing = false;
  await session.send("Tracing.end");
  await complete;
}

async function toPage(ctx: PlaywrightContext, x: number, y: number) {
  const frame = await ctx.frame();
  const box = await (await frame.frameElement()).boundingBox();
  const width = await frame.evaluate(() => window.innerWidth);
  const scale = box && width ? box.width / width : 1;
  return { x: (box?.x ?? 0) + x * scale, y: (box?.y ?? 0) + y * scale };
}

export const browserCommands = {
  mouseMove: async (ctx, x: number, y: number, steps?: number) => {
    const point = await toPage(context(ctx), x, y);
    lastPointer = { frame: { x, y }, page: point };
    await context(ctx).page.mouse.move(point.x, point.y, { steps: steps ?? 1 });
  },
  // Moves the pointer onto the page outside the test frame, so nothing in
  // the frame stays hovered. Negative coordinates are not reliably delivered.
  // The caller may pass the frame's box, as its own page measures it, to skip
  // asking the browser.
  mouseLeaveFrame: async (
    ctx,
    known?: { x: number; y: number; width: number; height: number }
  ) => {
    const page = context(ctx).page;
    const box =
      known ??
      (await (await (await context(ctx).frame()).frameElement()).boundingBox());
    const viewport = page.viewportSize() ?? { width: 1920, height: 1200 };
    if (!box) return;
    const candidates = [
      { x: box.x - 5, y: box.y + 5 },
      { x: box.x + box.width + 5, y: box.y + 5 },
      { x: box.x + 5, y: box.y + box.height + 5 },
      { x: box.x + 5, y: box.y - 5 },
    ];
    const point = candidates.find(
      ({ x, y }) => x >= 0 && y >= 0 && x < viewport.width && y < viewport.height
    ) ?? { x: viewport.width - 1, y: viewport.height - 1 };
    lastPointer = { frame: "outside", page: point };
    await page.mouse.move(point.x, point.y);
  },
  // A page that just loaded has the focus: give it to the test frame, whose
  // document then may use the clipboard.
  focusFrame: async (ctx) => {
    const frame = await context(ctx).frame();
    await (await frame.frameElement()).focus();
  },
  // Where the pointer was last sent and where the test frame sits, for
  // assertion failures that depend on hover.
  pointerState: async (ctx) => {
    const frame = await context(ctx).frame();
    const box = await (await frame.frameElement()).boundingBox();
    const width = await frame.evaluate(() => window.innerWidth);
    return { pointer: lastPointer, frameBox: box, frameInnerWidth: width };
  },
  // A multiple click's presses carry their count, as Playwright's own click does.
  mouseDown: (ctx, button?: "left" | "right" | "middle", clickCount = 1) =>
    (context(ctx).page.mouse.down as (options: object) => Promise<void>)({
      button: button ?? "left",
      clickCount,
    }),
  mouseUp: (ctx, button?: "left" | "right" | "middle", clickCount = 1) =>
    (context(ctx).page.mouse.up as (options: object) => Promise<void>)({
      button: button ?? "left",
      clickCount,
    }),
  mouseWheel: (ctx, deltaX: number, deltaY: number) =>
    context(ctx).page.mouse.wheel(deltaX, deltaY),
  keyboardPress: (ctx, key: string, delay?: number) =>
    context(ctx).page.keyboard.press(key, delay === undefined ? {} : { delay }),
  keyboardDown: (ctx, key: string) => context(ctx).page.keyboard.down(key),
  keyboardUp: (ctx, key: string) => context(ctx).page.keyboard.up(key),
  keyboardType: (ctx, text: string, delay?: number) =>
    context(ctx).page.keyboard.type(text, delay === undefined ? {} : { delay }),
  keyboardInsertText: (ctx, text: string) =>
    context(ctx).page.keyboard.insertText(text),
  emulateMedia: (ctx, options: Record<string, unknown>) =>
    context(ctx).page.emulateMedia(options),
  cdpSend: (ctx, method: string, params?: Record<string, unknown>) =>
    cdpSend(context(ctx), method, params),
  // The determinism proof (determinism/manifest.txt): DETERMINISM_RECORD names
  // the JSONL file each test appends its execution record to, and
  // DETERMINISM_CPU_SLOWDOWN slows the page's CPU for a run.
  determinismSettings: async (ctx) => {
    const slowdown = Number(process.env.DETERMINISM_CPU_SLOWDOWN ?? 1);
    if (slowdown > 1)
      await cdpSend(context(ctx), "Emulation.setCPUThrottlingRate", { rate: slowdown });
    return {
      recording: Boolean(process.env.DETERMINISM_RECORD),
      events: Boolean(process.env.DETERMINISM_EVENTS),
      timing: Boolean(process.env.DETERMINISM_TIMING),
    };
  },
  // DETERMINISM_TIMING: where each browser component test's real time went,
  // one JSON line per test, appended to the file it names or, given "1",
  // printed.
  reportTiming: async (_ctx, line: string) => {
    const target = process.env.DETERMINISM_TIMING;
    if (!target) return;
    if (target === "1") {
      process.stdout.write(`TIMING ${line}\n`);
      return;
    }
    const { appendFile } = await import("node:fs/promises");
    await appendFile(target, `${line}\n`);
  },
  // DETERMINISM_EVENTS names a directory for each test's raw events, to find
  // the first event two runs differ in.
  appendDeterminismEvents: async (_ctx, name: string, text: string) => {
    const directory = process.env.DETERMINISM_EVENTS;
    if (!directory) return;
    const { appendFile, mkdir } = await import("node:fs/promises");
    await mkdir(directory, { recursive: true });
    await appendFile(`${directory}/${name}`, text);
  },
  appendDeterminismRecord: async (_ctx, line: string) => {
    const path = process.env.DETERMINISM_RECORD;
    // This module also loads in the browser, for its command types.
    if (path) await (await import("node:fs/promises")).appendFile(path, `${line}\n`);
  },
  clearPermissions: (ctx) => context(ctx).page.context().clearPermissions(),
  // The browser's own state a test's page must not inherit, set back in one
  // command: held keys and buttons, permissions, device emulation and media.
  resetBrowserState: async (
    ctx,
    { scale, media }: { scale: number | undefined; media: Record<string, unknown> }
  ) => {
    const { page } = context(ctx);
    for (const key of ["Shift", "Control", "Alt", "Meta", "Space"])
      await page.keyboard.up(key);
    for (const button of ["left", "middle", "right"] as const)
      await page.mouse.up({ button });
    await page.context().clearPermissions();
    await (scale
      ? cdpSend(context(ctx), "Emulation.setDeviceMetricsOverride", {
          width: 0,
          height: 0,
          deviceScaleFactor: scale,
          mobile: false,
        })
      : cdpSend(context(ctx), "Emulation.clearDeviceMetricsOverride"));
    await page.emulateMedia(media);
  },
  grantPermissions: (ctx, permissions: string[]) =>
    context(ctx).page.context().grantPermissions(permissions),

  screenshot: async (
    ctx,
    clip: { x: number; y: number; width: number; height: number }
  ) => {
    const origin = await toPage(context(ctx), clip.x, clip.y);
    const corner = await toPage(
      context(ctx),
      clip.x + clip.width,
      clip.y + clip.height
    );
    const image = await context(ctx).page.screenshot({
      clip: {
        x: origin.x,
        y: origin.y,
        width: corner.x - origin.x,
        height: corner.y - origin.y,
      },
    });
    return image.toString("base64");
  },
} satisfies Record<string, BrowserCommand<never[]>>;

type Button = "left" | "right" | "middle";

declare module "vitest/browser" {
  interface BrowserCommands {
    mouseMove: (x: number, y: number, steps?: number) => Promise<void>;
    /** `clickCount`: which press of a multiple click this is (2 for a double click's second). */
    mouseDown: (button?: Button, clickCount?: number) => Promise<void>;
    mouseUp: (button?: Button, clickCount?: number) => Promise<void>;
    mouseWheel: (deltaX: number, deltaY: number) => Promise<void>;
    keyboardPress: (key: string, delay?: number) => Promise<void>;
    keyboardDown: (key: string) => Promise<void>;
    keyboardUp: (key: string) => Promise<void>;
    keyboardType: (text: string, delay?: number) => Promise<void>;
    keyboardInsertText: (text: string) => Promise<void>;
    emulateMedia: (options: Record<string, unknown>) => Promise<void>;
    cdpSend: (method: string, params?: Record<string, unknown>) => Promise<unknown>;
    grantPermissions: (permissions: string[]) => Promise<void>;
    clearPermissions: () => Promise<void>;
    resetBrowserState: (state: {
      scale: number | undefined;
      media: Record<string, unknown>;
    }) => Promise<void>;
    determinismSettings: () => Promise<{
      recording: boolean;
      events: boolean;
      timing: boolean;
    }>;
    reportTiming: (line: string) => Promise<void>;
    appendDeterminismEvents: (name: string, text: string) => Promise<void>;
    appendDeterminismRecord: (line: string) => Promise<void>;
    pointerState: () => Promise<unknown>;
    mouseLeaveFrame: (box?: {
      x: number;
      y: number;
      width: number;
      height: number;
    }) => Promise<void>;
    focusFrame: () => Promise<void>;
    screenshot: (clip: {
      x: number;
      y: number;
      width: number;
      height: number;
    }) => Promise<string>;
  }
}
