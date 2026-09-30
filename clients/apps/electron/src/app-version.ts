import type { CommaChannel } from "@comma/config";

declare const COMMA_DEFINED_DISPLAY_VERSION: string | undefined;

const stableVersionPattern = /^\d+\.\d+\.\d+$/u;
const stagingReleaseVersionPattern = /^\d+\.\d+\.\d+-staging\.[1-9]\d*$/u;

export interface ElectronDisplayVersionInput {
  flavor: CommaChannel;
  packageVersion: string;
  releaseVersion?: string | undefined;
}

interface ElectronAboutPanelOptions {
  applicationName: string;
  applicationVersion: string;
  version: string;
}

interface ElectronAboutPanelApp {
  setAboutPanelOptions(options: ElectronAboutPanelOptions): void;
}

function requireStableVersion(value: string, label: string) {
  const version = value.trim();
  if (!stableVersionPattern.test(version)) {
    throw new Error(`Invalid ${label} version: ${value || "<missing>"}`);
  }
  return version;
}

export function resolveElectronDisplayVersion({
  flavor,
  packageVersion,
  releaseVersion,
}: ElectronDisplayVersionInput) {
  const stableVersion = requireStableVersion(packageVersion, "Electron package");

  if (flavor === "dev") {
    return `${stableVersion}-dev`;
  }

  const explicitReleaseVersion = releaseVersion?.trim();
  if (flavor === "prod") {
    return explicitReleaseVersion
      ? requireStableVersion(explicitReleaseVersion, "production release")
      : stableVersion;
  }

  if (!explicitReleaseVersion) {
    return `${stableVersion}-staging.local`;
  }
  if (!stagingReleaseVersionPattern.test(explicitReleaseVersion)) {
    throw new Error(`Invalid staging release version: ${explicitReleaseVersion}`);
  }
  return explicitReleaseVersion;
}

export function getElectronDisplayVersion(
  input: Omit<ElectronDisplayVersionInput, "releaseVersion">
) {
  const embeddedVersion =
    typeof COMMA_DEFINED_DISPLAY_VERSION === "undefined"
      ? undefined
      : COMMA_DEFINED_DISPLAY_VERSION.trim();

  return (
    embeddedVersion ||
    resolveElectronDisplayVersion({
      ...input,
      releaseVersion: process.env.COMMA_PACK_VERSION,
    })
  );
}

export function configureElectronAboutPanel(
  app: ElectronAboutPanelApp,
  {
    displayVersion,
    productName,
  }: {
    displayVersion: string;
    productName: string;
  }
) {
  app.setAboutPanelOptions({
    applicationName: productName,
    applicationVersion: displayVersion,
    // Electron otherwise keeps CFBundleVersion as a second, stale build label.
    version: "",
  });
}
