import { expect, test } from "@playwright/test";
import { resolve } from "node:path";

// Uses the actual Electron renderer build, but holds the application chunk so
// the first painted frame cannot accidentally depend on React/chat startup.
const rendererRoot = resolve("apps/electron/.vite/renderer/main_window");
const taskUrl =
  "http://comma-task-boot.test/#/side-chat/test-window?workspaceId=wsp_1&groupId=grp_1&conversationId=cnv_1&sourceHeight=30&sourceWidth=120&sourceX=40&sourceY=80";

for (const reducedMotion of ["no-preference", "reduce"] as const) {
  test(`task window paints before application loading completes (${reducedMotion})`, async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion });
    await page.addInitScript(() => {
      const frames: Array<{
        expanded?: string | undefined;
        x: number;
        y: number;
        width: number;
        height: number;
        opacity: string;
        backdropTransform: string;
        hostTransform: string;
      }> = [];
      Object.assign(window, { taskEntranceFrames: frames });
      function sample() {
        const root = document.getElementById("comma-task-window-boot");
        const shell = root?.querySelector(".comma-side-chat-test-shell");
        if (root && shell) {
          const rect = shell.getBoundingClientRect();
          frames.push({
            expanded: root.dataset.expanded,
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
            opacity: getComputedStyle(shell).opacity,
            backdropTransform: getComputedStyle(root, "::before").transform,
            hostTransform: getComputedStyle(root).transform,
          });
        }
        if (frames.length < 120) requestAnimationFrame(sample);
      }
      requestAnimationFrame(sample);
    });
    let releaseApplication!: () => void;
    const applicationBlocked = new Promise<void>((release) => {
      releaseApplication = release;
    });
    let applicationRequested = false;
    await page.route("http://comma-task-boot.test/**", async (route) => {
      const pathname = new URL(route.request().url()).pathname;
      if (/\/renderComma-[^/]+\.js$/.test(pathname)) {
        applicationRequested = true;
        await applicationBlocked;
        await route.abort();
        return;
      }
      await route.fulfill({
        path: resolve(rendererRoot, `.${pathname === "/" ? "/index.html" : pathname}`),
      });
    });
    try {
      await page.goto(taskUrl, { waitUntil: "domcontentloaded" });
      const shell = page.locator("#comma-task-window-boot .comma-side-chat-test-shell");
      await expect(shell).toBeVisible();
      await expect.poll(() => applicationRequested).toBe(true);
      await expect(page.locator("#root")).toBeEmpty();
      await expect(page.locator("#root")).toHaveCSS("visibility", "hidden");
      const frames = await page.evaluate(
        () =>
          (
            window as typeof window & {
              taskEntranceFrames: Array<{
                expanded?: string | undefined;
                x: number;
                y: number;
                width: number;
                height: number;
                opacity: string;
                backdropTransform: string;
                hostTransform: string;
              }>;
            }
          ).taskEntranceFrames
      );
      expect(frames[0]!.expanded).toBe("false");
      expect(frames[0]!.opacity).toBe("1");
      expect(
        frames.every(
          (frame) =>
            frame.backdropTransform === "none" && frame.hostTransform === "none"
        )
      ).toBe(true);
      if (reducedMotion === "reduce") {
        expect(frames.every((frame) => frame.width === 560)).toBe(true);
      } else {
        expect(frames[0]!.x).toBeCloseTo(40, 2);
        expect(frames[0]!.y).toBeCloseTo(80, 2);
        expect(frames[0]!.width).toBeCloseTo(120, 2);
        expect(frames[0]!.height).toBeCloseTo(30, 2);
        expect(
          frames.filter((frame) => frame.width > 120.1 && frame.width < 559.9).length
        ).toBeGreaterThanOrEqual(4);
        expect(frames.at(-1)!.width).toBeCloseTo(560, 0);
      }
    } finally {
      releaseApplication();
      await page.unrouteAll({ behavior: "wait" });
    }
  });
}
