import { expect, test, type Locator, type Page } from "@playwright/test";
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
const fixtureRoot = resolve(currentDir, "fixtures/notch-width");
const range = { min: 32, default: 156, max: 240 };

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/notch-width-e2e"),
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
    root: fixtureRoot,
    server: {
      hmr: false,
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Notch width fixture server did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

async function openFixture(page: Page) {
  await page.goto(fixtureUrl);
  const slider = page.getByRole("slider", { name: "Notch width" });
  await expect(slider).toHaveAttribute("aria-valuenow", String(range.default));
  // Settings opens with a short zoom; the field is measured once it has landed.
  await page.evaluate(() =>
    Promise.all(
      document
        .getAnimations()
        .filter((animation) => animation.effect?.getTiming().iterations !== Infinity)
        .map((animation) => animation.finished)
    )
  );
  return slider;
}

const box = async (locator: Locator) => {
  const rect = await locator.boundingBox();
  if (!rect) throw new Error("Expected a visible element.");
  return rect;
};

async function logoEdgeGlow(page: Page) {
  const mark = await box(page.locator(".comma-notch-width__mark"));
  const scale = await page.evaluate(() => window.devicePixelRatio);
  const clip = {
    x: Math.floor(mark.x) - 2,
    y: Math.floor(mark.y) - 2,
    width: Math.ceil(mark.width) + 4,
    height: Math.ceil(mark.height) + 4,
  };
  const png = (await page.screenshot({ clip })).toString("base64");
  return page.evaluate(
    async ({ band, data, left, top }) => {
      const picture = new Image();
      picture.src = `data:image/png;base64,${data}`;
      await picture.decode();
      const canvas = document.createElement("canvas");
      canvas.width = picture.width;
      canvas.height = picture.height;
      const context = canvas.getContext("2d")!;
      context.drawImage(picture, 0, 0);
      const pixels = context.getImageData(left, top, 2, band).data;
      return Math.max(...pixels.filter((_, index) => index % 4 !== 3));
    },
    {
      band: Math.floor(mark.height * scale * 0.15),
      data: png,
      left: Math.floor((mark.x - clip.x) * scale),
      top: Math.floor((mark.y - clip.y) * scale),
    }
  );
}

test.describe("on a Retina display", () => {
  test.use({ deviceScaleFactor: 2 });

  test("the zooming logo leaves no line at the preview's left edge", async ({
    page,
  }) => {
    const slider = await openFixture(page);
    // Where the mark lands on the pixel grid decides whether the line shows,
    // so the check runs at several widths.
    for (const keys of [
      [],
      ["End"],
      ["Home", ...Array<string>(16).fill("ArrowRight")],
    ]) {
      await slider.focus();
      for (const key of keys) await page.keyboard.press(key);
      let settled = -1;
      await expect
        .poll(async () => {
          const x = (await box(page.locator(".comma-notch-width__mark"))).x;
          const still = x === settled;
          settled = x;
          return still;
        })
        .toBe(true);
      // 0.7s in, the ring has zoomed past the logo's left edge and has not yet
      // begun to fade.
      await page.evaluate(() => {
        for (const animation of document.getAnimations()) {
          animation.pause();
          animation.currentTime = 700;
        }
      });
      expect(await logoEdgeGlow(page)).toBeLessThan(64);
      await page.evaluate(() => {
        for (const animation of document.getAnimations()) animation.play();
      });
    }
  });
});
