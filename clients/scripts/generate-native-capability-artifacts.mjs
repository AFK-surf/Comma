#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { format, resolveConfig } from "prettier";
import {
  collectNativeCapabilityEntries,
  createRelativeImportSpecifierResolver,
  renderNativeCapabilityArtifacts,
  renderNativeCapabilityMainArtifacts,
} from "./generate-native-capability-artifacts-lib.mjs";

const clientsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourceFile = path.join(
  clientsRoot,
  "packages/native-bridge/src/capability-leaves.ts"
);
const generatedFile = path.join(
  clientsRoot,
  "packages/native-bridge/src/generated/native-capability-artifacts.ts"
);
const generatedMainFile = path.join(
  clientsRoot,
  "apps/electron/src/main/generated/native-capability-main-artifacts.ts"
);
const entries = collectNativeCapabilityEntries(
  readFileSync(sourceFile, "utf8"),
  sourceFile
);
const generatedFilePrettierOptions = {
  ...(await resolveConfig(generatedFile)),
  parser: "typescript",
};
const generatedMainFilePrettierOptions = {
  ...(await resolveConfig(generatedMainFile)),
  parser: "typescript",
};
const nextSource = await format(
  renderNativeCapabilityArtifacts(entries),
  generatedFilePrettierOptions
);
const nextMainSource = await format(
  renderNativeCapabilityMainArtifacts(entries, {
    handlerModuleSpecifier: createRelativeImportSpecifierResolver({
      outputFile: generatedMainFile,
      sourceFile,
    }),
  }),
  generatedMainFilePrettierOptions
);

if (process.argv.includes("--check")) {
  const currentSource = readFileSync(generatedFile, "utf8");
  const currentMainSource = readFileSync(generatedMainFile, "utf8");

  if (currentSource !== nextSource) {
    console.error(
      "Generated native capability artifacts are stale. Run `pnpm --dir clients generate:native-bridge`."
    );
    process.exit(1);
  }

  if (currentMainSource !== nextMainSource) {
    console.error(
      "Generated native capability main artifacts are stale. Run `pnpm --dir clients generate:native-bridge`."
    );
    process.exit(1);
  }

  console.log("Generated native capability artifacts are up to date.");
} else {
  writeFileSync(generatedFile, nextSource);
  writeFileSync(generatedMainFile, nextMainSource);
  console.log(`Wrote ${path.relative(clientsRoot, generatedFile)}`);
  console.log(`Wrote ${path.relative(clientsRoot, generatedMainFile)}`);
}
