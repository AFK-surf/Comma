import { app } from "electron";
import log from "electron-log/main";
import { UpdateManager, type UpdateInfo, type VelopackAsset } from "velopack";
import { getElectronDisplayVersion } from "../app-version";
import { getCommaReleaseConfig } from "../release-config";

const releaseConfig = getCommaReleaseConfig();
const updateUrl = releaseConfig.updateUrl;
const displayVersion = getElectronDisplayVersion({
  flavor: releaseConfig.flavor,
  packageVersion: app.getVersion(),
});

function formatError(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function createUpdateManager() {
  if (!updateUrl) {
    throw new Error(
      `${releaseConfig.productName} does not have a Velopack update feed configured.`
    );
  }

  return new UpdateManager(updateUrl);
}

function getReleaseStatusFields() {
  return {
    flavor: releaseConfig.flavor,
    releaseChannel: releaseConfig.releaseChannel,
    packageName: releaseConfig.packageName,
    productName: releaseConfig.productName,
    appBundleId: releaseConfig.appBundleId,
    packId: releaseConfig.packId,
    urlScheme: releaseConfig.urlScheme,
    apiBaseUrl: releaseConfig.apiBaseUrl,
  };
}

export function getUpdateStatus() {
  if (!updateUrl) {
    return {
      ...getReleaseStatusFields(),
      configured: false,
      currentVersion: displayVersion,
      error:
        releaseConfig.flavor === "dev"
          ? "Comma Dev does not use a remote update feed. Set COMMA_UPDATE_URL to test updates locally."
          : "Set COMMA_UPDATE_URL or COMMA_R2_PUBLIC_BASE_URL to a Velopack release feed before checking for updates.",
    };
  }

  try {
    const manager = createUpdateManager();

    return {
      ...getReleaseStatusFields(),
      configured: true,
      updateUrl,
      currentVersion: manager.getCurrentVersion(),
      appId: manager.getAppId(),
      portable: manager.isPortable(),
      pendingRestart: manager.getUpdatePendingRestart(),
    };
  } catch (error) {
    return {
      ...getReleaseStatusFields(),
      configured: true,
      updateUrl,
      currentVersion: displayVersion,
      error: formatError(error),
    };
  }
}

export async function checkForUpdate() {
  const manager = createUpdateManager();
  return manager.checkForUpdatesAsync();
}

export async function downloadUpdate(update: UpdateInfo) {
  const manager = createUpdateManager();

  await manager.downloadUpdateAsync(update, (progress) => {
    log.info(`Velopack download progress: ${progress}%`);
  });

  return true;
}

export async function applyUpdate(update: UpdateInfo | VelopackAsset) {
  const manager = createUpdateManager();

  manager.waitExitThenApplyUpdate(update, false, true);
  app.quit();

  return true;
}
