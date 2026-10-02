import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

test.use({ locale: "en-US", viewport: { width: 1440, height: 900 } });

test("voice input in the browser offers the Mac app instead of recording", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "desktop-prompt@comma.local",
    token: "comma_sess_desktop_prompt",
  });
  await page.goto("/");

  // The stub session has no chat backend; its toast would cover the composer.
  const unavailable = page.locator('[data-slot="toast-host"]');
  await unavailable.getByRole("button", { name: "Dismiss notification" }).click();
  await expect(unavailable.getByText("Chat is temporarily unavailable")).toHaveCount(0);

  const home = page.getByTestId("home-responsive-layout");
  const voice = home.getByRole("button", { name: "Voice input" });
  await voice.click();

  const prompt = page.getByRole("dialog", { name: "Get Comma for Mac" });
  await expect(prompt).toContainText("Voice input needs the Comma app for Mac.");
  await expect(home.locator('[data-slot="ai-input-voice-recording"]')).toHaveCount(0);

  await prompt.getByRole("button", { name: "Cancel" }).click();
  await expect(prompt).not.toBeVisible();
  await expect(voice).toBeVisible();

  await voice.click();
  await expect(prompt).toBeVisible();
  await page
    .context()
    .route("https://comma.surf/**", (route) =>
      route.fulfill({ status: 200, contentType: "text/html", body: "" })
    );
  const [download] = await Promise.all([
    page.waitForEvent("popup"),
    prompt.getByRole("button", { name: "Download" }).click(),
  ]);
  expect(download.url()).toBe("https://comma.surf/download?start=mac");
  await expect(prompt).not.toBeVisible();
});

test("desktop-only settings in the browser offer the Mac app and keep their values", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "desktop-prompt@comma.local",
    token: "comma_sess_desktop_prompt",
  });
  await page.goto("/#/settings");

  const prompt = page.getByRole("dialog", { name: "Get Comma for Mac" });
  const cases = [
    ["General", "switch", "Launch Comma at login", "Launching at login"],
    ["General", "switch", /^Show in (menu bar|system tray)$/, "The menu bar icon"],
    ["General", "switch", "Show in dock", "The Dock icon"],
    ["Notifications", "switch", "System notifications", "System notifications"],
    ["Meeting", "switch", "Hide recorder notch for others", "Meeting recording"],
    ["Meeting", "switch", "Smart summary", "Meeting recording"],
    ["Computer use", "button", "Manage permissions", "Computer use"],
    ["Computer use", "button", "Refresh status", "Computer use"],
    ["Compute node", "button", "Enable this Mac", "Compute node"],
  ] as const;
  for (const [category, role, name, feature] of cases) {
    await page.getByRole("button", { name: category, exact: true }).click();
    const control = page.getByRole(role, { name, exact: true });
    const checked = role === "switch" ? await control.isChecked() : undefined;
    if (role === "switch") {
      await control.focus();
      await control.press("Space");
    } else {
      await control.click();
    }
    await expect(prompt).toContainText(`${feature} needs the Comma app for Mac.`);
    await expect(prompt).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(prompt).not.toBeVisible();
    // The Settings window stays open behind the prompt.
    await expect(control).toBeVisible();
    if (checked !== undefined) expect(await control.isChecked()).toBe(checked);
  }

  // A choice from the meeting dropdown is not saved either.
  await page.getByRole("button", { name: "Meeting", exact: true }).click();
  const recording = page.getByRole("button", { name: /Start recording$/ });
  await recording.click();
  await page.getByRole("option", { name: "Auto", exact: true }).click();
  await expect(prompt).toContainText("Meeting recording needs the Comma app for Mac.");
  await expect(prompt).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(recording).not.toContainText("Auto");
});
