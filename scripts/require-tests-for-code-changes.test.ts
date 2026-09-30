import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import type { SpawnSyncReturns } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const policyScript = path.join(
  repoRoot,
  "scripts",
  "require-tests-for-code-changes.ts",
);

type FixtureFiles = Record<string, string>;
type EnvOverrides = Record<string, string | undefined>;
type FixtureCallback = (cwd: string) => void;

test("default PR template waiver prompt does not bypass test policy", () => {
  withGitFixture(
    {
      "clients/apps/electron/src/main.ts": "export const value = 1;\n",
    },
    (cwd) => {
      writeFixtureFile(
        cwd,
        "clients/apps/electron/src/main.ts",
        "export const value = 2;\n",
      );

      const result = runPolicy(cwd, {
        TEST_POLICY_WAIVER_TEXT:
          "- [ ] No tests needed: `[test-not-required]` with reason:",
      });

      assertPolicyFailed(result);
      assert.match(result.stderr, /without any test or harness files/);
    },
  );
});

test("checked waiver line with a concrete reason bypasses test policy", () => {
  withGitFixture(
    {
      "clients/apps/electron/src/main.ts": "export const value = 1;\n",
    },
    (cwd) => {
      writeFixtureFile(
        cwd,
        "clients/apps/electron/src/main.ts",
        "export const value = 2;\n",
      );

      const result = runPolicy(cwd, {
        TEST_POLICY_WAIVER_TEXT:
          "- [x] No tests needed: `[test-not-required]` with reason: docs-only generated binding refresh",
      });

      assert.equal(result.status, 0, result.stderr || result.stdout);
    },
  );
});

test("ambient workflow waiver text does not affect fixture policy runs", () => {
  withEnv(
    {
      TEST_POLICY_WAIVER_TEXT:
        "- [x] No tests needed: `[test-not-required]` with reason: docs-only generated binding refresh",
      TEST_POLICY_BASE: "main",
      TEST_POLICY_HEAD: "HEAD",
      GITHUB_BASE_REF: "main",
      GITHUB_BASE_SHA: "0000000000000000000000000000000000000000",
      GITHUB_SHA: "1111111111111111111111111111111111111111",
    },
    () => {
      withGitFixture(
        {
          "clients/apps/electron/src/main.ts": "export const value = 1;\n",
        },
        (cwd) => {
          writeFixtureFile(
            cwd,
            "clients/apps/electron/src/main.ts",
            "export const value = 2;\n",
          );

          const result = runPolicy(cwd);

          assertPolicyFailed(result);
        },
      );
    },
  );
});

test("checked waiver line with the template placeholder does not bypass test policy", () => {
  withGitFixture(
    {
      "clients/apps/electron/src/main.ts": "export const value = 1;\n",
    },
    (cwd) => {
      writeFixtureFile(
        cwd,
        "clients/apps/electron/src/main.ts",
        "export const value = 2;\n",
      );

      const result = runPolicy(cwd, {
        TEST_POLICY_WAIVER_TEXT:
          "- [x] No tests needed: `[test-not-required]` with reason: <explain why tests do not apply>",
      });

      assertPolicyFailed(result);
    },
  );
});

test("PR waiver text does not fall back to commit message waivers", () => {
  withGitFixture(
    {
      "systems/connector/salix_connect.py": "VALUE = 1\n",
    },
    (cwd) => {
      writeFixtureFile(
        cwd,
        "systems/connector/salix_connect.py",
        "VALUE = 2\n",
      );
      commitAll(
        cwd,
        "No tests needed: [test-not-required]: operational config only",
      );

      const result = runPolicy(cwd, {
        TEST_POLICY_BASE: "HEAD~1",
        TEST_POLICY_HEAD: "HEAD",
        TEST_POLICY_WAIVER_TEXT: "",
      });

      assertPolicyFailed(result);
    },
  );
});

test("local runs without PR waiver text can use commit message waivers", () => {
  withGitFixture(
    {
      "systems/connector/salix_connect.py": "VALUE = 1\n",
    },
    (cwd) => {
      writeFixtureFile(
        cwd,
        "systems/connector/salix_connect.py",
        "VALUE = 2\n",
      );
      commitAll(
        cwd,
        "No tests needed: [test-not-required]: operational config only",
      );

      const result = runPolicy(cwd, {
        TEST_POLICY_BASE: "HEAD~1",
        TEST_POLICY_HEAD: "HEAD",
        TEST_POLICY_WAIVER_TEXT: undefined,
      });

      assert.equal(result.status, 0, result.stderr || result.stdout);
    },
  );
});

test("source changes without tests fail test policy", async (t) => {
  const cases = [
    {
      name: "Swift native client source",
      file: "clients/apps/electron/native/macos/NotchKit/Sources/NotchKit/NotchRuntimeModel.swift",
      initial: "let value = 1\n",
      changed: "let value = 2\n",
      match: /NotchRuntimeModel\.swift/,
    },
    {
      name: "Go connector source",
      file: "systems/connector/salix-connect/main.go",
      initial: "package main\n",
      changed: "package main\n\nfunc main() {}\n",
      match: /salix-connect\/main\.go/,
    },
  ];

  for (const testCase of cases) {
    await t.test(testCase.name, () => {
      withGitFixture({ [testCase.file]: testCase.initial }, (cwd) => {
        writeFixtureFile(cwd, testCase.file, testCase.changed);

        const result = runPolicy(cwd);

        assertPolicyFailed(result);
        assert.match(result.stderr, testCase.match);
      });
    });
  }
});

test("source changes paired with their accepted test location satisfy test policy", async (t) => {
  const cases = [
    {
      name: "Go connector source with Go tests",
      file: "systems/connector/salix-connect/main.go",
      initial: "package main\n",
      changed: "package main\n\nfunc main() {}\n",
      testFile: "systems/connector/salix-connect/main_test.go",
      testContent: "package main\n\nfunc TestMain(t *testing.T) {}\n",
    },
    {
      name: "Swift native client source with SwiftPM tests",
      file: "clients/apps/electron/native/macos/NotchKit/Sources/NotchKit/Foo.swift",
      initial: "let value = 1\n",
      changed: "let value = 2\n",
      testFile:
        "clients/apps/electron/native/macos/NotchKit/Tests/NotchKitTests/FooTests.swift",
      testContent: "import Testing\n\n@Test func foo() {}\n",
    },
    {
      name: "Python connector source with Python tests",
      file: "systems/connector/salix_connect.py",
      initial: "VALUE = 1\n",
      changed: "VALUE = 2\n",
      testFile: "systems/connector/test_salix_connect.py",
      testContent: "def test_value():\n    assert True\n",
    },
    {
      name: "client app source with a colocated e2e spec",
      file: "clients/apps/electron/src/main/index.ts",
      initial: "export const value = 1;\n",
      changed: "export const value = 2;\n",
      testFile: "clients/apps/electron/e2e/shell.spec.ts",
      testContent:
        "import { test } from '@playwright/test';\ntest('shell', async () => {});\n",
    },
    {
      name: "client package source with a colocated e2e spec",
      file: "clients/packages/app/src/index.tsx",
      initial: "export const value = 1;\n",
      changed: "export const value = 2;\n",
      testFile: "clients/packages/app/e2e/shell-layout.spec.ts",
      testContent:
        "import { test } from '@playwright/test';\ntest('shell', async () => {});\n",
    },
    {
      name: "Helm chart template with its shell harness",
      file: "k8s/comma/chart/templates/application.yaml",
      initial: "apiVersion: apps/v1\nkind: Deployment\n",
      changed: "apiVersion: apps/v1\nkind: StatefulSet\n",
      testFile: "k8s/comma/chart/test-chart.sh",
      testContent: "#!/usr/bin/env bash\nset -euo pipefail\n",
    },
  ];

  for (const testCase of cases) {
    await t.test(testCase.name, () => {
      withGitFixture({ [testCase.file]: testCase.initial }, (cwd) => {
        writeFixtureFile(cwd, testCase.file, testCase.changed);
        writeFixtureFile(cwd, testCase.testFile, testCase.testContent);

        const result = runPolicy(cwd);

        assertPolicyPassed(result);
      });
    });
  }
});

test("client runtime source changes require e2e even when unit tests change", () => {
  withGitFixture(
    {
      "clients/packages/app/src/InboxView.tsx": "export const value = 1;\n",
    },
    (cwd) => {
      writeFixtureFile(
        cwd,
        "clients/packages/app/src/InboxView.tsx",
        "export const value = 2;\n",
      );
      writeFixtureFile(
        cwd,
        "clients/packages/app/src/test/InboxView.test.tsx",
        "import { test } from 'node:test';\ntest('inbox view', () => {});\n",
      );

      const result = runPolicy(cwd);

      assertPolicyFailed(result);
      assert.match(result.stderr, /without a Playwright E2E update/);
      assert.match(result.stderr, /Accepted Playwright E2E locations:/);
      assert.match(result.stderr, /clients\/e2e\//);
      assert.match(result.stderr, /clients\/apps\/<app>\/e2e\//);
      assert.match(result.stderr, /clients\/packages\/<package>\/e2e\//);
      assert.match(result.stderr, /clients\/playwright\.config\.ts/);
    },
  );
});

test("policy docs do not satisfy source changes as tests", () => {
  withGitFixture(
    {
      "systems/connector/salix_connect.py": "VALUE = 1\n",
      "docs/testing.md": "# Testing\n",
    },
    (cwd) => {
      writeFixtureFile(
        cwd,
        "systems/connector/salix_connect.py",
        "VALUE = 2\n",
      );
      writeFixtureFile(cwd, "docs/testing.md", "# Testing\n\nPolicy update.\n");

      const result = runPolicy(cwd);

      assertPolicyFailed(result);
      assert.match(result.stderr, /without any test or harness files/);
    },
  );
});

test("deleted source files are included in test policy analysis", () => {
  withGitFixture(
    {
      "systems/connector/salix_connect.py": "VALUE = 1\n",
    },
    (cwd) => {
      unlinkSync(path.join(cwd, "systems/connector/salix_connect.py"));

      const result = runPolicy(cwd);

      assertPolicyFailed(result);
      assert.match(result.stderr, /salix_connect\.py/);
    },
  );
});

test("critical non-runtime paths require tests or a waiver", async (t) => {
  const cases = [
    {
      name: "Electron release script",
      file: "clients/apps/electron/scripts/sign-notarize.ts",
      initial: "export const timeoutMs = 1000;\n",
      changed: "export const timeoutMs = 2000;\n",
      match: /sign-notarize\.ts/,
    },
    {
      name: "Electron shell release script",
      file: "clients/apps/electron/scripts/configure-macos-signing.sh",
      initial: "#!/usr/bin/env bash\nset -euo pipefail\n",
      changed: "#!/usr/bin/env bash\nset -eu\n",
      match: /configure-macos-signing\.sh/,
    },
    {
      name: "Electron runtime config",
      file: "clients/apps/electron/electron.vite.config.ts",
      initial: "export default { main: {} };\n",
      changed: "export default { main: { sourcemap: true } };\n",
      match: /electron\.vite\.config\.ts/,
    },
    {
      name: "Electron package config",
      file: "clients/apps/electron/package.json",
      initial: '{ "name": "@comma/electron" }\n',
      changed: '{ "name": "@comma/electron", "private": true }\n',
      match: /clients\/apps\/electron\/package\.json/,
    },
    {
      name: "Electron signing plist",
      file: "clients/apps/electron/build/entitlements.mac.plist",
      initial: "<plist></plist>\n",
      changed: "<plist><dict></dict></plist>\n",
      match: /entitlements\.mac\.plist/,
    },
    {
      name: "Electron signing entitlements",
      file: "clients/apps/electron/build/entitlements.mac.entitlements",
      initial: "<plist></plist>\n",
      changed: "<plist><dict></dict></plist>\n",
      match: /entitlements\.mac\.entitlements/,
    },
    {
      name: "release workflow",
      file: ".github/workflows/systems-docker.yml",
      initial: "name: Systems Docker\n",
      changed: "name: Systems Docker\npermissions: {}\n",
      match: /systems-docker\.yml/,
    },
    {
      name: "devtools app source",
      file: "devtools/e2e-reports/src/lib/api.ts",
      initial: "export const endpoint = '/api';\n",
      changed: "export const endpoint = '/reports';\n",
      match: /devtools\/e2e-reports\/src\/lib\/api\.ts/,
    },
    {
      name: "devtools Svelte route source",
      file: "devtools/salix-web-ui/src/routes/+page.svelte",
      initial: "<h1>Reports</h1>\n",
      changed: "<h1>Comma</h1>\n",
      match: /devtools\/salix-web-ui\/src\/routes\/\+page\.svelte/,
    },
    {
      name: "devtools runtime config",
      file: "devtools/salix-web-ui/wrangler.toml",
      initial: 'name = "salix-web-ui"\n',
      changed: 'name = "salix-web-ui"\ncompatibility_date = "2026-06-17"\n',
      match: /devtools\/salix-web-ui\/wrangler\.toml/,
    },
    {
      name: "devtools CSS source",
      file: "devtools/salix-web-ui/src/app.css",
      initial: ":root { color: black; }\n",
      changed: ":root { color: white; }\n",
      match: /devtools\/salix-web-ui\/src\/app\.css/,
    },
    {
      name: "devtools HTML source",
      file: "devtools/e2e-reports/src/app.html",
      initial: "<div>%sveltekit.body%</div>\n",
      changed: "<main>%sveltekit.body%</main>\n",
      match: /devtools\/e2e-reports\/src\/app\.html/,
    },
    {
      name: "resources skill script",
      file: "resources/salix-system-files/skills/website-manager/scripts/check.js",
      initial: "export function check() { return true; }\n",
      changed: "export function check() { return false; }\n",
      match:
        /resources\/salix-system-files\/skills\/website-manager\/scripts\/check\.js/,
    },
    {
      name: "resources skill helper outside scripts",
      file: "resources/salix-system-files/skills/docs/render_docx.py",
      initial: "def render():\n    return True\n",
      changed: "def render():\n    return False\n",
      match: /resources\/salix-system-files\/skills\/docs\/render_docx\.py/,
    },
    {
      name: "resources skill reference document",
      file: "resources/salix-system-files/skills/bridge/references/safety-boundaries.md",
      initial: "# Safety\n",
      changed: "# Safety\n\nUpdated boundary.\n",
      match:
        /resources\/salix-system-files\/skills\/bridge\/references\/safety-boundaries\.md/,
    },
    {
      name: "resources skill HTML asset",
      file: "resources/salix-system-files/skills/skill-eval/assets/viewer.html",
      initial: "<html><body>Viewer</body></html>\n",
      changed: "<html><body>Skill viewer</body></html>\n",
      match:
        /resources\/salix-system-files\/skills\/skill-eval\/assets\/viewer\.html/,
    },
    {
      name: "Helm application template",
      file: "k8s/comma/chart/templates/application.yaml",
      initial: "apiVersion: apps/v1\nkind: Deployment\n",
      changed: "apiVersion: apps/v1\nkind: StatefulSet\n",
      match: /k8s\/comma\/chart\/templates\/application\.yaml/,
    },
    {
      name: "systems Dockerfile",
      file: "systems/Dockerfile",
      initial: "FROM alpine:3.20\n",
      changed: "FROM alpine:3.21\n",
      match: /systems\/Dockerfile/,
    },
    {
      name: "systems runtime config",
      file: "systems/config/runtime.exs",
      initial: "import Config\n",
      changed: "import Config\nconfig :comma, :changed, true\n",
      match: /systems\/config\/runtime\.exs/,
    },
  ];

  for (const testCase of cases) {
    await t.test(testCase.name, () => {
      withGitFixture(
        {
          [testCase.file]: testCase.initial,
        },
        (cwd) => {
          writeFixtureFile(cwd, testCase.file, testCase.changed);

          const result = runPolicy(cwd);

          assertPolicyFailed(result);
          assert.match(result.stderr, testCase.match);
        },
      );
    });
  }
});

function withGitFixture(files: FixtureFiles, fn: FixtureCallback): void {
  const cwd = mkdtempSync(path.join(tmpdir(), "comma-test-policy-"));

  try {
    execFileSync("git", ["init"], { cwd, stdio: "ignore" });
    execFileSync("git", ["config", "user.email", "test@example.com"], {
      cwd,
      stdio: "ignore",
    });
    execFileSync("git", ["config", "user.name", "Test Policy"], {
      cwd,
      stdio: "ignore",
    });

    for (const [file, contents] of Object.entries(files)) {
      writeFixtureFile(cwd, file, contents);
    }

    commitAll(cwd, "initial");

    fn(cwd);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
}

function writeFixtureFile(cwd: string, file: string, contents: string): void {
  const fullPath = path.join(cwd, file);
  mkdirSync(path.dirname(fullPath), { recursive: true });
  writeFileSync(fullPath, contents);
}

function commitAll(cwd: string, message: string): void {
  execFileSync("git", ["add", "."], { cwd, stdio: "ignore" });
  execFileSync("git", ["commit", "-m", message], {
    cwd,
    stdio: "ignore",
  });
}

function withEnv(values: EnvOverrides, fn: () => void): void {
  const previousValues = new Map<string, string | undefined>();

  for (const [key, value] of Object.entries(values)) {
    previousValues.set(
      key,
      Object.hasOwn(process.env, key) ? process.env[key] : undefined,
    );

    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }

  try {
    fn();
  } finally {
    for (const [key, value] of previousValues.entries()) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
  }
}

function runPolicy(
  cwd: string,
  env: EnvOverrides = {},
): SpawnSyncReturns<string> {
  const childEnv: NodeJS.ProcessEnv = {
    ...process.env,
  };

  scrubFixtureEnv(childEnv);

  Object.assign(childEnv, env);

  for (const [key, value] of Object.entries(childEnv)) {
    if (value === undefined) {
      delete childEnv[key];
    }
  }

  return spawnSync(process.execPath, [policyScript], {
    cwd,
    encoding: "utf8",
    env: childEnv,
  });
}

function scrubFixtureEnv(env: NodeJS.ProcessEnv): void {
  for (const key of Object.keys(env)) {
    if (key.startsWith("TEST_POLICY_")) {
      delete env[key];
    }
  }

  delete env.GITHUB_BASE_REF;
  delete env.GITHUB_BASE_SHA;
  delete env.GITHUB_SHA;
}

function assertPolicyFailed(result: SpawnSyncReturns<string>): void {
  assert.notEqual(
    result.status,
    0,
    `expected policy to fail\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
  );
  assert.match(result.stderr, /Test policy failed:/);
}

function assertPolicyPassed(result: SpawnSyncReturns<string>): void {
  assert.equal(result.status, 0, result.stderr || result.stdout);
}
