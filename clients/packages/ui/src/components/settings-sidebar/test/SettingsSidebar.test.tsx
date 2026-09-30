import userEvent from "@testing-library/user-event";
import { render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { SettingsIcon } from "../../icons";
import { SettingsSidebar } from "../SettingsSidebar";

/** Three categories of a tab row, with one of them selected. */
const tabRowItems = (selectedId: string) =>
  ["general", "profile", "usage-billing"].map((id) => ({
    href: `#/settings?category=${id}`,
    icon: <SettingsIcon className="size-5" />,
    id,
    label: id,
    selected: id === selectedId,
  }));

describe("SettingsSidebar", () => {
  it("marks the selected settings section", () => {
    render(
      <SettingsSidebar
        ariaLabel="Settings sections"
        items={[
          {
            href: "#/settings",
            icon: <SettingsIcon className="size-5" />,
            id: "general",
            label: "General",
            selected: true,
          },
        ]}
        searchAriaLabel="Search settings"
        searchPlaceholder="Search settings"
        title="Settings"
      />
    );

    expect(
      screen.getByRole("complementary", { name: "Settings sections" })
    ).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Back to app" })).toBeNull();
    const searchbox = screen.getByRole("searchbox", {
      name: "Search settings",
    });
    expect(searchbox).toBeInTheDocument();
    expect(searchbox.closest("form")).toHaveClass("mb-xl", "px-none");
    expect(searchbox.closest("form")).not.toHaveClass("px-md");
    expect(screen.getByRole("link", { name: "General" })).toHaveAttribute(
      "aria-current",
      "page"
    );
  });

  it("brings the selected tab into view in the tab row", () => {
    const scrollIntoView = vi
      .spyOn(Element.prototype, "scrollIntoView")
      .mockImplementation(() => {});
    const { rerender } = render(
      <SettingsSidebar
        ariaLabel="Settings sections"
        items={tabRowItems("usage-billing")}
        layout="tabs"
        title="Settings"
      />
    );

    // A category selected past the row's end scrolls to itself on first paint.
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    expect(scrollIntoView.mock.contexts[0]).toBe(
      screen.getByRole("button", { name: "usage-billing" })
    );
    expect(scrollIntoView).toHaveBeenLastCalledWith({
      block: "nearest",
      inline: "nearest",
    });

    // So does the next category to become selected; nothing else scrolls.
    rerender(
      <SettingsSidebar
        ariaLabel="Settings sections"
        items={tabRowItems("profile")}
        layout="tabs"
        title="Settings"
      />
    );
    expect(scrollIntoView).toHaveBeenCalledTimes(2);
    expect(scrollIntoView.mock.contexts[1]).toBe(
      screen.getByRole("button", { name: "profile" })
    );
    scrollIntoView.mockRestore();
  });

  it("renders search results as regular-weight grouped items", async () => {
    const onPress = vi.fn();
    render(
      <SettingsSidebar
        ariaLabel="Settings sections"
        groups={[
          {
            id: "application",
            label: "Application",
            items: [
              {
                id: "general",
                label: "General",
                onPress: vi.fn(),
              },
            ],
          },
        ]}
        searchAriaLabel="Search settings"
        searchGroups={[
          {
            id: "application",
            label: "General",
            items: [
              {
                context: "Language for the app UI",
                id: "app.language",
                onPress,
                title: "Language",
              },
            ],
          },
          {
            id: "system",
            label: "Devices · Locale",
            items: [
              {
                context: "Language used by this device",
                id: "device.language",
                onPress: vi.fn(),
                title: "Device language",
              },
            ],
          },
        ]}
        searchValue="lang"
      />
    );

    expect(screen.getByText("General")).toBeInTheDocument();
    expect(screen.getByText("Devices · Locale")).toBeInTheDocument();
    const result = screen.getByRole("button", {
      name: /Language.*Language for the app UI/,
    });
    expect(result.querySelector("mark")).toBeNull();
    expect(screen.getByText("Language")).not.toHaveClass("font-semibold");

    await userEvent.click(result);
    expect(onPress).toHaveBeenCalledOnce();
  });

  it("renders the search empty state in the sidebar", () => {
    render(
      <SettingsSidebar
        searchEmptyDescription="Try another keyword."
        searchEmptyTitle="No settings found"
        searchGroups={[]}
        searchValue="missing"
      />
    );

    expect(screen.getByText("No settings found")).toBeInTheDocument();
    expect(screen.getByText("Try another keyword.")).toBeInTheDocument();
  });
});
