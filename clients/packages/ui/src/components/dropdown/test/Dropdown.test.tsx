import { useState } from "react";
import userEvent from "@testing-library/user-event";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { Dropdown } from "../Dropdown";
import {
  constrainSelectPopoverOffsetToViewportTop,
  countSeparatorsThroughIndex,
  getAnchoredPopoverOffset,
  getSelectPopoverOffset,
  getSelectionAlignedPopoverLayout,
  getSelectionAlignedPopoverOffset,
  getSelectPopoverVerticalSubpixelCorrection,
  isSelectPopoverViewportConstrained,
  readOverlaySafeTopPx,
  selectItemHeight,
  selectRowHeightClassName,
  selectSeparatorHeight,
} from "../select-primitives";

const items = [
  { id: "system", label: "Auto detect" },
  { id: "en", label: "English" },
  { id: "zh-CN", label: "Simplified Chinese" },
];

const ContentWidthDropdown = () => {
  const [value, setValue] = useState("system");

  return (
    <Dropdown
      items={items}
      onChange={setValue}
      placeholder="Select language"
      size="sm"
      value={value}
      width="content"
    />
  );
};

describe("Dropdown", () => {
  it("describes same-name options with subtitles while keeping the trigger label short", async () => {
    const onChange = vi.fn();
    render(
      <Dropdown
        ariaLabel="Model"
        value="us"
        onChange={onChange}
        items={[
          { id: "us", label: "Shared model", subtitle: "US endpoint" },
          { id: "eu", label: "Shared model", subtitle: "EU endpoint" },
          { id: "unique", label: "Unique model" },
        ]}
      />
    );
    const trigger = screen.getByRole("button", { name: /Model$/ });
    expect(trigger).toHaveTextContent("Shared model");
    expect(trigger).not.toHaveTextContent("US endpoint");
    await userEvent.click(trigger);
    const choices = screen.getAllByRole("option", {
      name: "Shared model",
    });
    expect(choices[0]).toHaveAccessibleDescription("US endpoint");
    expect(choices[1]).toHaveAccessibleDescription("EU endpoint");
    expect(screen.getByRole("option", { name: "Unique model" })).not.toHaveAttribute(
      "aria-describedby"
    );
    await userEvent.click(choices[1]!);
    expect(onChange).toHaveBeenCalledWith("eu");
  });

  it("keeps compact triggers and selection-aligned options on the same 32px row", async () => {
    render(
      <Dropdown
        contentAlign="end"
        items={items}
        placeholder="Select language"
        size="xs"
        value="system"
        width="content"
      />
    );

    const trigger = screen.getByRole("button", { name: /Select language/ });
    expect(selectItemHeight.xs).toBe(32);
    expect(trigger).toHaveClass(selectRowHeightClassName.xs);
    expect(trigger.querySelector('[data-slot="dropdown-row-label"]')).toHaveClass(
      "text-end"
    );

    await userEvent.click(trigger);

    const popover = screen
      .getByRole("listbox")
      .closest('[data-slot="dropdown-popover"]');
    expect(popover).toHaveAttribute("data-animation", "in-place");
    expect(popover).not.toHaveClass("transition-opacity");

    expect(
      screen
        .getByRole("option", { name: "Auto detect" })
        .querySelector('[data-slot="dropdown-option-content"]')
    ).toHaveClass(selectRowHeightClassName.xs, "rounded-sm", "px-md");
    expect(screen.getByRole("option", { name: "Auto detect" })).toHaveClass("px-sm");
    expect(
      screen
        .getByRole("option", { name: "Auto detect" })
        .querySelector('[data-slot="dropdown-row-label"]')
    ).toHaveClass("text-end");
    expect(getSelectPopoverOffset("xs", 1) - getSelectPopoverOffset("xs", 0)).toBe(
      -selectItemHeight.xs
    );
  });

  it("derives the trigger's document-space subpixel correction", () => {
    expect(getSelectPopoverVerticalSubpixelCorrection(167.75)).toBe(0.75);
    expect(getSelectPopoverVerticalSubpixelCorrection(168)).toBe(0);
  });

  it("reads the overlay safe-top custom property from the trigger", () => {
    const trigger = document.createElement("button");
    trigger.style.setProperty("--comma-overlay-safe-top", "2.75rem");
    document.body.append(trigger);
    expect(readOverlaySafeTopPx(trigger)).toBe(44);
    trigger.remove();
  });

  it("fits the subpixel correction inside the content padding budget", async () => {
    render(<ContentWidthDropdown />);

    const trigger = screen.getByRole("button", { name: /Select language/ });
    trigger.getBoundingClientRect = () =>
      ({
        bottom: 77.25,
        height: 36,
        left: 0,
        right: 134,
        top: 41.25,
        width: 134,
        x: 0,
        y: 41.25,
        toJSON: () => ({}),
      }) as DOMRect;

    await userEvent.click(trigger);

    const content = document.querySelector<HTMLElement>(
      '[data-slot="scroll-area-content"]'
    );
    expect(content?.style.position).toBe("");
    expect(content?.style.top).toBe("");
    expect(content?.style.paddingTop).toBe("4.25px");
    expect(content?.style.paddingBottom).toBe("3.75px");
    expect(
      Number.parseFloat(content?.style.paddingTop ?? "0") +
        Number.parseFloat(content?.style.paddingBottom ?? "0")
    ).toBe(8);
    expect(
      document.querySelector<HTMLElement>('[data-slot="dropdown-popover"]')?.style
        .translate
    ).toBe("");
  });

  it("keeps the menu open when the opening press ends over the selected row", async () => {
    const user = userEvent.setup();
    render(<ContentWidthDropdown />);

    const trigger = screen.getByRole("button", { name: /Select language/ });

    await user.click(trigger);
    const selectedOption = screen.getByRole("option", { name: "Auto detect" });
    fireEvent.pointerUp(selectedOption, {
      button: 0,
      isPrimary: true,
      pointerId: 1,
      pointerType: "mouse",
    });

    expect(trigger).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("listbox")).toBeInTheDocument();
    expect(trigger).toHaveTextContent("Auto detect");
  });

  it("dismisses Escape during a focus gap without changing the selection", async () => {
    const user = userEvent.setup();
    render(<ContentWidthDropdown />);
    const trigger = screen.getByRole("button", { name: /Select language/ });

    await user.click(trigger);
    // A reopened popover can temporarily leave focus on the document body.
    fireEvent.keyDown(document.body, { key: "Escape" });
    expect(trigger).toHaveAttribute("aria-expanded", "false");
    expect(trigger).toHaveTextContent("Auto detect");

    await user.click(trigger);
    await user.click(screen.getByRole("option", { name: "English" }));
    expect(trigger).toHaveAttribute("aria-expanded", "false");
    expect(trigger).toHaveTextContent("English");
  });

  it("commits pointer selection after the complete option press", async () => {
    const user = userEvent.setup();
    render(<ContentWidthDropdown />);

    const trigger = screen.getByRole("button", { name: /Select language/ });
    await user.click(trigger);
    const option = screen.getByRole("option", { name: "English" });

    await user.pointer({ keys: "[MouseLeft>]", target: option });
    expect(trigger).toHaveTextContent("Auto detect");
    expect(trigger).toHaveAttribute("aria-expanded", "true");

    await user.pointer({ keys: "[/MouseLeft]", target: option });
    expect(trigger).toHaveTextContent("English");
    expect(trigger).toHaveAttribute("aria-expanded", "false");
  });

  it("measures its trigger only to place an open menu", async () => {
    const { rerender } = render(
      <Dropdown ariaLabel="Language" items={items} onChange={vi.fn()} value="system" />
    );
    const trigger = screen.getByRole("button", { name: /Language$/ });
    const measure = vi.spyOn(trigger, "getBoundingClientRect");

    // A Settings page re-renders its closed selects whenever any of its state
    // moves; a layout read there forces a synchronous reflow per select.
    rerender(
      <Dropdown ariaLabel="Language" items={items} onChange={vi.fn()} value="en" />
    );
    expect(measure).not.toHaveBeenCalled();

    await userEvent.click(trigger);
    expect(screen.getByRole("listbox")).toBeVisible();
    expect(measure).toHaveBeenCalled();
  });

  it("sizes content fully and anchors the menu to the selected option", async () => {
    render(<ContentWidthDropdown />);

    const trigger = screen.getByRole("button", { name: /Select language/ });
    const dropdown = trigger.closest('[data-slot="dropdown"]');

    expect(dropdown).toHaveAttribute("data-width", "content");
    expect(dropdown).toHaveClass("w-fit");
    expect(dropdown).not.toHaveClass("w-80");
    expect(trigger).toHaveClass("w-fit", "max-w-full");
    expect(trigger).toHaveTextContent("Auto detect");
    trigger.getBoundingClientRect = () =>
      ({
        bottom: 236,
        height: 36,
        left: 200,
        right: 334,
        top: 200,
        width: 134,
        x: 200,
        y: 200,
        toJSON: () => ({}),
      }) as DOMRect;

    await userEvent.click(trigger);

    const popover = document.querySelector('[data-slot="dropdown-popover"]');
    const selectedOption = screen.getByRole("option", { name: "Auto detect" });
    const selectedContent = selectedOption.querySelector(
      '[data-slot="dropdown-option-content"]'
    );

    expect(trigger).toHaveClass(selectRowHeightClassName.sm, "pointer-events-none");
    expect(trigger).toHaveClass("opacity-0");
    expect(trigger.querySelector('[data-comma-icon=""]')).not.toHaveClass("rotate-180");
    expect(trigger.querySelector('[data-slot="dropdown-row-content"]')).toHaveClass(
      "w-full",
      "gap-md"
    );
    expect(trigger.querySelector('[data-slot="dropdown-row-leading"]')).toBeNull();
    expect(trigger.querySelector('[data-slot="dropdown-row-label"]')).toHaveClass(
      "min-w-0",
      "overflow-hidden",
      "flex-auto"
    );
    expect(trigger.querySelector('[data-slot="dropdown-row-label"]')).not.toHaveClass(
      "flex-none"
    );
    expect(trigger.querySelector('[data-slot="dropdown-trigger-label"]')).toHaveClass(
      "truncate",
      "whitespace-nowrap"
    );
    expect(selectedContent).toHaveClass(selectRowHeightClassName.sm);
    expect(selectedContent).not.toHaveClass("font-medium", "bg-secondary");
    expect(
      selectedContent?.querySelector('[data-slot="dropdown-row-content"]')
    ).toHaveClass("w-full", "gap-md");
    expect(trigger.querySelector('[data-slot="dropdown-row-indicator"]')).toHaveClass(
      "size-5"
    );
    expect(
      selectedContent?.querySelector('[data-slot="dropdown-row-indicator"]')
    ).toHaveClass("size-5");
    expect(selectedContent?.querySelector('[data-comma-icon=""]')).toHaveClass(
      "size-5"
    );
    expect(popover).toHaveClass(
      "z-50",
      "w-max",
      "min-w-[var(--trigger-width)]",
      "border-primary",
      "bg-primary",
      "[-webkit-app-region:no-drag]"
    );
    expect(popover).not.toHaveClass("animate-in", "animate-out", "fade-in");
    expect(popover).toHaveAttribute("data-anchor-index", "0");
    expect(popover).toHaveAttribute("data-positioning", "selection-aligned");
    expect(popover).not.toHaveAttribute("data-viewport-constrained");
    expect(popover?.querySelector('[data-slot="scroll-area"]')).toHaveAttribute(
      "data-edge-effect",
      "blur"
    );
    // A long list can open scrolled to its checked row, so a clipped top
    // blurs like a clipped bottom.
    const scrollAreaStyle = popover?.querySelector<HTMLElement>(
      '[data-slot="scroll-area"]'
    )?.style;
    expect(
      scrollAreaStyle?.getPropertyValue("--scroll-area-edge-blur-target-start-size")
    ).toBe(
      scrollAreaStyle?.getPropertyValue("--scroll-area-edge-blur-target-end-size")
    );
    expect(
      screen
        .getByRole("option", { name: "Simplified Chinese" })
        .querySelector('[data-slot="dropdown-option-label"]')
    ).toHaveClass("whitespace-nowrap");
    expect(
      screen
        .getByRole("option", { name: "Simplified Chinese" })
        .querySelector('[data-slot="dropdown-option-label"]')
    ).not.toHaveClass("truncate");

    await userEvent.click(screen.getByRole("option", { name: "English" }));
    expect(trigger).toHaveTextContent("English");

    await userEvent.click(trigger);
    expect(document.querySelector('[data-slot="dropdown-popover"]')).toHaveAttribute(
      "data-anchor-index",
      "1"
    );
    const englishOption = screen.getByRole("option", { name: "English" });
    expect(englishOption).toHaveAttribute("data-selected", "true");
    expect(englishOption.querySelector('[data-comma-icon=""]')).toHaveClass("size-5");
    expect(
      screen
        .getByRole("option", { name: "Auto detect" })
        .querySelector('[data-comma-icon=""]')
    ).not.toBeNull();
    expect(
      screen
        .getByRole("option", { name: "Auto detect" })
        .querySelector('[data-comma-icon=""]')
    ).toHaveClass("opacity-0", "blur-[4px]", "scale-[0.25]");
    expect(getSelectPopoverOffset("sm", 1) - getSelectPopoverOffset("sm", 0)).toBe(
      -selectItemHeight.sm
    );
  });

  it("centers the anchor row over triggers of any height", () => {
    // Equal trigger and row heights collapse to the classic select offset.
    expect(getAnchoredPopoverOffset({ anchorIndex: 2, rowHeight: 36 })).toBe(
      getSelectPopoverOffset("sm", 2, 36)
    );
    // A short trigger anchors on row centers: -( (24+32)/2 + 32 + 4 + 1 ).
    expect(
      getAnchoredPopoverOffset({ anchorIndex: 1, rowHeight: 32, triggerHeight: 24 })
    ).toBe(-65);
    // The popover chrome's border width enters the math.
    expect(
      getAnchoredPopoverOffset({
        anchorIndex: 0,
        chromeBorderWidth: 0.5,
        rowHeight: 32,
      })
    ).toBe(-36.5);
  });

  it("detects when selection alignment would leave the viewport", () => {
    expect(
      isSelectPopoverViewportConstrained({
        size: "sm",
        selectedIndex: 2,
        itemCount: 5,
        triggerTop: 470,
        viewportHeight: 550,
      })
    ).toBe(true);
    expect(selectItemHeight.sm).toBe(36);
    expect(getSelectPopoverOffset("sm", 2)).toBe(-113);
    expect(selectSeparatorHeight).toBe(8.5);
    expect(
      countSeparatorsThroughIndex(
        [{}, { separatorBefore: true }, { separatorBefore: true }],
        1
      )
    ).toBe(1);
    expect(getSelectPopoverOffset("sm", 1, 36, 1)).toBe(-85.5);
    expect(
      getSelectionAlignedPopoverOffset({
        items: [{}, { separatorBefore: true }, { separatorBefore: true }],
        selectedIndex: 1,
        trigger: null,
      })
    ).toBe(getSelectPopoverOffset("sm", 1, selectItemHeight.sm, 1));
    const unmeasuredLayout = getSelectionAlignedPopoverLayout({
      items: [{}],
      selectedIndex: 0,
      trigger: null,
    });
    expect(unmeasuredLayout.offset).toBe(getSelectPopoverOffset("sm", 0));
    expect(unmeasuredLayout.paddingTop).toBe(4);
    expect(unmeasuredLayout.paddingBottom).toBe(4);
    expect(unmeasuredLayout.maxHeight).toBe(Math.ceil(selectItemHeight.sm + 8 + 2) + 1);
    const fractionalTrigger = document.createElement("button");
    fractionalTrigger.getBoundingClientRect = () =>
      ({
        bottom: 77.25,
        height: 36,
        left: 0,
        right: 134,
        top: 41.25,
        width: 134,
        x: 0,
        y: 41.25,
        toJSON: () => ({}),
      }) as DOMRect;
    const fractionalLayout = getSelectionAlignedPopoverLayout({
      items: [{}],
      selectedIndex: 0,
      trigger: fractionalTrigger,
    });
    expect(fractionalLayout.paddingTop).toBe(4.25);
    expect(fractionalLayout.paddingBottom).toBe(3.75);
    expect(fractionalLayout.offset).toBe(getSelectPopoverOffset("sm", 0, 36));
    expect(
      isSelectPopoverViewportConstrained({
        size: "sm",
        selectedIndex: 1,
        itemCount: 3,
        triggerTop: 40,
        viewportHeight: 200,
        separatorCount: 2,
        separatorCountThroughAnchor: 1,
      })
    ).toBe(true);
    expect(
      getSelectPopoverOffset("sm", 19, 38) - getSelectPopoverOffset("sm", 18, 38)
    ).toBe(-38);
    expect(
      constrainSelectPopoverOffsetToViewportTop({
        offset: getSelectPopoverOffset("sm", 2),
        triggerHeight: 36,
        triggerTop: 12,
      })
    ).toBe(-36);
    expect(
      constrainSelectPopoverOffsetToViewportTop({
        offset: -300,
        triggerHeight: 36,
        triggerTop: 160,
        overlaySafeTop: 44,
      })
    ).toBe(-152);
    expect(
      isSelectPopoverViewportConstrained({
        size: "sm",
        selectedIndex: 8,
        itemCount: 9,
        triggerTop: 160,
        viewportHeight: 800,
        overlaySafeTop: 44,
      })
    ).toBe(true);
    expect(
      isSelectPopoverViewportConstrained({
        size: "sm",
        selectedIndex: 1,
        itemCount: 3,
        triggerTop: 200,
        viewportHeight: 550,
      })
    ).toBe(false);
  });

  it("expands the same selection-aligned surface immediately from its edge affordance", async () => {
    render(<ContentWidthDropdown />);

    const trigger = screen.getByRole("button", { name: /Select language/ });
    trigger.getBoundingClientRect = () =>
      ({
        bottom: 756,
        height: 36,
        left: 620,
        right: 754,
        top: 720,
        width: 134,
        x: 620,
        y: 720,
        toJSON: () => ({}),
      }) as DOMRect;

    await userEvent.click(trigger);

    const viewport = document.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    const popover = document.querySelector<HTMLElement>(
      '[data-slot="dropdown-popover"]'
    );
    const content = document.querySelector<HTMLElement>(
      '[data-slot="scroll-area-content"]'
    );
    const scrollDownHotArea = document.querySelector<HTMLElement>(
      '[data-slot="dropdown-scroll-down"]'
    );

    expect(viewport).not.toBeNull();
    expect(popover).not.toBeNull();
    expect(scrollDownHotArea).not.toBeNull();
    expect(trigger).toHaveClass("pointer-events-none", "opacity-0");
    expect(scrollDownHotArea).toHaveClass("absolute", "inset-x-0", "h-4xl");
    expect(
      scrollDownHotArea?.querySelector('[data-slot="dropdown-scroll-down-hit"]')
    ).toHaveClass("pointer-events-none");
    expect(scrollDownHotArea?.querySelector('[data-comma-icon=""]')).toHaveClass(
      "size-5"
    );

    expect(popover).toHaveAttribute("data-positioning", "selection-aligned");
    expect(popover).toHaveAttribute("data-viewport-constrained", "true");
    expect(popover).not.toHaveAttribute("data-content-expanded");
    expect(content?.style.paddingTop).toBe("4px");
    expect(content?.style.paddingBottom).toBe("4px");
    expect(popover?.querySelector('[data-slot="scroll-area"]')).toHaveAttribute(
      "data-edge-effect",
      "blur"
    );

    Object.defineProperty(viewport!, "clientHeight", {
      configurable: true,
      value: 72,
    });
    Object.defineProperty(viewport!, "scrollHeight", {
      configurable: true,
      value: 180,
    });
    viewport!.scrollTop = 24;
    popover!.getBoundingClientRect = () =>
      ({
        bottom: 272,
        height: 72,
        left: 620,
        right: 800,
        top: 200,
        width: 180,
        x: 620,
        y: 200,
        toJSON: () => ({}),
      }) as DOMRect;

    fireEvent.pointerMove(viewport!, {
      clientX: 710,
      clientY: 264,
    });

    expect(viewport?.scrollTop).toBe(0);
    expect(popover).toHaveAttribute("data-content-expanded", "true");
    expect(popover).toHaveAttribute("data-content-fully-expanded", "true");
    expect(popover).not.toHaveAttribute("data-scroll-fallback");
    expect(popover).toHaveAttribute("data-positioning", "selection-aligned");
    expect(popover?.querySelector('[data-slot="scroll-area"]')).toHaveAttribute(
      "data-edge-effect",
      "none"
    );
  });

  it("falls back to native scrolling when the remaining content cannot fit above", async () => {
    render(<ContentWidthDropdown />);

    const trigger = screen.getByRole("button", { name: /Select language/ });
    trigger.getBoundingClientRect = () =>
      ({
        bottom: 756,
        height: 36,
        left: 620,
        right: 754,
        top: 720,
        width: 134,
        x: 620,
        y: 720,
        toJSON: () => ({}),
      }) as DOMRect;

    await userEvent.click(trigger);

    const viewport = document.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    const popover = document.querySelector<HTMLElement>(
      '[data-slot="dropdown-popover"]'
    );

    Object.defineProperty(viewport!, "clientHeight", {
      configurable: true,
      value: 72,
    });
    Object.defineProperty(viewport!, "scrollHeight", {
      configurable: true,
      value: 720,
    });
    popover!.getBoundingClientRect = () =>
      ({
        bottom: 272,
        height: 72,
        left: 620,
        right: 800,
        top: 200,
        width: 180,
        x: 620,
        y: 200,
        toJSON: () => ({}),
      }) as DOMRect;

    fireEvent.pointerMove(viewport!, {
      clientX: 710,
      clientY: 264,
    });

    expect(viewport?.scrollTop).toBe(0);
    expect(popover).toHaveAttribute("data-content-expanded", "true");
    expect(popover).not.toHaveAttribute("data-content-fully-expanded");
    expect(popover).toHaveAttribute("data-scroll-fallback", "true");
    expect(popover?.querySelector('[data-slot="scroll-area"]')).toHaveAttribute(
      "data-edge-effect",
      "blur"
    );
  });

  it("renders optional leading content without changing label-only items", async () => {
    const { rerender } = render(
      <Dropdown
        items={[
          {
            id: "signal",
            label: "Signal Dark",
            leading: <span data-testid="theme-swatch">Aa</span>,
          },
          { id: "en", label: "English" },
        ]}
        placeholder="Select theme"
        value="signal"
      />
    );

    const trigger = screen.getByRole("button", { name: /Select theme/ });
    expect(trigger.querySelector('[data-testid="theme-swatch"]')).toHaveTextContent(
      "Aa"
    );
    expect(trigger).toHaveAttribute("data-no-press-feedback");

    await userEvent.click(trigger);

    expect(
      screen
        .getByRole("option", { name: "Signal Dark" })
        .querySelector('[data-testid="theme-swatch"]')
    ).toHaveTextContent("Aa");
    expect(trigger.querySelector('[data-slot="dropdown-row-leading"]')).not.toBeNull();
    expect(
      screen
        .getByRole("option", { name: "English" })
        .querySelector('[data-slot="dropdown-row-leading"]')
    ).toBeNull();
    expect(document.querySelector('[data-slot="dropdown-popover"]')).toHaveClass(
      "rounded-xl"
    );

    rerender(
      <Dropdown
        items={[
          {
            id: "signal",
            label: "Signal Dark",
            leading: <span data-testid="theme-swatch">Aa</span>,
          },
          { id: "en", label: "English" },
        ]}
        placeholder="Select theme"
        value="en"
      />
    );

    expect(trigger).toHaveTextContent("English");
    expect(trigger.querySelector('[data-slot="dropdown-row-leading"]')).toBeNull();
  });

  it("keeps label-only triggers free of an empty leading slot", async () => {
    render(
      <Dropdown
        defaultValue="default"
        items={[
          { id: "small", label: "Small" },
          { id: "default", label: "Default" },
          { id: "large", label: "Large" },
        ]}
        placeholder="Select font size"
        size="sm"
        width="content"
      />
    );

    const trigger = screen.getByRole("button", { name: /Select font size/ });
    expect(trigger.querySelector('[data-slot="dropdown-row-leading"]')).toBeNull();

    await userEvent.click(trigger);

    expect(trigger.querySelector('[data-slot="dropdown-row-leading"]')).toBeNull();
    expect(
      screen
        .getByRole("option", { name: "Default" })
        .querySelector('[data-comma-icon=""]')
    ).toHaveClass("opacity-100");
    expect(
      screen
        .getByRole("option", { name: "Small" })
        .querySelector('[data-slot="dropdown-row-leading"]')
    ).toBeNull();
  });

  it("renders separators before grouped options", async () => {
    render(
      <Dropdown
        items={[
          { id: "system", label: "Auto" },
          { id: "light", label: "Light", separatorBefore: true },
          { id: "dark", label: "Dark", separatorBefore: true },
        ]}
        placeholder="Select theme"
        size="sm"
        value="light"
      />
    );

    const trigger = screen.getByRole("button", { name: /Select theme/ });
    const viewportTop = window.visualViewport?.offsetTop ?? 0;
    const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
    const triggerTop = viewportTop + viewportHeight - 100;
    trigger.getBoundingClientRect = () =>
      ({
        bottom: triggerTop + selectItemHeight.sm,
        height: selectItemHeight.sm,
        left: 0,
        right: 120,
        top: triggerTop,
        width: 120,
        x: 0,
        y: triggerTop,
        toJSON: () => ({}),
      }) as DOMRect;

    await userEvent.click(trigger);

    expect(document.querySelectorAll('[data-slot="dropdown-separator"]')).toHaveLength(
      2
    );
    expect(document.querySelector('[data-slot="dropdown-popover"]')).toHaveAttribute(
      "data-anchor-index",
      "1"
    );
    expect(
      document.querySelector('[data-slot="dropdown-popover"]')
    ).not.toHaveAttribute("data-viewport-constrained");
  });

  it("updates the leading swatch after an uncontrolled selection", async () => {
    render(
      <Dropdown
        defaultValue="signal"
        items={[
          {
            id: "signal",
            label: "Signal Dark",
            leading: <span data-testid="lead-signal">S</span>,
          },
          {
            id: "paper",
            label: "Paper",
            leading: <span data-testid="lead-paper">P</span>,
          },
          { id: "plain", label: "Plain" },
        ]}
        placeholder="Select theme"
      />
    );

    const trigger = screen.getByRole("button", { name: /Select theme/ });
    expect(trigger.querySelector('[data-testid="lead-signal"]')).toHaveTextContent("S");

    await userEvent.click(trigger);
    await userEvent.click(screen.getByRole("option", { name: "Paper" }));

    expect(trigger.querySelector('[data-testid="lead-paper"]')).toHaveTextContent("P");
    expect(trigger.querySelector('[data-testid="lead-signal"]')).toBeNull();

    await userEvent.click(trigger);
    await userEvent.click(screen.getByRole("option", { name: "Plain" }));

    expect(trigger).toHaveTextContent("Plain");
    expect(trigger.querySelector('[data-slot="dropdown-row-leading"]')).toBeNull();
  });

  it("can intercept open to keep a controlled dropdown closed", async () => {
    render(
      <Dropdown
        isOpen={false}
        items={items}
        onOpenChange={() => undefined}
        placeholder="Select language"
        value="en"
      />
    );

    await userEvent.click(screen.getByRole("button", { name: /Select language/ }));
    expect(screen.queryByRole("listbox")).not.toBeInTheDocument();
  });
});
