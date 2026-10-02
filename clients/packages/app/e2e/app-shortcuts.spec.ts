import { expect, test } from "@playwright/test";
import {
  dismissOnboarding,
  installBrowserTestSession,
} from "../../../e2e/helpers/browser-auth";
import { installBrowserPlatform } from "../../../e2e/helpers/browser-platform";

const installSession = (
  page: Parameters<typeof installBrowserTestSession>[0],
  { legacyStores = false } = {}
) =>
  installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "app-shortcuts@comma.local",
    // Legacy renderer stores migrate only into absent client settings.
    onboardingCompleted: !legacyStores,
    token: "comma_sess_app_shortcuts",
  });

const usesCommandAsPrimary = async (
  page: Parameters<typeof installBrowserTestSession>[0]
) =>
  page.evaluate(() => {
    const navigatorWithPlatform = navigator as Navigator & {
      userAgentData?: { platform?: string };
    };
    const platform = `${navigatorWithPlatform.userAgentData?.platform ?? ""} ${
      navigator.platform
    } ${navigator.userAgent}`.toLocaleLowerCase();
    return (
      platform.includes("mac") ||
      platform.includes("iphone") ||
      platform.includes("ipad")
    );
  });

const toggleCommandPalette = async (
  page: Parameters<typeof installBrowserTestSession>[0]
) => {
  const primaryIsCommand = await usesCommandAsPrimary(page);
  await page.keyboard.press(primaryIsCommand ? "Meta+KeyK" : "Control+KeyK");
};

const commandPalette = (page: Parameters<typeof installBrowserTestSession>[0]) =>
  page.getByRole("dialog", { name: "Search Comma" });

test("Settings offers no Drive shortcut in the web client", async ({ page }) => {
  await installSession(page);
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Keyboard shortcuts" }).click();
  // The web client has no Drive entry, so it offers no shortcut to one.
  await expect(page.locator('[data-setting-id="keyboard.go-inbox"]')).toBeVisible();
  await expect(page.locator('[data-setting-id="keyboard.go-drive"]')).toHaveCount(0);
});

test("default navigation shortcuts open Search and reach their destinations", async ({
  page,
}) => {
  await installSession(page);
  await page.goto("/");
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();

  await toggleCommandPalette(page);
  await expect(commandPalette(page)).toBeVisible();
  await expect(page.getByRole("combobox", { name: "Search Comma" })).toBeFocused();
  await expect(page).toHaveURL(/\/(?:#\/)?$/);

  await toggleCommandPalette(page);
  await expect(commandPalette(page)).not.toBeVisible();
  await expect(page).toHaveURL(/\/(?:#\/)?$/);

  await toggleCommandPalette(page);
  await expect(commandPalette(page)).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(commandPalette(page)).not.toBeVisible();

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyI");
  await expect(page).toHaveURL(/#\/inbox$/);

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyT");
  await expect(page).toHaveURL(/#\/tasks$/);

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyP");
  await expect(page).toHaveURL(/#\/plugins$/);

  // The web client has no Drive entry, so its sequence goes nowhere.
  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyD");
  await expect(page).toHaveURL(/#\/plugins$/);

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyC");
  await expect(page).toHaveURL(/#\/$/);
});

test("sidebar navigation tooltips stay beside their item with the matching shortcut", async ({
  page,
}) => {
  await installSession(page);
  await page.goto("/");
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();
  await page.mouse.move(1, 1);

  const primaryIsCommand = await usesCommandAsPrimary(page);
  const cases = [
    {
      itemName: "Home",
      label: "Go to Home",
      keys: ["G", "C"],
    },
    {
      itemName: "Inbox",
      label: "Go to Inbox",
      keys: ["G", "I"],
    },
    {
      itemName: "Tasks",
      label: "Go to Tasks",
      keys: ["G", "T"],
    },
    {
      itemName: "Plugins",
      label: "Go to Plugins",
      keys: ["G", "P"],
    },
    {
      // Settings raises a modal instead of navigating, so its rail item is a
      // button.
      itemName: "Settings",
      label: "Go to Settings",
      keys: [primaryIsCommand ? "⌘" : "Ctrl", ","],
      role: "button" as const,
    },
  ] as const;

  for (const { itemName, keys, label, ...rest } of cases) {
    const item = page.getByRole("role" in rest ? rest.role : "link", {
      name: itemName,
      exact: true,
    });
    await item.hover();

    const tooltip = page.getByRole("tooltip").filter({ hasText: label });
    await expect(tooltip).toBeVisible();
    await expect(tooltip).toHaveAttribute("data-side", "right");
    await expect(tooltip.getByText(label, { exact: true })).toBeVisible();
    await expect(
      tooltip.getByLabel(`Keyboard shortcut: ${keys.join(" ")}`).locator("kbd")
    ).toHaveText([...keys]);
    // The row spans the rail's full width but only its icon slot is painted, so
    // the bubble is measured against that slot: one --spacing-xs off its edge
    // and centred on it.
    const icon = item.locator('[data-slot="left-rail-item-icon"]');
    await expect
      .poll(async () => {
        const [iconBox, tooltipBox] = await Promise.all([
          icon.boundingBox(),
          tooltip.boundingBox(),
        ]);
        if (!iconBox || !tooltipBox) return false;

        const horizontalGap = tooltipBox.x - (iconBox.x + iconBox.width);
        const verticalCenterDelta = Math.abs(
          tooltipBox.y + tooltipBox.height / 2 - (iconBox.y + iconBox.height / 2)
        );
        return horizontalGap >= 3 && horizontalGap <= 5 && verticalCenterDelta <= 2;
      })
      .toBe(true);
  }
});

for (const platformCase of [
  { hint: "Use ⌘K for search", label: "macOS", platform: "macos" },
  { hint: "Use Ctrl+K for search", label: "Windows", platform: "windows" },
] as const) {
  test(`the window bar search hint names the search shortcut and opens the palette on ${platformCase.label}`, async ({
    page,
  }) => {
    await installBrowserPlatform(page, platformCase.platform);
    await installSession(page);
    await page.goto("/");
    await expect(
      page.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();

    // Search left the rail: the window bar hint is the pointer path to the
    // palette, which opens over the current route rather than leaving it.
    await expect(page.getByRole("link", { name: "Search" })).toHaveCount(0);
    const hint = page.getByTestId("comma-window-bar-search");
    await expect(hint).toHaveText(platformCase.hint);
    await hint.click();
    await expect(commandPalette(page)).toBeVisible();
    await expect(page.getByRole("combobox", { name: "Search Comma" })).toBeFocused();
    await expect(page).toHaveURL(/\/(?:#\/)?$/);
  });
}

test("Search stays global while navigation shortcuts remain blocked in the composer", async ({
  page,
}) => {
  await installSession(page);
  await page.goto("/");
  const prompt = page.getByRole("textbox", { name: "AI prompt" });
  await prompt.focus();

  await page.keyboard.type("gt");
  await expect(prompt).toHaveText("gt");
  await expect(page).toHaveURL(/\/(?:#\/)?$/);

  await toggleCommandPalette(page);
  await expect(commandPalette(page)).toBeVisible();
  await expect(page.getByRole("combobox", { name: "Search Comma" })).toBeFocused();
  await expect(page).toHaveURL(/\/(?:#\/)?$/);

  await toggleCommandPalette(page);
  await expect(commandPalette(page)).not.toBeVisible();
  await expect(prompt).toHaveText("gt");

  await toggleCommandPalette(page);
  await expect(commandPalette(page)).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(commandPalette(page)).not.toBeVisible();
  await expect(page).toHaveURL(/\/(?:#\/)?$/);
});

test("an open select list takes typed letters to pick an option, not to navigate", async ({
  page,
}) => {
  await installSession(page);
  await page.goto("/#/settings");
  await page.getByRole("button", { name: /Select language/ }).click();
  const listbox = page.getByRole("listbox");
  await expect(listbox).toBeVisible();

  await page.keyboard.type("si");
  await expect(page.getByRole("option", { name: "Simplified Chinese" })).toBeFocused();
  // G then I goes to Inbox everywhere else.
  await page.keyboard.type("gi");
  await expect(listbox).toBeVisible();
  await expect(page).toHaveURL(/#\/settings$/);

  await page.keyboard.press("Escape");
  await expect(listbox).toBeHidden();
  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyI");
  await expect(page).toHaveURL(/#\/inbox$/);
});

test("Search does not offer or navigate to Settings commands", async ({ page }) => {
  await installSession(page);
  await page.goto("/#/inbox");
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();

  await toggleCommandPalette(page);
  const searchInput = page.getByRole("combobox", { name: "Search Comma" });
  const loading = page.locator('[data-slot="command-palette-loading"]');
  const settingsCommands = page.getByRole("option").filter({
    hasText:
      /Switch Comma to the dark theme|Open Appearance settings at (?:Theme|Font size)|Go to Settings/,
  });

  for (const query of ["dark", "font", "settings"]) {
    await searchInput.fill(query);
    await expect(loading).toBeVisible();
    await expect(
      page.getByText("Unable to search tasks. Try again in a moment.", {
        exact: true,
      })
    ).toBeVisible();
    await expect(settingsCommands).toHaveCount(0);
    await expect(page).toHaveURL(/#\/inbox$/);
  }
});

test("product sequences share candidates across navigation and shell owners", async ({
  page,
}) => {
  await installSession(page, { legacyStores: true });
  await page.addInitScript(() => {
    localStorage.setItem(
      "comma.app.shortcuts",
      JSON.stringify({
        overrides: {
          "toggle-left-sidebar": {
            kind: "sequence",
            codes: ["KeyG", "KeyB"],
          },
        },
        version: 2,
      })
    );
  });
  await page.goto("/");
  await dismissOnboarding(page);
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();

  const sidebar = page.getByTestId("comma-sidebar-slot");
  await expect(sidebar).toHaveAttribute("data-collapsed", "false");
  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyB");
  await expect(sidebar).toHaveAttribute("data-collapsed", "true");

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyI");
  await expect(page).toHaveURL(/#\/inbox$/);

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyT");
  await expect(page).toHaveURL(/#\/tasks$/);

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyP");
  await expect(page).toHaveURL(/#\/plugins$/);

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyC");
  await expect(page).toHaveURL(/#\/$/);
});

test("legacy prefix conflicts preserve the customization and disable its default", async ({
  page,
}) => {
  await installSession(page, { legacyStores: true });
  await page.addInitScript(() => {
    localStorage.setItem(
      "comma.app.shortcuts",
      JSON.stringify({
        "go-comma-assistant": { kind: "sequence", codes: ["KeyG", "KeyC"] },
        "go-inbox": {
          kind: "sequence",
          codes: ["KeyG", "KeyC", "KeyI"],
        },
      })
    );
  });
  await page.goto("/#/plugins");
  await dismissOnboarding(page);
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyC");
  await page.evaluate(
    () => new Promise<void>((resolve) => window.setTimeout(resolve, 1_100))
  );
  await expect(page).toHaveURL(/#\/plugins$/);

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyC");
  await page.keyboard.press("KeyI");
  await expect(page).toHaveURL(/#\/inbox$/);
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          JSON.parse(localStorage.getItem("comma.client-settings")!)
            .appShortcutOverrides
      )
    )
    .toEqual({
      "go-comma-assistant": null,
      "go-inbox": {
        kind: "sequence",
        codes: ["KeyG", "KeyC", "KeyI"],
      },
    });
});

test("Settings keeps navigation shortcuts active and a cleared binding inactive", async ({
  page,
}) => {
  await installSession(page);
  await page.goto("/#/settings");
  await expect(
    page.getByRole("complementary", { name: "Settings sections" })
  ).toBeVisible();

  await toggleCommandPalette(page);
  await expect(commandPalette(page)).toBeVisible();
  await expect(page.getByRole("combobox", { name: "Search Comma" })).toBeFocused();
  await expect(page).toHaveURL(/#\/settings$/);

  await toggleCommandPalette(page);
  await expect(commandPalette(page)).not.toBeVisible();

  await toggleCommandPalette(page);
  await expect(commandPalette(page)).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(commandPalette(page)).not.toBeVisible();
  await expect(page).toHaveURL(/#\/settings$/);

  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyI");
  await expect(page).toHaveURL(/#\/inbox$/);

  const primaryIsCommand = await usesCommandAsPrimary(page);
  const settingsChord = primaryIsCommand ? "Meta+Comma" : "Control+Comma";
  await page.keyboard.press(settingsChord);
  // Settings is a modal, so the chord raises it over Inbox rather than
  // navigating anywhere.
  await expect(page.getByRole("dialog", { name: "Settings sections" })).toBeVisible();
  await expect(page).toHaveURL(/#\/inbox$/);

  await page.getByRole("button", { name: "Keyboard shortcuts" }).click();
  const searchShortcut = page.getByRole("button", {
    name: /Search: (?:Command|Control) \+ K/,
  });
  await searchShortcut.focus();
  await toggleCommandPalette(page);
  await expect(commandPalette(page)).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(commandPalette(page)).not.toBeVisible();
  await expect(searchShortcut).toBeFocused();

  const inboxShortcut = page.getByRole("button", {
    name: "Go to Inbox: G then I",
  });
  await inboxShortcut.click();
  await page.getByRole("button", { name: "Clear shortcut" }).click();
  await expect(
    page.getByRole("button", { name: "Go to Inbox: Not set" })
  ).toBeVisible();

  // A reload lands on the route the modal was raised over, so reopen it to
  // read back the binding that was cleared.
  await page.reload();
  await expect(page).toHaveURL(/#\/inbox$/);
  await page.goto("/#/tasks");
  await page.keyboard.press(settingsChord);
  await expect(
    page.getByRole("complementary", { name: "Settings sections" })
  ).toBeVisible();
  await page.keyboard.press("KeyG");
  await page.keyboard.press("KeyI");
  await expect(page).toHaveURL(/#\/tasks$/);
});
