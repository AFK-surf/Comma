import { mkdirSync } from "node:fs";
import { join } from "node:path";
import type electronLog from "electron-log/main";
import type { CommaReleaseConfig } from "../release-config";

export interface CommaElectronRuntimePaths {
  logs: string;
  runtimeNamespace: string;
  sessionData: string;
  userData: string;
}

interface ElectronRuntimePathTarget {
  setAppLogsPath(path: string): void;
  setPath(name: "sessionData" | "userData", path: string): void;
}

interface ElectronLogTarget {
  initialize: typeof electronLog.initialize;
  transports: {
    file: Pick<typeof electronLog.transports.file, "resolvePathFn">;
  };
}

export function hasElectronUserDataOverride(argv: readonly string[]) {
  return argv.some((argument, index) => {
    if (argument.startsWith("--user-data-dir=")) {
      return argument.length > "--user-data-dir=".length;
    }
    return (
      argument === "--user-data-dir" &&
      Boolean(argv[index + 1]) &&
      !argv[index + 1]!.startsWith("--")
    );
  });
}

export function resolveCommaElectronRuntimePaths({
  appData,
  releaseConfig,
  userDataOverride,
}: {
  appData: string;
  releaseConfig: CommaReleaseConfig;
  userDataOverride?: string | undefined;
}): CommaElectronRuntimePaths {
  const userData = userDataOverride ?? join(appData, releaseConfig.runtimeNamespace);

  return {
    logs: join(userData, "logs"),
    runtimeNamespace: releaseConfig.runtimeNamespace,
    sessionData: userData,
    userData,
  };
}

export function installCommaElectronRuntimePaths(
  app: ElectronRuntimePathTarget,
  paths: CommaElectronRuntimePaths
) {
  mkdirSync(paths.userData, { recursive: true });
  mkdirSync(paths.logs, { recursive: true });
  app.setPath("userData", paths.userData);
  app.setPath("sessionData", paths.sessionData);
  app.setAppLogsPath(paths.logs);
}

export function initializeCommaElectronLog(
  log: ElectronLogTarget,
  paths: CommaElectronRuntimePaths
) {
  log.transports.file.resolvePathFn = () => join(paths.logs, "main.log");
  log.initialize();
}
