import { sharedBuildDir } from "../../../e2e/helpers/shared-build";
import { expect, test as baseTest, type Page } from "@playwright/test";
import { realpath, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { build, preview as createPreviewServer } from "vite";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ChatMessage } from "@comma/core/chat";

// An opt-in local experiment: repeated sends profiled on real time, with and
// without a native window recording (COMMA_PROFILE_SEND=1). The send's
// behaviour is e2e/app-shell/response-handoff.chromium.test.ts.
// Compile the real renderer fixture once per run; each worker serves that
// build. Each test still gets an isolated browser context, but does not reload
// a development module graph.
const test = baseTest.extend<{}, { handoffBaseURL: string }>({
  handoffBaseURL: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const webRoot = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const fixture = fileURLToPath(
        new URL(
          "../../../e2e/app-shell/fixtures/response-handoff/src/main.tsx",
          import.meta.url
        )
      );
      // macOS /var is a symlink. Match Vite's resolved module paths when it
      // derives output names relative to the fixture root.
      const scratch = await realpath(
        await sharedBuildDir("response-handoff", async (directory) => {
          const root = await realpath(directory);
          const entry = join(root, "index.html");
          await writeFile(
            entry,
            `<!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0"><div id="root"></div><script type="module" src="/@fs${fixture}"></script></body></html>`
          );
          const previousCwd = process.cwd();
          try {
            // The web config resolves workspace aliases from the web app directory.
            process.chdir(webRoot);
            await build({
              root,
              configFile: join(webRoot, "vite.config.ts"),
              configLoader: "runner",
              logLevel: "warn",
              build: {
                outDir: join(root, "dist"),
                emptyOutDir: true,
                rolldownOptions: { input: entry },
              },
            });
          } finally {
            process.chdir(previousCwd);
          }
        })
      );
      const server = await createPreviewServer({
        root: scratch,
        configFile: false,
        build: { outDir: join(scratch, "dist") },
        preview: { host: "127.0.0.1", port: 0 },
        logLevel: "warn",
      });
      try {
        const baseURL = server.resolvedUrls?.local[0];
        if (!baseURL) throw new Error("Compiled handoff fixture did not expose a URL");
        await use(baseURL);
      } finally {
        await server.close();
      }
    },
    { scope: "worker" },
  ],
});

if (process.env.COMMA_PROFILE_SEND === "1") test.use({ video: "off", trace: "off" });
test.describe("outgoing motion performance", () => {
  test.skip(
    process.env.COMMA_PROFILE_SEND !== "1",
    "Opt-in local performance experiment"
  );
  test("profiles repeated sends with and without native window recording", async ({
    page,
    handoffBaseURL,
  }, info) => {
    await openSurface(page, handoffBaseURL);
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.evaluate(() => {
      document.title = "Comma send performance";
    });
    const history = Array.from({ length: 24 }, (_, index) => ({
      ...message(
        `history-${index}`,
        index % 2 ? "assistant" : "user",
        index % 2
          ? "### Result\n\n" +
              "A paragraph with **formatted text**, `inline code`, and a link.\n\n".repeat(
                18
              )
          : "Summarize the next result."
      ),
      ...(index % 2 ? { replyToMessageId: `history-${index - 1}` } : {}),
    }));
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    const traceEvents: unknown[] = [];
    cdp.on("Tracing.dataCollected", ({ value }) => traceEvents.push(...value));
    await cdp.send("Tracing.start", {
      categories:
        "devtools.timeline,blink.user_timing,disabled-by-default-devtools.timeline",
      transferMode: "ReportEvents",
    });
    const cli = process.env.COMMA_PROFILE_RECORDER;
    const run = promisify(execFile);
    const recordingPath = info.outputPath("native-recording.cam");
    const results: unknown[] = [];
    let recording = false;
    try {
      for (const phase of cli
        ? ["warmup", "baseline", "recording"]
        : ["warmup", "baseline"]) {
        if (phase === "recording") {
          await page.bringToFront();
          await page.evaluate(() => {
            document.title = "Comma send performance";
          });
          const status = JSON.parse(
            (await run(cli!, ["recording", "status", "--no-interaction"])).stdout
          );
          expect(status.output.recordingStatus.state).toBe("idle");
          const targets = JSON.parse(
            (
              await run(cli!, [
                "recording",
                "targets",
                "--target-kind",
                "window",
                "--no-interaction",
              ])
            ).stdout
          );
          const target = targets.output.recordingTargets.find(
            (value: { windowTitle?: string }) =>
              value.windowTitle?.includes("Comma send performance")
          );
          expect(target, "headed test window is available to ScreenCam").toBeTruthy();
          await run(cli!, [
            "recording",
            "start",
            "--target-id",
            target.id,
            "--output",
            recordingPath,
            "--no-system-audio",
            "--no-microphone",
            "--no-camera",
            "--no-keyboard",
            "--no-interaction",
          ]);
          recording = true;
          await page.waitForTimeout(700);
        }
        for (
          let sample = 0;
          sample <
          (phase === "warmup" ? 1 : Number(process.env.COMMA_PROFILE_SAMPLES ?? 5));
          sample++
        ) {
          await show(page, { messages: history });
          const composer = page.locator(".comma-chat-composer");
          await composer
            .getByRole("textbox")
            .fill(
              "记录一下这个发送动画：气泡和文字同时缩小，最终位置平滑展开。".repeat(5)
            );
          await page.waitForTimeout(250);
          const before = (await cdp.send("Performance.getMetrics")).metrics;
          const probe = await page.evaluateHandle(() => {
            const times: number[] = [];
            const tasks: number[] = [];
            let first = 0;
            let frame = 0;
            const started = performance.now();
            performance.mark("send-profile-start");
            const observer = new PerformanceObserver((list) =>
              tasks.push(...list.getEntries().map((entry) => entry.duration))
            );
            observer.observe({ type: "longtask" });
            const captureFrame = (time: number) => {
              if (document.querySelector('[data-outgoing-presentation="flying"]')) {
                first ||= performance.now();
                times.push(time);
              }
              frame = requestAnimationFrame(captureFrame);
            };
            frame = requestAnimationFrame(captureFrame);
            return {
              finish() {
                cancelAnimationFrame(frame);
                observer.disconnect();
                performance.mark("send-profile-end");
                return { times, tasks, startLatency: first - started };
              },
            };
          });
          await composer.getByRole("button", { name: /Send/ }).click();
          await page.waitForTimeout(1300);
          const frames = await probe.evaluate((value) => value.finish());
          const after = (await cdp.send("Performance.getMetrics")).metrics;
          const metrics = Object.fromEntries(
            after
              .filter(({ name }) =>
                [
                  "LayoutCount",
                  "RecalcStyleCount",
                  "LayoutDuration",
                  "RecalcStyleDuration",
                  "ScriptDuration",
                  "TaskDuration",
                ].includes(name)
              )
              .map(({ name, value }) => [
                name,
                value - (before.find((metric) => metric.name === name)?.value ?? 0),
              ])
          );
          const gaps = frames.times
            .slice(1)
            .map((value, index) => value - frames.times[index]!);
          const result = {
            phase,
            sample,
            startLatency: frames.startLatency,
            frames: frames.times.length,
            over25ms: gaps.filter((value) => value > 25).length,
            maxGap: Math.max(...gaps),
            longTasks: frames.tasks,
            metrics,
          };
          results.push(result);
          console.log(JSON.stringify(result));
        }
      }
    } finally {
      if (recording) await run(cli!, ["recording", "stop", "--no-interaction"]);
      const complete = new Promise<void>((resolve) =>
        cdp.once("Tracing.tracingComplete", () => resolve())
      );
      await cdp.send("Tracing.end");
      await complete;
      await writeFile(info.outputPath("profile.json"), JSON.stringify(results));
      await writeFile(
        info.outputPath("chrome-trace.json"),
        JSON.stringify({ traceEvents })
      );
      await info.attach("send-profile", {
        body: JSON.stringify(results),
        contentType: "application/json",
      });
      await info.attach("chrome-trace", {
        body: JSON.stringify({ traceEvents }),
        contentType: "application/json",
      });
    }
  });
});
async function openSurface(page: Page, handoffBaseURL: string) {
  await page.setViewportSize({ width: 800, height: 720 });
  await page.goto(new URL("/index.html", handoffBaseURL).href);
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          typeof (window as unknown as { setHandoffState?: unknown }).setHandoffState
      )
    )
    .toBe("function");
}
async function show(page: Page, state: Record<string, unknown>) {
  await page.evaluate(
    (serialized) =>
      (
        window as unknown as { setHandoffState: (next: unknown) => void }
      ).setHandoffState(JSON.parse(serialized)),
    JSON.stringify(state)
  );
}
function message(messageId: string, role: string, text: string): ChatMessage {
  return {
    messageId,
    role,
    text,
    parts: [{ kind: "markdown", text }],
    attachments: [],
    blocksKey: undefined,
    refs: [],
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    source: "server",
    status: "completed",
  };
}
