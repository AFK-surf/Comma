import { expect, test as baseTest } from "@playwright/test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { build, preview } from "vite";

const test = baseTest.extend<{}, { resizeBaseURL: string }>({
  resizeBaseURL: [
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const outDir = await mkdtemp(join(tmpdir(), "comma-resize-"));
      const previousCwd = process.cwd();
      let server: Awaited<ReturnType<typeof preview>>;
      try {
        process.chdir(root);
        const configFile = join(root, "vite.config.ts");
        await build({
          root: fileURLToPath(new URL("./fixtures/", import.meta.url)),
          configFile,
          logLevel: "error",
          build: {
            outDir,
            emptyOutDir: true,
            rolldownOptions: {
              input: fileURLToPath(
                new URL("./fixtures/viewport-resize.html", import.meta.url)
              ),
            },
          },
        });
        server = await preview({
          root,
          configFile,
          build: { outDir },
          preview: { host: "127.0.0.1", port: 0, strictPort: false },
        });
      } finally {
        process.chdir(previousCwd);
      }
      try {
        await use(new URL("viewport-resize.html", server.resolvedUrls!.local[0]!).href);
      } finally {
        await new Promise<void>((done) => server.httpServer.close(() => done()));
        await rm(outDir, { recursive: true, force: true });
      }
    },
    { scope: "worker" },
  ],
});

// Trace the renderer below; Playwright video/trace recording distorts resize work.
test.use({ trace: "off", video: "off" });

test("window breakpoints reuse retained transcript layouts", async ({
  page,
  resizeBaseURL,
}, testInfo) => {
  await page.setViewportSize({ width: 1920, height: 800 });
  await page.goto(resizeBaseURL);
  await expect(page.locator("main section")).toHaveCount(1500);
  await page.evaluate(() => document.fonts.ready);
  const settle = () =>
    page.evaluate(
      () =>
        new Promise<void>((done) =>
          requestAnimationFrame(() => requestAnimationFrame(() => done()))
        )
    );
  await settle();
  const cdp = await page.context().newCDPSession(page);
  type TraceEvent = {
    name: string;
    dur?: number;
    args?: { beginData?: { dirtyObjects: number; totalObjects: number } };
  };
  const events: TraceEvent[] = [];
  cdp.on("Tracing.dataCollected", ({ value }) =>
    events.push(...(value as unknown as TraceEvent[]))
  );
  await cdp.send("Tracing.start", {
    categories: "blink,devtools.timeline,disabled-by-default-devtools.timeline",
    transferMode: "ReportEvents",
  });
  // Cover all current breakpoints in both directions, including exact boundaries.
  // The wider sweep also catches newly introduced Tailwind viewport variants.
  const widths = [
    1920, 1600, 1535, 1280, 1279, 1100, 1024, 1023, 861, 860, 859, 769, 768, 767, 721,
    720, 719, 641, 640, 639, 601, 600, 599, 481, 480, 479, 385, 384, 383, 320,
  ];
  for (const width of [...widths, ...widths.toReversed()]) {
    await page.setViewportSize({ width, height: 800 });
    await settle();
  }
  const complete = new Promise<void>((done) =>
    cdp.once("Tracing.tracingComplete", () => done())
  );
  await cdp.send("Tracing.end");
  await complete;
  const layouts = events.filter(
    (event) => event.name === "Layout" && event.args?.beginData
  );
  const fullLayouts = layouts.filter((event) => {
    const { dirtyObjects, totalObjects } = event.args!.beginData!;
    return totalObjects > 1500 && dirtyObjects / totalObjects > 0.9;
  });
  const fontInvalidations = events.filter(
    (event) => event.name === "LayoutObject::InvalidateSubtreeForFontUpdates"
  );
  const resultPath = testInfo.outputPath("resize-layouts.json");
  await writeFile(resultPath, JSON.stringify({ layouts, fontInvalidations }, null, 2));
  await testInfo.attach("resize-layouts", {
    path: resultPath,
    contentType: "application/json",
  });
  expect(layouts.length).toBeGreaterThan(20);
  expect
    .soft(fullLayouts, "unchanged transcript paragraphs must retain their layouts")
    .toEqual([]);
  expect(
    fontInvalidations,
    "width breakpoints must not invalidate document fonts"
  ).toEqual([]);
});

test("responsive surfaces use window width through nested containers and portals", async ({
  page,
  resizeBaseURL,
}) => {
  await page.goto(`${resizeBaseURL}?surfaces`);
  for (const fontSize of ["small", "default", "large"]) {
    await page.evaluate((size) => {
      document.documentElement.dataset.commaFontSize = size;
    }, fontSize);
    for (const width of [
      1024, 1023, 861, 860, 721, 720, 641, 640, 601, 600, 599, 481, 480, 479, 384, 383,
    ]) {
      await page.setViewportSize({ width, height: 800 });
      await expect(page.getByTestId("settings")).toHaveCSS(
        "padding-top",
        width <= 720 ? "28px" : "48px"
      );
      await expect(page.locator(".comma-meeting-recorder")).toHaveCSS(
        "flex-wrap",
        width <= 480 ? "wrap" : "nowrap"
      );
      const listIndent = await page
        .getByTestId("markdown-list")
        .evaluate(
          (element) =>
            parseFloat(getComputedStyle(element).paddingLeft) /
            parseFloat(getComputedStyle(element).fontSize)
        );
      expect(listIndent).toBeCloseTo(width < 1024 ? 14 / 9 : 0, 3);
      await expect(page.locator(".html-preview-frame")).toHaveCSS(
        "height",
        width <= 640 ? "640px" : "560px"
      );
      await expect(page.locator(".comma-settings-sidebar")).toHaveCSS(
        "min-width",
        width <= 860 ? "196px" : "0px"
      );
    }
    await page.getByRole("button", { name: "Open search" }).click();
    for (const width of [481, 480, 479, 384, 383]) {
      await page.setViewportSize({ width, height: 800 });
      await expect(page.locator(".comma-command-palette-overlay")).toHaveCSS(
        "padding-top",
        width < 480 ? "8px" : "16px"
      );
      await expect(page.getByText("Yesterday", { exact: true })).toHaveCSS(
        "display",
        width < 384 ? "none" : "block"
      );
      await expect
        .poll(async () =>
          Math.round(
            (await page.locator(".comma-command-palette-modal").boundingBox())!.width
          )
        )
        .toBe(width - (width < 480 ? 16 : 32));
    }
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toHaveCount(0);
  }
  await page.getByRole("button", { name: "Show notification" }).click();
  const notification = page.getByText("Notification", { exact: true });
  await expect(notification).toBeVisible();
  for (const width of [601, 600, 599, 480, 360]) {
    await page.setViewportSize({ width, height: 800 });
    // Both Sonner's mobile row and Comma's card must end at the window inset.
    await expect
      .poll(async () => {
        const box = await page.getByTestId("notification").boundingBox();
        return box ? Math.round(width - box.x - box.width) : -1;
      })
      .toBe(24);
  }
});
