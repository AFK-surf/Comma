import { expect, test } from "@playwright/test";

// Runs against the isolated production-LiveView preview, not shared staging.
// Start meeting_preparation_preview.exs with MEETING_PREVIEW_LOCALE=en.
const previewURL = process.env.MEETING_PREVIEW_URL;

test("meeting history opens existing source links and keeps preparation navigation", async ({ page }) => {
  test.skip(!previewURL, "Requires the local meeting preview fixture");
  await page.goto(previewURL!);
  const welcome = page.locator("button[phx-click=onboarding-welcome-later]");
  if (await welcome.isVisible()) await welcome.click();
  await page.getByRole("link", { name: "Past meetings", exact: true }).click();
  await expect(page.getByRole("button", { name: /Stand-up · sample meeting/ })).toBeVisible();
  await expect(page.getByText("Private source must not appear")).toHaveCount(0);
  const detail = page.locator("#meeting-record-detail");
  await expect(detail).toHaveCount(0);
  await page.getByRole("button", { name: /Stand-up · sample meeting/ }).click();
  await expect(detail.getByRole("link", { name: "Open recording in Slack" })).toHaveAttribute(
    "href", "https://sample.slack.com/files/UTEST/FRECORD",
  );
  await expect(detail.getByRole("link", { name: "Open Canvas in Slack" })).toHaveAttribute(
    "href", "https://sample.slack.com/docs/TTEST/FTEST",
  );
  await expect(page.getByText("Do not expose a content preview")).toHaveCount(0);
  await page.getByRole("button", { name: "Close meeting details" }).click();
  await page.getByRole("button", { name: /Planning · sample meeting/ }).click();
  await expect(detail).toContainText("No recording was saved for this meeting.");
  await expect(detail.getByRole("link", { name: "Open recording in Slack" })).toHaveCount(0);
  await page.keyboard.press("Escape");
  await expect(detail).toHaveCount(0);
  await page.getByRole("button", { name: /Design sync · sample meeting/ }).click();
  await expect(detail).toContainText("The meeting is processing. No recording link is available yet.");
  await page.getByRole("button", { name: "Close meeting details" }).click();
  await expect(detail).toHaveCount(0);
  await page.getByRole("link", { name: "Upcoming", exact: true }).click();
  await expect(page.locator("#meeting-history")).toHaveCount(0);
  await page.getByRole("link", { name: "Preparation settings", exact: true }).click();
  await expect(page.locator("#meeting-preparation-form")).toBeVisible();
  await expect(page.locator("#meeting-attendee-dms")).toBeVisible();
});
