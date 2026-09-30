import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

test.use({ locale: "en-US", viewport: { width: 1440, height: 900 } });

test("the empty conversation centers its mark and titles it at 18px", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "empty-chat@comma.local",
    token: "comma_sess_empty_chat",
  });
  await page.goto("/");

  const empty = page.getByTestId("home-responsive-layout").getByTestId("chat-empty");
  await expect(empty).toBeVisible();
  await expect(
    empty.getByRole("heading", { name: "You start. Comma does the rest." })
  ).toHaveCSS("font-size", "18px");

  const alignment = await empty.evaluate((element) => {
    const viewport = element.closest('[data-slot="scroll-area-viewport"]');
    const mark = element.querySelector(".comma-chat-empty-mark");
    const copy = element.querySelector(".comma-chat-empty-copy");
    if (!viewport || !mark || !copy) {
      return null;
    }
    const frame = viewport.getBoundingClientRect();
    const markBox = mark.getBoundingClientRect();
    const copyBox = copy.getBoundingClientRect();
    const top = Math.min(markBox.top, copyBox.top);
    const bottom = Math.max(markBox.bottom, copyBox.bottom);
    const left = Math.min(markBox.left, copyBox.left);
    const right = Math.max(markBox.right, copyBox.right);
    return {
      emptyHeight: element.getBoundingClientRect().height,
      frameHeight: frame.height,
      offsetX: (left + right) / 2 - (frame.left + frame.width / 2),
      offsetY: (top + bottom) / 2 - (frame.top + frame.height / 2),
    };
  });

  expect(alignment).not.toBeNull();
  expect(alignment!.emptyHeight).toBeGreaterThan(alignment!.frameHeight * 0.75);
  expect(Math.abs(alignment!.offsetX)).toBeLessThan(8);
  expect(Math.abs(alignment!.offsetY)).toBeLessThan(24);
});
