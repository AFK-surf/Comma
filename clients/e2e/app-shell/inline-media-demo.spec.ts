import { expect, test, type Page } from "@playwright/test";
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

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/inline-media-demo");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.use({
  video: { mode: "on", size: { width: 900, height: 720 } },
  viewport: { width: 900, height: 720 },
});

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/inline-media-demo-e2e"),
    configFile: false,
    define: { "process.env.NODE_ENV": JSON.stringify("test") },
    plugins: [react(), tailwindcss({ optimize: false }), localGroupSelectors()],
    resolve: {
      alias: {
        "@comma/app/styles.css": resolve(clientsRoot, "packages/app/src/styles.css"),
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src/index.ts"),
      },
    },
    root: fixtureRoot,
    server: { hmr: false, host: "127.0.0.1", port: 0 },
  });
  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Inline media fixture did not expose a TCP port.");
  }
  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

test("only agent inline media follows the small-radius token and retains a border", async ({
  page,
}) => {
  await page.goto(`${fixtureUrl}?sharedControls`);
  const inlineSurfaces = page.locator(
    ".comma-chat-inline-image, .comma-chat-inline-image .chat-panel-image-preview-trigger, .comma-chat-inline-video, .comma-chat-inline-video .chat-panel-video-stage"
  );
  await expect(inlineSurfaces).toHaveCount(6);
  const radius = await page.evaluate(() =>
    getComputedStyle(document.documentElement).getPropertyValue("--radius-xxs").trim()
  );
  for (const surface of await inlineSurfaces.all()) {
    await expect(surface).toHaveCSS("border-radius", radius);
  }
  const borders = await page
    .locator(".comma-chat-inline-image, .comma-chat-inline-video")
    .evaluateAll((elements) =>
      elements.map((element) => {
        const style = getComputedStyle(element);
        return {
          width: Number.parseFloat(style.borderTopWidth),
          style: style.borderTopStyle,
          color: style.borderTopColor,
        };
      })
    );
  for (const border of borders) {
    expect(border.width).toBeGreaterThan(0);
    expect(border.style).toBe("solid");
    expect(border.color).not.toBe("rgba(0, 0, 0, 0)");
  }

  const sharedSurfaces = page
    .getByTestId("shared-media-controls")
    .locator(
      ".chat-panel-image, .chat-panel-image-preview-trigger, .chat-panel-video, .chat-panel-video-stage"
    );
  const sharedRadii = await sharedSurfaces.evaluateAll((elements) =>
    elements.map((element) => getComputedStyle(element).borderRadius)
  );
  // Changing the token must affect the Agent frames, not their shared counterparts.
  await page.evaluate(() => {
    document.documentElement.style.setProperty("--radius-xxs", "7px");
  });
  for (const surface of await inlineSurfaces.all()) {
    await expect(surface).toHaveCSS("border-radius", "7px");
  }
  expect(
    await sharedSurfaces.evaluateAll((elements) =>
      elements.map((element) => getComputedStyle(element).borderRadius)
    )
  ).toEqual(sharedRadii);
});

/**
 * The frame and the picture it holds, rounded, plus how far the picture escapes
 * the frame. A negative escape means the frame's `overflow: hidden` is cutting
 * the picture away.
 */
const measureImages = async (page: Page, bubbleWidth: number) => {
  await page.goto(`${fixtureUrl}?bubbleWidth=${bubbleWidth}`);
  await page.locator(".comma-chat-inline-image").first().waitFor();
  await page.waitForTimeout(300);
  return page.evaluate(() =>
    Array.from(document.querySelectorAll(".comma-chat-inline-image")).map((frame) => {
      const picture = frame.querySelector(".chat-panel-image-content")!;
      const frameRect = frame.getBoundingClientRect();
      const pictureRect = picture.getBoundingClientRect();
      return {
        coveredHeight: Math.round(pictureRect.height - frameRect.height),
        coveredWidth: Math.round(pictureRect.width - frameRect.width),
        frame: {
          height: Math.round(frameRect.height),
          width: Math.round(frameRect.width),
        },
        picture: {
          height: Math.round(pictureRect.height),
          width: Math.round(pictureRect.width),
        },
      };
    })
  );
};

test("keeps an agent's media inside the bounded frame without cropping", async ({
  page,
}) => {
  for (const bubbleWidth of [640, 240]) {
    const measured = await measureImages(page, bubbleWidth);
    console.log(`MEASURED_IMAGES_${bubbleWidth}`, JSON.stringify(measured));
    const videoFrame = await page
      .locator(".comma-chat-inline-video")
      .first()
      .boundingBox();
    console.log(`MEASURED_VIDEO_${bubbleWidth}`, JSON.stringify(videoFrame));

    const [panorama, poster] = measured;
    for (const item of measured) {
      // The frame is only a clipped viewport: anything that escapes it is cut.
      expect(item.coveredWidth).toBeLessThanOrEqual(1);
      expect(item.coveredHeight).toBeLessThanOrEqual(1);
      expect(item.frame.width).toBeLessThanOrEqual(bubbleWidth + 1);
    }
    // Both pictures stay inside 480x384 and keep the ratio they were made at.
    expect(panorama!.picture.width).toBeLessThanOrEqual(481);
    expect(panorama!.picture.height).toBeLessThanOrEqual(385);
    expect(panorama!.picture.width / panorama!.picture.height).toBeCloseTo(6, 1);
    expect(poster!.picture.width).toBeLessThanOrEqual(481);
    expect(poster!.picture.height).toBeLessThanOrEqual(385);
    expect(poster!.picture.width / poster!.picture.height).toBeCloseTo(0.25, 1);
    // The video frame obeys the same bounds.
    expect(videoFrame!.width).toBeLessThanOrEqual(481);
    expect(videoFrame!.height).toBeLessThanOrEqual(385);
    expect(videoFrame!.width).toBeLessThanOrEqual(bubbleWidth + 1);
  }

  const video = page.video();
  await page
    .locator("video")
    .first()
    .evaluate((node) => {
      const element = node as HTMLVideoElement;
      element.muted = true;
      return element.play();
    });
  await page.waitForTimeout(8000);
  await page.close();
  console.log("VIDEO_PATH", await video?.path());
});
