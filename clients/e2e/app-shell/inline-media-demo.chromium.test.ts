import { expect, test, type Page, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";

useFixture(
  fixtureMount(new URL("./fixtures/inline-media-demo/src/main.tsx", import.meta.url)),
  // The video plays from a fake on the test clock, not a decoder on real time.
  {
    media: {
      "generated-video-preview.webm": { duration: 19.008, width: 1112, height: 642 },
    },
  }
);
const fixtureUrl = "http://fixture.test/";

test.use({
  viewport: { width: 900, height: 720 },
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
    const videoFrame = await page
      .locator(".comma-chat-inline-video")
      .first()
      .boundingBox();

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
});
