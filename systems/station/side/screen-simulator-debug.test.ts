// A simulator's debugging (screens/sim-debug.ts) on a real Mac with Xcode, after still.fail's side test: a simulator of this
// test's own made and booted (deleted afterwards), a small app built for it installed from a zip, started again, the
// device's light and dark set, a real screenshot and a real movie. Real time, a real device: a side test.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { platform, tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { SimDebug } from "../src/screens/sim-debug.ts";
import { SIMCTL } from "../src/screens/simulator.ts";

const APP = "surf.comma.side.debug";
const SOURCE = `
import UIKit
import os
let logger = Logger(subsystem: "surf.comma.side", category: "side")
@objc(SideScene) class Scene: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    window = UIWindow(windowScene: scene as! UIWindowScene)
    window!.rootViewController = UIViewController()
    window!.makeKeyAndVisible()
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
      logger.error("side-logger")
      NSLog("side-nslog")
      print("side-print")
    }
  }
}
@objc(SideDelegate) class Delegate: UIResponder, UIApplicationDelegate {}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, "SideDelegate")
`;
const PLIST = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${APP}</string>
<key>CFBundleName</key><string>SideDebug</string>
<key>CFBundleExecutable</key><string>SideDebug</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>UIApplicationSceneManifest</key><dict>
<key>UIApplicationSupportsMultipleScenes</key><false/>
<key>UISceneConfigurations</key><dict><key>UIWindowSceneSessionRoleApplication</key><array><dict>
<key>UISceneConfigurationName</key><string>Default</string>
<key>UISceneDelegateClassName</key><string>SideScene</string>
</dict></array></dict>
</dict>
</dict></plist>`;

const xcrun = (...args: string[]) => execFileSync("xcrun", args, { encoding: "utf8" }).trim();
// CoreSimulator's own, as the station's: `xcrun simctl` may first run `xcodebuild -runFirstLaunch` and its password window.
const simctl = (...args: string[]) => execFileSync(SIMCTL, args, { encoding: "utf8" }).trim();
const hasSimctl = platform() === "darwin" && existsSync(SIMCTL);
const run = async (file: string, args: string[]) => execFileSync(file, args, { encoding: "utf8", maxBuffer: 16 << 20 });
const OUT = process.env.COMMA_SIM_DEBUG_OUT;

test("a simulator's app installed, restarted, its light and dark set, a picture and a movie taken", { skip: !hasSimctl && "no Xcode simulators here" }, async () => {
  const runtimes = JSON.parse(simctl("list", "-j", "runtimes")).runtimes.filter((r: any) => r.isAvailable && r.platform === "iOS" && r.identifier.endsWith("iOS-27-2"));
  const runtime = runtimes.at(-1) ?? JSON.parse(simctl("list", "-j", "runtimes")).runtimes.filter((r: any) => r.isAvailable && r.platform === "iOS").at(-1);
  const type = runtime.supportedDeviceTypes.find((t: any) => t.productFamily === "iPhone");
  const udid = simctl("create", `comma side debug ${process.pid}`, type.identifier, runtime.identifier);
  const dir = mkdtempSync(join(tmpdir(), "sim-debug-"));
  const picture = async () => {
    const jpg = join(dir, "shot.jpg");
    simctl("io", udid, "screenshot", "--type=jpeg", jpg);
    return readFileSync(jpg);
  };
  const debug = new SimDebug(SIMCTL, udid, run, picture);
  try {
    simctl("bootstatus", udid, "-b");
    const app = join(dir, "SideDebug.app");
    mkdirSync(app);
    writeFileSync(join(dir, "main.swift"), SOURCE);
    writeFileSync(join(app, "Info.plist"), PLIST);
    const sdk = xcrun("--sdk", "iphonesimulator", "--show-sdk-path");
    xcrun("--sdk", "iphonesimulator", "swiftc", "-target", `${process.arch === "arm64" ? "arm64" : "x86_64"}-apple-ios17.0-simulator`, "-sdk", sdk, join(dir, "main.swift"), "-o", join(app, "SideDebug"));
    execFileSync("codesign", ["-s", "-", "--force", app]);
    const zip = join(debug.installFolder(), `side-${process.pid}.zip`);
    execFileSync("ditto", ["-c", "-k", "--keepParent", app, zip]);

    assert.deepEqual(await debug.install(zip), { app: APP });
    assert.equal(existsSync(zip), false, "the file is let go of");

    // launchd says it a moment after it started.
    let first: { app: string; name: string } | null = null;
    for (let i = 0; i < 40 && first === null; i++) {
      await sleep(500);
      first = await debug.restart();
    }
    assert.deepEqual(first, { app: APP, name: "SideDebug" });

    const stands = (await debug.state()).appearance;
    assert.ok(stands === "light" || stands === "dark", String(stands));
    const other = stands === "dark" ? ("light" as const) : ("dark" as const);
    await debug.setAppearance(other);
    assert.equal((await debug.state()).appearance, other);

    const png = await debug.screenshot();
    assert.deepEqual([...png.subarray(0, 4)], [0x89, 0x50, 0x4e, 0x47]);
    if (OUT) writeFileSync(join(OUT, "sim-screenshot.png"), png);

    await debug.recordStart(null);
    assert.equal((await debug.state()).recording, true);
    // (simctl writes a frame only when the screen changes: light and dark make it change)
    for (const one of [stands, other, stands]) {
      await sleep(800);
      await debug.setAppearance(one);
    }
    await sleep(800);
    const movie = (await debug.recordStop())!;
    assert.ok(statSync(movie.path).size > 1000, "a movie came");
    assert.equal(readFileSync(movie.path).toString("latin1", 4, 8), "ftyp", "an MP4 with its moov whole");
    assert.ok(readFileSync(movie.path).includes(Buffer.from("moov")));
    if (OUT) writeFileSync(join(OUT, "sim-recording.mp4"), readFileSync(movie.path));
    assert.equal((await debug.state()).recording, false);
    console.log(JSON.stringify({ udid, png: png.length, movie: statSync(movie.path).size, appearance: other }));
    await movie.release?.();
  } finally {
    await debug.close();
    try {
      simctl("shutdown", udid);
    } catch {}
    simctl("delete", udid);
    rmSync(dir, { recursive: true, force: true });
  }
});
