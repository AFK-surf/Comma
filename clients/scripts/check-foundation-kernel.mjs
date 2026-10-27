#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { format, resolveConfig } from "prettier";
import ts from "typescript";
import {
  findHasBeforeUniversalSubjects,
  findNativeSessionAdmissionViolations,
  findUncappedLoops,
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

check("renderers make no Comma API requests beyond the shrinking allowlist", () => {
  // Requests belong to the client core (packages/core): a renderer subscribes to
  // its topics and makes its named calls. Files still doing it themselves are
  // listed; the list only shrinks.
  const allowlist = readJson(fromClients("scripts/renderer-requests-allowlist.json"));
  const roots = [
    "packages/app/src",
    "packages/ui/src",
    "apps/web/src",
    "apps/electron/src/renderer",
  ];
  const files = roots
    .flatMap((root) => listSourceFiles(fromClients(root)))
    .map((file) => path.relative(clientsRoot, file).split(path.sep).join("/"))
    .filter((file) => !/\/test\/|\.test\.|\.spec\.|\.stories\./.test(file));
  const kinds = {
    requests: /\bcreateCommaApi\s*\(|(^|[^.\w])fetch\s*\(|new\s+EventSource\s*\(/m,
    apiClient: /\bCommaApiClient\b|\buseChatApi\s*\(|\bapi\.[a-zA-Z]+\(/,
  };
  const problems = [];
  for (const [kind, pattern] of Object.entries(kinds)) {
    const allowed = new Set(allowlist[kind]);
    const found = new Set(
      files.filter((file) => pattern.test(readFileSync(fromClients(file), "utf8")))
    );
    for (const file of found)
      if (!allowed.has(file))
        problems.push(
          `${file} makes Comma API requests (${kind}); make them core calls and topics`
        );
    for (const file of allowed)
      if (!found.has(file))
        problems.push(
          `${file} no longer makes requests (${kind}); remove it from scripts/renderer-requests-allowlist.json`
        );
  }
  if (problems.length > 0) fail(problems.join("\n"));
});

check(
  "UI code takes time only from the UI clock, beyond the shrinking allowlist",
  () => {
    // Business timing (polls, retries, expiry) is the client core's, on its Clock.
    // Presentation timing goes through the one UI clock (packages/ui/src/clock),
    // which a test replaces with a virtual clock and steps. Files that still use
    // platform timers or clock reads directly are listed with their count; the
    // counts only shrink. Comma Admin takes all of its time from its Effect services.
    const allowlist = readJson(fromClients("scripts/ui-time-allowlist.json")).time;
    const files = [
      "apps/admin/src",
      "packages/app/src",
      "packages/ui/src",
      "apps/web/src",
      "apps/electron/src/renderer",
    ]
      .flatMap((root) => listSourceFiles(fromClients(root)))
      .map((file) => path.relative(clientsRoot, file).split(path.sep).join("/"))
      .filter(
        (file) =>
          !file.startsWith("packages/ui/src/clock/") &&
          !/\/test\/|\.test\.|\.spec\.|\.stories\./.test(file)
      );
    const timing =
      /\b(?:setTimeout|setInterval|requestAnimationFrame)\s*\(|\b(?:Date|performance)\.now\s*\(|\bnew\s+Date\s*\(\s*\)/g;
    const problems = [];
    const counted = new Map();
    for (const file of files) {
      const uses = readFileSync(fromClients(file), "utf8").match(timing)?.length ?? 0;
      if (uses > 0) counted.set(file, uses);
    }
    for (const [file, uses] of counted) {
      const allowed = allowlist[file] ?? 0;
      if (uses > allowed)
        problems.push(
          `${file} uses platform timers or clock reads (${uses}, ${allowed} allowed); move business timing into the core, and use uiClock from @comma/ui/clock for presentation timing`
        );
      else if (uses < allowed)
        problems.push(
          `${file} has ${uses} timers or clock reads now; lower it to ${uses} in scripts/ui-time-allowlist.json`
        );
    }
    for (const file of Object.keys(allowlist))
      if (!counted.has(file))
        problems.push(
          `${file} no longer uses platform time; remove it from scripts/ui-time-allowlist.json`
        );
    if (problems.length > 0) fail(problems.join("\n"));
  }
);

check(
  "the client core runs its work as Effect fibers, beyond its hosts and the shrinking allowlist",
  () => {
    // The core's work runs on Effect: fibers in scopes, time on its Clock, queues for
    // inputs, so every run is recorded and plays again. Host adapters (hosts/) and the
    // test kit (testing/) meet the platform's promises and timers. Files still written
    // with async functions, promises, raw timers or unsafe deferreds are listed with their count; it
    // only shrinks.
    const allowlist = readJson(fromClients("scripts/core-async-allowlist.json")).async;
    const files = listSourceFiles(fromClients("packages/core/src"))
      .map((file) => path.relative(clientsRoot, file).split(path.sep).join("/"))
      .filter((file) => !/\/test\/|\.test\.|\/hosts\/|\/testing\//.test(file));
    const imperative =
      /\basync\s+(?=[\w#(*<])|\b(?:setTimeout|setInterval)\s*\(|\bDate\.now\s*\(|\bnew\s+Promise\b|\.then\s*\(|\bDeferred\.(?:make|done|isDone)Unsafe\b/g;
    const problems = [];
    const counted = new Map();
    for (const file of files) {
      const uses =
        readFileSync(fromClients(file), "utf8").match(imperative)?.length ?? 0;
      if (uses > 0) counted.set(file, uses);
    }
    for (const [file, uses] of counted) {
      const allowed = allowlist[file] ?? 0;
      if (uses > allowed)
        problems.push(
          `${file} has ${uses} async functions, promises, raw timers or unsafe deferreds (${allowed} allowed); write it with fibers, queues and the core's Clock`
        );
      else if (uses < allowed)
        problems.push(
          `${file} has ${uses} now; lower it to ${uses} in scripts/core-async-allowlist.json`
        );
    }
    for (const file of Object.keys(allowlist))
      if (!counted.has(file))
        problems.push(
          `${file} no longer has any; remove it from scripts/core-async-allowlist.json`
        );
    if (problems.length > 0) fail(problems.join("\n"));
  }
);

check("app and UI stylesheets keep :has() anchors off universal subjects", () => {
  // `.a:has(.b) *` (also as nested `&, & *`) turns every `:has()` anchor into a
  // whole-subtree restyle in Chromium on each insertion beneath it: each
  // streamed block restyled its whole message. Style the anchor itself, or
  // name what is inside it. What the parser cannot read fails too.
  const files = ["packages/app/src", "packages/ui/src"].flatMap((root) =>
    listSourceFiles(fromClients(root), /\.css$/)
  );
  const problems = files.flatMap((file) =>
    findHasBeforeUniversalSubjects(readFileSync(file, "utf8"), file).map(
      (problem) => `${path.relative(clientsRoot, file)}: ${problem}`
    )
  );
  if (problems.length > 0) fail(problems.join("\n"));
});

check("looping animations move at most 60 times a second", () => {
  // An endless loop on a 120 or 240 Hz display redraws two or four times as
  // often as on a 60 Hz one; a running task's shine cost half a core. Loops
  // use steps() (linear) or a --motion-loop-* staircase (eased, tokens/motion.ts).
  const roots = ["apps", "packages"].flatMap((group) =>
    readdirSync(fromClients(group), { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => fromClients(`${group}/${entry.name}/src`))
  );
  const files = roots
    .filter((root) => existsSync(root))
    .flatMap((root) => listSourceFiles(root, /\.(css|ts|tsx)$/))
    .filter(
      (file) =>
        !/[\\/](test|tests|e2e|__tests__)[\\/]/.test(file) &&
        !/\.(test|spec|stories)\.tsx?$/.test(file)
    );
  const problems = files.flatMap((file) =>
    findUncappedLoops(readFileSync(file, "utf8")).map(
      (problem) => `${path.relative(clientsRoot, file)} ${problem}`
    )
  );
  if (problems.length > 0) fail(problems.join("\n"));
});

check("Electron e2e close their apps through closeElectronTestApp", () => {
  // A raw ElectronApplication.close() can wait over a minute for Chromium to flush the throwaway profile after Main
  // finished its shutdown; closeElectronTestApp ends at Main's shutdown report. A close that is itself the behavior
  // under test says so on the line before: `// e2e-raw-close: <why>`.
  const helper = "apps/electron/e2e/close-electron-test-app.ts";
  const files = ["apps/electron/e2e", "e2e"]
    .flatMap((root) => listSourceFiles(fromClients(root)))
    .filter((file) => !file.includes(`${path.sep}node_modules${path.sep}`));
  const config = ts.getParsedCommandLineOfConfigFile(
    fromClients("tsconfig.test.json"),
    {},
    { ...ts.sys, onUnRecoverableConfigFileDiagnostic: () => {} }
  );
  const program = ts.createProgram(files, {
    ...config.options,
    noEmit: true,
    skipLibCheck: true,
    incremental: false,
    composite: false,
  });
  const checker = program.getTypeChecker();
  const problems = [];
  for (const file of files) {
    const relative = path.relative(clientsRoot, file).split(path.sep).join("/");
    if (relative === helper) continue;
    const source = program.getSourceFile(file);
    if (!source) continue;
    const lines = source.text.split("\n");
    const visit = (node) => {
      if (
        ts.isCallExpression(node) &&
        ts.isPropertyAccessExpression(node.expression) &&
        node.expression.name.text === "close"
      ) {
        const type = checker.getNonNullableType(
          checker.getTypeAtLocation(node.expression.expression)
        );
        if (type.getSymbol()?.getName() === "ElectronApplication") {
          const line = source.getLineAndCharacterOfPosition(node.getStart()).line;
          if (!lines[line - 1]?.includes("e2e-raw-close:"))
            problems.push(
              `${relative}:${line + 1} closes an Electron app directly; use closeElectronTestApp`
            );
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  if (problems.length > 0) fail(problems.join("\n"));
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

function listSourceFiles(directory, pattern = /\.(ts|tsx)$/) {
  return readdirSync(directory, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile() && pattern.test(entry.name))
    .map((entry) => path.join(entry.parentPath, entry.name));
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
