import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { targetArch } from "./build-target";
import { copyNativeFile } from "./native-build-cache";

type GypTarget = {
  target_name: string;
  sources: string[];
  defines?: string[];
  include_dirs?: string[];
  libraries?: string[];
  xcode_settings?: Record<string, string>;
};

const clangArch = targetArch === "x64" ? "x86_64" : targetArch;

function xcrun(args: string[], cwd: string) {
  execFileSync("xcrun", args, { cwd, stdio: "inherit" });
}

function nodeHeaders() {
  const headers =
    process.env.COMMA_NODE_HEADERS ??
    resolve(dirname(process.execPath), "../include/node");
  if (!existsSync(resolve(headers, "node_api.h"))) {
    throw new Error(`Node-API headers were not found at ${headers}`);
  }
  return headers;
}

/** Builds a binding.gyp addon with `xcrun clang++`, for hosts where node-gyp cannot target macOS. */
export function buildNativeAddonWithXcrun({
  addonDir,
  label,
  output,
  targetName,
  configuration,
  incremental,
}: {
  addonDir: string;
  label: string;
  output: string;
  targetName: string;
  configuration: "release" | "debug";
  incremental: boolean;
}) {
  const gyp = JSON.parse(readFileSync(resolve(addonDir, "binding.gyp"), "utf8")) as {
    targets: GypTarget[];
  };
  const target = gyp.targets.find((candidate) => candidate.target_name === targetName);
  if (!target) throw new Error(`${addonDir}/binding.gyp has no target ${targetName}`);
  const settings = target.xcode_settings ?? {};
  const built = resolve(
    addonDir,
    "build",
    configuration === "release" ? "Release" : "Debug",
    `${targetName}.node`
  );
  mkdirSync(dirname(built), { recursive: true });
  xcrun(
    [
      "clang++",
      "-target",
      `${clangArch}-apple-macosx${settings.MACOSX_DEPLOYMENT_TARGET ?? "13.0"}`,
      `-std=${settings.CLANG_CXX_LANGUAGE_STANDARD ?? "c++17"}`,
      ...(settings.CLANG_ENABLE_OBJC_ARC === "YES" ? ["-fobjc-arc"] : []),
      ...(settings.GCC_ENABLE_OBJC_EXCEPTIONS === "YES" ? ["-fobjc-exceptions"] : []),
      ...(configuration === "release" ? ["-O3"] : ["-O0", "-g"]),
      "-fvisibility=hidden",
      "-DBUILDING_NODE_EXTENSION",
      `-DNODE_GYP_MODULE_NAME=${targetName}`,
      ...(target.defines ?? []).map((define) => `-D${define}`),
      `-I${nodeHeaders()}`,
      ...(target.include_dirs ?? []).map((dir) => `-I${resolve(addonDir, dir)}`),
      "-bundle",
      "-undefined",
      "dynamic_lookup",
      ...target.sources.map((source) => resolve(addonDir, source)),
      ...(target.libraries ?? []).flatMap((library) => library.split(/\s+/)),
      "-o",
      built,
    ],
    addonDir
  );
  copyNativeFile(built, output, incremental);
  console.log(`${label} built (${configuration}).`);
}

function escapeXml(value: string) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function plist(entries: Record<string, string | boolean>) {
  const body = Object.entries(entries)
    .map(([key, value]) =>
      typeof value === "boolean"
        ? `\t<key>${escapeXml(key)}</key>\n\t<${value}/>`
        : `\t<key>${escapeXml(key)}</key>\n\t<string>${escapeXml(value)}</string>`
    )
    .join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
${body}
</dict>
</plist>
`;
}

/** Builds the MenuBarHost app as its Xcode project does, with `xcrun swiftc` instead of xcodebuild. */
export function buildMenuBarHostWithXcrun({
  projectDir,
  appPath,
  executableName,
  bundleId,
  configuration,
}: {
  projectDir: string;
  appPath: string;
  executableName: string;
  bundleId: string;
  configuration: "release" | "debug";
}) {
  const sourceDir = resolve(projectDir, "Comma");
  const project = readFileSync(
    resolve(projectDir, "Comma.xcodeproj/project.pbxproj"),
    "utf8"
  );
  const referencedSources = [
    ...project.matchAll(
      /isa = PBXFileReference; lastKnownFileType = sourcecode\.swift;[^}]*?path = ("[^"]+"|[^;]+);[^}]*?sourceTree = "<group>";/g
    ),
  ].map(([, path = ""]) => resolve(projectDir, path.replace(/^"|"$/g, "")));
  const sources = [
    ...readdirSync(sourceDir)
      .filter((name) => name.endsWith(".swift"))
      .toSorted()
      .map((name) => resolve(sourceDir, name)),
    ...referencedSources,
  ];
  const contents = resolve(appPath, "Contents");
  mkdirSync(resolve(contents, "MacOS"), { recursive: true });
  xcrun(
    [
      "swiftc",
      "-target",
      `${clangArch}-apple-macosx14.0`,
      "-swift-version",
      "5",
      "-module-name",
      executableName,
      ...[
        "DisableOutwardActorInference",
        "GlobalActorIsolatedTypesUsability",
        "InferIsolatedConformances",
        "InferSendableFromCaptures",
        "NonisolatedNonsendingByDefault",
        "MemberImportVisibility",
      ].flatMap((feature) => ["-enable-upcoming-feature", feature]),
      configuration === "release" ? "-O" : "-Onone",
      "-whole-module-optimization",
      "-Xlinker",
      "-rpath",
      "-Xlinker",
      "@executable_path/../Frameworks",
      ...sources,
      "-o",
      resolve(contents, "MacOS", executableName),
    ],
    projectDir
  );
  writeFileSync(
    resolve(contents, "Info.plist"),
    plist({
      CFBundleDevelopmentRegion: "en",
      CFBundleExecutable: executableName,
      CFBundleIdentifier: bundleId,
      CFBundleInfoDictionaryVersion: "6.0",
      CFBundleName: executableName,
      CFBundlePackageType: "APPL",
      CFBundleShortVersionString: "1.0",
      CFBundleVersion: "1",
      LSMinimumSystemVersion: "14.0",
      LSUIElement: true,
      NSHumanReadableCopyright: "",
    })
  );
  writeFileSync(resolve(contents, "PkgInfo"), "APPL????");
}
