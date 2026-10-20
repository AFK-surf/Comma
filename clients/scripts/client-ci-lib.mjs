import { execFileSync } from "node:child_process";
import { appendFile } from "node:fs/promises";

const exactClientFiles = new Set([
  ".npmrc",
  "package.json",
  "pnpm-lock.yaml",
  "pnpm-workspace.yaml",
  ".github/workflows/client-build.yml",
  ".github/workflows/client-checks.yml",
  // Generated from the card templates; a client test checks that it is current.
  "systems/apps/salix_agent/priv/dynamic_ui/card-contract.json",
]);

// A standalone Gradle project: no JS package, Electron build or other client uses it.
const androidRoot = "clients/apps/android/";
// Both phone apps carry the client core as Hermes bytecode, bundled from these packages' sources.
const mobileCoreSources = [
  "clients/packages/core/",
  "clients/packages/core-kernel/",
  "clients/packages/chat-contract/",
  "clients/packages/session-contract/",
  "clients/packages/recommendation-contract/",
  "clients/packages/mesh/",
  "clients/packages/i18n/",
];

export function isClientCiPath(path) {
  return (
    exactClientFiles.has(path) ||
    (path.startsWith("clients/") && !path.startsWith(androidRoot)) ||
    path.startsWith("systems/connector/salix-connect/") ||
    // How every macOS client job installs its dependencies and caches.
    path.startsWith(".github/actions/setup-macos-cache/")
  );
}

const connectorRoot = "systems/connector/salix-connect/";

export function isComputerUseCiPath(path) {
  return (
    path.startsWith(`${connectorRoot}native/macos/ComputerUseHost/`) ||
    path.startsWith(`${connectorRoot}native/macos/patches/permission-flow-`) ||
    path === `${connectorRoot}scripts/package-computer-use-helper.sh` ||
    path === `${connectorRoot}scripts/test_packaged_computer_use.py` ||
    path === `${connectorRoot}scripts/fixtures/permission_flow_panel.swift` ||
    path === "clients/apps/electron/e2e/computer-use-permissions.spec.ts"
  );
}

export function clientCiChanged(paths) {
  return paths.some((path) => isClientCiPath(path) && !isComputerUseCiPath(path));
}

// Inputs every client job shares: the toolchain, the lockfile and the workflow.
const sharedClientInputs = new Set([
  ".npmrc",
  "package.json",
  "pnpm-lock.yaml",
  "pnpm-workspace.yaml",
  ".github/workflows/client-checks.yml",
  "clients/package.json",
  "clients/playwright.config.ts",
  "clients/vitest.config.ts",
]);

export function computerUseCiChanged(paths) {
  // The helper checks build the Swift helper and run its own tests; client code
  // reaches them only through the one Electron module the probe spec imports.
  return paths.some(
    (path) =>
      isComputerUseCiPath(path) ||
      sharedClientInputs.has(path) ||
      path === "clients/apps/electron/src/main/open-wait.ts" ||
      path.startsWith(".github/actions/setup-macos-cache/")
  );
}

// Client apps the Electron app does not bundle; no package depends on them.
const outsideElectron = [
  "clients/apps/admin/",
  "clients/apps/apple/",
  "clients/apps/bft/",
  "clients/apps/web/",
  "clients/packages/apple-core/",
];

export function electronCiChanged(paths) {
  return paths.some(
    (path) =>
      isClientCiPath(path) &&
      !isComputerUseCiPath(path) &&
      !path.endsWith(".md") &&
      !outsideElectron.some((prefix) => path.startsWith(prefix))
  );
}

const synchInputs = [
  "clients/scripts/synch-smoke.mjs",
  "clients/apps/electron/package.json",
  "clients/apps/electron/scripts/build-native.ts",
  "clients/apps/electron/scripts/synch-release.ts",
  "clients/apps/electron/src/main/modules/synchronicity/",
  "clients/apps/electron/src/main/test/synchronicity-control.test.ts",
  // The unit test harness the smoke's synchronicity-control test runs under.
  "clients/packages/test-utils/src/",
  "clients/vitest.config.ts",
];

export function synchCiChanged(paths) {
  return paths.some(
    (path) =>
      sharedClientInputs.has(path) ||
      synchInputs.some(
        (input) => path === input || (input.endsWith("/") && path.startsWith(input))
      )
  );
}

export function appleCiChanged(paths) {
  return paths.some(
    (path) =>
      path === ".github/workflows/ios-testflight.yml" ||
      path === ".github/workflows/client-checks.yml" ||
      path === "pnpm-lock.yaml" ||
      ((path.startsWith("clients/apps/apple/") ||
        path.startsWith("clients/packages/apple-core/") ||
        mobileCoreSources.some((root) => path.startsWith(root)) ||
        path.startsWith(".github/actions/setup-apple-build/")) &&
        !path.endsWith(".md"))
  );
}

export function androidCiChanged(paths) {
  return paths.some(
    (path) =>
      path === ".github/workflows/client-checks.yml" ||
      path.startsWith(".github/actions/setup-android/") ||
      path === ".github/workflows/android-release.yml" ||
      path.startsWith(".github/scripts/android") ||
      path === ".github/scripts/public_mirror.py" ||
      path === "clients/scripts/client-ci.mjs" ||
      path === "clients/scripts/client-ci-lib.mjs" ||
      path.startsWith(".github/actions/setup-pinned-node/") ||
      path.startsWith(".github/actions/setup-macos-cache/") ||
      path.startsWith(".github/actions/host-snapshot/") ||
      path.startsWith(".github/actions/synch-cache/") ||
      [
        ".npmrc",
        "package.json",
        "pnpm-workspace.yaml",
        "clients/package.json",
      ].includes(path) ||
      path === "pnpm-lock.yaml" ||
      ((path.startsWith(androidRoot) ||
        mobileCoreSources.some((root) => path.startsWith(root))) &&
        !path.endsWith(".md"))
  );
}

export function clientBuildChanged(paths) {
  return paths.some((path) => {
    if (path.startsWith(".github/actions/r2-artifact/")) return true;
    if (!isClientCiPath(path)) return false;
    if (!path.startsWith("clients/")) return true;
    return !(
      /\/(?:e2e|test|tests)\//.test(path) ||
      /\.(?:test|spec|stories)\.[^/]+$/.test(path) ||
      path.endsWith(".md")
    );
  });
}

// The marketing site reads only these of the clients: the analytics package,
// the app's messages (the documentation's pictures of the app, in
// website/docs-pages.ts), the design tokens (website/css-variables.ts and its
// stylesheets) and the TypeScript settings its own tsconfigs extend.
const websiteClientInputs = [
  "clients/packages/analytics/",
  "clients/packages/i18n/messages/",
  "clients/packages/ui/src/styles/theme.css",
  "clients/tsconfig.base.json",
  "clients/tsconfig.node.json",
];

export function websiteChanged(paths) {
  return paths.some(
    (path) =>
      path.startsWith("website/") ||
      websiteClientInputs.some((input) => path.startsWith(input)) ||
      path === "clients/package.json" ||
      path === "clients/.oxlintrc.json" ||
      path === "clients/.prettierrc.json" ||
      path === "clients/.prettierignore" ||
      path === "clients/scripts/client-ci.mjs" ||
      path === "clients/scripts/client-ci-lib.mjs" ||
      (exactClientFiles.has(path) && !path.startsWith("systems/"))
  );
}

// The Storybook jobs build and test the stories of packages/ui and packages/app,
// which import packages only; the one app they read is the web app's sources,
// which packages/app/src/styles.css scans for Tailwind classes.
export function storybookChanged(paths) {
  return paths.some(
    (path) =>
      isClientCiPath(path) &&
      !isComputerUseCiPath(path) &&
      !path.endsWith(".md") &&
      (!path.startsWith("clients/apps/") || path.startsWith("clients/apps/web/src/")) &&
      !path.startsWith("clients/packages/apple-core/")
  );
}

// What Workflow Checks validates: the workflows, their actions and the CI scripts.
export function workflowCiChanged(paths) {
  return paths.some(
    (path) =>
      path.startsWith(".github/") ||
      path.startsWith("scripts/") ||
      path.startsWith("clients/scripts/")
  );
}

export function gitChangedFiles(base, head, cwd) {
  const output = execFileSync("git", ["diff", "--name-only", `${base}...${head}`], {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  return output.split(/\r?\n/).filter(Boolean);
}

export async function writeGitHubOutput(path, key, value) {
  await appendFile(path, `${key}=${value}\n`);
}

const gateOutputs = {
  "android-checks": "android",
  "android-unit-test": "android",
  "apple-ios-build": "apple",
  "computer-use": "computer_use",
  "e2e-test": "electron",
  "e2e-electron-shell": "electron",
  "synch-binary-smoke": "synch",
  storybook: "storybook",
  "storybook-e2e": "storybook",
  "website-smoke": "website",
  "build-website": "website",
  "workflow-checks": "workflows",
};

// Jobs a pull request runs only with the `full-e2e` label; main runs them for their inputs.
const fullE2eOnly = new Set([
  "e2e-browser",
  "e2e-browser-side",
  "e2e-electron-shell",
  "e2e-test",
  "synch-binary-smoke",
]);

/**
 * Checks each client job's result against what the run asked of it. `fullE2e` is false for a pull request without
 * the `full-e2e` label: its full E2E and binary smoke jobs are expected to skip.
 */
export function validateClientGate(needs, { fullE2e = true } = {}) {
  const changes = needs.changes;
  if (!changes || changes.result !== "success") {
    return ["Client change detection did not succeed."];
  }

  const jobResults = Object.entries(needs)
    .filter(([name]) => name !== "changes")
    .map(([name, job]) => [name, job.result]);
  return jobResults.flatMap(([name, result]) => {
    const output = gateOutputs[name] ?? "client";
    const expected =
      changes.outputs?.[output] === "true" && (fullE2e || !fullE2eOnly.has(name))
        ? "success"
        : "skipped";
    return result === expected
      ? []
      : [`Client job ${name} was ${result}; expected ${expected}.`];
  });
}
