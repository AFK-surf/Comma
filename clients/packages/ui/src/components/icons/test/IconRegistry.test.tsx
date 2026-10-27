import type { ComponentType } from "react";
import { render } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import {
  centralIconPackage,
  parseCentralIconVariantName,
} from "../centralIconVariants";
import {
  iconRegistry,
  iconRegistryByExport,
  type IconRegistryEntry,
} from "../iconRegistry";
import { brandMarks } from "../brandMarks";
import * as icons from "../index";

const BRAND_MARKS = new Set([
  // A logo's weight is the mark's own, and these only ever sit beside other
  // marks, so they stay on whichever package matches the trademark.
  "OpenAiIcon",
  "CodexBrandIcon",
  "AnthropicBrandIcon",
  "GeminiBrandIcon",
  "DeepSeekBrandIcon",
  "MistralBrandIcon",
  "MetaAiBrandIcon",
  "GrokBrandIcon",
  "QwenBrandIcon",
  "ZaiBrandIcon",
  "NvidiaBrandIcon",
  "OllamaBrandIcon",
  "OpencodeBrandIcon",
  "VercelBrandIcon",
  "CopilotBrandIcon",
  "ClaudeAiIcon",
  "GithubBrandIcon",
  "GoogleBrandIcon",
  "LinearBrandIcon",
  "NotionBrandIcon",
  "TelegramBrandIcon",
  "SlackBrandIcon",
  "XBrandIcon",
  "WechatBrandIcon",
  "DiscordBrandIcon",
]);

// Central ships these as a fill in both packages, so no stroke rule reaches
// them. They take the stroke-2 package (centralIconVariants.ts).
const FILL_ONLY = new Set([
  "ColumnWideAddIcon",
  "LayoutColumnIcon",
  "PanelLeftIcon",
  "PanelRightIcon",
  "ShapesPlusXSquareCircleIcon",
]);

describe("icon stroke weight", () => {
  it("renders adjustable strokes for outlined interface glyphs", () => {
    for (const [exportName, IconExport] of Object.entries(icons)) {
      const entry =
        iconRegistryByExport[exportName as keyof typeof iconRegistryByExport];
      if (
        !entry ||
        BRAND_MARKS.has(exportName) ||
        entry.variant.filled ||
        entry.variant.stroke !== 2
      )
        continue;
      const Icon = IconExport as ComponentType;
      const view = render(<Icon />);
      // Filled paths cannot follow the shared stroke-width token.
      const stroke = view.container.querySelector(
        'svg [stroke-width="2"], svg[stroke-width="2"]'
      );
      if (FILL_ONLY.has(exportName)) {
        expect(view.container.querySelector("[stroke-width]"), exportName).toBeNull();
      } else {
        expect(stroke, entry.exportName).not.toBeNull();
      }
      view.unmount();
    }
  });
});

describe("iconRegistry", () => {
  it("parses Central Icons Figma variant names", () => {
    expect(
      parseCentralIconVariantName("filled=off, stroke=1.5, radius=2, join=round")
    ).toEqual({
      filled: false,
      stroke: 1.5,
      radius: 2,
      join: "round",
    });
  });

  it("maps variants to Central Icons npm packages", () => {
    expect(
      centralIconPackage({
        filled: false,
        stroke: 1.5,
        radius: 2,
        join: "round",
      })
    ).toBe("@central-icons-react/round-outlined-radius-2-stroke-1.5");
  });

  it("uses the filled stroke-2 variant for generated-media player controls", () => {
    const mediaIconNames = [
      "PlayIcon",
      "PauseIcon",
      "VolumeFullIcon",
      "VolumeHalfIcon",
      "VolumeOffIcon",
      "MediaDownloadIcon",
      "MediaExpandIcon",
    ];

    expect(
      iconRegistry
        .filter((entry) => mediaIconNames.includes(entry.exportName))
        .map((entry) => [entry.exportName, entry.variant])
    ).toEqual(
      mediaIconNames.map((exportName) => [
        exportName,
        { filled: true, stroke: 2, radius: 2, join: "round" },
      ])
    );
    expect(
      centralIconPackage({ filled: true, stroke: 2, radius: 2, join: "round" })
    ).toBe("@central-icons-react/round-filled-radius-2-stroke-2");
    expect(iconRegistryByExport.DownloadIcon?.variant).toEqual({
      filled: false,
      stroke: 2,
      radius: 2,
      join: "round",
    });
  });

  it("takes stroke-1.5 only where the stroke-2 glyph has no 2 stroke to match", () => {
    // Everything else is stroke-2: the shared stroke rule draws both packages'
    // main strokes at the token width.
    const realStroke = iconRegistry
      .filter((entry) => entry.variant.stroke === 1.5)
      .map((entry) => entry.exportName);

    expect(realStroke.toSorted()).toEqual([
      "BookIcon",
      // Central draws the cursor at 2.05556 in the stroke-2 package, which the
      // shared `[stroke-width="2"]` rule does not match.
      "Cursor1Icon",
      "MacbookAirIcon",
      "Smartwatch2Icon",
      "SquareGridCircleIcon",
    ]);

    for (const entry of iconRegistry) {
      if (realStroke.includes(entry.exportName)) continue;
      expect(entry.variant.stroke, entry.exportName).toBe(2);
    }
  });

  it("locks the raw Central path contract used by the composite volume icon", () => {
    const { container } = render(
      <>
        <icons.VolumeHalfIcon className="half" mode="raw" />
        <icons.VolumeFullIcon className="full" mode="raw" />
        <icons.VolumeOffIcon className="off" mode="raw" />
      </>
    );
    const half = container.querySelector("svg.half");
    const full = container.querySelector("svg.full");
    const off = container.querySelector("svg.off");

    expect(half?.querySelector("mask")).toBeNull();
    expect(half?.querySelectorAll(":scope > path")).toHaveLength(2);
    expect(full?.querySelector("mask")).toBeNull();
    expect(full?.querySelectorAll(":scope > path")).toHaveLength(5);
    expect(off?.querySelector("mask")).toBeNull();
    expect(off?.querySelectorAll(":scope > path")).toHaveLength(2);
  });

  it("covers every exported UI icon wrapper", () => {
    const exportedIconNames = Object.keys(icons).filter(
      (name) => name.endsWith("Icon") || name === "StatusDot"
    );

    for (const exportName of exportedIconNames) {
      expect(
        iconRegistryByExport[exportName as keyof typeof iconRegistryByExport],
        exportName
      ).toBeDefined();
    }
  });

  it("records every content brand mark", () => {
    for (const key of Object.keys(brandMarks)) {
      expect(
        iconRegistryByExport[`brandMarks.${key}` as keyof typeof iconRegistryByExport],
        key
      ).toBeDefined();
    }
  });

  it("keeps Figma node ids real when present", () => {
    const figmaNodeIdPattern = /^\d+:\d+(;\d+:\d+)*$/;

    for (const entry of iconRegistry) {
      const { figmaNodeId } = entry as IconRegistryEntry;

      if (figmaNodeId === undefined) {
        continue;
      }

      expect(entry.source, entry.exportName).toBe("figma");
      expect(figmaNodeId, entry.exportName).toMatch(figmaNodeIdPattern);
    }
  });

  it("keeps unique export names", () => {
    const exportNames = iconRegistry.map((entry) => entry.exportName);
    expect(new Set(exportNames).size).toBe(exportNames.length);
  });
});
