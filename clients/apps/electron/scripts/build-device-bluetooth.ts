import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const app = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const output = resolve(app, "dist/native/macos");
mkdirSync(output, { recursive: true });
const localHeaders = resolve(dirname(process.execPath), "../include/node");
const headers =
  process.env.COMMA_NODE_HEADERS ??
  (existsSync(resolve(localHeaders, "node_api.h"))
    ? localHeaders
    : resolve(
        process.env.HOME!,
        "Library/Caches/node-gyp",
        process.versions.node,
        "include/node"
      ));
if (!existsSync(resolve(headers, "node_api.h")))
  execFileSync(resolve(app, "../../../node_modules/.bin/node-gyp"), ["install"], {
    stdio: "inherit",
  });
execFileSync(
  "xcrun",
  [
    "swiftc",
    "-swift-version",
    "6",
    "-parse-as-library",
    "-emit-library",
    "-module-name",
    "CommaDeviceBluetooth",
    "-target",
    `${process.arch === "arm64" ? "arm64" : "x86_64"}-apple-macosx13.0`,
    "-Xlinker",
    "-install_name",
    "-Xlinker",
    "@loader_path/libCommaDeviceBluetooth.dylib",
    resolve(app, "../apple/Shared/Bluetooth/DeviceBluetooth.swift"),
    "-o",
    resolve(output, "libCommaDeviceBluetooth.dylib"),
  ],
  { stdio: "inherit" }
);
execFileSync(
  "xcrun",
  [
    "clang++",
    "-std=c++20",
    "-shared",
    "-undefined",
    "dynamic_lookup",
    "-DNAPI_VERSION=8",
    `-I${headers}`,
    resolve(app, "native/macos/DeviceBluetooth/bridge.cc"),
    `-L${output}`,
    "-lCommaDeviceBluetooth",
    "-o",
    resolve(output, "comma-device-bluetooth.node"),
  ],
  { stdio: "inherit" }
);
