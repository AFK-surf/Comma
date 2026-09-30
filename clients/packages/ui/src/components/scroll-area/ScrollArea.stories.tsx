import type { Meta, StoryObj } from "@storybook/react-vite";
import { ScrollArea } from "../index";
import type {
  ScrollAreaEdgeEffect,
  ScrollAreaOrientation,
  ScrollAreaScrollbarVisibility,
} from "./ScrollArea";

interface ScrollAreaStoryArgs {
  orientation: ScrollAreaOrientation;
  edgeEffect: ScrollAreaEdgeEffect;
  scrollbarVisibility: ScrollAreaScrollbarVisibility;
  scrollbarHideDelay: number;
  scrollbarHoverReveal: boolean;
  width: number;
  height: number;
  itemCount: number;
  itemWidth: number;
  itemHeight: number;
  gap: number;
  maskSize: number;
  maskStartSize: number;
  maskEndSize: number;
  blurSize: number;
  blurStartSize: number;
  blurEndSize: number;
  blurLayers: number;
  minBlur: number;
  maxBlur: number;
  blurCurve: number;
  blurMaskCoverage: number;
  blurMaskCurve: number;
  edgeTransitionDuration: number;
  edgeTransitionEasing: string;
  observeResize: boolean;
  scrollbarSize: number;
  scrollbarInset: number;
  minThumbSize: number;
}

const sampleNames = [
  "Inbox triage",
  "Regression sweep",
  "Workspace sync",
  "Provider audit",
  "Design review",
  "Runtime smoke",
  "Billing catalog",
  "Policy check",
  "Desktop bridge",
  "Release note",
  "Trace review",
  "Fixture repair",
];

const defaultArgs = {
  orientation: "vertical",
  edgeEffect: "blur",
  scrollbarVisibility: "scroll",
  scrollbarHideDelay: 500,
  scrollbarHoverReveal: true,
  width: 420,
  height: 320,
  itemCount: 18,
  itemWidth: 220,
  itemHeight: 96,
  gap: 10,
  maskSize: 28,
  maskStartSize: 28,
  maskEndSize: 28,
  blurSize: 56,
  blurStartSize: 36,
  blurEndSize: 36,
  blurLayers: 4,
  minBlur: 0,
  maxBlur: 14,
  blurCurve: 3.1,
  blurMaskCoverage: 100,
  blurMaskCurve: 1.7,
  edgeTransitionDuration: 450,
  edgeTransitionEasing: "cubic-bezier(0.16, 1, 0.3, 1)",
  observeResize: true,
  scrollbarSize: 8,
  scrollbarInset: 2,
  minThumbSize: 28,
} satisfies ScrollAreaStoryArgs;

const meta: Meta<ScrollAreaStoryArgs> = {
  title: "Base components/ScrollArea",
  parameters: {
    layout: "centered",
  },
  args: defaultArgs,
  argTypes: {
    orientation: {
      control: "select",
      options: ["vertical", "horizontal"],
    },
    edgeEffect: {
      control: "inline-radio",
      options: ["none", "mask", "blur"],
    },
    scrollbarVisibility: {
      control: "inline-radio",
      options: ["always", "hover", "scroll", "scrollbar-hover"],
    },
    scrollbarHideDelay: {
      control: { type: "range", min: 0, max: 2000, step: 50 },
    },
    scrollbarHoverReveal: { control: "boolean" },
    width: { control: { type: "range", min: 240, max: 900, step: 20 } },
    height: { control: { type: "range", min: 160, max: 640, step: 20 } },
    itemCount: { control: { type: "range", min: 3, max: 80, step: 1 } },
    itemWidth: { control: { type: "range", min: 160, max: 420, step: 10 } },
    itemHeight: { control: { type: "range", min: 64, max: 140, step: 4 } },
    gap: { control: { type: "range", min: 0, max: 32, step: 1 } },
    maskSize: { control: { type: "range", min: 0, max: 120, step: 2 } },
    maskStartSize: { control: { type: "range", min: 0, max: 120, step: 2 } },
    maskEndSize: { control: { type: "range", min: 0, max: 120, step: 2 } },
    blurSize: { control: { type: "range", min: 0, max: 160, step: 2 } },
    blurStartSize: { control: { type: "range", min: 0, max: 160, step: 2 } },
    blurEndSize: { control: { type: "range", min: 0, max: 160, step: 2 } },
    blurLayers: { control: { type: "range", min: 1, max: 8, step: 1 } },
    minBlur: { control: { type: "range", min: 0, max: 24, step: 0.5 } },
    maxBlur: { control: { type: "range", min: 0, max: 48, step: 1 } },
    blurCurve: { control: { type: "range", min: 0.2, max: 4, step: 0.05 } },
    blurMaskCoverage: {
      control: { type: "range", min: 0, max: 100, step: 1 },
    },
    blurMaskCurve: {
      control: { type: "range", min: 0.2, max: 4, step: 0.05 },
    },
    edgeTransitionDuration: {
      control: { type: "range", min: 0, max: 900, step: 10 },
    },
    edgeTransitionEasing: {
      control: "select",
      options: [
        "ease",
        "ease-out",
        "cubic-bezier(0.16, 1, 0.3, 1)",
        "cubic-bezier(0.22, 1, 0.36, 1)",
        "cubic-bezier(0.34, 1.56, 0.64, 1)",
        "linear",
      ],
    },
    observeResize: { control: "boolean" },
    scrollbarSize: { control: { type: "range", min: 4, max: 18, step: 1 } },
    scrollbarInset: { control: { type: "range", min: 0, max: 10, step: 1 } },
    minThumbSize: { control: { type: "range", min: 16, max: 80, step: 2 } },
  },
};

export default meta;
type Story = StoryObj<ScrollAreaStoryArgs>;

function renderItems(args: ScrollAreaStoryArgs) {
  const isHorizontal = args.orientation === "horizontal";
  const isBoth = args.orientation === "both";
  const descriptionLines = args.itemHeight >= 92 ? 2 : 1;

  return (
    <div
      className={isHorizontal || isBoth ? "flex" : "flex flex-col"}
      style={{ gap: args.gap }}
    >
      {Array.from({ length: args.itemCount }, (_, index) => (
        <article
          className="flex shrink-0 flex-col overflow-hidden rounded-lg border border-secondary bg-primary px-4 py-3 shadow-xs"
          key={index}
          style={{
            height: args.itemHeight,
            width: isHorizontal || isBoth ? args.itemWidth : "100%",
            minWidth: isBoth ? args.itemWidth : undefined,
          }}
        >
          <div className="flex shrink-0 items-center justify-between gap-4">
            <p className="min-w-0 truncate text-sm font-medium text-primary">
              {sampleNames[index % sampleNames.length]}
            </p>
            <span className="shrink-0 rounded-full bg-secondary px-2 py-0.5 text-xs text-tertiary">
              #{String(index + 1).padStart(2, "0")}
            </span>
          </div>
          <p
            className="mt-2 min-h-0 overflow-hidden text-xs leading-5 text-tertiary"
            style={{
              display: "-webkit-box",
              WebkitBoxOrient: "vertical",
              WebkitLineClamp: descriptionLines,
            }}
          >
            Shared scroll presentation with overlay thumbs and optional edge treatment
            for dense client panels.
          </p>
        </article>
      ))}
    </div>
  );
}

function renderPlayground(args: ScrollAreaStoryArgs) {
  return (
    <div className="rounded-xl border border-secondary bg-secondary p-4 shadow-sm">
      <ScrollArea
        className="rounded-lg border border-primary bg-primary"
        contentClassName="p-4"
        edgeBlur={{
          size: args.blurSize,
          startSize: args.blurStartSize,
          endSize: args.blurEndSize,
          layers: args.blurLayers,
          minBlur: args.minBlur,
          maxBlur: args.maxBlur,
          blurCurve: args.blurCurve,
          maskCoverage: args.blurMaskCoverage,
          maskCurve: args.blurMaskCurve,
        }}
        edgeEffect={args.edgeEffect}
        edgeMask={{
          size: args.maskSize,
          startSize: args.maskStartSize,
          endSize: args.maskEndSize,
        }}
        edgeTransitionDuration={args.edgeTransitionDuration}
        edgeTransitionEasing={args.edgeTransitionEasing}
        observeResize={args.observeResize}
        orientation={args.orientation}
        scrollbar={{
          size: args.scrollbarSize,
          inset: args.scrollbarInset,
          minThumbSize: args.minThumbSize,
        }}
        scrollbarHideDelay={args.scrollbarHideDelay}
        scrollbarHoverReveal={args.scrollbarHoverReveal}
        scrollbarVisibility={args.scrollbarVisibility}
        style={{ height: args.height, width: args.width }}
      >
        {renderItems(args)}
      </ScrollArea>
    </div>
  );
}

export const Playground: Story = {
  render: renderPlayground,
};

export const VisibilityPolicies: Story = {
  render: () => {
    const variants = [
      { label: "Always", visibility: "always" },
      { label: "Scroll area hover", visibility: "hover" },
      { label: "While scrolling", visibility: "scroll" },
      { label: "Scrollbar hover", visibility: "scrollbar-hover" },
    ] as const satisfies readonly {
      label: string;
      visibility: ScrollAreaScrollbarVisibility;
    }[];

    return (
      <div className="grid grid-cols-2 gap-4">
        {variants.map((variant) => (
          <section
            className="rounded-xl border border-secondary bg-secondary p-3"
            key={variant.visibility}
          >
            <p className="mb-2 text-xs font-medium uppercase text-tertiary">
              {variant.label}
            </p>
            <ScrollArea
              className="h-56 w-80 rounded-lg border border-primary bg-primary"
              contentClassName="p-3"
              scrollbarVisibility={variant.visibility}
            >
              {renderItems({
                ...defaultArgs,
                itemCount: 12,
                itemHeight: 64,
                width: 320,
                height: 224,
              })}
            </ScrollArea>
          </section>
        ))}
      </div>
    );
  },
};

export const EdgeEffects: Story = {
  render: () => {
    const variants = [
      { edgeEffect: "none", label: "Plain" },
      { edgeEffect: "mask", label: "Mask" },
      {
        edgeEffect: "blur",
        label: "Blur",
      },
    ] as const satisfies readonly {
      edgeEffect: ScrollAreaEdgeEffect;
      label: string;
    }[];

    return (
      <div className="grid grid-cols-3 gap-4">
        {variants.map((variant) => (
          <section
            className="rounded-xl border border-secondary bg-secondary p-3"
            key={variant.label}
          >
            <p className="mb-2 text-xs font-medium uppercase text-tertiary">
              {variant.label}
            </p>
            <ScrollArea
              className="h-72 w-80 rounded-lg border border-primary bg-primary"
              contentClassName="p-3"
              edgeBlur={{
                size: 56,
                startSize: 36,
                endSize: 36,
                layers: 4,
                minBlur: 0,
                maxBlur: 14,
                blurCurve: 3.1,
                maskCoverage: 100,
                maskCurve: 1.7,
              }}
              edgeEffect={variant.edgeEffect}
              edgeTransitionDuration={450}
              edgeTransitionEasing="cubic-bezier(0.16, 1, 0.3, 1)"
              edgeMask={{ size: 32 }}
            >
              {renderItems({
                ...defaultArgs,
                itemCount: 16,
                itemHeight: 64,
                width: 320,
                height: 288,
              })}
            </ScrollArea>
          </section>
        ))}
      </div>
    );
  },
};

export const Horizontal: Story = {
  args: {
    orientation: "horizontal",
    edgeEffect: "blur",
    width: 640,
    height: 220,
    itemCount: 14,
    itemWidth: 220,
    itemHeight: 148,
  },
  render: renderPlayground,
};
