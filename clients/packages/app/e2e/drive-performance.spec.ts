import { expect, test as baseTest } from "@playwright/test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build, preview } from "vite";

const test = baseTest.extend<{}, { driveBaseURL: string }>({
  driveBaseURL: [
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const artifactDir = process.env.COMMA_PERF_ARTIFACT_DIR;
      const outDir = artifactDir
        ? resolve(artifactDir, "build")
        : await mkdtemp(join(tmpdir(), "comma-drive-performance-"));
      const cwd = process.cwd();
      let server: Awaited<ReturnType<typeof preview>>;
      try {
        process.chdir(root);
        const configFile = join(root, "vite.config.ts");
        if (process.env.COMMA_PERF_REUSE_BUILD !== "1")
          await build({
            root: fileURLToPath(new URL("./fixtures/", import.meta.url)),
            configFile,
            logLevel: "error",
            build: {
              outDir,
              emptyOutDir: true,
              rollupOptions: {
                input: fileURLToPath(
                  new URL("./fixtures/drive-performance.html", import.meta.url)
                ),
              },
            },
          });
        server = await preview({
          root,
          configFile,
          build: { outDir },
          preview: { host: "127.0.0.1", port: 0 },
        });
      } finally {
        process.chdir(cwd);
      }
      try {
        await use(server.resolvedUrls!.local[0]!);
      } finally {
        await new Promise<void>((done) => server.httpServer.close(() => done()));
        if (!artifactDir) await rm(outDir, { recursive: true, force: true });
      }
    },
    { scope: "worker" },
  ],
});

test.use({ actionTimeout: 10_000 });

for (const count of [200, 2000]) {
  test(`Drive directory ${count} files @frame-budget`, async ({
    page,
    driveBaseURL,
  }, testInfo) => {
    test.setTimeout(180_000);
    await page.goto(new URL("/drive-performance.html", driveBaseURL).href);
    await page.waitForFunction(() => Boolean(window.driveStress));
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    await cdp.send("Performance.enable");
    if (process.env.COMMA_PERF_CPU_PROFILE === "1") {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.start");
    }
    const before = await cdp.send("Performance.getMetrics");
    const metrics = await page.evaluate(async (fileCount) => {
      // The callback runs in the browser and cannot capture a Node helper.
      // eslint-disable-next-line unicorn/consistent-function-scoping
      const paint = () =>
        new Promise<void>((done) =>
          requestAnimationFrame(() => requestAnimationFrame(() => done()))
        );
      const time = async (action: () => void) => {
        const start = performance.now();
        action();
        await paint();
        return performance.now() - start;
      };
      const mountMs = await time(() => window.driveStress.load(fileCount));
      await paint();
      const initialThumbnailRequests = window.driveStress.thumbnails.length;
      const initialRows = document.querySelectorAll(
        '[data-testid^="drive-file-file-"]'
      ).length;
      const initialNodes = document.querySelectorAll("*").length;
      const selectionMs: number[] = [];
      const sortMs: number[] = [];
      for (let index = 0; index < 8; index++) {
        selectionMs.push(
          await time(() => {
            document
              .querySelector<HTMLInputElement>(
                '[data-testid="drive-file-file-0"] input'
              )!
              .click();
          })
        );
      }
      for (let index = 0; index < 6; index++) {
        sortMs.push(
          await time(() =>
            document
              .querySelector<HTMLElement>('[data-testid="drive-sort-name"]')!
              .click()
          )
        );
      }
      const viewport = document.querySelector<HTMLElement>(
        '[data-slot="scroll-area-viewport"]'
      )!;
      const scrollFrames: number[] = [];
      let previous = await new Promise<number>((done) => requestAnimationFrame(done));
      for (let index = 0; index < 40; index++) {
        viewport.scrollTop += 80;
        const now = await new Promise<number>((done) => requestAnimationFrame(done));
        scrollFrames.push(now - previous);
        previous = now;
      }
      viewport.scrollTop = 0;
      await paint();
      return {
        count: fileCount,
        mountMs,
        initialThumbnailRequests,
        initialRows,
        initialNodes,
        selectionMs,
        sortMs,
        scrollFrames,
      };
    }, count);
    const after = await cdp.send("Performance.getMetrics");
    const profile =
      process.env.COMMA_PERF_CPU_PROFILE === "1"
        ? (await cdp.send("Profiler.stop")).profile
        : undefined;
    const durations = Object.fromEntries(
      ["ScriptDuration", "LayoutDuration", "TaskDuration", "RecalcStyleDuration"].map(
        (key) => [
          key + "Ms",
          ((after.metrics.find((metric) => metric.name === key)?.value ?? 0) -
            (before.metrics.find((metric) => metric.name === key)?.value ?? 0)) *
            1000,
        ]
      )
    );
    const result = { ...metrics, ...durations };
    console.log(JSON.stringify(result));
    await testInfo.attach("metrics", {
      body: JSON.stringify(result, null, 2),
      contentType: "application/json",
    });
    if (process.env.COMMA_PERF_ARTIFACT_DIR) {
      const directory = resolve(process.env.COMMA_PERF_ARTIFACT_DIR);
      await mkdir(directory, { recursive: true });
      const name = `drive-${count}-${testInfo.repeatEachIndex}`;
      await writeFile(join(directory, `${name}.json`), JSON.stringify(result, null, 2));
      if (profile)
        await writeFile(join(directory, `${name}.cpuprofile`), JSON.stringify(profile));
      await page.screenshot({ path: join(directory, `${name}.png`) });
    }
    // Thumbnail requests and mounted rows must follow the viewport, not the directory.
    expect(metrics.initialThumbnailRequests).toBeLessThan(60);
    expect(metrics.initialRows).toBeLessThan(60);
    await page.getByTestId("drive-list-header").locator("label").click();
    await expect(page.getByTestId("selection-count")).toHaveText(String(count));
    await page.getByTestId("drive-list-header").locator("label").click();
    await expect(page.getByTestId("selection-count")).toHaveText("0");
    const viewport = page.locator('[data-slot="scroll-area-viewport"]');
    await viewport.evaluate((element) => {
      element.scrollTop = element.scrollHeight;
    });
    await page.getByTestId(`drive-file-file-${count - 1}`).click();
    await expect(page.getByTestId("opened-file")).toHaveText(`file-${count - 1}`);
  });
}

test("Drive window preserves keyboard traversal, menus and recording reveals", async ({
  page,
  driveBaseURL,
}) => {
  await page.goto(new URL("/drive-performance.html", driveBaseURL).href);
  await page.waitForFunction(() => Boolean(window.driveStress));
  await page.evaluate(() => window.driveStress.load(200));
  await page.getByTestId("drive-file-file-0").focus();
  for (let row = 1; row <= 30; row++) {
    for (let control = 0; control < 4; control++) await page.keyboard.press("Tab");
    await expect(page.getByTestId(`drive-file-file-${row}`)).toBeFocused();
  }
  await page.getByTestId("drive-file-file-30").click({ button: "right" });
  await expect(page.getByRole("menu")).toBeVisible();
  await page.locator('[data-slot="scroll-area-viewport"]').evaluate((element) => {
    element.scrollTop = element.scrollHeight;
  });
  await expect(page.getByRole("menu")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("drive-file-file-30")).toBeFocused();
  await page.evaluate(() => {
    document.documentElement.style.fontSize = "20px";
  });
  await page.evaluate(() => window.driveStress.reveal(199));
  const target = page.getByTestId("drive-file-file-199");
  await expect(target).toHaveAttribute("data-reveal-highlight", "true");
  await expect(target).toBeFocused();
  await expect(target).toBeInViewport();
  await expect(page.getByTestId("selection-count")).toHaveText("0");
  await expect(page.getByTestId("opened-file")).toHaveText("");
  const rectangles = await page
    .locator('[data-testid^="drive-file-file-"]')
    .evaluateAll((elements) =>
      elements
        .map((element) => element.getBoundingClientRect())
        .filter((rect) => rect.top >= 0 && rect.bottom <= innerHeight)
        .sort((left, right) => left.top - right.top)
    );
  expect(rectangles.length).toBeGreaterThan(1);
  expect(
    rectangles.every(
      (rect, index) => index === 0 || rect.top >= rectangles[index - 1]!.bottom
    )
  ).toBe(true);
});

test("Drive folder selection includes unloaded rows and nested files", async ({
  page,
  driveBaseURL,
}, testInfo) => {
  await page.goto(new URL("/drive-performance.html", driveBaseURL).href);
  await page.waitForFunction(() => Boolean(window.driveStress));
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
  await cdp.send("Performance.enable");
  const before = await cdp.send("Performance.getMetrics");
  const metrics = await page.evaluate(async () => {
    // The callback runs in the browser and cannot capture a Node helper.
    // eslint-disable-next-line unicorn/consistent-function-scoping
    const paint = () =>
      new Promise<void>((done) =>
        requestAnimationFrame(() => requestAnimationFrame(() => done()))
      );
    const mountStart = performance.now();
    window.driveStress.load(2000, true);
    await paint();
    const mountMs = performance.now() - mountStart;
    const mountedFolders = document.querySelectorAll(
      '[data-testid^="drive-folder-"]'
    ).length;
    const selectionMs: number[] = [];
    for (let index = 0; index < 8; index++) {
      const start = performance.now();
      document
        .querySelector<HTMLInputElement>('[data-testid="drive-folder-Folder 0"] input')!
        .click();
      await paint();
      selectionMs.push(performance.now() - start);
    }
    return { mountMs, mountedFolders, selectionMs, files: 2000, folders: 200 };
  });
  const after = await cdp.send("Performance.getMetrics");
  const result = {
    ...metrics,
    ...Object.fromEntries(
      ["ScriptDuration", "TaskDuration"].map((name) => [
        name + "Ms",
        ((after.metrics.find((value) => value.name === name)?.value ?? 0) -
          (before.metrics.find((value) => value.name === name)?.value ?? 0)) *
          1000,
      ])
    ),
  };
  await testInfo.attach("folder-metrics", {
    body: JSON.stringify(result, null, 2),
    contentType: "application/json",
  });
  if (process.env.COMMA_PERF_ARTIFACT_DIR) {
    await writeFile(
      join(
        resolve(process.env.COMMA_PERF_ARTIFACT_DIR),
        `drive-folders-${testInfo.repeatEachIndex}.json`
      ),
      JSON.stringify(result, null, 2)
    );
  }
  await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
  expect(metrics.mountedFolders).toBeLessThan(60);
  await page.getByTestId("drive-folder-Folder 0").locator("label").click();
  await expect(page.getByTestId("selection-count")).toHaveText("10");
  await page.getByTestId("drive-list-header").locator("label").click();
  await expect(page.getByTestId("selection-count")).toHaveText("2000");
  await page.getByTestId("drive-list-header").locator("label").click();
  await page.evaluate(() => window.driveStress.reveal(1999));
  await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("Nested");
  await expect(page.getByTestId("drive-file-file-1999")).toBeFocused();
  await expect(page.getByTestId("drive-file-file-1999")).toBeInViewport();
});
