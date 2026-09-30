import { expect, test as baseTest, type Locator } from "@playwright/test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build, preview } from "vite";

const test = baseTest.extend<{}, { themeBaseURL: string }>({
  themeBaseURL: [
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const cacheDir = await mkdtemp(join(tmpdir(), "comma-theme-perf-"));
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
            outDir: cacheDir,
            emptyOutDir: true,
            rollupOptions: {
              input: fileURLToPath(
                new URL("./fixtures/theme-studio-performance.html", import.meta.url)
              ),
            },
          },
        });
        server = await preview({
          root,
          configFile,
          build: { outDir: cacheDir },
          preview: { host: "127.0.0.1", port: 0, strictPort: false },
        });
      } finally {
        process.chdir(previousCwd);
      }
      try {
        await use(server.resolvedUrls!.local[0]!);
      } finally {
        await new Promise<void>((done) => server.httpServer.close(() => done()));
        await rm(cacheDir, { recursive: true, force: true });
      }
    },
    { scope: "worker" },
  ],
});

const countStyleMutations = (studio: Locator, duration: number) =>
  studio.evaluate(async (element, milliseconds) => {
    let count = 0;
    const observer = new MutationObserver((records) => {
      count += records.length;
    });
    observer.observe(element, {
      attributes: true,
      subtree: true,
      attributeFilter: ["style", "data-dragging"],
    });
    await new Promise<void>((done) => setTimeout(done, milliseconds));
    observer.disconnect();
    return count;
  }, duration);

for (const reducedMotion of ["no-preference", "reduce"] as const) {
  test(`Theme studio sleeps after settling with ${reducedMotion} @frame-budget`, async ({
    page,
    themeBaseURL,
  }, testInfo) => {
    test.setTimeout(90_000);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    await cdp.send("Performance.enable");
    await page.emulateMedia({ reducedMotion });
    await page.goto(new URL("/theme-studio-performance.html", themeBaseURL).href);
    const studio = page.locator('[data-slot="custom-theme-studio"]');
    await expect(studio).toBeVisible();
    await page.waitForTimeout(750);
    // Keep observer callbacks out of the CPU measurements.
    const mutations = await countStyleMutations(studio, 2000);
    const samples = [];
    for (let run = 0; run < 3; run++) {
      const before = await cdp.send("Performance.getMetrics");
      await page.waitForTimeout(2000);
      const after = await cdp.send("Performance.getMetrics");
      const delta = (name: string) =>
        ((after.metrics.find((entry) => entry.name === name)?.value ?? 0) -
          (before.metrics.find((entry) => entry.name === name)?.value ?? 0)) *
        1000;
      samples.push({
        run,
        scriptMs: delta("ScriptDuration"),
        taskMs: delta("TaskDuration"),
        styleMs: delta("RecalcStyleDuration"),
        layoutMs: delta("LayoutDuration"),
      });
    }
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.start");
    await page.waitForTimeout(2000);
    const { profile } = await cdp.send("Profiler.stop");
    const result = { reducedMotion, idleMs: 2000, mutations, samples };
    console.log("Theme idle", JSON.stringify(result));
    await testInfo.attach("theme-timing", {
      body: JSON.stringify(result, null, 2),
      contentType: "application/json",
    });
    await testInfo.attach("theme.cpuprofile", {
      body: JSON.stringify(profile),
      contentType: "application/json",
    });
    const artifactDir = process.env.COMMA_MOTION_REPORT_DIR;
    if (artifactDir) {
      await mkdir(resolve(artifactDir), { recursive: true });
      await writeFile(
        join(resolve(artifactDir), `theme-${reducedMotion}.json`),
        JSON.stringify(result, null, 2)
      );
      await writeFile(
        join(resolve(artifactDir), `theme-${reducedMotion}.cpuprofile`),
        JSON.stringify(profile)
      );
      await page.screenshot({
        path: join(resolve(artifactDir), `theme-${reducedMotion}.png`),
      });
    }
    const hue = studio.getByRole("slider", { name: "Hue", exact: true });
    const initial = await hue.getAttribute("aria-valuenow");
    const initialTransform = await hue.evaluate((element) => element.style.transform);
    await hue.focus();
    await page.keyboard.press("ArrowRight");
    await expect(hue).not.toHaveAttribute("aria-valuenow", initial!);
    await expect
      .poll(() => hue.evaluate((element) => element.style.transform))
      .not.toBe(initialTransform);
    const bounds = (await hue.boundingBox())!;
    await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
    await page.mouse.down();
    await expect(hue).toHaveAttribute("data-dragging", "true");
    await page.mouse.move(
      bounds.x + bounds.width / 2 + 30,
      bounds.y + bounds.height / 2 - 15,
      { steps: 5 }
    );
    await page.mouse.up();
    await expect(hue).not.toHaveAttribute("data-dragging", "true");
    await page.waitForTimeout(750);
    await expect.poll(() => countStyleMutations(studio, 300)).toBe(0);
    const afterDrag = await hue.getAttribute("aria-valuenow");
    await page.getByRole("button", { name: "Close studio", exact: true }).click();
    await expect(studio).toHaveCount(0);
    await page.getByRole("button", { name: "Open studio", exact: true }).click();
    await expect(studio).toBeVisible();
    await expect(hue).toHaveAttribute("aria-valuenow", afterDrag!);
    await page.emulateMedia({
      reducedMotion: reducedMotion === "reduce" ? "no-preference" : "reduce",
    });
    await hue.focus();
    const reopenedTransform = await hue.evaluate((element) => element.style.transform);
    await page.keyboard.press("ArrowLeft");
    await expect(hue).not.toHaveAttribute("aria-valuenow", afterDrag!);
    await expect
      .poll(() => hue.evaluate((element) => element.style.transform))
      .not.toBe(reopenedTransform);
    const canvas = studio.locator(".comma-custom-theme-studio__canvas");
    const oldCanvas = (await canvas.boundingBox())!;
    const oldTransform = await hue.evaluate((element) => element.style.transform);
    await page.setViewportSize({ width: 400, height: 800 });
    await expect
      .poll(async () => (await canvas.boundingBox())!.width)
      .toBeLessThan(oldCanvas.width);
    await expect
      .poll(() => hue.evaluate((element) => element.style.transform))
      .not.toBe(oldTransform);
    await expect.poll(() => countStyleMutations(studio, 300)).toBe(0);
    const newCanvas = (await canvas.boundingBox())!;
    const newHue = (await hue.boundingBox())!;
    expect(newHue.x + newHue.width / 2).toBeGreaterThan(newCanvas.x);
    expect(newHue.x + newHue.width / 2).toBeLessThan(newCanvas.x + newCanvas.width);
    await page.reload();
    await expect(studio).toBeVisible();
    await expect(hue).not.toHaveAttribute("aria-valuenow", initial!);
    expect(mutations).toBe(0);

    // The actual popover scales on entrance. Its visual scale must not become
    // the indicator's layout coordinate system when the pad goes to sleep.
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.emulateMedia({ reducedMotion });
    await page.goto(
      new URL("/theme-studio-performance.html?picker", themeBaseURL).href
    );
    await page.getByRole("button", { name: /Select theme/ }).click();
    await page.getByRole("option", { name: "Custom", exact: true }).click();
    await expect(page.locator("html")).toHaveAttribute("data-comma-theme", "custom");
    await expect(studio).toBeVisible();
    await page.waitForTimeout(750);
    await expect.poll(() => countStyleMutations(studio, 300)).toBe(0);
    const centerError = () =>
      hue.evaluate((element) => {
        const pad = element
          .closest('[data-slot="custom-theme-studio"]')!
          .querySelector(".comma-custom-theme-studio__canvas")!
          .getBoundingClientRect();
        const indicator = element.getBoundingClientRect();
        const value = Number.parseFloat(
          getComputedStyle(document.documentElement).getPropertyValue("--comma-theme-h")
        );
        return Math.abs(
          indicator.x + indicator.width / 2 - pad.x - (value / 360) * pad.width
        );
      });
    await expect.poll(centerError).toBeLessThan(0.1);
    const rootHue = () =>
      page.evaluate(() =>
        Number.parseFloat(
          getComputedStyle(document.documentElement).getPropertyValue("--comma-theme-h")
        )
      );
    const popupValue = await rootHue();
    const popupBounds = (await hue.boundingBox())!;
    const popupCanvas = (await canvas.boundingBox())!;
    await page.mouse.move(
      popupBounds.x + popupBounds.width / 2,
      popupBounds.y + popupBounds.height / 2
    );
    await page.mouse.down();
    await page.mouse.move(
      popupBounds.x + popupBounds.width / 2 + 10,
      popupBounds.y + popupBounds.height / 2,
      { steps: 5 }
    );
    await page.mouse.up();
    await expect
      .poll(async () =>
        Math.abs((await rootHue()) - popupValue - (10 / popupCanvas.width) * 360)
      )
      .toBeLessThan(0.1);
    await expect.poll(() => countStyleMutations(studio, 300)).toBe(0);
  });
}
