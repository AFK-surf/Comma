#!/usr/bin/env node
import { execFileSync } from "node:child_process";

const waiverToken = "[test-not-required]";
const acceptedClientE2eLocations = [
  "clients/e2e/",
  "clients/apps/<app>/e2e/",
  "clients/packages/<package>/e2e/",
  "clients/playwright.config.ts",
] as const;
const args = parseArgs(process.argv.slice(2));
const base =
  args.get("base") ??
  process.env.TEST_POLICY_BASE ??
  process.env.GITHUB_BASE_SHA ??
  "";
const head =
  args.get("head") ??
  process.env.TEST_POLICY_HEAD ??
  process.env.GITHUB_SHA ??
  "HEAD";

const changedFiles = getChangedFiles(base, head);
const sourceFiles = changedFiles.filter(isSourceFile);
const testFiles = changedFiles.filter(isTestOrHarnessFile);
const clientE2eSourceFiles = sourceFiles.filter(needsClientE2e);
const e2eFiles = changedFiles.filter(isClientE2eFile);
const waiverText = getWaiverText(base, head);
const waiverReason = getWaiverReason(waiverText);

if (sourceFiles.length === 0) {
  console.log("No source changes detected; test policy passed.");
  process.exit(0);
}

if (waiverReason) {
  console.log(`${waiverToken} waiver found with reason: ${waiverReason}`);
  process.exit(0);
}

const failures: string[] = [];

if (testFiles.length === 0) {
  failures.push(
    "Source files changed without any test or harness files in the same diff.",
  );
}

if (clientE2eSourceFiles.length > 0 && e2eFiles.length === 0) {
  failures.push(
    [
      "Client runtime source changed without a Playwright E2E update.",
      `Accepted Playwright E2E locations: ${acceptedClientE2eLocations.join(
        ", ",
      )}.`,
    ].join(" "),
  );
}

if (failures.length > 0) {
  console.error("Test policy failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }

  console.error("\nSource changes:");
  for (const file of sourceFiles) {
    console.error(`- ${file}`);
  }

  console.error(
    `\nAdd matching tests, or include a checked ${waiverToken} waiver line with a concrete reason.`,
  );
  process.exit(1);
}

console.log("Test policy passed.");

function parseArgs(values: string[]): Map<string, string> {
  const parsed = new Map<string, string>();

  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (!value) {
      continue;
    }

    if (!value.startsWith("--")) {
      continue;
    }

    const [key, inlineValue] = value.slice(2).split("=", 2);
    if (!key) {
      continue;
    }

    if (inlineValue !== undefined) {
      parsed.set(key, inlineValue);
      continue;
    }

    const next = values[index + 1];
    if (next && !next.startsWith("--")) {
      parsed.set(key, next);
      index += 1;
    } else {
      parsed.set(key, "1");
    }
  }

  return parsed;
}

function git(commandArgs: string[]): string {
  return execFileSync("git", commandArgs, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function getChangedFiles(baseRef: string, headRef: string): string[] {
  const ranges: string[] = [];
  const files = new Set<string>();

  if (baseRef) {
    ranges.push(`${baseRef}...${headRef}`, `${baseRef}..${headRef}`);
  }

  if (process.env.GITHUB_BASE_REF) {
    ranges.push(`origin/${process.env.GITHUB_BASE_REF}...${headRef}`);
  }

  ranges.push("HEAD~1...HEAD", "HEAD~1..HEAD");

  for (const range of ranges) {
    try {
      const output = git(["diff", "--name-only", "--diff-filter=ACMRD", range]);

      addFiles(files, output);
      break;
    } catch {
      // Try the next range. Local runs may not have origin/main or HEAD~1.
    }
  }

  for (const commandArgs of [
    ["diff", "--name-only", "--diff-filter=ACMRD"],
    ["diff", "--cached", "--name-only", "--diff-filter=ACMRD"],
    ["ls-files", "--others", "--exclude-standard"],
  ]) {
    try {
      addFiles(files, git(commandArgs));
    } catch {
      // Dirty working tree checks are best-effort outside a git checkout.
    }
  }

  return Array.from(files);
}

function getWaiverText(baseRef: string, headRef: string): string {
  if (Object.hasOwn(process.env, "TEST_POLICY_WAIVER_TEXT")) {
    return process.env.TEST_POLICY_WAIVER_TEXT ?? "";
  }

  const messages: string[] = [];

  if (baseRef) {
    try {
      messages.push(git(["log", "--format=%B", `${baseRef}..${headRef}`]));
    } catch {
      // Commit messages are best-effort for local runs.
    }
  }

  return messages.join("\n");
}

function getWaiverReason(text: string): string {
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();

    if (!line.includes(waiverToken) || isUncheckedChecklistLine(line)) {
      continue;
    }

    if (!isExplicitWaiverLine(line)) {
      continue;
    }

    const reason = getReasonAfterWaiverToken(line);
    if (reason) {
      return reason;
    }
  }

  return "";
}

function isUncheckedChecklistLine(line: string): boolean {
  return /^[-*]\s*\[\s\]/.test(line);
}

function isExplicitWaiverLine(line: string): boolean {
  return (
    /^[-*]\s*\[[xX]\]\s*No tests needed\s*:/i.test(line) ||
    /^(?:test(?:s)? not required|test waiver|testing waiver|no tests needed)\s*:/i.test(
      line,
    ) ||
    line.startsWith(`${waiverToken}:`) ||
    line.startsWith(`\`${waiverToken}\`:`)
  );
}

function getReasonAfterWaiverToken(line: string): string {
  const tokenIndex = line.indexOf(waiverToken);
  if (tokenIndex === -1) {
    return "";
  }

  const reason = line
    .slice(tokenIndex + waiverToken.length)
    .trim()
    .replace(/^`/, "")
    .trim()
    .replace(/^[:\-–—]\s*/, "")
    .replace(/^(?:with\s+)?reason\s*:?\s*/i, "")
    .trim();

  if (!reason || isPlaceholderReason(reason)) {
    return "";
  }

  return reason;
}

function isPlaceholderReason(reason: string): boolean {
  const normalized = reason.replace(/[<>]/g, "").trim();

  return /^(?:reason|explain|explanation|explain why tests do not apply|todo|n\/a|none|not applicable)\.?$/i.test(
    normalized,
  );
}

function normalizePath(file: string): string {
  return file.replaceAll("\\", "/");
}

function addFiles(target: Set<string>, output: string): void {
  for (const file of output.split("\n")) {
    const normalized = normalizePath(file.trim());
    if (normalized) {
      target.add(normalized);
    }
  }
}

function isSourceFile(file: string): boolean {
  if (isTestOrHarnessFile(file)) {
    return false;
  }

  return (
    /^\.github\/workflows\/.+\.ya?ml$/.test(file) ||
    /^clients\/(?:apps|packages)\/[^/]+\/src\/.+\.(?:ts|tsx)$/.test(file) ||
    /^clients\/apps\/electron\/scripts\/.+\.(?:js|mjs|cjs|ts|py|sh)$/.test(
      file,
    ) ||
    /^clients\/apps\/electron\/package\.json$/.test(file) ||
    /^clients\/apps\/electron\/build\/.+\.(?:plist|entitlements)$/.test(file) ||
    /^clients\/apps\/electron\/[^/]*config[^/]*\.(?:js|mjs|cjs|ts)$/.test(
      file,
    ) ||
    /^clients\/apps\/electron\/native\/macos\/.+\.swift$/.test(file) ||
    /^devtools\/[^/]+\/src\/.+\.(?:js|jsx|ts|tsx|svelte|css|html)$/.test(
      file,
    ) ||
    /^devtools\/[^/]+\/(?:package\.json|vite\.config\.(?:js|mjs|ts)|svelte\.config\.(?:js|mjs|ts)|tsconfig[^/]*\.json|wrangler\.toml)$/.test(
      file,
    ) ||
    /^resources\/.+\/skills\/[^/]+\/SKILL\.md$/.test(file) ||
    /^resources\/.+\/skills\/[^/]+\/.+\.(?:js|mjs|cjs|ts|py|sh|md|mdx|json|yaml|yml|html|css)$/.test(
      file,
    ) ||
    /^k8s\/.+\.(?:yaml|yml|json)$/.test(file) ||
    /(^|\/)Dockerfile(?:\..*)?$/.test(file) ||
    /^systems\/apps\/[^/]+\/lib\/.+\.(?:ex|exs)$/.test(file) ||
    /^systems\/config\/.+\.(?:ex|exs)$/.test(file) ||
    /^systems\/connector\/.+\.sh$/.test(file) ||
    /^systems\/connector\/.+\.py$/.test(file) ||
    /^systems\/connector\/salix-connect\/.+\.go$/.test(file)
  );
}

function isTestOrHarnessFile(file: string): boolean {
  const normalized = normalizePath(file);
  const lowerFile = normalized.toLowerCase();
  const basename = normalized.split("/").at(-1) ?? normalized;

  return (
    /\.(?:test|spec)\.[cm]?(?:js|jsx|ts|tsx)$/.test(basename) ||
    /_test\.exs$/.test(basename) ||
    /_test\.go$/.test(basename) ||
    /(?:^test_.+|.+_test)\.py$/.test(basename) ||
    /(?:^test_.+|.+_test)\.(?:c|h)$/.test(basename) ||
    /tests?\.swift$/.test(basename) ||
    /^k8s\/comma\/chart\/test-[^/]+\.sh$/.test(normalized) ||
    lowerFile.includes("/test/") ||
    lowerFile.includes("/tests/") ||
    lowerFile.includes("/e2e/") ||
    normalized.startsWith("clients/test/") ||
    normalized.startsWith("clients/e2e/") ||
    normalized === "clients/vitest.config.ts" ||
    normalized === "clients/playwright.config.ts" ||
    normalized === "clients/tsconfig.test.json" ||
    normalized === "scripts/require-tests-for-code-changes.ts"
  );
}

function needsClientE2e(file: string): boolean {
  return (
    /^clients\/apps\/[^/]+\/src\/.+\.(?:ts|tsx)$/.test(file) ||
    /^clients\/packages\/(?:app|ui|native-bridge)\/src\/.+\.(?:ts|tsx)$/.test(
      file,
    )
  );
}

function isClientE2eFile(file: string): boolean {
  return (
    file.startsWith("clients/e2e/") ||
    // Playwright specs also live next to the app/package they exercise, e.g.
    // clients/apps/electron/e2e/ and clients/packages/app/e2e/.
    /^clients\/apps\/[^/]+\/e2e\//.test(file) ||
    /^clients\/packages\/[^/]+\/e2e\//.test(file) ||
    file === "clients/playwright.config.ts"
  );
}
