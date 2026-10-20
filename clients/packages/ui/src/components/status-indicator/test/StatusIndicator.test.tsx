import { act, fireEvent, render, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { useState, type ReactElement } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  loadStatusIndicatorElement,
  StatusIndicator,
  statusIds,
  type StatusId,
} from "../StatusIndicator";
import { StatusIndicatorPreview } from "../StatusIndicatorPreview";

function stubPlatform(platform: "MacIntel" | "Win32") {
  vi.stubGlobal("navigator", {
    ...navigator,
    platform,
    userAgent: platform === "MacIntel" ? "Macintosh" : "Windows NT 10.0",
    userAgentData: undefined,
  });
}

/**
 * Renders, then waits for the element to register. It registers on a dynamic
 * import at first mount: real I/O that the test clock does not move, so the
 * test awaits the import the mounted indicator awaits.
 */
async function renderLoaded(ui: ReactElement) {
  const view = render(ui);
  await act(() => loadStatusIndicatorElement());
  return view;
}

async function renderShortcutHarness() {
  const changes: StatusId[] = [];

  function ShortcutHarness() {
    const [value, setValue] = useState<StatusId>("cancel");
    return (
      <>
        <input aria-label="Composer" defaultValue="Keep typing here" />
        <button type="button">Elsewhere</button>
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

  const view = await renderLoaded(<ShortcutHarness />);
  await waitFor(() => {
    expect(
      view.container
        .querySelector<HTMLElement>("status-indicator")
        ?.shadowRoot?.querySelectorAll('[role="radio"]')
    ).toHaveLength(4);
  });
  const indicator = view.container.querySelector<HTMLElement>("status-indicator");
  return { changes, getByRole: view.getByRole, indicator };
}

describe("StatusIndicator Storybook integration", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    document.documentElement.removeAttribute("data-comma-reduced-motion");
  });

  it("renders the Comma statuses with Iconists Central Icons and Storybook tokens", async () => {
    const { container } = await renderLoaded(
      <StatusIndicatorPreview value="in-progress" />
    );
    await waitFor(() => {
      expect(container.querySelector("status-indicator")).not.toBeNull();
    });
    await waitFor(() => {
      expect(
        container
          .querySelector<HTMLElement>("status-indicator")
          ?.shadowRoot?.querySelectorAll('[role="radio"]')
      ).toHaveLength(4);
    });
    const indicator = container.querySelector<HTMLElement>("status-indicator");

    const icons = indicator?.shadowRoot?.querySelectorAll(".icon svg");
    expect(icons).toHaveLength(4);
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
    expect(indicator).toHaveAttribute("value", "in-progress");
    expect(
      indicator?.shadowRoot?.querySelector('[role="radio"][aria-checked="true"]')
    ).toHaveTextContent("In progress");

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
    const { container } = await renderLoaded(
      <StatusIndicatorPreview value="in-progress" />
    );
    await waitFor(() => {
      expect(
        container
          .querySelector<HTMLElement>("status-indicator")
          ?.shadowRoot?.querySelectorAll('[role="radio"]')
      ).toHaveLength(4);
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

    expect(items?.[3]).toHaveAttribute("aria-checked", "true");
    expect(items?.[3]?.style.width).toBe(selectedWidth);
    expect(items?.[0]?.style.width).not.toBe(selectedWidth);
  });

  it("snaps a controlled value update when Comma reduces motion", async () => {
    document.documentElement.setAttribute("data-comma-reduced-motion", "true");
    const { container, rerender } = await renderLoaded(
      <StatusIndicatorPreview value="in-progress" />
    );
    await waitFor(() => {
      const lazyIndicator = container.querySelector<HTMLElement>("status-indicator");
      expect(
        lazyIndicator?.shadowRoot?.querySelectorAll('[role="radio"]')
      ).toHaveLength(4);
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
      expect(items?.[3]).toHaveAttribute("aria-checked", "true");
      expect(items?.[3]?.style.width).toBe(selectedWidth);
      expect(items?.[0]?.style.width).not.toBe(selectedWidth);
    });
  });

  it("maps Option plus the physical number keys to statuses without moving focus", async () => {
    const { changes, getByRole, indicator } = await renderShortcutHarness();
    const statuses =
      indicator?.shadowRoot?.querySelectorAll<HTMLElement>('[role="radio"]');
    statusIds.forEach((_, index) => {
      expect(statuses?.[index]).toHaveAttribute(
        "aria-keyshortcuts",
        `Alt+${index + 1}`
      );
    });

    const elsewhere = getByRole("button", { name: "Elsewhere" });
    elsewhere.focus();

    for (const [index, expectedStatus] of statusIds.entries()) {
      const accepted = fireEvent.keyDown(elsewhere, {
        altKey: true,
        code: `Digit${index + 1}`,
        // macOS Option changes event.key for several digits; code stays stable.
        key: index === 0 ? "¡" : String(index + 1),
      });
      expect(accepted).toBe(false);
      await waitFor(() => {
        expect(indicator).toHaveAttribute("value", expectedStatus);
      });
      expect(document.activeElement).toBe(elsewhere);
    }

    expect(changes).toEqual(statusIds);
    fireEvent.keyDown(elsewhere, {
      altKey: true,
      code: "Digit1",
      key: "¡",
      shiftKey: true,
    });
    expect(indicator).toHaveAttribute("value", "cancel");
    expect(changes).toEqual(statusIds);
  });

  it("leaves Option plus a digit to a text field where it types a character", async () => {
    stubPlatform("MacIntel");
    const { changes, getByRole, indicator } = await renderShortcutHarness();
    const composer = getByRole("textbox", { name: "Composer" });
    composer.focus();

    // On a Swedish Mac, Option+2 types "@": the field keeps the key.
    expect(
      fireEvent.keyDown(composer, { altKey: true, code: "Digit2", key: "@" })
    ).toBe(true);
    expect(indicator).toHaveAttribute("value", "cancel");
    expect(changes).toEqual([]);

    // Where Option with a digit reports the digit itself, the shortcut
    // still runs from the field.
    expect(
      fireEvent.keyDown(composer, { altKey: true, code: "Digit1", key: "1" })
    ).toBe(false);
    await waitFor(() => {
      expect(indicator).toHaveAttribute("value", "in-progress");
    });
    expect(document.activeElement).toBe(composer);
    expect(changes).toEqual(["in-progress"]);

    // A German closing quote stays with the field.
    expect(
      fireEvent.keyDown(composer, { altKey: true, code: "Digit2", key: "“" })
    ).toBe(true);
    expect(changes).toEqual(["in-progress"]);

    // A dead key stays with the field too.
    expect(
      fireEvent.keyDown(composer, { altKey: true, code: "Digit3", key: "Dead" })
    ).toBe(true);
    expect(changes).toEqual(["in-progress"]);
  });

  it("keeps Option plus a digit as the shortcut in a text field where it types a rare symbol", async () => {
    stubPlatform("MacIntel");
    const { changes, getByRole, indicator } = await renderShortcutHarness();
    const composer = getByRole("textbox", { name: "Composer" });
    composer.focus();

    // On a US Mac, Option+2 types "™": the shortcut wins.
    expect(
      fireEvent.keyDown(composer, { altKey: true, code: "Digit2", key: "™" })
    ).toBe(false);
    await waitFor(() => {
      expect(indicator).toHaveAttribute("value", "needs-review");
    });
    expect(document.activeElement).toBe(composer);
    expect(changes).toEqual(["needs-review"]);
  });

  it("keeps Alt plus a digit as the shortcut in a text field outside macOS", async () => {
    stubPlatform("Win32");
    const { changes, getByRole, indicator } = await renderShortcutHarness();
    const composer = getByRole("textbox", { name: "Composer" });
    composer.focus();

    // On French AZERTY, event.key for Digit1 is "&", but Alt+1 types nothing
    // on Windows and Linux: the shortcut wins.
    expect(
      fireEvent.keyDown(composer, { altKey: true, code: "Digit1", key: "&" })
    ).toBe(false);
    await waitFor(() => {
      expect(indicator).toHaveAttribute("value", "in-progress");
    });
    expect(document.activeElement).toBe(composer);
    expect(changes).toEqual(["in-progress"]);
  });
});
