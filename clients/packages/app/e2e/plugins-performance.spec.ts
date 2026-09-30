import { expect, test as baseTest } from "@playwright/test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build, preview } from "vite";

const test = baseTest.extend<{}, { pluginsBaseURL: string }>({
  pluginsBaseURL: [
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const artifactDir = process.env.COMMA_PERF_ARTIFACT_DIR;
      const cacheDir = artifactDir
        ? resolve(artifactDir, "plugins-build")
        : await mkdtemp(join(tmpdir(), "comma-plugins-perf-"));
      const previousCwd = process.cwd();
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
              outDir: cacheDir,
              emptyOutDir: true,
              rollupOptions: {
                input: fileURLToPath(
                  new URL("./fixtures/plugins-performance.html", import.meta.url)
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
        if (!artifactDir) await rm(cacheDir, { recursive: true, force: true });
      }
    },
    { scope: "worker" },
  ],
});

const metric = (result: { metrics: { name: string; value: number }[] }, name: string) =>
  result.metrics.find((entry) => entry.name === name)?.value ?? 0;

for (const count of [50, 500, 2000]) {
  test(`Skills search retains category and keyboard behavior at ${count} rows @performance`, async ({
    page,
    pluginsBaseURL,
  }, testInfo) => {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    await cdp.send("Performance.enable");
    await page.goto(
      new URL(`/plugins-performance.html?count=${count}`, pluginsBaseURL).href
    );
    const search = page.getByRole("textbox", { name: "Search skills" });
    await expect(search).toBeVisible();
    await page.waitForFunction(() => window.pluginsMount !== undefined);
    const initialMount = await page.evaluate(() => window.pluginsMount!);
    const mountMetrics = await cdp.send("Performance.getMetrics");
    const firstSearchMs = await page.evaluate(async () => {
      const input = document.querySelector("input")!;
      const started = performance.now();
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(
        input,
        "Skill"
      );
      input.dispatchEvent(new Event("input", { bubbles: true }));
      await new Promise<void>((done) =>
        requestAnimationFrame(() => requestAnimationFrame(() => done()))
      );
      return performance.now() - started;
    });
    await expect(page.locator('[data-slot="plugin-list-item"]')).toHaveCount(count);
    const fullListDomNodes = await page.evaluate(
      () => document.querySelectorAll("*").length
    );
    const cpuProfile = process.env.COMMA_PERF_CPU_PROFILE === "1";
    if (cpuProfile) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.start");
    }
    const before = await cdp.send("Performance.getMetrics");
    const samples = await page.evaluate(async () => {
      const input = document.querySelector("input")!;
      const setter = Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        "value"
      )!.set!;
      const values: number[] = [];
      for (let index = 0; index < 20; index++) {
        const queries = [
          "S",
          "Sk",
          "Ski",
          "Skil",
          "Skill",
          "Skil",
          "Ski",
          "Sk",
          "S",
          "Sk",
        ];
        const value = queries[index % queries.length]!;
        const started = performance.now();
        setter.call(input, value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
        await new Promise<void>((done) =>
          requestAnimationFrame(() => requestAnimationFrame(() => done()))
        );
        if (input.value !== value) throw new Error("Search did not commit");
        values.push(performance.now() - started);
      }
      return values;
    });
    const after = await cdp.send("Performance.getMetrics");
    const profile = cpuProfile ? await cdp.send("Profiler.stop") : undefined;
    const sorted = samples.slice(4).toSorted((a, b) => a - b);
    const result = {
      rows: count,
      cpuThrottle: 4,
      cpuProfile,
      initialMount,
      mountScriptMs: metric(mountMetrics, "ScriptDuration") * 1000,
      mountLayoutMs: metric(mountMetrics, "LayoutDuration") * 1000,
      firstSearchMs,
      fullListDomNodes,
      samples,
      medianMs: sorted[Math.floor(sorted.length / 2)],
      p95Ms: sorted[Math.floor(sorted.length * 0.95)],
      scriptMs:
        (metric(after, "ScriptDuration") - metric(before, "ScriptDuration")) * 1000,
      taskMs: (metric(after, "TaskDuration") - metric(before, "TaskDuration")) * 1000,
    };
    await testInfo.attach("skills-timing", {
      body: JSON.stringify(result, null, 2),
      contentType: "application/json",
    });
    const artifactDir = process.env.COMMA_PAGES_PERFORMANCE_OUTPUT;
    if (artifactDir) {
      await mkdir(resolve(artifactDir), { recursive: true });
      await writeFile(
        join(resolve(artifactDir), `skills-${count}.json`),
        JSON.stringify(result, null, 2)
      );
      if (profile)
        await writeFile(
          join(resolve(artifactDir), `skills-${count}.cpuprofile`),
          JSON.stringify(profile.profile)
        );
      await page.screenshot({
        path: join(resolve(artifactDir), `skills-${count}.png`),
      });
    }
    // Offscreen rows remain reachable by native focus and scrolling.
    const distant = page.locator(`[data-plugin-id="skill-${count - 1}"] button`);
    await distant.focus();
    await expect(distant).toBeInViewport();
    await page.keyboard.press("Enter");
    await expect(page.getByTestId("opened-skill")).toHaveText(
      `skill-${count - 1}:keyboard`
    );
    await search.fill(`Skill ${count - 1}`);
    await expect(page.locator('[data-slot="plugin-list-item"]')).toHaveCount(1);
    const last = page.locator(`[data-plugin-id="skill-${count - 1}"] button`);
    await last.focus();
    await page.keyboard.press("Enter");
    await expect(page.getByTestId("opened-skill")).toHaveText(
      `skill-${count - 1}:keyboard`
    );
    await search.clear();
    await page.getByRole("button", { name: "System", exact: true }).click();
    await expect(page.locator('[data-slot="plugin-list-item"]')).toHaveCount(count / 2);
    await search.fill("Skill 1");
    await expect(page.locator('[data-plugin-id="skill-1"]')).toHaveCount(1);
    await search.clear();
    await expect(page.locator('[data-plugin-id="skill-1"]')).toHaveCount(0);
  });
}
