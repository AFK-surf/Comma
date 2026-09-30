import { act, fireEvent, render, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { afterEach, describe, expect, it } from "vitest";
import { StatusIndicator, statusIds, type StatusId } from "../StatusIndicator";
import { StatusIndicatorPreview } from "../StatusIndicatorPreview";

describe("StatusIndicator Storybook integration", () => {
  afterEach(() => {
    document.documentElement.removeAttribute("data-comma-reduced-motion");
  });

  it("renders the Comma statuses with Iconists Central Icons and Storybook tokens", async () => {
    const { container } = render(<StatusIndicatorPreview value="backlog" />);
    // The element registers lazily on first mount.
    await waitFor(() => {
      expect(container.querySelector("status-indicator")).not.toBeNull();
    });
    await waitFor(() => {
      expect(
        container
          .querySelector<HTMLElement>("status-indicator")
          ?.shadowRoot?.querySelectorAll('[role="radio"]')
      ).toHaveLength(5);
    });
    const indicator = container.querySelector<HTMLElement>("status-indicator");

    const icons = indicator?.shadowRoot?.querySelectorAll(".icon svg");
    expect(icons).toHaveLength(5);
    for (const icon of icons ?? []) {
      expect(icon.querySelector("path")).toHaveAttribute("stroke-width", "2");
    }
    expect(indicator?.shadowRoot?.querySelector(".glyph--spin")).toBeNull();
    expect(indicator?.shadowRoot?.querySelector("path.check")).toBeNull();
    expect(indicator?.style.getPropertyValue("--si-pill-bg")).toBe(
      "var(--color-bg-quaternary)"
    );
    expect(indicator?.style.getPropertyValue("--si-dot-hover-bg")).toBe(
      "var(--color-bg-quaternary)"
    );
    expect(indicator?.style.getPropertyValue("--si-label")).toBe(
      "var(--color-text-primary)"
    );
    expect(indicator?.style.getPropertyValue("--si-focus-ring")).toBe(
      "var(--color-fg-primary)"
    );

    const user = userEvent.setup();
    const selectedStatus = indicator?.shadowRoot?.querySelector<HTMLButtonElement>(
      '[role="radio"][aria-checked="true"]'
    );

    act(() => {
      selectedStatus?.focus();
    });
    await user.keyboard("{End}");
    expect(indicator).toHaveAttribute("value", "cancel");
    expect(
      indicator?.shadowRoot?.querySelector('[role="radio"][aria-checked="true"]')
    ).toHaveTextContent("Cancel");

    await user.keyboard("{Home}");
    expect(indicator).toHaveAttribute("value", "backlog");
    expect(
      indicator?.shadowRoot?.querySelector('[role="radio"][aria-checked="true"]')
    ).toHaveTextContent("Backlog");

    const finalSelectedStatus = indicator?.shadowRoot?.querySelector<HTMLButtonElement>(
      '[role="radio"][aria-checked="true"]'
    );
    expect(indicator?.shadowRoot?.activeElement).toBe(finalSelectedStatus);
    act(() => {
      finalSelectedStatus?.blur();
    });
    expect(indicator?.shadowRoot?.activeElement).toBeNull();
  });

  it("snaps Shadow DOM motion to its final state when Comma reduces motion", async () => {
    const { container } = render(<StatusIndicatorPreview value="backlog" />);
    await waitFor(() => {
      expect(
        container
          .querySelector<HTMLElement>("status-indicator")
          ?.shadowRoot?.querySelectorAll('[role="radio"]')
      ).toHaveLength(5);
    });
    const indicator = container.querySelector<HTMLElement>("status-indicator");
    document.documentElement.setAttribute("data-comma-reduced-motion", "true");

    await waitFor(() => {
      expect(
        indicator?.shadowRoot?.querySelector("style[data-comma-reduced-motion]")
      ).toHaveTextContent(".glyph--spin svg");
    });

    const items =
      indicator?.shadowRoot?.querySelectorAll<HTMLElement>('[role="radio"]');
    const selectedWidth = items?.[0]?.style.width;
    expect(selectedWidth).toBeTruthy();

    const user = userEvent.setup();
    act(() => {
      items?.[0]?.focus();
    });
    await user.keyboard("{End}");

    expect(items?.[4]).toHaveAttribute("aria-checked", "true");
    expect(items?.[4]?.style.width).toBe(selectedWidth);
    expect(items?.[0]?.style.width).not.toBe(selectedWidth);
  });

  it("snaps a controlled value update when Comma reduces motion", async () => {
    document.documentElement.setAttribute("data-comma-reduced-motion", "true");
    const { container, rerender } = render(<StatusIndicatorPreview value="backlog" />);
    await waitFor(() => {
      const lazyIndicator = container.querySelector<HTMLElement>("status-indicator");
      expect(
        lazyIndicator?.shadowRoot?.querySelectorAll('[role="radio"]')
      ).toHaveLength(5);
      expect(
        lazyIndicator?.shadowRoot?.querySelector("style[data-comma-reduced-motion]")
      ).toBeInTheDocument();
    });
    const indicator = container.querySelector<HTMLElement>("status-indicator");

    const items =
      indicator?.shadowRoot?.querySelectorAll<HTMLElement>('[role="radio"]');
    const selectedWidth = items?.[0]?.style.width;
    expect(selectedWidth).toBeTruthy();

    rerender(<StatusIndicatorPreview value="cancel" />);

    await waitFor(() => {
      expect(items?.[4]).toHaveAttribute("aria-checked", "true");
      expect(items?.[4]?.style.width).toBe(selectedWidth);
      expect(items?.[0]?.style.width).not.toBe(selectedWidth);
    });
  });

  it("maps Option plus the physical number keys to statuses without moving focus", async () => {
    const changes: StatusId[] = [];

    function ShortcutHarness() {
      const [value, setValue] = useState<StatusId>("cancel");
      return (
        <>
          <input aria-label="Composer" defaultValue="Keep typing here" />
          <StatusIndicator
            onChange={(nextValue) => {
              changes.push(nextValue);
              setValue(nextValue);
            }}
            value={value}
          />
        </>
      );
    }

    const { container, getByRole } = render(<ShortcutHarness />);
    await waitFor(() => {
      expect(
        container
          .querySelector<HTMLElement>("status-indicator")
          ?.shadowRoot?.querySelectorAll('[role="radio"]')
      ).toHaveLength(5);
    });
    const indicator = container.querySelector<HTMLElement>("status-indicator");
    const statuses =
      indicator?.shadowRoot?.querySelectorAll<HTMLElement>('[role="radio"]');
    statusIds.forEach((_, index) => {
      expect(statuses?.[index]).toHaveAttribute(
        "aria-keyshortcuts",
        `Alt+${index + 1}`
      );
    });

    const composer = getByRole("textbox", { name: "Composer" });
    composer.focus();

    for (const [index, expectedStatus] of statusIds.entries()) {
      const accepted = fireEvent.keyDown(window, {
        altKey: true,
        code: `Digit${index + 1}`,
        // macOS Option changes event.key for several digits; code stays stable.
        key: index === 0 ? "¡" : String(index + 1),
      });
      expect(accepted).toBe(false);
      await waitFor(() => {
        expect(indicator).toHaveAttribute("value", expectedStatus);
      });
      expect(document.activeElement).toBe(composer);
    }

    expect(changes).toEqual(statusIds);
    fireEvent.keyDown(window, {
      altKey: true,
      code: "Digit1",
      key: "¡",
      shiftKey: true,
    });
    expect(indicator).toHaveAttribute("value", "cancel");
    expect(changes).toEqual(statusIds);
  });
});
