import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect } from "storybook/test";
import { Button, PlaceholderIcon } from "..";
import type { ButtonHierarchy, ButtonSize } from "./types";

const hierarchies = [
  "primary",
  "secondary-color",
  "secondary-gray",
  "tertiary-color",
  "tertiary-gray",
  "destructive",
  "link-color",
  "link-gray",
] as const satisfies readonly ButtonHierarchy[];

const sizes = ["xs", "sm", "md", "lg"] as const satisfies readonly ButtonSize[];

const meta = {
  title: "Base components/Buttons",
  component: Button,
  args: {
    children: "Button CTA",
    hierarchy: "primary",
    size: "md",
  },
} satisfies Meta<typeof Button>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Hierarchies: Story = {
  render: () => (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-3">
        {hierarchies
          .filter((hierarchy) => !hierarchy.startsWith("link-"))
          .map((hierarchy) => (
            <Button key={hierarchy} hierarchy={hierarchy}>
              {hierarchy}
            </Button>
          ))}
      </div>
      <div className="flex flex-wrap items-center gap-3">
        <Button hierarchy="link-color">Link color</Button>
        <Button hierarchy="link-gray">Link gray</Button>
      </div>
    </div>
  ),
};

export const Sizes: Story = {
  render: () => (
    <div className="flex flex-wrap items-end gap-3">
      {sizes.map((size) => (
        <Button key={size} size={size} hierarchy="primary">
          {size.toUpperCase()}
        </Button>
      ))}
    </div>
  ),
};

export const Icons: Story = {
  render: () => (
    <div className="flex flex-col gap-6">
      {sizes.map((size) => (
        <div key={size} className="flex flex-col gap-2">
          <p className="text-xs font-medium uppercase tracking-wide text-tertiary">
            {size}
          </p>
          <div className="flex flex-wrap items-center gap-3">
            <Button
              data-icon-slot-size={size}
              size={size}
              iconLeading={<PlaceholderIcon />}
            >
              Leading
            </Button>
            <Button size={size} iconTrailing={<PlaceholderIcon />}>
              Trailing
            </Button>
            <Button
              size={size}
              iconLeading={<PlaceholderIcon />}
              iconTrailing={<PlaceholderIcon />}
            >
              Both
            </Button>
            <Button size={size} dotLeading>
              Status
            </Button>
            <Button size={size} iconOnly aria-label={`${size} icon only`} />
          </div>
        </div>
      ))}
    </div>
  ),
  play: async ({ canvasElement }) => {
    const documentElement = canvasElement.ownerDocument.documentElement;
    const originalFontSize = documentElement.style.fontSize;
    const originalPreference = documentElement.getAttribute("data-comma-font-size");
    const preferences = [
      { name: "small", rootFontSize: 14.4 },
      { name: "default", rootFontSize: 16 },
      { name: "large", rootFontSize: 17.6 },
    ] as const;
    const expectedSlotSizes = { xs: 16, sm: 16, md: 20, lg: 20 } as const;

    try {
      for (const preference of preferences) {
        documentElement.setAttribute("data-comma-font-size", preference.name);
        documentElement.style.fontSize = `${preference.rootFontSize}px`;
        await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));

        for (const size of sizes) {
          const button = canvasElement.querySelector<HTMLElement>(
            `[data-icon-slot-size="${size}"]`
          );
          const slot = button?.querySelector<HTMLElement>(".comma-icon-slot");
          const icon = slot?.querySelector<SVGElement>("svg[data-comma-icon]");

          await expect(button).not.toBeNull();
          await expect(slot).not.toBeNull();
          await expect(icon).not.toBeNull();

          const expectedSize = expectedSlotSizes[size];
          const slotRect = slot!.getBoundingClientRect();
          const iconRect = icon!.getBoundingClientRect();
          await expect(slotRect.width).toBeCloseTo(expectedSize, 4);
          await expect(slotRect.height).toBeCloseTo(expectedSize, 4);
          await expect(iconRect.width).toBeCloseTo(expectedSize, 4);
          await expect(iconRect.height).toBeCloseTo(expectedSize, 4);
        }
      }
    } finally {
      documentElement.style.fontSize = originalFontSize;
      if (originalPreference === null) {
        documentElement.removeAttribute("data-comma-font-size");
      } else {
        documentElement.setAttribute("data-comma-font-size", originalPreference);
      }
    }
  },
};

export const Disabled: Story = {
  render: () => (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-3">
        {hierarchies
          .filter((hierarchy) => !hierarchy.startsWith("link-"))
          .map((hierarchy) => (
            <Button key={hierarchy} hierarchy={hierarchy} disabled>
              {hierarchy}
            </Button>
          ))}
      </div>
      <div className="flex flex-wrap items-center gap-3">
        <Button hierarchy="link-color" disabled>
          Link color
        </Button>
        <Button hierarchy="link-gray" disabled>
          Link gray
        </Button>
      </div>
    </div>
  ),
};

export const LinkSizes: Story = {
  render: () => (
    <div className="flex flex-wrap items-center gap-4">
      {sizes.map((size) => (
        <Button
          key={size}
          size={size}
          hierarchy="link-color"
          iconTrailing={<PlaceholderIcon />}
        >
          Link {size}
        </Button>
      ))}
    </div>
  ),
};
