import { describe, expect, it } from "vitest";
import {
  clientBuildChanged,
  clientCiChanged,
  computerUseCiChanged,
  validateClientGate,
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
    expect(computerUseCiChanged([`${root}main.go`])).toBe(true);
  });

  it("requires native checks while unrelated jobs skip for helper-only changes", () => {
    const jobs = {
      changes: {
        result: "success",
        outputs: { client: "false", computer_use: "true" },
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
    jobs.changes.outputs.computer_use = "false";
    jobs["computer-use"].result = "skipped";
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
  });

  it("routes website edits separately from client E2E and builds", () => {
    const files = ["website/src/copy/zh-CN.json"];
    expect(clientCiChanged(files)).toBe(false);
    expect(clientBuildChanged(files)).toBe(false);
    expect(websiteChanged(files)).toBe(true);
    expect(websiteChanged(["clients/apps/electron/src/main.ts"])).toBe(false);
    expect(
      websiteChanged(["clients/packages/app/src/components/CommaProductMark.tsx"])
    ).toBe(true);
    expect(websiteChanged(["pnpm-lock.yaml"])).toBe(true);
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
