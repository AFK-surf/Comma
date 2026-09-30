import { expect, test as baseTest } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build, preview } from "vite";
import { fileURLToPath } from "node:url";
// Build the real chat surface in production mode; timings carry no network.
const test = baseTest.extend<{}, { mediaBaseURL: string }>({
  mediaBaseURL: [
    // Playwright requires fixture dependencies to use object destructuring.
    // eslint-disable-next-line no-empty-pattern
    async ({}, use) => {
      const root = fileURLToPath(new URL("../../../apps/web/", import.meta.url));
      const cacheDir = await mkdtemp(join(tmpdir(), "comma-media-retention-"));
      const previousCwd = process.cwd();
      let server: Awaited<ReturnType<typeof preview>> | undefined;
      try {
        // The web app config resolves workspace source aliases from its own cwd.
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
                new URL("./fixtures/media-retention.html", import.meta.url)
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
        await new Promise<void>((resolve) => server.httpServer.close(() => resolve()));
        await rm(cacheDir, { recursive: true, force: true });
      }
    },
    { scope: "worker" },
  ],
});

test("scrolling preserves loaded images and video nodes, geometry and playback position", async ({
  page,
  mediaBaseURL,
}) => {
  await page.addInitScript(() => {
    const revoked: string[] = [];
    Object.assign(window, { revokedMediaUrls: revoked });
    const revoke = URL.revokeObjectURL.bind(URL);
    URL.revokeObjectURL = (url) => {
      revoked.push(url);
      revoke(url);
    };
  });
  await page.goto(new URL("/media-retention.html", mediaBaseURL).href);
  const viewport = page.locator('[data-slot="scroll-area-viewport"]').first();
  await expect(viewport).toBeVisible();
  await viewport.evaluate((element) => {
    element.scrollTop = 0;
  });
  const image = page.getByRole("img", { name: "original.png", exact: true });
  await expect(image).toBeVisible();
  await expect
    .poll(() =>
      image.evaluate(
        (element: HTMLImageElement) => element.complete && element.naturalWidth > 0
      )
    )
    .toBe(true);
  const video = page.locator("video").first();
  await video.scrollIntoViewIfNeeded();
  await expect
    .poll(() => video.evaluate((element: HTMLVideoElement) => element.readyState))
    .toBeGreaterThan(0);
  await video.evaluate((element: HTMLVideoElement) => {
    element.pause();
    element.currentTime = Math.min(0.2, element.duration / 2);
  });
  await expect
    .poll(() => video.evaluate((element: HTMLVideoElement) => element.seeking))
    .toBe(false);
  const state = await page.evaluate(() => {
    const imageElement = document.querySelector('img[alt="original.png"]')!;
    const videoElement = document.querySelector("video")!;
    Object.assign(window, {
      retainedNodes: { image: imageElement, video: videoElement },
    });
    return {
      src: imageElement.getAttribute("src"),
      videoSrc: videoElement.currentSrc,
      currentTime: videoElement.currentTime,
      height: document.querySelector('[data-slot="scroll-area-viewport"]')!
        .scrollHeight,
    };
  });
  for (let visit = 0; visit < 3; visit += 1) {
    await viewport.evaluate((element) => {
      element.scrollTop = element.scrollHeight;
    });
    // Wait beyond both observer bands before returning.
    await page.waitForTimeout(200);
    await expect(page.locator("[data-comma-image-group-placeholder]")).toHaveCount(0);
    await expect(image).toHaveAttribute("src", state.src!);
    await viewport.evaluate((element) => {
      element.scrollTop = 0;
    });
    await expect(image).toBeVisible();
    const retained = await page.evaluate(() => {
      const refs = (
        window as unknown as {
          retainedNodes: { image: Element; video: HTMLVideoElement };
        }
      ).retainedNodes;
      return {
        image: refs.image === document.querySelector('img[alt="original.png"]'),
        video: refs.video === document.querySelector("video"),
        currentTime: refs.video.currentTime,
        height: document.querySelector('[data-slot="scroll-area-viewport"]')!
          .scrollHeight,
      };
    });
    expect(retained.image).toBe(true);
    expect(retained.video).toBe(true);
    expect(retained.currentTime).toBeCloseTo(state.currentTime, 2);
    expect(retained.height).toBe(state.height);
  }
  const metrics = await page.evaluate(
    () =>
      (window as unknown as { mediaRetention: { metrics: object } }).mediaRetention
        .metrics
  );
  expect(metrics).toEqual({ imageLoads: 1, imageReleases: 0, videoLoads: 1 });
  await page.evaluate(() =>
    (
      window as unknown as { mediaRetention: { unmount(): void } }
    ).mediaRetention.unmount()
  );
  await expect(image).toHaveCount(0);
  await expect(video).toHaveCount(0);
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as unknown as {
              mediaRetention: { metrics: { imageReleases: number } };
            }
          ).mediaRetention.metrics.imageReleases
      )
    )
    .toBe(1);
  await expect
    .poll(() =>
      page.evaluate(
        () => (window as unknown as { revokedMediaUrls: string[] }).revokedMediaUrls
      )
    )
    .toEqual(expect.arrayContaining([state.src, state.videoSrc]));
});

test("sixty sequentially viewed images remain available without repeat loads and release on departure", async ({
  page,
  mediaBaseURL,
}) => {
  test.setTimeout(180_000);
  await page.goto(new URL("/media-retention.html?images=60", mediaBaseURL).href);
  const viewport = page.locator('[data-slot="scroll-area-viewport"]').first();
  await viewport.hover();
  await page.mouse.wheel(0, -600);
  await expect
    .poll(() =>
      viewport.evaluate(
        (element) => element.scrollHeight - element.clientHeight - element.scrollTop
      )
    )
    .toBeGreaterThan(100);
  // Older messages are not mounted until reader navigation expands the window.
  // Drive the real scrollport instead of asking an absent DOM node to scroll.
  await expect
    .poll(async () => {
      if (await page.locator('article[data-message-id="image-0"]').count()) return true;
      await page.mouse.wheel(
        0,
        -(await viewport.evaluate((element) => element.scrollHeight))
      );
      return false;
    })
    .toBe(true);
  for (let index = 0; index < 60; index += 1) {
    const message = page.locator(`article[data-message-id="image-${index}"]`);
    await message.scrollIntoViewIfNeeded();
    const image = page.getByRole("img", { name: `image-${index}.png`, exact: true });
    await expect(image).toBeVisible();
    await expect
      .poll(() =>
        image.evaluate(
          (element: HTMLImageElement) => element.complete && element.naturalWidth > 0
        )
      )
      .toBe(true);
  }
  const metrics = () =>
    page.evaluate(
      () =>
        (
          window as unknown as {
            mediaRetention: { metrics: { imageLoads: number; imageReleases: number } };
          }
        ).mediaRetention.metrics
    );
  const afterFirstVisits = await metrics();
  // Initial offscreen acquisitions can be cancelled before they display.
  // Revisiting ready images must not start any additional acquisition.
  expect(afterFirstVisits.imageLoads).toBeGreaterThanOrEqual(60);
  await page.locator('article[data-message-id="image-0"]').scrollIntoViewIfNeeded();
  await expect(
    page.getByRole("img", { name: "image-0.png", exact: true })
  ).toBeVisible();
  await expect(page.locator("[data-comma-image-group-placeholder]")).toHaveCount(0);
  expect(await metrics()).toEqual(afterFirstVisits);
  expect(afterFirstVisits.imageReleases).toBe(0);
  await page.evaluate(() =>
    (
      window as unknown as { mediaRetention: { unmount(): void } }
    ).mediaRetention.unmount()
  );
  await expect.poll(async () => (await metrics()).imageReleases).toBe(60);
});
