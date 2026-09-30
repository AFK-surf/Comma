import userEvent from "@testing-library/user-event";
import { render, screen } from "@comma/test-utils/render";
import { useState } from "react";
import { describe, expect, it } from "vitest";
import { SettingsPage } from "../SettingsPage";
import { createSettingsRegistry } from "../settingsRegistry";

const registry = createSettingsRegistry({
  groups: [
    {
      id: "application",
      label: "Application",
      categories: [
        {
          id: "general",
          icon: "general",
          label: "General",
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
              items: [{ id: "appearance.theme", title: "Theme" }],
            },
          ],
        },
        {
          id: "notifications",
          icon: "notifications",
          label: "Notifications",
          sections: [
            {
              id: "notifications.delivery",
              title: "",
              items: [
                {
                  id: "notifications.system",
                  title: "System notifications",
                  keywords: ["banner"],
                },
              ],
            },
          ],
        },
      ],
    },
  ],
});

const StatefulSettings = () => {
  const [enabled, setEnabled] = useState(false);
  const statefulRegistry = createSettingsRegistry({
    groups: [
      {
        id: "application",
        categories: [
          {
            id: "general",
            icon: "general",
            label: "General",
            sections: [
              {
                id: "general.features",
                title: "Features",
                items: [
                  {
                    id: "feature.enabled",
                    title: "Enable feature",
                    keywords: ["feature"],
                    control: {
                      type: "toggle",
                      checked: enabled,
                      onChange: (event) => setEnabled(event.target.checked),
                    },
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  });

  return (
    <SettingsPage
      registry={statefulRegistry}
      searchAriaLabel="Search settings"
      searchPlaceholder="Search settings"
    />
  );
};

describe("SettingsPage", () => {
  it("owns category navigation and global settings search", async () => {
    const { container } = render(
      <SettingsPage
        contentAriaLabel="Settings content"
        registry={registry}
        searchAriaLabel="Search settings"
        searchPlaceholder="Search settings"
      />
    );

    expect(
      screen.getByRole("heading", { level: 1, name: "General" })
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "General" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(screen.getByRole("button", { name: "Appearance" })).not.toHaveAttribute(
      "aria-current"
    );
    expect(container.querySelector('[data-slot="settings-page"]')).toHaveClass(
      "comma-settings-page",
      "[--comma-overlay-safe-top:2.75rem]"
    );
    expect(screen.getByRole("region", { name: "Settings content" })).toHaveClass(
      "comma-settings-content"
    );
    expect(
      container.querySelector('[data-slot="settings-content-titlebar-drag"]')
    ).toBeNull();

    await userEvent.click(screen.getByRole("button", { name: "Appearance" }));
    expect(
      screen.getByRole("heading", { level: 1, name: "Appearance" })
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Appearance" })).toHaveAttribute(
      "aria-current",
      "page"
    );

    await userEvent.type(
      screen.getByRole("searchbox", { name: "Search settings" }),
      "locale"
    );
    expect(
      screen.getByRole("heading", { level: 1, name: "Appearance" })
    ).toBeInTheDocument();
    expect(screen.getByText("Theme")).toBeInTheDocument();

    const searchResults = container.querySelector(
      '[data-slot="settings-search-results"]'
    );
    expect(searchResults).not.toBeNull();
    expect(searchResults).toHaveTextContent("General");
    expect(searchResults).toHaveTextContent("Language");
    expect(searchResults?.querySelector("mark")).toBeNull();

    await userEvent.click(screen.getByRole("button", { name: /Language.*locale/ }));
    expect(screen.getByRole("searchbox", { name: "Search settings" })).toHaveValue("");
    expect(
      screen.getByRole("heading", { level: 1, name: "General" })
    ).toBeInTheDocument();
    const row = screen.getByText("Language").closest('[data-slot="settings-row"]');
    expect(row).toHaveAttribute("data-active", "true");
    expect(row).toHaveFocus();
  });

  it("labels search results from an untitled section by the category alone", async () => {
    const { container } = render(
      <SettingsPage
        registry={registry}
        searchAriaLabel="Search settings"
        searchPlaceholder="Search settings"
      />
    );

    await userEvent.type(
      screen.getByRole("searchbox", { name: "Search settings" }),
      "banner"
    );

    const searchResults = container.querySelector(
      '[data-slot="settings-search-results"]'
    );
    expect(searchResults).toHaveTextContent("Notifications");
    expect(searchResults).toHaveTextContent("System notifications");
    expect(searchResults?.textContent).not.toContain("·");
  });

  it("preserves control focus across repeated keyboard updates after search navigation", async () => {
    render(<StatefulSettings />);
    await userEvent.type(
      screen.getByRole("searchbox", { name: "Search settings" }),
      "feature"
    );
    await userEvent.click(screen.getByRole("button", { name: /Enable feature/ }));

    await userEvent.tab();
    const toggle = screen.getByRole("switch", { name: "Enable feature" });
    expect(toggle).toHaveFocus();
    await userEvent.keyboard(" ");
    expect(toggle).toBeChecked();
    expect(toggle).toHaveFocus();
    await userEvent.keyboard(" ");
    expect(toggle).not.toBeChecked();
    expect(toggle).toHaveFocus();
  });
});
