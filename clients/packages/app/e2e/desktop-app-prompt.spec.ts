import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

// A Mac reader: the download page starts the macOS download for them.
test.use({
  locale: "en-US",
  userAgent:
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
  viewport: { width: 1440, height: 900 },
});

test("voice input in the browser offers the desktop app instead of recording", async ({
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

  const prompt = page.getByRole("dialog", { name: "Get the Comma desktop app" });
  await expect(prompt).toContainText("Voice input needs the Comma desktop app.");
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

test("desktop-only settings in the browser offer the desktop app and keep their values", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "desktop-prompt@comma.local",
    token: "comma_sess_desktop_prompt",
  });
  await page.goto("/#/settings");

  const prompt = page.getByRole("dialog", { name: "Get the Comma desktop app" });
  // Features only the macOS app has name the Mac app.
  const cases = [
    ["General", "switch", "Launch Comma at login", "Launching at login", "desktop app"],
    [
      "General",
      "switch",
      /^Show in (menu bar|system tray)$/,
      "The menu bar icon",
      "desktop app",
    ],
    ["General", "switch", "Show in dock", "The Dock icon", "app for Mac"],
    [
      "Notifications",
      "switch",
      "System notifications",
      "System notifications",
      "desktop app",
    ],
    [
      "Meeting",
      "switch",
      "Hide recorder notch for others",
      "Meeting recording",
      "desktop app",
    ],
    ["Meeting", "switch", "Smart summary", "Meeting recording", "desktop app"],
    ["Computer use", "button", "Manage permissions", "Computer use", "app for Mac"],
    ["Computer use", "button", "Refresh status", "Computer use", "app for Mac"],
    ["Devices", "button", "Open the desktop app", "Compute node", "app for Mac"],
  ] as const;
  for (const [category, role, name, feature, app] of cases) {
    await page.getByRole("button", { name: category, exact: true }).click();
    const control = page.getByRole(role, { name, exact: true });
    const checked = role === "switch" ? await control.isChecked() : undefined;
    if (role === "switch") {
      await control.focus();
      await control.press("Space");
    } else {
      await control.click();
    }
    await expect(prompt).toContainText(
      app === "desktop app"
        ? `${feature} needs the Comma desktop app.`
        : `${feature} needs the Comma app for Mac.`
    );
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
  await expect(prompt).toContainText("Meeting recording needs the Comma desktop app.");
  await expect(prompt).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(recording).not.toContainText("Auto");
});
