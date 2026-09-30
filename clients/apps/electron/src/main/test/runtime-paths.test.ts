import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { getCommaReleaseConfig } from "../../release-config";
import {
  hasElectronUserDataOverride,
  installCommaElectronRuntimePaths,
  initializeCommaElectronLog,
  resolveCommaElectronRuntimePaths,
} from "../runtime-paths";

const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("Comma Electron runtime paths", () => {
  it.each([
    [["electron", "main.js", "--user-data-dir=/tmp/comma"], true],
    [["electron", "main.js", "--user-data-dir", "/tmp/comma"], true],
    [["electron", "main.js", "--user-data-dir="], false],
    [["electron", "main.js", "--user-data-dir", "--lang=en-US"], false],
    [["electron", "main.js"], false],
  ] as const)("detects an explicit Electron userData argument", (argv, expected) => {
    expect(hasElectronUserDataOverride(argv)).toBe(expected);
  });

  it.each([
    ["prod", "@comma"],
    ["staging", "@comma-staging"],
    ["dev", "@comma-dev"],
  ] as const)("resolves %s from its release runtime namespace", (flavor, namespace) => {
    const paths = resolveCommaElectronRuntimePaths({
      appData: "/Users/test/Library/Application Support",
      releaseConfig: getCommaReleaseConfig(flavor),
    });

    const userData = join("/Users/test/Library/Application Support", namespace);
    expect(paths).toEqual({
      logs: join(userData, "logs"),
      runtimeNamespace: namespace,
      sessionData: userData,
      userData,
    });
  });

  it("lets the E2E userData pointer replace every path without changing the release namespace", () => {
    const paths = resolveCommaElectronRuntimePaths({
      appData: "/ignored",
      releaseConfig: getCommaReleaseConfig("staging"),
      userDataOverride: "/tmp/comma-e2e",
    });

    expect(paths).toEqual({
      logs: "/tmp/comma-e2e/logs",
      runtimeNamespace: "@comma-staging",
      sessionData: "/tmp/comma-e2e",
      userData: "/tmp/comma-e2e",
    });
  });

  it("binds Electron user data, session data, and logs from one resolved root", () => {
    const root = mkdtempSync(join(tmpdir(), "comma-runtime-paths-"));
    temporaryDirectories.push(root);
    const paths = resolveCommaElectronRuntimePaths({
      appData: root,
      releaseConfig: getCommaReleaseConfig("dev"),
    });
    const setPath = vi.fn();
    const setAppLogsPath = vi.fn();

    installCommaElectronRuntimePaths({ setAppLogsPath, setPath }, paths);

    expect(setPath.mock.calls).toEqual([
      ["userData", join(root, "@comma-dev")],
      ["sessionData", join(root, "@comma-dev")],
    ]);
    expect(setAppLogsPath).toHaveBeenCalledWith(join(root, "@comma-dev", "logs"));
  });

  it("binds electron-log to the same runtime root before initialization", () => {
    const initialize = vi.fn();
    const log = {
      initialize,
      transports: { file: { resolvePathFn: () => "/legacy/main.log" } },
    };
    const paths = resolveCommaElectronRuntimePaths({
      appData: "/Users/test/Library/Application Support",
      releaseConfig: getCommaReleaseConfig("staging"),
    });

    initializeCommaElectronLog(log, paths);

    expect(log.transports.file.resolvePathFn()).toBe(
      "/Users/test/Library/Application Support/@comma-staging/logs/main.log"
    );
    expect(initialize).toHaveBeenCalledOnce();
  });
});
