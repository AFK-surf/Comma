import { render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SettingsPanel } from "../SettingsPanel";

describe("SettingsPanel", () => {
  afterEach(() => {
    document.documentElement.removeAttribute("data-comma-reduced-motion");
  });

  it("renders sections and setting controls", () => {
    const onChange = vi.fn();
    render(
      <SettingsPanel
        sections={[
          {
            id: "general",
            title: "General",
            items: [
              {
                id: "team",
                title: "Team",
                description: "Choose active team",
                control: {
                  type: "dropdown",
                  items: [{ id: "core", label: "Core" }],
                  onChange,
                },
              },
              {
                id: "enabled",
                title: "Enabled",
                control: { type: "toggle" },
              },
            ],
          },
        ]}
        title="Settings"
      />
    );

    expect(
      screen.getByRole("heading", { level: 1, name: "Settings" })
    ).toBeInTheDocument();
    const pageTitle = screen.getByRole("heading", { level: 1, name: "Settings" });
    const sectionTitle = screen.getByRole("heading", { level: 2, name: "General" });
    const section = screen.getByRole("region", { name: "General" });

    expect(pageTitle).toHaveClass("px-xl", "text-xl");
    expect(pageTitle.parentElement).toHaveClass("gap-3xl");
    expect(sectionTitle).toHaveClass("text-sm", "text-quaternary");
    expect(sectionTitle.parentElement).toHaveClass("px-xl");
    expect(section).toHaveClass("gap-md");
    expect(section.parentElement).toHaveClass("gap-3xl");
    expect(section.querySelectorAll(".bg-main-panel-item-bg")).toHaveLength(3);
    expect(screen.getByText("Team")).toBeInTheDocument();
    const settingsRow = screen.getByText("Team").closest('[data-slot="settings-row"]');
    const settingsCopy = screen
      .getByText("Team")
      .closest('[data-slot="settings-copy"]');
    expect(settingsRow).toHaveClass("py-xl");
    expect(settingsRow).toHaveClass("px-xl");
    expect(settingsRow).not.toHaveClass(
      "py-[calc(var(--spacing-md)+var(--spacing-xxs))]"
    );
    expect(settingsCopy).toHaveClass("gap-xxs", "tracking-normal");
    expect(settingsCopy).not.toHaveClass("gap-xs", "tracking-[-0.14px]");
    expect(
      screen.getByRole("button", { name: "Select team member" })
    ).toBeInTheDocument();
    const toggle = screen.getByRole("switch");
    const toggleRoot = toggle.closest("label");
    expect(toggle).toBeInTheDocument();
    expect(toggleRoot?.querySelector('[data-slot="toggle-base"]')).toHaveClass(
      "h-5.5",
      "w-9",
      "[--comma-toggle-thumb-size:18px]"
    );
    expect(toggleRoot?.querySelector('[data-slot="toggle-thumb-motion"]')).toHaveClass(
      "comma-toggle-thumb-motion"
    );
    expect(toggleRoot?.querySelector('[data-slot="toggle-thumb"]')).toHaveClass(
      "comma-toggle-thumb",
      "size-full"
    );
    expect(toggleRoot?.querySelector('[data-slot="toggle-thumb"]')).not.toHaveClass(
      "w-6"
    );
  });

  it("renders one provider row with accessible secondary actions", async () => {
    const disconnect = vi.fn();
    const openBot = vi.fn();
    render(
      <SettingsPanel
        sections={[
          {
            id: "telegram",
            title: "",
            items: [
              {
                id: "telegram.connection",
                title: "Telegram",
                icon: <svg data-testid="provider-logo" />,
                description: "Chat with Comma in Telegram.",
                integration: {
                  status: { label: "Connected", color: "success" },
                  details: [
                    { label: "Telegram account", value: "@ada" },
                    {
                      label: "Comma bot",
                      value: "@CommaTestBot",
                      actionLabel: "Open in Telegram",
                      onPress: openBot,
                    },
                  ],
                  note: "Private chats only.",
                },
                control: {
                  type: "menu",
                  label: "Manage",
                  items: [
                    {
                      id: "disconnect",
                      label: "Disconnect",
                      tone: "destructive",
                      onPress: disconnect,
                    },
                  ],
                },
              },
            ],
          },
        ]}
        title="Channels"
      />
    );
    expect(screen.getByRole("region", { name: "Telegram" })).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Telegram" })).not.toBeInTheDocument();
    expect(screen.getByText("@ada")).toBeInTheDocument();
    expect(screen.getByText("Connected")).toBeInTheDocument();
    expect(screen.getByText("Telegram account").tagName).toBe("DT");
    expect(screen.getByText("Private chats only.")).toBeInTheDocument();
    expect(screen.getByTestId("provider-logo").parentElement).toHaveAttribute(
      "aria-hidden",
      "true"
    );
    const botAction = screen.getByRole("button", {
      name: "Open in Telegram (@CommaTestBot)",
    });
    expect(botAction).toHaveTextContent("@CommaTestBot");
    screen.getByRole("button", { name: "Manage" }).focus();
    await userEvent.tab();
    expect(botAction).toHaveFocus();
    await userEvent.keyboard("{Enter}");
    expect(openBot).toHaveBeenCalledOnce();
    expect(
      screen.queryByRole("menuitem", { name: "Disconnect" })
    ).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Manage" }));
    await userEvent.click(screen.getByRole("menuitem", { name: "Disconnect" }));
    expect(disconnect).toHaveBeenCalledOnce();
  });

  it("renders display-only shortcut keycaps", () => {
    render(
      <SettingsPanel
        sections={[
          {
            id: "media",
            title: "Media",
            items: [
              {
                id: "play",
                title: "Play",
                control: { type: "keycaps", keys: ["Space"] },
              },
            ],
          },
        ]}
        title="Keyboard shortcuts"
      />
    );

    expect(screen.getByLabelText("Keyboard shortcut: Space")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Play/ })).toBeNull();
  });

  it("preserves the title slot while aligning a category action", () => {
    render(
      <SettingsPanel
        sections={[]}
        title="Keyboard shortcuts"
        titleAction={<button type="button">Reset all</button>}
      />
    );

    const pageTitle = screen.getByRole("heading", {
      level: 1,
      name: "Keyboard shortcuts",
    });
    const panelContent = pageTitle.closest('[data-slot="settings-panel-content"]');
    const titleAction = screen
      .getByRole("button", { name: "Reset all" })
      .closest('[data-slot="settings-panel-title-action"]');

    expect(pageTitle).toHaveClass("px-xl");
    expect(pageTitle.parentElement).toBe(panelContent);
    expect(panelContent).toHaveClass(
      "grid",
      "grid-cols-[minmax(0,1fr)_auto]",
      "items-center",
      "gap-3xl",
      "gap-x-0"
    );
    expect(titleAction).toHaveClass("shrink-0", "pr-xl");
    expect(titleAction?.parentElement).toBe(panelContent);
  });

  it("leaves the page surface to its owner when embedded", () => {
    const { container, rerender } = render(<SettingsPanel />);
    const panel = container.querySelector('[data-slot="settings-panel"]');

    expect(panel).toHaveAttribute("data-surface", "standalone");
    expect(panel).toHaveClass(
      "rounded-2xl",
      "border-[0.5px]",
      "bg-main-panel-bg",
      "shadow-sm"
    );

    rerender(<SettingsPanel surface="embedded" />);

    expect(panel).toHaveAttribute("data-surface", "embedded");
    expect(panel).not.toHaveClass(
      "rounded-2xl",
      "border-[0.5px]",
      "bg-main-panel-bg",
      "shadow-sm"
    );
  });

  it("focuses the active setting row for search navigation", () => {
    const scrollIntoView = vi.fn();
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: scrollIntoView,
    });

    render(
      <SettingsPanel
        activeItemId="language"
        sections={[
          {
            id: "general",
            title: "General",
            items: [
              { id: "team", title: "Team" },
              { id: "language", title: "Language" },
            ],
          },
        ]}
      />
    );

    const activeRow = screen
      .getByText("Language")
      .closest('[data-slot="settings-row"]');
    expect(activeRow).toHaveAttribute("data-active", "true");
    expect(activeRow).toHaveFocus();
    expect(scrollIntoView).toHaveBeenCalledWith({
      behavior: "smooth",
      block: "center",
    });
  });

  it("scrolls the active setting without animation when reduced motion is enabled", () => {
    document.documentElement.setAttribute("data-comma-reduced-motion", "true");
    const scrollIntoView = vi.fn();
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: scrollIntoView,
    });

    render(
      <SettingsPanel
        activeItemId="language"
        sections={[
          {
            id: "general",
            title: "General",
            items: [{ id: "language", title: "Language" }],
          },
        ]}
      />
    );

    expect(scrollIntoView).toHaveBeenCalledWith({
      behavior: "auto",
      block: "center",
    });
  });

  it("reports row state in the trailing edge and opens an icon-only row menu", async () => {
    const rename = vi.fn();
    render(
      <SettingsPanel
        sections={[
          {
            id: "devices",
            title: "",
            items: [
              {
                id: "devices.office",
                title: "Office Mac Studio",
                description: "macOS · arm64",
                icon: <svg data-testid="device-icon" />,
                status: { label: "Connected", color: "success" },
                control: {
                  type: "menu",
                  label: "More",
                  icon: <svg data-testid="more-icon" />,
                  items: [{ id: "rename", label: "Rename device", onPress: rename }],
                },
              },
              {
                id: "devices.office.codex",
                title: "Codex",
                status: { label: "Needs operations", color: "gray" },
              },
            ],
          },
        ]}
      />
    );

    const identity = screen
      .getByText("Office Mac Studio")
      .closest('[data-slot="settings-row"]');
    const state = identity?.querySelector('[data-slot="settings-status"]');
    expect(state).toHaveTextContent("Connected");
    // States line up with the controls rather than trailing the description.
    expect(state?.closest('[data-slot="settings-control"]')).not.toBeNull();
    // A row with state alone still renders that column.
    expect(
      screen
        .getByText("Codex")
        .closest('[data-slot="settings-row"]')
        ?.querySelector('[data-slot="settings-status"]')
    ).toHaveTextContent("Needs operations");

    const trigger = screen.getByRole("button", { name: "More" });
    expect(trigger).not.toHaveTextContent("More");
    await userEvent.click(trigger);
    await userEvent.click(screen.getByRole("menuitem", { name: "Rename device" }));
    expect(rename).toHaveBeenCalledOnce();
  });

  it("stacks large instruments under a visually hidden title", () => {
    render(
      <SettingsPanel
        sections={[
          {
            id: "appearance",
            title: "",
            items: [
              {
                id: "custom-studio",
                title: "Custom theme",
                layout: "stack",
                control: { type: "custom", content: <div>Studio</div> },
              },
            ],
          },
        ]}
      />
    );

    const row = screen.getByText("Custom theme").closest('[data-slot="settings-row"]');
    const control = row?.querySelector('[data-slot="settings-control"]');
    expect(
      screen.queryByRole("heading", { level: 2, name: "Custom theme" })
    ).toBeNull();
    expect(screen.getByRole("region", { name: "Custom theme" })).toBeInTheDocument();
    expect(screen.getByText("Custom theme")).toHaveClass("sr-only");
    expect(row).toHaveClass("flex-col", "w-full");
    expect(control).toHaveClass("w-full");
  });
});
