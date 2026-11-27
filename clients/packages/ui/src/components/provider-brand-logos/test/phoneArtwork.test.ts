import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { inflateSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import { providerBrandLogoNames } from "../providerBrandLogoResolver";

// The phone apps ship each desktop logo as artwork of their own
// (`pnpm --dir clients/packages/ui export:provider-marks <key>`); a logo
// missing there shows the puzzle piece on the phone only.
const clients = resolve(import.meta.dirname, "../../../../../..");
const androidRes = resolve(clients, "apps/android/app/src/main/res");
const iosLogos = resolve(clients, "apps/apple/Resources/Assets.xcassets/ProviderLogos");
const densities = ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"];
// Brand keys that share another key's artwork on every client.
const aliases = new Set(["googleworkspace", "colab"]);
const keys = providerBrandLogoNames.filter((key) => !aliases.has(key));

/** The number of pixels of an 8-bit RGBA PNG that are not fully transparent. */
function visiblePixels(png: Buffer) {
  const width = png.readUInt32BE(16);
  const height = png.readUInt32BE(20);
  expect([png[24], png[25]]).toEqual([8, 6]);
  const chunks: Buffer[] = [];
  for (let at = 8; at < png.length; ) {
    const length = png.readUInt32BE(at);
    if (png.toString("ascii", at + 4, at + 8) === "IDAT")
      chunks.push(png.subarray(at + 8, at + 8 + length));
    at += length + 12;
  }
  const data = inflateSync(Buffer.concat(chunks));
  const stride = width * 4;
  let previous = Buffer.alloc(stride);
  let visible = 0;
  for (let y = 0; y < height; y++) {
    const filter = data[y * (stride + 1)]!;
    const row = Buffer.from(
      data.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1))
    );
    for (let x = 0; x < stride; x++) {
      const left = x >= 4 ? row[x - 4]! : 0;
      const up = previous[x]!;
      const upLeft = x >= 4 ? previous[x - 4]! : 0;
      const p = left + up - upLeft;
      const [pa, pb, pc] = [Math.abs(p - left), Math.abs(p - up), Math.abs(p - upLeft)];
      const predictor = [
        0,
        left,
        up,
        (left + up) >> 1,
        pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft,
      ][filter]!;
      row[x] = (row[x]! + predictor) & 0xff;
    }
    for (let x = 3; x < stride; x += 4) if (row[x]! > 0) visible++;
    previous = row;
  }
  return visible;
}

describe("phone provider artwork", () => {
  it.each(keys)("ships %s on Android at every density, not blank", (key) => {
    for (const density of densities) {
      const file = resolve(androidRes, `drawable-${density}`, `provider_${key}.png`);
      expect(existsSync(file), file).toBe(true);
      expect(visiblePixels(readFileSync(file)), file).toBeGreaterThan(0);
    }
  });

  it.each(keys)("ships %s on iOS", (key) => {
    const set = resolve(iosLogos, `provider-${key}.imageset`);
    const contents = JSON.parse(
      readFileSync(resolve(set, "Contents.json"), "utf8")
    ) as {
      images: { filename?: string }[];
    };
    const files = contents.images.flatMap((image) => image.filename ?? []);
    expect(files.length, set).toBeGreaterThan(0);
    for (const file of files) expect(existsSync(resolve(set, file)), file).toBe(true);
  });
});
