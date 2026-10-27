import { describe, expect, it } from "vitest";
import {
  androidCiChanged,
  appleCiChanged,
  clientBuildChanged,
  clientCiChanged,
  computerUseCiChanged,
  electronCiChanged,
  synchCiChanged,
  validateClientGate,
  storybookChanged,
  websiteChanged,
} from "./client-ci-lib.mjs";

describe("client CI CLI", () => {
  it("selects client-owned and build-input changes", () => {
    expect(clientCiChanged(["docs/testing.md", "clients/packages/ui/index.ts"])).toBe(
      true
    );
    expect(clientCiChanged(["pnpm-lock.yaml"])).toBe(true);
    expect(clientCiChanged(["systems/connector/salix-connect/main.go"])).toBe(true);
    expect(
      clientCiChanged([".github/actions/setup-macos-cache/install-node-modules.sh"])
    ).toBe(true);
    expect(
      clientCiChanged(["systems/apps/salix_agent/priv/dynamic_ui/card-contract.json"])
    ).toBe(true);
    expect(clientCiChanged(["docs/testing.md", "systems/README.md"])).toBe(false);
  });

  it("routes helper changes to native checks without browser or Electron suites", () => {
    const root = "systems/connector/salix-connect/";
    const inputs = [
      `${root}native/macos/ComputerUseHost/Sources/CommaComputerUseDaemon/PermissionAuthWindow.swift`,
      `${root}native/macos/ComputerUseHost/Tests/CUTests/PermissionAuthorizationTests.swift`,
      `${root}native/macos/patches/permission-flow-display-name.patch`,
      `${root}scripts/package-computer-use-helper.sh`,
      `${root}scripts/test_packaged_computer_use.py`,
      "clients/apps/electron/e2e/computer-use-permissions.spec.ts",
    ];
    for (const input of inputs) {
      expect(clientCiChanged([input])).toBe(false);
      expect(computerUseCiChanged([input])).toBe(true);
    }
    expect(clientBuildChanged(inputs)).toBe(true);
    expect(computerUseCiChanged(["docs/testing.md"])).toBe(false);
    expect(clientCiChanged([...inputs, "clients/packages/ui/src/button.tsx"])).toBe(
      true
    );
    expect(computerUseCiChanged(["pnpm-lock.yaml"])).toBe(true);
    expect(computerUseCiChanged([`${root}main.go`])).toBe(false);
    expect(computerUseCiChanged(["clients/packages/ui/src/button.tsx"])).toBe(false);
    expect(computerUseCiChanged(["clients/apps/electron/src/main/open-wait.ts"])).toBe(
      true
    );
  });

  it("runs the Mac apps server's Swift tests and still builds Electron for it", () => {
    const source =
      "clients/apps/electron/native/macos/MacAppsHost/Sources/MacApps/Tool.swift";
    expect(computerUseCiChanged([source])).toBe(true);
    expect(electronCiChanged([source])).toBe(true);
  });

  it("runs the macOS E2E job only for code Electron bundles", () => {
    for (const input of [
      "clients/apps/web/src/main.tsx",
      "clients/apps/admin/src/App.tsx",
      "clients/apps/bft/src/index.tsx",
      "clients/apps/apple/project.yml",
      "clients/packages/apple-core/Sources/CommaCore/Router.swift",
      "clients/packages/app/README.md",
      "website/src/index.tsx",
      "docs/testing.md",
    ]) {
      expect(electronCiChanged([input])).toBe(false);
    }
    for (const input of [
      "clients/apps/electron/src/main.ts",
      "clients/packages/app/src/App.tsx",
      "clients/packages/ui/src/button.tsx",
      "clients/e2e/p0/electron-smoke.spec.ts",
      "clients/playwright.config.ts",
      "systems/connector/salix-connect/main.go",
      "pnpm-lock.yaml",
    ]) {
      expect(electronCiChanged([input])).toBe(true);
    }
    expect(
      electronCiChanged([
        "clients/apps/web/src/main.tsx",
        "clients/packages/ui/src/button.tsx",
      ])
    ).toBe(true);
  });

  it("runs the Synchronicity smoke only for its pinned binary and client", () => {
    for (const input of [
      "clients/apps/electron/scripts/synch-release.ts",
      "clients/apps/electron/src/main/modules/synchronicity/control.proto",
      "clients/apps/electron/src/main/test/synchronicity-control.test.ts",
      "clients/scripts/synch-smoke.mjs",
      "pnpm-lock.yaml",
      ".github/workflows/client-checks.yml",
    ]) {
      expect(synchCiChanged([input])).toBe(true);
    }
    expect(synchCiChanged(["clients/apps/electron/src/main.ts"])).toBe(false);
    expect(synchCiChanged(["clients/packages/ui/src/button.tsx"])).toBe(false);
  });

  it("maps the macOS and cross-platform jobs to their own outputs", () => {
    const jobs = {
      changes: {
        result: "success",
        outputs: { client: "true", electron: "false", synch: "false" },
      },
      "e2e-browser": { result: "success" },
      "e2e-test": { result: "skipped" },
      "synch-binary-smoke": { result: "skipped" },
    };
    expect(validateClientGate(jobs)).toEqual([]);
    jobs.changes.outputs.electron = "true";
    expect(validateClientGate(jobs)).toEqual([
      "Client job e2e-test was skipped; expected success.",
    ]);
  });

  it("expects a pull request's full E2E jobs to skip unless it has the full-e2e label", () => {
    const jobs = {
      changes: {
        result: "success",
        outputs: { client: "true", electron: "true", synch: "true" },
      },
      "unit-test": { result: "success" },
      "e2e-browser": { result: "skipped" },
      "e2e-browser-side": { result: "skipped" },
      "e2e-test": { result: "skipped" },
      "e2e-electron-shell": { result: "skipped" },
      "synch-binary-smoke": { result: "skipped" },
    };
    // A pull request without the label: they skip, and must.
    expect(validateClientGate(jobs, { fullE2e: false })).toEqual([]);
    jobs["unit-test"].result = "skipped";
    expect(validateClientGate(jobs, { fullE2e: false })).toEqual([
      "Client job unit-test was skipped; expected success.",
    ]);
    jobs["unit-test"].result = "success";
    // Main, or a pull request with the label: they run and must pass.
    expect(validateClientGate(jobs, { fullE2e: true })).toEqual([
      "Client job e2e-browser was skipped; expected success.",
      "Client job e2e-browser-side was skipped; expected success.",
      "Client job e2e-test was skipped; expected success.",
      "Client job e2e-electron-shell was skipped; expected success.",
      "Client job synch-binary-smoke was skipped; expected success.",
    ]);
  });

  it("requires native checks while unrelated jobs skip for helper-only changes", () => {
    const jobs = {
      changes: {
        result: "success",
        outputs: {
          client: "false",
          computer_use: "true",
          workflows: "true",
        },
      },
      "e2e-browser": { result: "skipped" },
      "e2e-test": { result: "skipped" },
      "computer-use": { result: "failure" },
    };
    expect(validateClientGate(jobs)).toEqual([
      "Client job computer-use was failure; expected success.",
    ]);
    jobs["computer-use"].result = "success";
    expect(validateClientGate(jobs)).toEqual([]);
    Object.assign(jobs, { "workflow-checks": { result: "skipped" } });
    expect(validateClientGate(jobs)).toEqual([
      "Client job workflow-checks was skipped; expected success.",
    ]);
    Object.assign(jobs, { "workflow-checks": { result: "success" } });
    expect(validateClientGate(jobs)).toEqual([]);
    jobs.changes.outputs.computer_use = "false";
    jobs["computer-use"].result = "skipped";
    expect(validateClientGate(jobs)).toEqual([]);
  });

  it("passes a change outside the clients with every job skipped", () => {
    const jobs = {
      changes: {
        result: "success",
        outputs: { client: "false", workflows: "false" },
      },
      "workflow-checks": { result: "skipped" },
      "unit-test": { result: "skipped" },
    };
    expect(validateClientGate(jobs)).toEqual([]);
    jobs["unit-test"].result = "success";
    expect(validateClientGate(jobs)).toEqual([
      "Client job unit-test was success; expected skipped.",
    ]);
  });

  it("selects Apple source and build configuration changes", () => {
    const inputs = [
      "clients/apps/apple/project.yml",
      "clients/packages/apple-core/Sources/CommaCore/Router.swift",
      "clients/packages/apple-core/Tests/CommaCoreTests/RouterTests.swift",
      ".github/workflows/ios-testflight.yml",
      ".github/workflows/client-checks.yml",
      ".github/actions/setup-apple-build/action.yml",
    ];
    for (const input of inputs) {
      expect(appleCiChanged([input])).toBe(true);
    }
    expect(
      appleCiChanged([
        "clients/apps/apple/README.md",
        "clients/packages/apple-core/README.md",
        ".github/actions/setup-apple-build/README.md",
        "clients/apps/electron/src/main.ts",
        "clients/packages/app/src/App.tsx",
        "website/src/index.tsx",
      ])
    ).toBe(false);
    // The app carries the client core: its sources and the lockfile build it.
    for (const input of [
      "clients/packages/core/src/timeline.ts",
      "clients/packages/core-kernel/src/store.ts",
      "pnpm-lock.yaml",
    ])
      expect(appleCiChanged([input])).toBe(true);
  });

  it("requires the Apple build only when Apple inputs changed", () => {
    const jobs = {
      changes: {
        result: "success",
        outputs: { client: "false", electron: "false", apple: "true" },
      },
      "e2e-test": { result: "skipped" },
      "apple-ios-build": { result: "failure" },
    };
    expect(validateClientGate(jobs)).toEqual([
      "Client job apple-ios-build was failure; expected success.",
    ]);
    jobs["apple-ios-build"].result = "skipped";
    expect(validateClientGate(jobs)).toEqual([
      "Client job apple-ios-build was skipped; expected success.",
    ]);
    jobs["apple-ios-build"].result = "success";
    expect(validateClientGate(jobs)).toEqual([]);
    jobs.changes.outputs.client = "true";
    jobs.changes.outputs.electron = "true";
    jobs.changes.outputs.apple = "false";
    jobs["e2e-test"].result = "success";
    jobs["apple-ios-build"].result = "skipped";
    expect(validateClientGate(jobs)).toEqual([]);
  });

  it("runs only the Android checks for Android project changes", () => {
    const inputs = [
      "clients/apps/android/app/src/main/java/surf/comma/android/MainActivity.kt",
      "clients/apps/android/app/build.gradle.kts",
      "clients/apps/android/version.properties",
      ".github/workflows/client-checks.yml",
    ];
    for (const input of inputs) {
      expect(androidCiChanged([input])).toBe(true);
    }
    const android = inputs.slice(0, 3);
    expect(clientCiChanged(android)).toBe(false);
    expect(electronCiChanged(android)).toBe(false);
    expect(clientBuildChanged(android)).toBe(false);
    expect(websiteChanged(android)).toBe(false);
    expect(
      androidCiChanged([
        "clients/apps/android/README.md",
        "clients/apps/apple/project.yml",
        "clients/packages/ui/src/button.tsx",
      ])
    ).toBe(false);
    // The app carries the client core: its sources and the lockfile build it.
    for (const input of [
      "clients/packages/core/src/timeline.ts",
      "clients/packages/core-kernel/src/store.ts",
      "clients/packages/i18n/messages/en.json",
      ".github/workflows/android-release.yml",
      ".github/scripts/android_signing.py",
      ".github/scripts/public_mirror.py",
      ".github/actions/setup-pinned-node/action.yml",
      ".github/actions/setup-android/action.yml",
      "package.json",
      "pnpm-lock.yaml",
    ])
      expect(androidCiChanged([input])).toBe(true);

    const jobs = {
      changes: {
        result: "success",
        outputs: { client: "false", electron: "false", android: "true" },
      },
      "e2e-test": { result: "skipped" },
      "android-checks": { result: "failure" },
    };
    expect(validateClientGate(jobs)).toEqual([
      "Client job android-checks was failure; expected success.",
    ]);
    jobs["android-checks"].result = "success";
    expect(validateClientGate(jobs)).toEqual([]);
    jobs.changes.outputs.android = "false";
    jobs["android-checks"].result = "skipped";
    expect(validateClientGate(jobs)).toEqual([]);
  });

  it("does not rebuild deliverables for test-only or documentation changes", () => {
    expect(clientBuildChanged(["clients/packages/ui/src/button.test.tsx"])).toBe(false);
    expect(clientBuildChanged(["clients/apps/electron/e2e/startup.spec.ts"])).toBe(
      false
    );
    expect(clientBuildChanged(["clients/README.md"])).toBe(false);
    expect(clientBuildChanged(["clients/packages/ui/src/button.tsx"])).toBe(true);
    expect(clientBuildChanged(["pnpm-lock.yaml"])).toBe(true);
    expect(clientBuildChanged([".github/actions/r2-artifact/transfer.sh"])).toBe(true);
  });

  it("routes website edits separately from client E2E and builds", () => {
    const files = ["website/src/copy/zh-CN.json"];
    expect(clientCiChanged(files)).toBe(false);
    expect(clientBuildChanged(files)).toBe(false);
    expect(websiteChanged(files)).toBe(true);
    expect(websiteChanged(["clients/apps/electron/src/main.ts"])).toBe(false);
    // The site reads only the analytics package, the design tokens and the
    // TypeScript settings of the clients.
    expect(
      websiteChanged(["clients/packages/app/src/components/CommaProductMark.tsx"])
    ).toBe(false);
    expect(websiteChanged(["clients/packages/core/src/tasks.ts"])).toBe(false);
    expect(websiteChanged(["clients/packages/ui/src/styles/theme.css"])).toBe(true);
    expect(websiteChanged(["clients/packages/analytics/src/index.ts"])).toBe(true);
    expect(websiteChanged(["clients/packages/i18n/messages/zh-CN.json"])).toBe(true);
    expect(websiteChanged(["clients/packages/i18n/src/index.ts"])).toBe(false);
    expect(websiteChanged(["clients/tsconfig.base.json"])).toBe(true);
    expect(websiteChanged(["pnpm-lock.yaml"])).toBe(true);
  });

  it("runs the Storybook jobs for the packages their stories read, not for an app", () => {
    expect(storybookChanged(["clients/packages/ui/src/components/button.tsx"])).toBe(
      true
    );
    expect(storybookChanged(["clients/packages/core/src/tasks.ts"])).toBe(true);
    expect(storybookChanged(["pnpm-lock.yaml"])).toBe(true);
    // packages/app's stylesheet scans the web app's sources for Tailwind classes.
    expect(storybookChanged(["clients/apps/web/src/main.tsx"])).toBe(true);
    expect(storybookChanged(["clients/apps/electron/src/main/index.ts"])).toBe(false);
    expect(storybookChanged(["clients/apps/apple/iOS/Home/HomeView.swift"])).toBe(
      false
    );
    expect(storybookChanged(["clients/packages/apple-core/Sources/x.swift"])).toBe(
      false
    );
    expect(storybookChanged(["clients/packages/ui/README.md"])).toBe(false);
  });

  it("requires website checks while unrelated client jobs are skipped", () => {
    const jobs = {
      changes: { result: "success", outputs: { client: "false", website: "true" } },
      "website-smoke": { result: "success" },
      "build-website": { result: "success" },
      e2e: { result: "skipped" },
    };
    expect(validateClientGate(jobs)).toEqual([]);
    jobs["website-smoke"].result = "failure";
    expect(validateClientGate(jobs)).toEqual([
      "Client job website-smoke was failure; expected success.",
    ]);
  });

  it("requires all heavy jobs only for client changes", () => {
    const jobs = {
      changes: { result: "success", outputs: { client: "true" } },
      static: { result: "success" },
      e2e: { result: "failure" },
    };
    expect(validateClientGate(jobs)).toEqual([
      "Client job e2e was failure; expected success.",
    ]);
    jobs.changes.outputs.client = "false";
    jobs.static.result = "skipped";
    jobs.e2e.result = "skipped";
    expect(validateClientGate(jobs)).toEqual([]);
  });

  it("fails closed when change detection fails", () => {
    expect(validateClientGate({ changes: { result: "failure" } })).toEqual([
      "Client change detection did not succeed.",
    ]);
  });
});
