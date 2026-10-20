import { expect, test } from "@playwright/test";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import type { AddressInfo } from "node:net";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../helpers/built-fixture";

// Touch specs stay in Playwright: each test needs a fresh touch context, and
// on Linux turning touch emulation off again leaves a page without
// (hover: hover), which would break the hover specs in the Vitest browser project.
const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.use({ hasTouch: true, viewport: { height: 900, width: 1180 } });

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/chat-panel-media-e2e"),
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
    },
    plugins: [react(), tailwindcss({ optimize: false }), localGroupSelectors()],
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src"),
      },
    },
    root: resolve(currentDir, "fixtures/chat-panel-media"),
    server: { hmr: false, host: "127.0.0.1", port: 0 },
  });
  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Chat panel media fixture did not expose a TCP port.");
  }
  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

test("keeps every hover-only media control reachable by tap", async ({ page }) => {
  await page.goto(fixtureUrl);
  expect(await page.evaluate(() => matchMedia("(any-pointer: coarse)").matches)).toBe(
    true
  );

  const imageToolbar = page.locator(".chat-panel-image-toolbar");
  const videoPlayer = page
    .locator(".chat-panel-video-stage")
    .locator(":scope > .chat-panel-media-player");
  const audioSlider = page.getByRole("slider", {
    name: "Audio playback position",
  });
  await expect(imageToolbar).toHaveCSS("opacity", "1");
  await expect(imageToolbar).toHaveCSS("pointer-events", "auto");
  await expect(imageToolbar).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, 0)");
  await expect(videoPlayer).toHaveCSS("opacity", "1");
  await expect(videoPlayer).toHaveCSS("pointer-events", "auto");
  await expect(videoPlayer).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, 0)");
  await expect(audioSlider).toHaveCSS("--chat-panel-media-thumb-opacity", "1");

  await page.getByRole("button", { name: "Copy image" }).tap();
  await expect(page.getByRole("button", { name: "Image copied" })).toBeVisible();
  await page.getByRole("button", { name: "Preview generated image" }).tap();
  await expect(
    page.getByRole("dialog", { name: "Generated image preview" })
  ).toBeVisible();
});
