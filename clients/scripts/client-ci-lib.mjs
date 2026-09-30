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

export function isClientCiPath(path) {
  return (
    exactClientFiles.has(path) ||
    path.startsWith("clients/") ||
    path.startsWith("systems/connector/salix-connect/")
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

export function computerUseCiChanged(paths) {
  // Keep the existing helper checks for client changes and helper-only changes.
  return clientCiChanged(paths) || paths.some(isComputerUseCiPath);
}

export function clientBuildChanged(paths) {
  return paths.some((path) => {
    if (!isClientCiPath(path)) return false;
    if (!path.startsWith("clients/")) return true;
    return !(
      /\/(?:e2e|test|tests)\//.test(path) ||
      /\.(?:test|spec|stories)\.[^/]+$/.test(path) ||
      path.endsWith(".md")
    );
  });
}

export function websiteChanged(paths) {
  return paths.some(
    (path) =>
      path.startsWith("website/") ||
      path.startsWith("clients/packages/") ||
      path.startsWith("clients/vite/") ||
      path.startsWith("clients/tsconfig.") ||
      path === "clients/package.json" ||
      path === "clients/.oxlintrc.json" ||
      path === "clients/.prettierrc.json" ||
      path === "clients/.prettierignore" ||
      path === "clients/scripts/client-ci.mjs" ||
      path === "clients/scripts/client-ci-lib.mjs" ||
      (exactClientFiles.has(path) && !path.startsWith("systems/"))
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

export function validateClientGate(needs) {
  const changes = needs.changes;
  if (!changes || changes.result !== "success") {
    return ["Client change detection did not succeed."];
  }

  const jobResults = Object.entries(needs)
    .filter(([name]) => name !== "changes")
    .map(([name, job]) => [name, job.result]);
  return jobResults.flatMap(([name, result]) => {
    const output =
      name === "computer-use"
        ? "computer_use"
        : ["website-smoke", "build-website"].includes(name)
          ? "website"
          : "client";
    const expected = changes.outputs?.[output] === "true" ? "success" : "skipped";
    return result === expected
      ? []
      : [`Client job ${name} was ${result}; expected ${expected}.`];
  });
}
