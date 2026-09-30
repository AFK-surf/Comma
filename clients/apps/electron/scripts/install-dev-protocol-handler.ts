import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { getCommaReleaseConfig } from "../src/release-config";
import { prepareDevElectronBundle } from "./dev-electron-bundle";

// A deep link must launch the same bundle `electron-forge start` runs.
const electronExecutable = prepareDevElectronBundle().executablePath;
const appRoot = resolve(import.meta.dirname, "..");
const releaseConfig = getCommaReleaseConfig();
const handlerName = `${releaseConfig.productName} URL Handler`;
// Forge clears .vite while starting the source app. Keep its URL handler alive.
const bundlePath = resolve(
  appRoot,
  ".dev-electron/protocol-handler",
  `${handlerName}.app`
);
const contentsPath = resolve(bundlePath, "Contents");
const executablePath = resolve(contentsPath, "MacOS", "CommaURLHandler");
const sourcePath = resolve(import.meta.dirname, "CommaDevURLHandler.swift");

function xml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function run(command: string, args: string[]) {
  const result = spawnSync(command, args, { stdio: "inherit", shell: false });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} exited with ${result.status}`);
  }
}

mkdirSync(resolve(contentsPath, "MacOS"), { recursive: true });
writeFileSync(
  resolve(contentsPath, "Info.plist"),
  `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>CommaURLHandler</string>
  <key>CFBundleIdentifier</key><string>${xml(`${releaseConfig.appBundleId}.url-handler`)}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${xml(handlerName)}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>CommaBuildFlavor</key><string>${xml(releaseConfig.flavor)}</string>
  <key>CommaElectronExecutable</key><string>${xml(electronExecutable)}</string>
  <key>CommaProjectRoot</key><string>${xml(appRoot)}</string>
  <key>CommaURLScheme</key><string>${xml(releaseConfig.urlScheme)}</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>${xml(releaseConfig.productName)}</string>
    <key>CFBundleURLSchemes</key><array><string>${xml(releaseConfig.urlScheme)}</string></array>
  </dict></array>
</dict>
</plist>
`
);

run("xcrun", [
  "swiftc",
  "-framework",
  "Cocoa",
  "-framework",
  "CoreServices",
  sourcePath,
  "-o",
  executablePath,
]);
chmodSync(executablePath, 0o755);

const launchServices =
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
run(launchServices, ["-f", bundlePath]);
run(executablePath, ["--install"]);

console.log(
  `Registered ${releaseConfig.urlScheme}:// for ${releaseConfig.productName} development.`
);
