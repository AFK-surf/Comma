#!/usr/bin/env node

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { format, resolveConfig } from "prettier";
import { nativePartnerProtocolRegistry } from "../src/capability-leaves.ts";
import {
  renderNativePartnerJSONSchema,
  renderNativePartnerSwift,
} from "./native-partner-codegen.mjs";

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const generatedRoot = path.resolve(packageRoot, "../chat-contract/generated");
const jsonSchemaFile = path.join(generatedRoot, "native-partner-contracts.schema.json");
const swiftFile = path.join(generatedRoot, "CommaChatWire.generated.swift");
const notchSwiftFile = path.resolve(
  packageRoot,
  "../../apps/electron/native/macos/NotchHost/Sources/NotchHost/CommaNotchContracts.generated.swift"
);
const notchRegistry = nativePartnerProtocolRegistry.filter(
  ({ id }) => id === "notch.scene-payload"
);
const jsonSchemaSource = await format(
  renderNativePartnerJSONSchema(nativePartnerProtocolRegistry),
  {
    ...(await resolveConfig(jsonSchemaFile)),
    parser: "json",
  }
);
const outputs = [
  [jsonSchemaFile, jsonSchemaSource],
  [swiftFile, renderNativePartnerSwift(nativePartnerProtocolRegistry)],
  [notchSwiftFile, renderNativePartnerSwift(notchRegistry)],
];

if (process.argv.includes("--check")) {
  let stale = false;
  for (const [file, expected] of outputs) {
    let actual = "";
    try {
      actual = readFileSync(file, "utf8");
    } catch {
      // The missing artifact is reported through the same freshness failure.
    }
    if (actual !== expected) {
      console.error(
        `${path.relative(packageRoot, file)} is stale. Run \`pnpm --filter @comma/native-bridge generate:partners\`.`
      );
      stale = true;
    }
  }
  if (stale) process.exit(1);
  console.log("Generated native partner contracts are up to date.");
} else {
  mkdirSync(generatedRoot, { recursive: true });
  for (const [file, content] of outputs) {
    writeFileSync(file, content);
    console.log(`Wrote ${path.relative(packageRoot, file)}`);
  }
}
