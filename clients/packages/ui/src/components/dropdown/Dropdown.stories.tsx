import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import { expect, fireEvent, userEvent, waitFor, within } from "storybook/test";
import { Dropdown } from "../index";

const dropdownItems = [
  { id: "1", label: "Option one" },
  { id: "2", label: "Option two" },
  { id: "3", label: "Option three" },
];

const languageItems = [
  { id: "system", label: "Auto detect" },
  { id: "en", label: "English" },
  { id: "zh-CN", label: "Simplified Chinese" },
];

const edgeItems = [
  { id: "smaller", label: "Smaller" },
  { id: "small", label: "Small" },
  { id: "default", label: "Default" },
  { id: "large", label: "Large" },
  { id: "larger", label: "Larger" },
];

const longEdgeItems = Array.from({ length: 20 }, (_, index) => ({
  id: `option-${index + 1}`,
  label: `Option ${index + 1}`,
}));

const ContentWidthDropdown = () => {
  const [value, setValue] = useState("system");

  return (
    <div className="px-3xl pt-7xl pb-3xl">
      <Dropdown
        items={languageItems}
        onChange={setValue}
        placeholder="Select language"
        size="sm"
        value={value}
        width="content"
      />
    </div>
  );
};

const NarrowContentWidthDropdown = () => (
  <div className="p-3xl">
    <div className="w-[100px]">
      <Dropdown
        defaultValue="zh-CN"
        items={languageItems}
        placeholder="Select language"
        size="sm"
        width="content"
      />
    </div>
  </div>
);

const ViewportEdgeDropdown = () => (
  <div className="fixed right-xl bottom-7xl">
    <Dropdown defaultValue="default" items={edgeItems} size="sm" width="content" />
  </div>
);

const FractionalViewportDropdown = () => (
  <div className="fixed top-[100.5px] left-xl">
    <Dropdown defaultValue="system" items={languageItems} size="sm" width="content" />
  </div>
);

const LongViewportEdgeDropdown = () => (
  <div className="fixed right-xl bottom-7xl">
    <Dropdown defaultValue="option-3" items={longEdgeItems} size="sm" width="content" />
  </div>
);

const meta = {
  title: "Base components/Dropdown",
  parameters: {
    layout: "centered",
  },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: () => (
    <Dropdown
      label="Team"
      hint="This is a hint text to help user."
      placeholder="Select teams"
      items={dropdownItems}
      defaultValue="1"
    />
  ),
};

export const SmallSize: Story = {
  render: () => (
    <Dropdown
      size="sm"
      label="Team"
      items={dropdownItems}
      placeholder="Select option"
    />
  ),
};

export const ContentWidth: Story = {
  render: () => <ContentWidthDropdown />,
};

export const NarrowContentWidth: Story = {
  render: () => <NarrowContentWidthDropdown />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const trigger = canvas.getByRole("button", { name: /Select language/ });
    const triggerLabel = trigger.querySelector<HTMLElement>(
      '[data-slot="dropdown-trigger-label"]'
    );

    await expect(trigger).toHaveTextContent("Simplified Chinese");
    await waitFor(() => {
      expect(trigger.clientWidth).toBeLessThanOrEqual(100);
      expect(trigger.scrollWidth).toBeLessThanOrEqual(trigger.clientWidth);
      expect(triggerLabel?.scrollWidth ?? 0).toBeGreaterThan(
        triggerLabel?.clientWidth ?? 0
      );
    });

    await userEvent.click(trigger);
    const fullLabel = await page.findByRole("option", {
      name: "Simplified Chinese",
    });
    await expect(fullLabel.scrollWidth).toBeLessThanOrEqual(fullLabel.clientWidth);
  },
};

export const ContentWidthInteraction: Story = {
  tags: ["!dev", "!autodocs"],
  render: () => <ContentWidthDropdown />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const trigger = canvas.getByRole("button", { name: /Select language/ });
    const dropdown = trigger.closest('[data-slot="dropdown"]');

    await expect(dropdown).toHaveAttribute("data-width", "content");
    await expect(trigger).toHaveTextContent("Auto detect");
    const autoDetectWidth = trigger.getBoundingClientRect().width;
    await userEvent.click(trigger);
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
    const fullLabel = await page.findByRole("option", {
      name: "Simplified Chinese",
    });
    await expect(fullLabel.scrollWidth).toBeLessThanOrEqual(fullLabel.clientWidth);
    await userEvent.click(await page.findByRole("option", { name: "English" }));
    await expect(trigger).toHaveTextContent("English");
    await expect(trigger.getBoundingClientRect().width).toBeLessThan(autoDetectWidth);

    await userEvent.click(trigger);
    const selectedOption = await page.findByRole("option", { name: "English" });
    const triggerLabel = trigger.querySelector('[data-slot="dropdown-row-label"]');
    const selectedLabel = selectedOption.querySelector(
      '[data-slot="dropdown-row-label"]'
    );
    await waitFor(() => {
      expect(
        Math.abs(
          selectedOption.getBoundingClientRect().top -
            trigger.getBoundingClientRect().top
        )
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(
          (selectedLabel?.getBoundingClientRect().left ?? 0) -
            (triggerLabel?.getBoundingClientRect().left ?? 0)
        )
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(
          (selectedLabel?.getBoundingClientRect().top ?? 0) -
            (triggerLabel?.getBoundingClientRect().top ?? 0)
        )
      ).toBeLessThanOrEqual(1);
    });
    await userEvent.click(await page.findByRole("option", { name: "Auto detect" }));
    await expect(trigger).toHaveTextContent("Auto detect");
  },
};

export const FractionalViewportWheelInteraction: Story = {
  tags: ["!dev", "!autodocs"],
  parameters: {
    layout: "fullscreen",
  },
  render: () => <FractionalViewportDropdown />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const trigger = canvas.getByRole("button");

    await expect(trigger.getBoundingClientRect().top % 1).toBeCloseTo(0.5, 1);
    await userEvent.click(trigger);

    const selectedOption = page.getByRole("option", { name: "Auto detect" });
    const scrollViewport = page
      .getByRole("listbox")
      .closest('[data-slot="dropdown-popover"]')
      ?.querySelector<HTMLElement>('[data-slot="scroll-area-viewport"]');

    await waitFor(() =>
      expect(
        scrollViewport?.scrollHeight ?? Number.POSITIVE_INFINITY
      ).toBeLessThanOrEqual(scrollViewport?.clientHeight ?? 0)
    );
    await waitFor(() =>
      expect(
        selectedOption
          .closest('[data-slot="dropdown-popover"]')!
          .getAnimations()
          .some((animation) => animation.pending || animation.playState === "running")
      ).toBe(false)
    );
    const selectedTopBeforeWheel = selectedOption.getBoundingClientRect().top;
    await expect(
      Math.abs(selectedTopBeforeWheel - trigger.getBoundingClientRect().top)
    ).toBeLessThanOrEqual(0.1);

    await fireEvent.wheel(scrollViewport!, { deltaY: 100 });

    await waitFor(() => expect(scrollViewport?.scrollTop ?? -1).toBe(0));
    await expect(selectedOption.getBoundingClientRect().top).toBe(
      selectedTopBeforeWheel
    );
    await expect(
      Math.abs(
        selectedOption.getBoundingClientRect().top - trigger.getBoundingClientRect().top
      )
    ).toBeLessThanOrEqual(0.1);
  },
};

export const ViewportEdge: Story = {
  parameters: {
    layout: "fullscreen",
  },
  render: () => <ViewportEdgeDropdown />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const trigger = canvas.getByRole("button");

    await userEvent.click(trigger);
    const popover = page.getByRole("listbox").closest('[data-slot="dropdown-popover"]');
    const selectedOption = page.getByRole("option", { name: "Default" });
    const scrollArea = popover?.querySelector('[data-slot="scroll-area"]');
    const scrollViewport = popover?.querySelector('[data-slot="scroll-area-viewport"]');
    const scrollDownHotArea = popover?.querySelector<HTMLElement>(
      '[data-slot="dropdown-scroll-down"]'
    );

    await expect(popover).toHaveAttribute("data-positioning", "selection-aligned");
    await expect(popover).toHaveAttribute("data-viewport-constrained", "true");
    await expect(popover).toHaveAttribute("data-placement", "bottom");
    await expect(scrollArea).toHaveAttribute("data-edge-effect", "blur");
    await expect(trigger).toHaveClass("pointer-events-none", "opacity-0");
    await waitFor(() =>
      expect(scrollViewport?.scrollHeight ?? 0).toBeGreaterThan(
        scrollViewport?.clientHeight ?? 0
      )
    );
    await waitFor(() =>
      expect(scrollArea).toHaveAttribute("data-edge-end-visible", "true")
    );
    await expect(scrollDownHotArea).toHaveClass("inset-x-0", "h-4xl");

    await waitFor(() => {
      const popoverRect = popover?.getBoundingClientRect();
      const triggerRect = trigger.getBoundingClientRect();

      expect(
        Math.abs(selectedOption.getBoundingClientRect().top - triggerRect.top)
      ).toBeLessThanOrEqual(1);
      expect(popoverRect?.top ?? Number.POSITIVE_INFINITY).toBeLessThanOrEqual(
        triggerRect.top
      );
      expect(popoverRect?.bottom ?? Number.NEGATIVE_INFINITY).toBeGreaterThanOrEqual(
        triggerRect.bottom
      );
    });

    await expect(trigger).toHaveAttribute("aria-expanded", "true");
  },
};

export const ViewportEdgeInteraction: Story = {
  tags: ["!dev", "!autodocs"],
  parameters: {
    layout: "fullscreen",
  },
  render: () => <ViewportEdgeDropdown />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const trigger = canvas.getByRole("button");

    await userEvent.click(trigger);
    const popover = page.getByRole("listbox").closest('[data-slot="dropdown-popover"]');
    const scrollArea = popover?.querySelector('[data-slot="scroll-area"]');
    const scrollViewport = popover?.querySelector('[data-slot="scroll-area-viewport"]');

    await expect(popover).toHaveAttribute("data-positioning", "selection-aligned");
    await expect(popover).toHaveAttribute("data-viewport-constrained", "true");
    await waitFor(() =>
      expect(scrollArea).toHaveAttribute("data-edge-end-visible", "true")
    );

    // Measure the settled popup, not an intermediate enter-animation frame.
    await waitFor(() =>
      expect(
        popover!.getAnimations().some((animation) => animation.playState === "running")
      ).toBe(false)
    );
    const initialRect = popover?.getBoundingClientRect();
    fireEvent.pointerMove(scrollViewport!, {
      clientX: (initialRect?.left ?? 0) + (initialRect?.width ?? 0) / 2,
      clientY: (initialRect?.bottom ?? 0) - 8,
    });
    await waitFor(() =>
      expect(popover).toHaveAttribute("data-content-expanded", "true")
    );
    await expect(scrollArea).toHaveAttribute("data-edge-effect", "none");
    await waitFor(() =>
      expect(scrollViewport?.scrollHeight ?? 0).toBeLessThanOrEqual(
        scrollViewport?.clientHeight ?? 0
      )
    );

    const hoveredRect = popover?.getBoundingClientRect();
    await expect(scrollViewport?.scrollTop ?? 0).toBe(0);
    await expect(
      (hoveredRect?.top ?? Number.POSITIVE_INFINITY) < (initialRect?.top ?? 0)
    ).toBe(true);
    await expect(
      (hoveredRect?.height ?? 0) > (initialRect?.height ?? Number.POSITIVE_INFINITY)
    ).toBe(true);
    await expect(
      Math.abs((hoveredRect?.bottom ?? 0) - (initialRect?.bottom ?? 0))
    ).toBeLessThanOrEqual(1);
    await expect(trigger).toHaveClass("pointer-events-none", "opacity-0");
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
  },
};

export const LongViewportEdge: Story = {
  parameters: {
    layout: "fullscreen",
  },
  render: () => <LongViewportEdgeDropdown />,
};

export const LongViewportEdgeInteraction: Story = {
  tags: ["!dev", "!autodocs"],
  parameters: {
    layout: "fullscreen",
  },
  render: () => <LongViewportEdgeDropdown />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const trigger = canvas.getByRole("button");

    await userEvent.click(trigger);
    const popover = page.getByRole("listbox").closest('[data-slot="dropdown-popover"]');
    const scrollArea = popover?.querySelector('[data-slot="scroll-area"]');
    const scrollViewport = popover?.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    const scrollDownHotArea = popover?.querySelector<HTMLElement>(
      '[data-slot="dropdown-scroll-down"]'
    );

    await waitFor(() =>
      expect(scrollViewport?.scrollHeight ?? 0).toBeGreaterThan(
        scrollViewport?.clientHeight ?? Number.POSITIVE_INFINITY
      )
    );
    await waitFor(() =>
      expect(scrollArea).toHaveAttribute("data-edge-end-visible", "true")
    );

    // Measure the settled popup, not an intermediate enter-animation frame.
    await waitFor(() =>
      expect(
        popover!.getAnimations().some((animation) => animation.playState === "running")
      ).toBe(false)
    );
    const initialRect = popover?.getBoundingClientRect();
    fireEvent.pointerMove(scrollViewport!, {
      clientX: (initialRect?.left ?? 0) + (initialRect?.width ?? 0) / 2,
      clientY: (initialRect?.bottom ?? 0) - 8,
    });

    await waitFor(() =>
      expect(popover).toHaveAttribute("data-scroll-fallback", "true")
    );
    await expect(popover).not.toHaveAttribute("data-content-fully-expanded");
    await expect(scrollArea).toHaveAttribute("data-edge-effect", "blur");
    await waitFor(() =>
      expect(getComputedStyle(scrollDownHotArea!).pointerEvents).toBe("none")
    );

    const expandedRect = popover?.getBoundingClientRect();
    await expect(
      (expandedRect?.top ?? Number.POSITIVE_INFINITY) < (initialRect?.top ?? 0)
    ).toBe(true);
    await expect(
      Math.abs((expandedRect?.bottom ?? 0) - (initialRect?.bottom ?? 0))
    ).toBeLessThanOrEqual(1);

    const hotAreaRect = scrollDownHotArea!.getBoundingClientRect();
    const hitTarget = canvasElement.ownerDocument.elementFromPoint(
      hotAreaRect.left + hotAreaRect.width / 2,
      hotAreaRect.top + hotAreaRect.height / 2
    );

    await expect(hitTarget).not.toBe(scrollDownHotArea);
    await expect(scrollViewport?.contains(hitTarget)).toBe(true);

    // The list is scrolled by the browser, which a synthetic wheel cannot
    // drive; what the chevron owes the list is that a wheel over it lands in
    // the list and nothing cancels it on the way. Real wheel input over this
    // state is covered by e2e/app-shell/menu.spec.ts.
    await expect(await fireEvent.wheel(hitTarget!, { deltaY: 200 })).toBe(true);
  },
};

const fontSizeItems = [
  { id: "small", label: "Small" },
  { id: "default", label: "Default" },
  { id: "large", label: "Large" },
];

const FontSizeDropdown = () => (
  <div className="px-3xl pt-7xl pb-3xl">
    <Dropdown
      defaultValue="default"
      items={fontSizeItems}
      placeholder="Select font size"
      size="sm"
      width="content"
    />
  </div>
);

const leadingSeparatorItems = [
  {
    id: "default",
    label: "Default",
    leading: <span data-testid="swatch-default">Aa</span>,
  },
  {
    id: "light",
    label: "Light",
    leading: <span data-testid="swatch-light">Aa</span>,
    separatorBefore: true,
  },
  {
    id: "dark",
    label: "Dark",
    leading: <span data-testid="swatch-dark">Aa</span>,
    separatorBefore: true,
  },
];

const LeadingSeparatorDropdown = () => (
  <div className="px-3xl pt-7xl pb-3xl">
    <Dropdown
      defaultValue="light"
      items={leadingSeparatorItems}
      placeholder="Select theme"
      size="sm"
      width="content"
    />
  </div>
);

export const FontSize: Story = {
  render: () => <FontSizeDropdown />,
};

export const FontSizeInteraction: Story = {
  tags: ["!dev", "!autodocs"],
  render: () => <FontSizeDropdown />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const trigger = canvas.getByRole("button", { name: /Select font size/ });
    const triggerLabel = trigger.querySelector('[data-slot="dropdown-row-label"]');

    await expect(trigger).toHaveTextContent("Default");
    await expect(
      trigger.querySelector('[data-slot="dropdown-row-leading"]')
    ).toBeNull();

    await userEvent.click(trigger);
    const selectedOption = await page.findByRole("option", { name: "Default" });
    const selectedLabel = selectedOption.querySelector(
      '[data-slot="dropdown-row-label"]'
    );

    await expect(trigger).toHaveClass("pointer-events-none", "opacity-0");
    await expect(
      trigger.querySelector('[data-slot="dropdown-row-leading"]')
    ).toBeNull();
    await waitFor(() => {
      expect(
        Math.abs(
          selectedOption.getBoundingClientRect().top -
            trigger.getBoundingClientRect().top
        )
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(
          (selectedLabel?.getBoundingClientRect().left ?? 0) -
            (triggerLabel?.getBoundingClientRect().left ?? 0)
        )
      ).toBeLessThanOrEqual(1);
    });
  },
};

export const LeadingSeparators: Story = {
  render: () => <LeadingSeparatorDropdown />,
};

export const LeadingSeparatorsInteraction: Story = {
  tags: ["!dev", "!autodocs"],
  render: () => <LeadingSeparatorDropdown />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const trigger = canvas.getByRole("button", { name: /Select theme/ });
    const triggerLabel = trigger.querySelector('[data-slot="dropdown-row-label"]');

    await expect(
      trigger.querySelector('[data-testid="swatch-light"]')
    ).toHaveTextContent("Aa");

    await userEvent.click(trigger);
    const selectedOption = await page.findByRole("option", { name: "Light" });
    const selectedLabel = selectedOption.querySelector(
      '[data-slot="dropdown-row-label"]'
    );

    await expect(
      page.getByRole("listbox").querySelectorAll('[data-slot="dropdown-separator"]')
    ).toHaveLength(2);
    await expect(
      canvasElement.ownerDocument.querySelector('[data-slot="dropdown-popover"]')
    ).toHaveAttribute("data-anchor-index", "1");
    await expect(
      canvasElement.ownerDocument.querySelector('[data-slot="dropdown-popover"]')
    ).not.toHaveAttribute("data-viewport-constrained");
    await waitFor(() => {
      expect(
        Math.abs(
          selectedOption.getBoundingClientRect().top -
            trigger.getBoundingClientRect().top
        )
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(
          (selectedLabel?.getBoundingClientRect().left ?? 0) -
            (triggerLabel?.getBoundingClientRect().left ?? 0)
        )
      ).toBeLessThanOrEqual(1);
    });
  },
};

export const Destructive: Story = {
  render: () => (
    <Dropdown
      destructive
      label="Team"
      items={dropdownItems}
      hint="Selection required"
    />
  ),
};
