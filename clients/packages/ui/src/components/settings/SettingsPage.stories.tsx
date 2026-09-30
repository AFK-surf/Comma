import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, userEvent, waitFor, within } from "storybook/test";
import { useMemo, useState } from "react";
import { Button } from "../Button";
import {
  chordKeybinding,
  sameAppKeybinding,
  sequenceKeybinding,
  type AppKeybinding,
  type SettingsShortcutValue,
} from "../settings-shortcut";
import { SettingsPage } from "./SettingsPage";
import { createSettingsRegistry } from "./settingsRegistry";

const defaultGeneralBindings = {
  "go-settings": chordKeybinding("Comma", { meta: true }),
  "go-comma-assistant": sequenceKeybinding("KeyG", "KeyC"),
  "go-inbox": sequenceKeybinding("KeyG", "KeyI"),
  "toggle-left-sidebar": chordKeybinding("KeyB", { meta: true }),
  "toggle-right-sidebar": chordKeybinding("KeyB", { alt: true, meta: true }),
} satisfies Record<string, AppKeybinding>;

type GeneralBindingId = keyof typeof defaultGeneralBindings;

const generalShortcutRows: {
  id: GeneralBindingId;
  settingsItemId: string;
  title: string;
  description: string;
}[] = [
  {
    id: "go-settings",
    settingsItemId: "keyboard.go-settings",
    title: "Go to Settings",
    description: "Open Comma Settings.",
  },
  {
    id: "go-comma-assistant",
    settingsItemId: "keyboard.go-comma-assistant",
    title: "Go to Comma assistant",
    description: "Open Comma assistant.",
  },
  {
    id: "go-inbox",
    settingsItemId: "keyboard.go-inbox",
    title: "Go to Inbox",
    description: "Open Inbox.",
  },
  {
    id: "toggle-left-sidebar",
    settingsItemId: "keyboard.toggle-left-sidebar",
    title: "Toggle left sidebar",
    description: "Show or hide the left sidebar.",
  },
  {
    id: "toggle-right-sidebar",
    settingsItemId: "keyboard.toggle-right-sidebar",
    title: "Toggle right sidebar",
    description: "Show or hide the right sidebar.",
  },
];

const SettingsStory = () => {
  const [language, setLanguage] = useState("system");
  const [theme, setTheme] = useState("system");
  const [fontSize, setFontSize] = useState("default");
  const [pointerCursors, setPointerCursors] = useState(false);
  const [launchAtLogin, setLaunchAtLogin] = useState(false);
  const [sideChatShortcut, setSideChatShortcut] = useState<SettingsShortcutValue>({
    key: "z",
    modifiers: {
      alt: false,
      control: true,
      meta: false,
      shift: false,
    },
  });
  const [generalBindings, setGeneralBindings] = useState(defaultGeneralBindings);
  const generalBindingsAreDefault = generalShortcutRows.every((row) =>
    sameAppKeybinding(generalBindings[row.id], defaultGeneralBindings[row.id])
  );
  const registry = useMemo(
    () =>
      createSettingsRegistry({
        groups: [
          {
            id: "application",
            label: "Application",
            categories: [
              {
                id: "general",
                icon: "general",
                label: "General",
                keywords: ["preferences"],
                sections: [
                  {
                    id: "general.application",
                    title: "General",
                    items: [
                      {
                        id: "app.language",
                        title: "Language",
                        description: "Language for the app UI",
                        keywords: ["locale"],
                        control: {
                          type: "dropdown",
                          placeholder: "Select language",
                          items: [
                            { id: "system", label: "Auto detect" },
                            { id: "en", label: "English" },
                            { id: "zh-CN", label: "Simplified Chinese" },
                          ],
                          onChange: setLanguage,
                          value: language,
                        },
                      },
                      {
                        id: "app.launch-at-login",
                        title: "Launch Comma at login",
                        description:
                          "Automatically start Comma when you log in to your computer.",
                        keywords: ["startup", "boot"],
                        control: {
                          type: "toggle",
                          checked: launchAtLogin,
                          onChange: (event) => setLaunchAtLogin(event.target.checked),
                        },
                      },
                      {
                        id: "app.menu-bar",
                        title: "Show in menu bar",
                        description:
                          "Keep Comma in the macOS menu bar when the main window is closed.",
                        control: { type: "toggle" },
                      },
                      {
                        id: "app.dock",
                        title: "Show in dock",
                        description: "Keep Comma available in the macOS Dock.",
                        control: { type: "toggle" },
                      },
                    ],
                  },
                ],
              },
              {
                id: "profile",
                icon: "profile",
                label: "Profile",
                sections: [
                  {
                    id: "profile.account",
                    title: "Account",
                    items: [
                      {
                        id: "account.profile",
                        title: "Profile details",
                        description: "Manage your name, avatar, and account details.",
                        control: { type: "button", label: "Manage" },
                      },
                    ],
                  },
                ],
              },
              {
                id: "appearance",
                icon: "appearance",
                label: "Appearance",
                sections: [
                  {
                    id: "appearance.theme",
                    title: "Appearance",
                    items: [
                      {
                        id: "appearance.color-theme",
                        title: "Theme",
                        description: "Choose light, dark, or match your system.",
                        control: {
                          type: "segmented",
                          items: [
                            { id: "light", label: "Light" },
                            { id: "dark", label: "Dark" },
                            { id: "system", label: "Auto" },
                          ],
                          onChange: setTheme,
                          value: theme,
                        },
                      },
                      {
                        id: "appearance.font-size",
                        title: "Font size",
                        description: "Adjust the size of text across the app.",
                        control: {
                          type: "dropdown",
                          value: fontSize,
                          placeholder: "Select font size",
                          items: [
                            { id: "small", label: "Small" },
                            { id: "default", label: "Default" },
                            { id: "large", label: "Large" },
                          ],
                          onChange: setFontSize,
                        },
                      },
                      {
                        id: "appearance.pointer-cursors",
                        title: "Use pointer cursors",
                        description:
                          "Change the cursor when hovering over interactive elements.",
                        control: {
                          type: "toggle",
                          checked: pointerCursors,
                          onChange: (event) => setPointerCursors(event.target.checked),
                        },
                      },
                    ],
                  },
                ],
              },
              {
                id: "keyboard-shortcuts",
                icon: "keyboard-shortcuts",
                label: "Keyboard shortcuts",
                titleAction: (
                  <Button
                    className="h-auto px-lg py-xs"
                    disabled={generalBindingsAreDefault}
                    hierarchy="secondary-gray"
                    onPress={() => setGeneralBindings(defaultGeneralBindings)}
                    size="sm"
                  >
                    Reset all to defaults
                  </Button>
                ),
                sections: [
                  {
                    id: "keyboard.general",
                    title: "Navigation",
                    items: generalShortcutRows.map((row) => ({
                      id: row.settingsItemId,
                      title: row.title,
                      description: row.description,
                      keywords: ["hotkey", "shortcut", row.title],
                      control: {
                        type: "keybinding" as const,
                        value: generalBindings[row.id],
                        recordingLabel: "Press shortcut",
                        clearLabel: "Reset shortcut",
                        onClear: () => {
                          setGeneralBindings((current) => ({
                            ...current,
                            [row.id]: defaultGeneralBindings[row.id],
                          }));
                        },
                        onChange: (binding: AppKeybinding) => {
                          setGeneralBindings((current) => ({
                            ...current,
                            [row.id]: binding,
                          }));
                        },
                      },
                    })),
                  },
                  {
                    id: "keyboard.commands",
                    title: "Commands",
                    items: [
                      {
                        id: "keyboard.open-comma",
                        title: "Open Comma",
                        description: "View and customize the global shortcut.",
                        keywords: ["hotkey", "command"],
                      },
                      {
                        id: "keyboard.open-side-chat",
                        title: "Open Side Chat",
                        description: "Open Side Chat from anywhere.",
                        keywords: ["side chat", "hotkey", "shortcut"],
                        control: {
                          type: "shortcut",
                          value: sideChatShortcut,
                          recordingLabel: "Press shortcut",
                          onChange: setSideChatShortcut,
                        },
                      },
                    ],
                  },
                ],
              },
              {
                id: "usage-billing",
                icon: "usage-billing",
                label: "Usage & billing",
                sections: [
                  {
                    id: "billing.plan",
                    title: "Plan",
                    items: [
                      {
                        id: "billing.current-plan",
                        title: "Current plan",
                        description: "Review usage, invoices, and plan details.",
                        control: { type: "button", label: "Manage" },
                      },
                    ],
                  },
                ],
              },
            ],
          },
          {
            id: "system",
            label: "System",
            categories: [
              {
                id: "devices",
                icon: "devices",
                label: "Devices",
                sections: [
                  {
                    id: "devices.connected",
                    title: "Connected devices",
                    items: [
                      {
                        id: "devices.current",
                        title: "This device",
                        description: "Review devices connected to your Comma account.",
                        control: { type: "button", label: "View" },
                      },
                    ],
                  },
                ],
              },
              {
                id: "computer-use",
                icon: "computer-use",
                label: "Computer use",
                sections: [
                  {
                    id: "computer-use.access",
                    title: "Access",
                    items: [
                      {
                        id: "computer-use.enabled",
                        title: "Allow computer use",
                        description:
                          "Let Comma interact with applications on this computer.",
                        control: { type: "toggle" },
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      }),
    [
      fontSize,
      generalBindings,
      generalBindingsAreDefault,
      language,
      launchAtLogin,
      pointerCursors,
      sideChatShortcut,
      theme,
    ]
  );

  return (
    <div className="h-screen min-h-[720px] w-screen min-w-[1024px] bg-window p-md">
      <SettingsPage
        emptySearchDescription="Try a setting name, description, or related keyword."
        registry={registry}
        searchAriaLabel="Search settings"
        searchPlaceholder="Search settings"
      />
    </div>
  );
};

const meta = {
  title: "App components/Settings/Page",
  component: SettingsPage,
  args: {
    registry: createSettingsRegistry({ groups: [] }),
    searchAriaLabel: "Search settings",
    searchPlaceholder: "Search settings",
  },
  parameters: {
    layout: "fullscreen",
  },
  render: () => <SettingsStory />,
} satisfies Meta<typeof SettingsPage>;

export default meta;
type Story = StoryObj<typeof meta>;

export const AllCategories: Story = {};

export const AdaptiveLanguageDropdown: Story = {};

export const AdaptiveLanguageDropdownInteraction: Story = {
  tags: ["!dev", "!autodocs"],
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const trigger = canvas.getByRole("button", { name: /Select language/ });
    const dropdown = trigger.closest('[data-slot="dropdown"]');

    await expect(dropdown).toHaveAttribute("data-width", "content");
    await expect(trigger).toHaveTextContent("Auto detect");
    const triggerTop = trigger.getBoundingClientRect().top;
    await userEvent.click(trigger);
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
    const selectedOption = await page.findByRole("option", { name: "Auto detect" });
    await waitFor(() =>
      expect(
        Math.abs(selectedOption.getBoundingClientRect().top - triggerTop)
      ).toBeLessThanOrEqual(0.1)
    );
    await userEvent.click(await page.findByRole("option", { name: "English" }));
    await expect(trigger).toHaveTextContent("English");
    await userEvent.click(trigger);
    await userEvent.click(await page.findByRole("option", { name: "Auto detect" }));
    await expect(trigger).toHaveTextContent("Auto detect");
  },
};

export const Search: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const search = canvas.getByRole("searchbox", { name: "Search settings" });

    await userEvent.type(search, "startup");
    await expect(
      canvas.getByRole("heading", { level: 1, name: "General" })
    ).toBeInTheDocument();
    await expect(canvas.getByText("Language")).toBeInTheDocument();

    const results = canvasElement.querySelector(
      '[data-slot="settings-search-results"]'
    );
    await expect(results).not.toBeNull();
    const resultList = within(results as HTMLElement);
    await expect(resultList.getByText("Launch Comma at login")).toBeInTheDocument();
    await expect(resultList.getByText("General")).toBeInTheDocument();
    await expect(resultList.getByText("startup")).not.toHaveClass("font-semibold");

    await userEvent.click(
      resultList.getByRole("button", { name: /Launch Comma at login/ })
    );
    await expect(search).toHaveValue("");
    await expect(
      canvasElement.querySelector('[data-slot="settings-search-results"]')
    ).toBeNull();
  },
};

export const AppearanceControls: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);

    await userEvent.click(canvas.getByRole("button", { name: "Appearance" }));
    await userEvent.click(canvas.getByRole("button", { name: "Dark" }));
    await expect(canvas.getByRole("button", { name: "Dark" })).toHaveAttribute(
      "aria-pressed",
      "true"
    );

    await userEvent.click(canvas.getByRole("button", { name: /Select font size/ }));
    const fontSizeTrigger = canvas.getByRole("button", { name: /Select font size/ });
    const selectedFontSize = await page.findByRole("option", { name: "Default" });
    await expect(
      fontSizeTrigger.querySelector('[data-slot="dropdown-row-leading"]')
    ).toBeNull();
    await waitFor(() =>
      expect(
        Math.abs(
          selectedFontSize.getBoundingClientRect().top -
            fontSizeTrigger.getBoundingClientRect().top
        )
      ).toBeLessThanOrEqual(1)
    );
    await userEvent.click(page.getByRole("option", { name: "Large" }));
    await expect(
      canvas.getByRole("button", { name: /Select font size/ })
    ).toHaveTextContent("Large");

    const pointerCursors = canvas.getByRole("switch");
    await userEvent.click(pointerCursors);
    await expect(pointerCursors).toBeChecked();
  },
};

export const KeyboardShortcut: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);

    await userEvent.click(canvas.getByRole("button", { name: "Keyboard shortcuts" }));
    await expect(
      canvas.getByRole("heading", { level: 2, name: "Navigation" })
    ).toBeInTheDocument();
    await expect(
      canvas.queryByRole("heading", { level: 2, name: "Media" })
    ).not.toBeInTheDocument();
    await expect(
      canvas.getByRole("button", { name: "Go to Inbox: G then I" })
    ).toBeInTheDocument();

    const inboxShortcut = canvas.getByRole("button", {
      name: "Go to Inbox: G then I",
    });
    await userEvent.click(inboxShortcut);
    await userEvent.keyboard("gx");
    await expect(
      await canvas.findByRole(
        "button",
        { name: "Go to Inbox: G then X" },
        // Sequence capture commits after 1000 ms; allow time to render it.
        { timeout: 2_000 }
      )
    ).toBeInTheDocument();

    const shortcut = canvas.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(shortcut);
    await userEvent.keyboard("{Control>}k{/Control}");

    await expect(
      canvas.getByRole("button", { name: "Open Side Chat: Ctrl + K" })
    ).toBeInTheDocument();
  },
};
