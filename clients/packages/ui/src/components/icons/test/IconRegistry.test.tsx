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
  "ClaudeAiIcon",
  "GithubBrandIcon",
  "GoogleBrandIcon",
  "LinearBrandIcon",
  "NotionBrandIcon",
  "TelegramBrandIcon",
  "SlackBrandIcon",
  "WechatBrandIcon",
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
      expect(
        view.container.querySelector('svg [stroke-width="2"], svg[stroke-width="2"]'),
        entry.exportName
      ).not.toBeNull();
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

  it("takes stroke-1.5 only for glyphs Central ships as a fill", () => {
    // Everything else must be stroke-2 and let the global token thin it.
    const preThinned = iconRegistry
      .filter((entry) => entry.variant.stroke === 1.5)
      .map((entry) => entry.exportName);

    expect(preThinned.toSorted()).toEqual([
      "BookIcon",
      // Central draws the cursor at 2.05556, which the global token's
      // `[stroke-width="2"]` selector cannot match, let alone thin.
      "Cursor1Icon",
      "LayoutColumnIcon",
      "PanelLeftIcon",
      "PanelRightIcon",
      "ShapesPlusXSquareCircleIcon",
      "SquareGridCircleIcon",
    ]);

    for (const entry of iconRegistry) {
      if (preThinned.includes(entry.exportName)) continue;
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

  it("locks the AI input drop overlay glyphs to their Central Icons variants", () => {
    expect(iconRegistryByExport.ImageIcon?.centralName).toBe("IconImages1");
    expect(iconRegistryByExport.ImageIcon?.source).toBe("figma");
    expect(iconRegistryByExport.ImageIcon?.figmaNodeId).toBe("1180:11256;3471:598450");
    expect(iconRegistryByExport.ImageIcon?.variant).toEqual({
      filled: false,
      stroke: 2,
      radius: 2,
      join: "round",
    });
    expect(iconRegistryByExport.VideoIcon?.centralName).toBe("IconVideo");
    expect(iconRegistryByExport.VideoIcon?.source).toBe("figma");
    expect(iconRegistryByExport.VideoIcon?.figmaNodeId).toBe("1180:11433;3471:598450");
    expect(iconRegistryByExport.VideoIcon?.variant).toEqual({
      filled: false,
      stroke: 2,
      radius: 2,
      join: "round",
    });
  });

  it("exports a dedicated copy icon instead of reusing the file attachment icon", () => {
    expect(icons.CopyIcon).toBeDefined();
    expect(iconRegistryByExport.CopyIcon?.centralName).toBe("IconSquareBehindSquare6");
    expect(iconRegistryByExport.CopyIcon?.source).toBe("figma");
    expect(iconRegistryByExport.CopyIcon?.figmaNodeId).toBe("7798:28574");
  });

  it("locks the Tasks action glyphs to their requested Central Icons variants", () => {
    expect(iconRegistryByExport.LayoutColumnIcon?.centralName).toBe("IconLayoutColumn");
    expect(iconRegistryByExport.BarsThreeIcon?.centralName).toBe("IconBarsThree2");
    // Fill-only in the stroke-2 package, so it is taken pre-thinned at 1.5.
    expect(iconRegistryByExport.LayoutColumnIcon?.variant).toEqual({
      filled: false,
      stroke: 1.5,
      radius: 2,
      join: "round",
    });
    expect(iconRegistryByExport.BarsThreeIcon?.variant).toEqual({
      filled: false,
      stroke: 2,
      radius: 2,
      join: "round",
    });
    expect(iconRegistryByExport.SquareCursorIcon?.centralName).toBe("IconSquareCursor");
    expect(iconRegistryByExport.SquareCursorIcon?.variant).toEqual({
      filled: true,
      stroke: 2,
      radius: 2,
      join: "round",
    });
    expect(iconRegistryByExport.ExclamationTriangleIcon?.centralName).toBe(
      "IconExclamationTriangle"
    );
    expect(iconRegistryByExport.ExclamationTriangleIcon?.variant).toEqual({
      filled: false,
      stroke: 2,
      radius: 2,
      join: "round",
    });
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
