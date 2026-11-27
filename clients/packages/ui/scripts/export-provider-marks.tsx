// Exports the desktop's provider brand logos as the phone apps' artwork:
// Android `drawable-*dpi/provider_<key>.png` (32dp) and iOS
// `ProviderLogos/provider-<key>.imageset` (vector PDF). Chromium renders each
// logo, so clip paths and embedded images draw as they do on the
// desktop. A logo that renders without a visible pixel fails the export, and so
// does an SVG mask: the iOS PDF keeps it as a soft mask that iOS ignores.
//
//   pnpm --dir clients/packages/ui export:provider-marks [key ...]
//
// With no key, every logo of the resolver is exported.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import {
  providerBrandLogoNames,
  resolveProviderBrandLogo,
} from "../src/components/provider-brand-logos/providerBrandLogoResolver";

const clients = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const androidRes = join(clients, "apps/android/app/src/main/res");
const iosLogos = join(clients, "apps/apple/Resources/Assets.xcassets/ProviderLogos");
const densities = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
const androidDp = 32;
const iosPoints = 18;
// Chromium prints CSS pixels at 0.75 pt each.
const iosPixels = iosPoints / 0.75;

/** Logos drawn in currentColor: tinted by each app instead of keeping a colour. */
const monochromeProviderMarks = new Set(["blender", "github", "notion", "x"]);

// Keys the resolver lists twice under another name.
const aliases: Record<string, string> = { googleworkspace: "google" };

function markup(key: string, size: number) {
  const Logo = resolveProviderBrandLogo(key);
  if (!Logo) throw new Error(`no provider logo for ${key}`);
  const svg = renderToStaticMarkup(createElement(Logo, {}));
  if (svg.includes("<mask"))
    throw new Error(`${key} uses an SVG mask: draw it with a clipPath`);
  // Size the root element; the logos keep their own viewBox.
  return svg.replace(
    /^<svg([^>]*)>/,
    (_, attrs: string) =>
      `<svg${attrs
        .replace(/\s(width|height)="[^"]*"/g, "")
        .replace(/\sclass="[^"]*"/, "")} width="${size}" height="${size}" color="#000">`
  );
}

function page(svg: string, size: number) {
  return `<!doctype html><html><head><style>
    @page { size: ${size}px ${size}px; margin: 0 }
    html, body { margin: 0; padding: 0; background: transparent }
    svg { display: block }
  </style></head><body>${svg}</body></html>`;
}

const keys = process.argv.slice(2).length
  ? process.argv.slice(2)
  : providerBrandLogoNames.filter((key) => !(key in aliases));

const browser = await chromium.launch();
try {
  for (const key of keys) {
    for (const [density, scale] of Object.entries(densities)) {
      const context = await browser.newContext({
        deviceScaleFactor: scale,
        viewport: { width: androidDp, height: androidDp },
      });
      const tab = await context.newPage();
      await tab.setContent(page(markup(key, androidDp), androidDp));
      await tab.waitForLoadState("networkidle");
      const visible = await tab.evaluate(async () => {
        const svg = document.querySelector("svg")!;
        const image = new Image();
        image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg.outerHTML)}`;
        await image.decode();
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = 64;
        const context2d = canvas.getContext("2d")!;
        context2d.drawImage(image, 0, 0, 64, 64);
        const { data } = context2d.getImageData(0, 0, 64, 64);
        let count = 0;
        for (let index = 3; index < data.length; index += 4)
          if (data[index]! > 16) count++;
        return count;
      });
      if (visible < 64)
        throw new Error(`${key} renders blank (${visible} visible pixels)`);
      const out = join(androidRes, `drawable-${density}`, `provider_${key}.png`);
      mkdirSync(dirname(out), { recursive: true });
      await tab.screenshot({ path: out, omitBackground: true });
      await context.close();
    }

    const context = await browser.newContext();
    const tab = await context.newPage();
    await tab.setContent(page(markup(key, iosPixels), iosPixels));
    await tab.waitForLoadState("networkidle");
    const set = join(iosLogos, `provider-${key}.imageset`);
    mkdirSync(set, { recursive: true });
    writeFileSync(
      join(set, `provider-${key}.pdf`),
      await tab.pdf({
        width: `${iosPixels}px`,
        height: `${iosPixels}px`,
        pageRanges: "1",
        printBackground: false,
      })
    );
    await context.close();
    const properties: Record<string, unknown> = {
      "preserves-vector-representation": true,
    };
    if (monochromeProviderMarks.has(key))
      properties["template-rendering-intent"] = "template";
    writeFileSync(
      join(set, "Contents.json"),
      `${JSON.stringify(
        {
          images: [{ filename: `provider-${key}.pdf`, idiom: "universal" }],
          info: { author: "xcode", version: 1 },
          properties,
        },
        null,
        2
      )}\n`
    );
    console.log(`exported ${key}`);
  }
} finally {
  await browser.close();
}
