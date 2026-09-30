import { expect, test as baseTest } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "vite";
import { fileURLToPath } from "node:url";

// One source server per worker is necessary to exercise the real SideChat
// renderer, which is absent from the built web shell. It exposes no production
// test route, uses an ephemeral local port/cache, and is closed after this file.
const test = baseTest.extend<{}, { handoffBaseURL: string }>({
  handoffBaseURL: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const cacheDir = await mkdtemp(join(tmpdir(), "comma-handoff-vite-"));
      const previousCwd = process.cwd();
      let server: Awaited<ReturnType<typeof createServer>> | undefined;
      try {
        // The web app config resolves workspace source aliases from its own cwd.
        process.chdir(root);
        server = await createServer({
          root,
          configFile: join(root, "vite.config.ts"),
          cacheDir,
          server: {
            host: "127.0.0.1",
            port: 0,
            strictPort: false,
            hmr: false,
            watch: null,
          },
          optimizeDeps: { include: ["eventsource-parser", "shiki", "mermaid"] },
          logLevel: "error",
        });
        await server.listen();
      } finally {
        process.chdir(previousCwd);
      }
      try {
        await use(server.resolvedUrls!.local[0]!);
      } finally {
        await server.close();
        await rm(cacheDir, { recursive: true, force: true });
      }
    },
    { scope: "worker" },
  ],
});

test("task sidebar slides out separately and right-edge resizing tracks the pointer while keeping the pair centered", async ({
  page,
  handoffBaseURL,
}, info) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.route("**/floating-task-fixture", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<!doctype html><html><body style="margin:0"><div id="root"></div><script type="module">import RefreshRuntime from '/@react-refresh';RefreshRuntime.injectIntoGlobalHook(window);window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>t=>t;window.__vite_plugin_react_preamble_installed__=true;</script><script type="module" src="/@fs${encodeURI(fileURLToPath(new URL("./fixtures/task-floating-sidebar.tsx", import.meta.url)))}"></script></body></html>`,
    })
  );
  await page.goto(
    new URL(
      "/floating-task-fixture#/side-chat/test-window?workspaceId=wsp_1&groupId=grp_1&conversationId=cnv_parent&sourceHeight=30&sourceWidth=120&sourceX=40&sourceY=80",
      handoffBaseURL
    ).href
  );
  const chat = page.getByRole("dialog", { name: "Task chat" });
  const toggle = page.getByRole("button", { name: "Toggle chat sidebar" });
  await expect(toggle).toBeVisible();
  await expect.poll(async () => (await chat.boundingBox())?.width).toBe(560);
  const before = (await chat.boundingBox())!;
  await toggle.evaluate((button) => {
    button.addEventListener(
      "click",
      () => {
        const samples: Array<{ x: number; width: number; chatWidth: number }> = [];
        Object.assign(window, { floatingFrames: samples });
        const sample = () => {
          const panel = document.querySelector(".comma-side-chat-task-sidebar")!;
          const chatElement = document.querySelector("dialog")!;
          const rect = panel.getBoundingClientRect();
          samples.push({
            x: rect.x,
            width: rect.width,
            chatWidth: chatElement.getBoundingClientRect().width,
          });
          if (samples.length < 24) requestAnimationFrame(sample);
        };
        sample();
      },
      { capture: true, once: true }
    );
  });
  await toggle.click();
  const panel = page.locator(".comma-side-chat-task-sidebar");
  await expect(panel).toHaveCSS("opacity", "1");
  await expect
    .poll(async () =>
      Math.round(
        (await panel.boundingBox())!.x - ((await chat.boundingBox())!.x + before.width)
      )
    )
    .toBe(12);
  const frames = await page.evaluate(
    () =>
      (
        window as unknown as {
          floatingFrames: Array<{ x: number; width: number; chatWidth: number }>;
        }
      ).floatingFrames
  );
  expect(frames[0]!.x + frames[0]!.width / 2).toBe(720);
  expect(frames.every((frame) => frame.chatWidth === 560)).toBe(true);
  const destination = (await panel.boundingBox())!.x;
  expect(
    frames.filter((frame) => frame.x > frames[0]!.x + 1 && frame.x < destination - 1)
      .length
  ).toBeGreaterThanOrEqual(4);
  const opened = (await chat.boundingBox())!;
  expect(opened.width).toBe(before.width);
  expect(opened.height).toBe(before.height);
  const handle = page.getByRole("separator", { name: "Resize chat sidebar" });
  const box = (await handle.boundingBox())!;
  const panelBefore = (await panel.boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + 80);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2 + 100, box.y + 80, { steps: 10 });
  await page.evaluate(
    () =>
      new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve))
      )
  );
  const duringChat = (await chat.boundingBox())!;
  const duringPanel = (await panel.boundingBox())!;
  expect((duringChat.x + duringPanel.x + duringPanel.width) / 2).toBeCloseTo(720, 0);
  expect(duringPanel.x + duringPanel.width).toBeCloseTo(
    panelBefore.x + panelBefore.width + 100,
    0
  );
  await page.mouse.up();
  expect((await panel.boundingBox())!.width).toBeCloseTo(panelBefore.width + 200, 0);
  const resized = (await chat.boundingBox())!;
  const resizedPanel = (await panel.boundingBox())!;
  expect(resized.width).toBe(opened.width);
  expect(resized.height).toBe(opened.height);
  expect(resized.x).toBeCloseTo(opened.x - 100, 0);
  expect((resized.x + resizedPanel.x + resizedPanel.width) / 2).toBeCloseTo(720, 0);
  expect(resizedPanel.x + resizedPanel.width).toBeCloseTo(
    panelBefore.x + panelBefore.width + 100,
    0
  );
  expect(
    await page
      .locator(".comma-side-chat-test-window")
      .evaluate((el) => getComputedStyle(el, "::before").transform)
  ).toBe("none");
  await page.screenshot({ path: info.outputPath("floating-sidebar.png") });
  await toggle.click();
  await expect(panel).toHaveCSS("opacity", "0");
  await expect.poll(async () => (await chat.boundingBox())!.x).toBe(before.x);
  await toggle.click();
  await expect(panel).toHaveCSS("opacity", "1");
  expect((await chat.boundingBox())!.width).toBe(before.width);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.setViewportSize({ width: 900, height: 800 });
  await expect
    .poll(async () =>
      Math.round((await panel.boundingBox())!.x + (await panel.boundingBox())!.width)
    )
    .toBeLessThanOrEqual(876);
  expect((await chat.boundingBox())!.width).toBe(560);
  await toggle.click();
  await expect(panel).toHaveCSS("opacity", "0");
  await toggle.click();
  await expect(panel).toHaveCSS("opacity", "1");
});
