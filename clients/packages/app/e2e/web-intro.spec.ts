import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

test("a first sign-in on the web shows the intro card, not the onboarding, until it is closed", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  try {
    await page.setViewportSize({ width: 1280, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "web-intro@comma.local",
      onboardingCompleted: false,
      token: "comma_sess_web_intro",
    });
    // Home reads its Routines at once: nothing waits for the card.
    const routines = page.waitForRequest((request) =>
      /\/v1\/comma\/workspaces\/[^/]+\/recommendations$/.test(
        new URL(request.url()).pathname
      )
    );
    await page.goto("/");

    const prompt = page
      .getByRole("region", { name: "Content" })
      .getByRole("textbox", { name: "AI prompt" });
    const card = page.getByRole("complementary", { name: "Comma on the web" });
    await expect(card).toBeVisible();
    await expect(page.getByRole("dialog", { name: "Welcome to Comma" })).toHaveCount(0);
    await routines;

    // It rests in the window's bottom-right corner above the composer's line,
    // and the product stays usable around it.
    // Read once its entrance has settled.
    await expect
      .poll(async () => {
        const box = (await card.boundingBox())!;
        return [1280 - (box.x + box.width), 800 - (box.y + box.height)];
      })
      .toEqual([24, 80]);
    // A narrow window brings the composer under the card's column; its send
    // button stays reachable.
    await page.setViewportSize({ width: 1024, height: 768 });
    await prompt.fill("Plan my week");
    await page
      .getByRole("region", { name: "Content" })
      .getByRole("button", { name: "Send", exact: true })
      .click({ trial: true });
    await prompt.fill("");
    await page.setViewportSize({ width: 1280, height: 800 });
    await prompt.click();
    await expect(prompt).toBeFocused();

    const heading = card.getByRole("heading");
    await expect(heading).toHaveText("Just ask your Router");
    const top = (await card.boundingBox())!.y;
    await card.getByRole("button", { name: "Next" }).click();
    await expect(heading).toHaveText("Connect your apps");
    // Every tip's copy shares one cell, so the card does not resize under the
    // pointer.
    expect((await card.boundingBox())!.y).toBe(top);
    await card.getByRole("button", { name: "Next" }).click();
    await expect(heading).toHaveText("More in the desktop app");
    // Each scene plays and then rests: nothing in the card animates forever.
    expect(
      await card.evaluate((element) =>
        element
          .getAnimations({ subtree: true })
          .every((animation) =>
            Number.isFinite(animation.effect?.getComputedTiming().endTime)
          )
      )
    ).toBe(true);
    await card.getByRole("button", { name: "Close" }).click();
    await expect(card).toHaveCount(0);
    // It plays its exit, then leaves the page.
    await expect(page.getByTestId("web-intro-card")).toHaveCount(0);
    // Closing hands focus back to where the user was.
    await expect(prompt).toBeFocused();

    await page.reload();
    await expect(prompt).toBeVisible();
    await expect(card).toHaveCount(0);
  } finally {
    await stub.close();
  }
});
