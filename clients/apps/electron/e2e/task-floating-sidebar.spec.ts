import { _electron as electron, expect, test } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

// Playwright requires fixture parameters to use object destructuring.
// eslint-disable-next-line no-empty-pattern
test("real task sidebar keeps the pair centered and resizes without rebuilding observers", async ({}, info) => {
  test.setTimeout(120000);
  const web = createServer((_, res) => {
    res.setHeader("Content-Type", "text/html");
    res.end(
      '<body style="margin:0;background:#ff0000"><div>Native webpage</div></body>'
    );
  });
  await new Promise<void>((done) => web.listen(0, "127.0.0.1", done));
  const url = `http://127.0.0.1:${(web.address() as AddressInfo).port}/`;
  const api = await startChatSmokeStub({
    taskAssistantReply:
      `[Preview](${url})` +
      "\n\nA task with a long transcript.\n\n```js\nconst example = { width: 440, centered: true };\n```".repeat(
        40
      ),
  });
  const userData = await mkdtemp(join(tmpdir(), "comma-task-floating-"));
  const { ELECTRON_RUN_AS_NODE: _, ...env } = process.env;
  const app = await electron.launch({
    args: [resolve("apps/electron/.vite/build/main.js"), `--user-data-dir=${userData}`],
    cwd: resolve("apps/electron"),
    env: {
      ...env,
      NODE_ENV: "test",
      COMMA_API_BASE_URL: api.baseUrl,
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "task-floating@comma.local",
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "task-floating-token",
    },
  });
  try {
    const main = await findElectronWindowByNativeRole(app, "main-window");
    await main.getByRole("textbox", { name: "AI prompt" }).waitFor();
    await main.evaluate(
      async (target) => {
        await window.commaNative!.sideChat.openTestWindow({
          target,
          sourceFrame: { x: 100, y: 100, width: 120, height: 30 },
        });
      },
      {
        workspaceId: chatSmokeWorkspace.id,
        groupId: chatSmokeWorkspace.group_id,
        conversationId: chatSmokeTaskConversation.id,
      }
    );
    const task = await findElectronWindowByNativeRole(app, "side-chat-test-window");
    const toggle = task.getByRole("button", { name: "Toggle chat sidebar" });
    await toggle.click();
    const address = task.getByPlaceholder("Search or enter URL");
    await address.fill(url);
    await address.press("Enter");
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, targetUrl) =>
            webContents
              .getAllWebContents()
              .some((wc) => wc.getURL() === targetUrl && !wc.isLoading()),
          url
        )
      )
      .toBe(true);
    const panel = task.locator(".comma-side-chat-task-sidebar");
    await expect(panel).toHaveCSS("opacity", "1");
    const report = await task.evaluate(() => {
      const elements = [
        ".comma-side-chat-task-sidebar",
        ".comma-chat-sidebar",
        ".comma-chat-sidebar-surface",
        ".comma-chat-sidebar-panels",
        ".comma-chat-sidebar-browser",
        ".comma-chat-sidebar-browser-viewport",
      ];
      return elements.map((selector) => {
        const el = document.querySelector(selector)!;
        const css = getComputedStyle(el);
        return {
          selector,
          bounds: el.getBoundingClientRect().toJSON(),
          radius: css.borderRadius,
          overflow: css.overflow,
          background: css.backgroundColor,
        };
      });
    });
    await info.attach("layers.json", {
      body: JSON.stringify(report, null, 2),
      contentType: "application/json",
    });
    const before = (await panel.boundingBox())!;
    const handle = task.getByRole("separator", { name: "Resize chat sidebar" });
    const box = (await handle.boundingBox())!;
    await task.evaluate(() => {
      const bridge = window.commaNative!;
      let updates = 0;
      let observersCreated = 0;
      const OriginalObserver = window.ResizeObserver;
      window.ResizeObserver = class extends OriginalObserver {
        constructor(callback: ResizeObserverCallback) {
          super(callback);
          observersCreated++;
        }
      };
      const update = bridge.browserSidebar.update.bind(bridge.browserSidebar);
      window.commaNative = {
        ...bridge,
        browserSidebar: {
          ...bridge.browserSidebar,
          update: (input) => {
            updates++;
            return update(input);
          },
        },
      };
      const frames: number[] = [];
      let running = true;
      const sample = (time: number) => {
        frames.push(time);
        if (running) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
      Object.assign(window, {
        finishResizeSample: () => {
          running = false;
          return { updates, frames, observersCreated };
        },
      });
    });
    await task.mouse.move(box.x + 8, box.y + 100);
    await task.mouse.down();
    for (let step = 1; step <= 30; step++) {
      await task.mouse.move(box.x + 8 + step * 2, box.y + 100);
      await task.evaluate(() => new Promise(requestAnimationFrame));
    }
    await task.mouse.up();
    // End at the final gesture paint.
    await task.evaluate(() => new Promise(requestAnimationFrame));
    const samples = await task.evaluate(() =>
      (
        window as unknown as {
          finishResizeSample: () => {
            updates: number;
            frames: number[];
            observersCreated: number;
          };
        }
      ).finishResizeSample()
    );

    const after = (await panel.boundingBox())!;
    const chat = (await task.getByRole("dialog", { name: "Task chat" }).boundingBox())!;
    expect(after.width).toBeCloseTo(before.width + 120, 0);
    expect((chat.x + after.x + after.width) / 2).toBeCloseTo(
      (await task.evaluate(() => innerWidth)) / 2,
      0
    );
    await info.attach("resize.json", {
      body: JSON.stringify(samples),
      contentType: "application/json",
    });
    console.log("Resize metrics", {
      observersCreated: samples.observersCreated,
      updates: samples.updates,
      maxFrameGap: Math.max(
        ...samples.frames.slice(1).map((time, index) => time - samples.frames[index]!)
      ),
    });
    expect(samples.observersCreated).toBe(0);
    expect(samples.updates).toBeGreaterThan(0);
    expect(samples.updates).toBeLessThanOrEqual(samples.frames.length + 2);
    expect(
      Math.max(...samples.frames.slice(1).map((t, i) => t - samples.frames[i]!))
    ).toBeLessThan(80);
  } finally {
    await app.close();
    await api.close();
    await new Promise<void>((done) => web.close(() => done()));
    await rm(userData, { recursive: true, force: true });
  }
});
