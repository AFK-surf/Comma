// Run on macOS: node clients/apps/electron/scripts/generate-app-icons.mjs
// Production uses Icon Composer. Dev and Staging retain their detailed artwork
// with a continuous-corner mask. All flavors include PNG and legacy ICNS.
import { execFileSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

if (process.platform !== "darwin") {
  throw new Error("Generate the icons on macOS with Xcode 26 or later.");
}

const outputDir = fileURLToPath(new URL("../build/icons/", import.meta.url));
const sourceDir = fileURLToPath(
  new URL("../../../assets/brand/comma/app-icons/", import.meta.url)
);
const developerDir = execFileSync("xcode-select", ["-p"], {
  encoding: "utf8",
}).trim();
const iconComposer = resolve(
  developerDir,
  "../Applications/Icon Composer.app/Contents/Executables/ictool"
);
const temporaryDir = await mkdtemp(join(tmpdir(), "comma-app-icons-"));

async function renderIcon(flavor) {
  if (flavor === "prod") {
    const rendered = join(temporaryDir, "prod.png");
    execFileSync(iconComposer, [
      join(outputDir, flavor, "icon.icon"),
      "--export-image",
      "--output-file",
      rendered,
      "--platform",
      "macOS",
      "--rendition",
      "Default",
      "--width",
      "1024",
      "--height",
      "1024",
      "--scale",
      "1",
    ]);
    // ictool exports the full icon face. Legacy ICNS needs the Dock safe zone.
    return sharp(rendered)
      .resize(824, 824)
      .extend({
        top: 100,
        bottom: 100,
        left: 100,
        right: 100,
        background: { r: 0, g: 0, b: 0, alpha: 0 },
      })
      .png()
      .toBuffer();
  }

  // Unmasked artwork from 18cfe71a3e retains the highlights and surface detail.
  const artwork = await sharp(join(sourceDir, `${flavor}.png`))
    .resize(824, 824)
    .toBuffer();
  return sharp({
    create: {
      width: 1024,
      height: 1024,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite([
      { input: artwork, left: 100, top: 100 },
      { input: join(sourceDir, "macos-mask.svg"), blend: "dest-in" },
    ])
    .png()
    .toBuffer();
}

try {
  for (const flavor of ["dev", "staging", "prod"]) {
    const destination = join(outputDir, flavor);
    const icon = await renderIcon(flavor);
    const iconset = join(temporaryDir, `${flavor}.iconset`);
    await mkdir(destination, { recursive: true });
    await mkdir(iconset);

    for (const size of [16, 32, 128, 256, 512]) {
      for (const scale of [1, 2]) {
        const suffix = scale === 2 ? "@2x" : "";
        await sharp(icon)
          .resize(size * scale, size * scale)
          .png()
          .toFile(join(iconset, `icon_${size}x${size}${suffix}.png`));
      }
    }
    execFileSync("/usr/bin/iconutil", [
      "-c",
      "icns",
      iconset,
      "-o",
      join(temporaryDir, `${flavor}.icns`),
    ]);
    await writeFile(join(destination, "icon.png"), icon);
    await copyFile(
      join(temporaryDir, `${flavor}.icns`),
      join(destination, "icon.icns")
    );
    console.log(`Generated ${flavor} PNG and ICNS icons.`);
  }
} finally {
  await rm(temporaryDir, { recursive: true, force: true });
}
