import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import { LEFT_RAIL_WIDTH, LeftRail, LeftRailItemControl } from "../LeftRail";

describe("LeftRail", () => {
  it("renders the default items and marks the selected one as current", () => {
    render(<LeftRail />);

    const nav = screen.getByRole("navigation", { name: "Primary" });
    expect(nav).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Home" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(screen.getByRole("button", { name: "Inbox" })).not.toHaveAttribute(
      "aria-current"
    );
    const settings = screen.getByRole("button", { name: "Settings" });
    expect(settings).toHaveAttribute("data-slot", "left-rail-item");
    expect(settings).not.toHaveAttribute("aria-current");
    expect(screen.getByRole("complementary").lastElementChild).toBe(settings);
    expect(screen.getByRole("complementary")).toHaveStyle({
      width: `${LEFT_RAIL_WIDTH}px`,
    });
  });

  it("paints the selected state on the icon slot and the label's colour", () => {
    render(
      <LeftRailItemControl
        item={{ icon: <svg />, id: "home", label: "Home", selected: true }}
      />
    );

    const item = screen.getByRole("button", { name: "Home" });
    const icon = item.querySelector('[data-slot="left-rail-item-icon"]');
    const label = item.querySelector('[data-slot="left-rail-item-label"]');

    expect(item).toHaveAttribute("data-selected", "true");
    expect(icon).toHaveClass("bg-sidebar-bg-item");
    // Only the icon carries the fill; the label marks the item with its colour.
    expect(label).toHaveClass("text-sidebar-text-highlight");
    expect(label).not.toHaveClass("bg-sidebar-bg-item");
  });

  it("keeps an unselected label at its resting colour", () => {
    render(
      <LeftRailItemControl item={{ icon: <svg />, id: "inbox", label: "Inbox" }} />
    );

    const label = screen
      .getByRole("button", { name: "Inbox" })
      .querySelector('[data-slot="left-rail-item-label"]');

    expect(label).toHaveClass("text-quaternary");
  });

  it("renders linked items as anchors and forwards presses", async () => {
    const onPress = vi.fn();
    render(
      <LeftRailItemControl
        item={{ href: "#/inbox", icon: <svg />, id: "inbox", label: "Inbox", onPress }}
      />
    );

    const link = screen.getByRole("link", { name: "Inbox" });
    expect(link).toHaveAttribute("href", "#/inbox");
    expect(link).toHaveAttribute("data-slot", "left-rail-item");
    expect(link).not.toHaveAttribute("aria-current");

    await userEvent.click(link);

    expect(onPress).toHaveBeenCalledTimes(1);
  });

  it("paints an unread badge on the icon slot when asked", () => {
    render(
      <LeftRailItemControl
        item={{ badge: true, icon: <svg />, id: "inbox", label: "Inbox" }}
      />
    );

    const item = screen.getByRole("button", { name: "Inbox" });
    const icon = item.querySelector<HTMLElement>('[data-slot="left-rail-item-icon"]');
    const badge = item.querySelector<HTMLElement>('[data-slot="left-rail-item-badge"]');

    expect(badge).not.toBeNull();
    expect(icon).toContainElement(badge);
  });

  it("omits the unread badge until asked", () => {
    render(
      <LeftRailItemControl item={{ icon: <svg />, id: "inbox", label: "Inbox" }} />
    );

    expect(
      screen
        .getByRole("button", { name: "Inbox" })
        .querySelector('[data-slot="left-rail-item-badge"]')
    ).toBeNull();
  });
});
