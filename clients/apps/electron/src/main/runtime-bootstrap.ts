import { app } from "electron";
import log from "electron-log/main";
import { getCommaReleaseConfig, type CommaReleaseConfig } from "../release-config";
import { resolveElectronE2eHooks, type ElectronE2eHooks } from "./e2e-hooks";
import {
  hasElectronUserDataOverride,
  installCommaElectronRuntimePaths,
  initializeCommaElectronLog,
  resolveCommaElectronRuntimePaths,
  type CommaElectronRuntimePaths,
} from "./runtime-paths";

export interface CommaElectronRuntime {
  e2eHooks: ElectronE2eHooks;
  paths: CommaElectronRuntimePaths;
  releaseConfig: CommaReleaseConfig;
}

let activeRuntime: CommaElectronRuntime | undefined;

export function bootstrapCommaElectronRuntime(): CommaElectronRuntime {
  if (activeRuntime) return activeRuntime;

  const releaseConfig = getCommaReleaseConfig();
  const e2eHooks = resolveElectronE2eHooks({
    isPackaged: app.isPackaged,
  });
  const commandLineUserDataPath =
    app.commandLine.hasSwitch("user-data-dir") ||
    hasElectronUserDataOverride(process.argv)
      ? app.getPath("userData")
      : undefined;
  const paths = resolveCommaElectronRuntimePaths({
    appData: app.getPath("appData"),
    releaseConfig,
    // A declared Electron profile is authoritative. The test-only temporary
    // directory exists solely as isolation for launches that omitted one.
    userDataOverride: commandLineUserDataPath ?? e2eHooks.fallbackUserDataPath,
  });

  installCommaElectronRuntimePaths(app, paths);
  app.setName(releaseConfig.productName);
  activeRuntime = Object.freeze({ e2eHooks, paths, releaseConfig });
  initializeCommaElectronLog(log, paths);
  return activeRuntime;
}
