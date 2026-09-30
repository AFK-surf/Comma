#!/usr/bin/env node
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { format, resolveConfig } from "prettier";
import {
  findNativeSessionAdmissionViolations,
  formatFoundationCheckList,
  foundationCheckId,
} from "./check-foundation-kernel-lib.mjs";
import {
  collectNativeCapabilityEntries,
  createRelativeImportSpecifierResolver,
  renderNativeCapabilityArtifacts,
  renderNativeCapabilityMainArtifacts,
} from "./generate-native-capability-artifacts-lib.mjs";
import {
  nativeCapabilityRegistry,
  nativePartnerProtocolRegistry,
} from "../packages/native-bridge/src/capability-leaves.ts";
import {
  renderNativePartnerJSONSchema,
  renderNativePartnerSwift,
} from "../packages/native-bridge/scripts/native-partner-codegen.mjs";

const clientsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const checks = [];
const args = process.argv.slice(2).filter((arg) => arg !== "--");
if (args.some((arg) => arg !== "--list")) {
  console.error("Usage: check-foundation-kernel.mjs [--list]");
  process.exit(2);
}
const listMode = args.includes("--list");

check("web/shared packages do not depend on Electron runtime packages", () => {
  const packageFiles = [
    "apps/web/package.json",
    "packages/app/package.json",
    "packages/native-bridge/package.json",
  ];

  for (const packageFile of packageFiles) {
    const packageJson = readJson(fromClients(packageFile));
    const blocks = [
      "dependencies",
      "devDependencies",
      "peerDependencies",
      "optionalDependencies",
    ];

    for (const block of blocks) {
      const dependencies = packageJson[block] ?? {};
      for (const dependencyName of Object.keys(dependencies)) {
        if (isForbiddenWebDependency(dependencyName)) {
          fail(`${packageFile} ${block} includes ${dependencyName}`);
        }
      }
    }
  }
});

check("client tsconfigs do not enable legacy decorators", () => {
  const tsconfigFiles = ["apps/electron/tsconfig.main.json", "tsconfig.test.json"];

  for (const tsconfigFile of tsconfigFiles) {
    const tsconfig = readJson(fromClients(tsconfigFile));
    if (tsconfig.compilerOptions?.experimentalDecorators === true) {
      fail(`${tsconfigFile} enables experimentalDecorators without decorator usage`);
    }
  }
});

check("native capability session admission is exhaustively classified", () => {
  const violations = findNativeSessionAdmissionViolations(nativeCapabilityRegistry);

  if (violations.length > 0) {
    fail(violations.join("; "));
  }
});

check("native capability generated artifacts are up to date", async () => {
  const capabilitySourceFile = fromClients(
    "packages/native-bridge/src/capability-leaves.ts"
  );
  const capabilitySource = readFileSync(capabilitySourceFile, "utf8");
  const generatedArtifactFile = fromClients(
    "packages/native-bridge/src/generated/native-capability-artifacts.ts"
  );
  const generatedMainArtifactFile = fromClients(
    "apps/electron/src/main/generated/native-capability-main-artifacts.ts"
  );
  const entries = collectNativeCapabilityEntries(
    capabilitySource,
    capabilitySourceFile
  );
  const generatedArtifactPrettierOptions = {
    ...(await resolveConfig(generatedArtifactFile)),
    parser: "typescript",
  };
  const generatedMainArtifactPrettierOptions = {
    ...(await resolveConfig(generatedMainArtifactFile)),
    parser: "typescript",
  };
  const expectedArtifact = await format(
    renderNativeCapabilityArtifacts(entries),
    generatedArtifactPrettierOptions
  );
  const expectedMainArtifact = await format(
    renderNativeCapabilityMainArtifacts(entries, {
      handlerModuleSpecifier: createRelativeImportSpecifierResolver({
        outputFile: generatedMainArtifactFile,
        sourceFile: capabilitySourceFile,
      }),
    }),
    generatedMainArtifactPrettierOptions
  );
  const actualArtifact = readFileSync(generatedArtifactFile, "utf8");
  const actualMainArtifact = readFileSync(generatedMainArtifactFile, "utf8");

  if (actualArtifact !== expectedArtifact) {
    fail(
      "native capability generated artifacts are stale. Run `pnpm generate:native-bridge`."
    );
  }

  if (actualMainArtifact !== expectedMainArtifact) {
    fail(
      "native capability main artifacts are stale. Run `pnpm generate:native-bridge`."
    );
  }
});

check("native partner leaf contracts are generated and up to date", async () => {
  const generatedJSONSchemaFile = fromClients(
    "packages/chat-contract/generated/native-partner-contracts.schema.json"
  );
  const generatedSwiftFile = fromClients(
    "packages/chat-contract/generated/CommaChatWire.generated.swift"
  );
  const generatedNotchSwiftFile = fromClients(
    "apps/electron/native/macos/NotchHost/Sources/NotchHost/CommaNotchContracts.generated.swift"
  );
  const expectedJSONSchema = await format(
    renderNativePartnerJSONSchema(nativePartnerProtocolRegistry),
    {
      ...(await resolveConfig(generatedJSONSchemaFile)),
      parser: "json",
    }
  );
  const expectedSwift = renderNativePartnerSwift(nativePartnerProtocolRegistry);
  const expectedNotchSwift = renderNativePartnerSwift(
    nativePartnerProtocolRegistry.filter(({ id }) => id === "notch.scene-payload")
  );
  const actualJSONSchema = readFileSync(generatedJSONSchemaFile, "utf8");
  const actualSwift = readFileSync(generatedSwiftFile, "utf8");
  const actualNotchSwift = readFileSync(generatedNotchSwiftFile, "utf8");

  if (actualJSONSchema !== expectedJSONSchema) {
    fail(
      "native partner JSON Schema artifacts are stale. Run `pnpm --filter @comma/native-bridge generate:partners`."
    );
  }

  if (actualSwift !== expectedSwift) {
    fail(
      "native partner Swift artifacts are stale. Run `pnpm --filter @comma/native-bridge generate:partners`."
    );
  }

  if (actualNotchSwift !== expectedNotchSwift) {
    fail(
      "native partner NotchHost Swift artifacts are stale. Run `pnpm --filter @comma/native-bridge generate:partners`."
    );
  }

  const generatedManifest = JSON.parse(actualJSONSchema)["x-comma-native-protocols"];
  const expectedLeafIds = nativePartnerProtocolRegistry.map(({ id }) => id).toSorted();
  const generatedLeafIds = generatedManifest.map(({ id }) => id).toSorted();

  if (JSON.stringify(generatedLeafIds) !== JSON.stringify(expectedLeafIds)) {
    fail("native partner generated manifest does not cover every protocol leaf");
  }
});

let failed = 0;
const results = [];

for (const { id, name, run } of checks) {
  try {
    await run();
    results.push({ id, name, status: "pass" });
    if (!listMode) {
      console.log(`PASS ${name}`);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    failed += 1;
    results.push({ error: message, id, name, status: "fail" });
    if (!listMode) {
      console.error(`FAIL ${name}`);
      console.error(message);
    }
  }
}

if (listMode) {
  console.log(JSON.stringify(formatFoundationCheckList(results), null, 2));
}

if (failed > 0) {
  process.exit(1);
}

function check(name, run) {
  checks.push({ id: foundationCheckId(name), name, run });
}

function fail(message) {
  throw new Error(message);
}

function fromClients(relativePath) {
  return path.join(clientsRoot, relativePath);
}

function readJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function isForbiddenWebDependency(specifier) {
  return (
    specifier === "electron" ||
    specifier === "velopack" ||
    specifier.startsWith("@electron/") ||
    specifier.startsWith("@electron-forge/") ||
    specifier.startsWith("@neon-rs/")
  );
}
