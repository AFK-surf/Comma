import {
  getCommaConfig,
  parseCommaChannelStrict,
  type CommaChannel,
} from "@comma/config";

export type CommaBuildFlavor = CommaChannel;
export type CommaReleaseChannel = "prod" | "staging";

declare const COMMA_DEFINED_BUILD_FLAVOR: string | undefined;
declare const COMMA_DEFINED_R2_PUBLIC_BASE_URL: string | undefined;
declare const COMMA_DEFINED_UPDATE_URL: string | undefined;
declare const COMMA_DEFINED_API_BASE_URL: string | undefined;

export interface CommaReleaseConfig {
  flavor: CommaBuildFlavor;
  runtimeNamespace: string;
  releaseChannel?: CommaReleaseChannel;
  packageName: string;
  productName: string;
  executableName: string;
  packId: string;
  appBundleId: string;
  appUserModelId: string;
  urlScheme: string;
  apiBaseUrl: string;
  r2Path?: string;
  updateUrl?: string;
}

export type CommaPackableReleaseConfig = CommaReleaseConfig & {
  releaseChannel: CommaReleaseChannel;
  r2Path: string;
};

const configs: Record<CommaBuildFlavor, Omit<CommaReleaseConfig, "updateUrl">> = {
  prod: {
    flavor: "prod",
    runtimeNamespace: "@comma",
    releaseChannel: "prod",
    packageName: "comma",
    productName: "Comma",
    executableName: "comma",
    packId: "surf.comma.desktop",
    appBundleId: "surf.comma.desktop",
    appUserModelId: "surf.comma.desktop",
    urlScheme: "comma",
    apiBaseUrl: getCommaConfig("prod").apiBaseUrl,
    r2Path: "comma/electron/prod",
  },
  staging: {
    flavor: "staging",
    runtimeNamespace: "@comma-staging",
    releaseChannel: "staging",
    packageName: "comma-staging",
    productName: "Comma Staging",
    executableName: "comma-staging",
    packId: "surf.comma.desktop.staging",
    appBundleId: "surf.comma.desktop.staging",
    appUserModelId: "surf.comma.desktop.staging",
    urlScheme: "comma-staging",
    apiBaseUrl: getCommaConfig("staging").apiBaseUrl,
    r2Path: "comma/electron/staging",
  },
  dev: {
    flavor: "dev",
    runtimeNamespace: "@comma-dev",
    packageName: "comma-dev",
    productName: "Comma Dev",
    executableName: "comma-dev",
    packId: "surf.comma.desktop.dev",
    appBundleId: "surf.comma.desktop.dev",
    appUserModelId: "surf.comma.desktop.dev",
    urlScheme: "comma-dev",
    apiBaseUrl: getCommaConfig("dev").apiBaseUrl,
  },
};

function readDefinedValue(name: string) {
  switch (name) {
    case "COMMA_BUILD_FLAVOR":
      return typeof COMMA_DEFINED_BUILD_FLAVOR === "undefined"
        ? undefined
        : COMMA_DEFINED_BUILD_FLAVOR;
    case "COMMA_R2_PUBLIC_BASE_URL":
      return typeof COMMA_DEFINED_R2_PUBLIC_BASE_URL === "undefined"
        ? undefined
        : COMMA_DEFINED_R2_PUBLIC_BASE_URL;
    case "COMMA_UPDATE_URL":
      return typeof COMMA_DEFINED_UPDATE_URL === "undefined"
        ? undefined
        : COMMA_DEFINED_UPDATE_URL;
    case "COMMA_API_BASE_URL":
      return typeof COMMA_DEFINED_API_BASE_URL === "undefined"
        ? undefined
        : COMMA_DEFINED_API_BASE_URL;
    default:
      return undefined;
  }
}

function readEnv(name: string) {
  return readDefinedValue(name)?.trim() || process.env[name]?.trim();
}

function joinUrl(baseUrl: string, path: string) {
  return `${baseUrl.replace(/\/+$/, "")}/${path.replace(/^\/+/, "")}`;
}

function assertPackableReleaseConfig(
  config: CommaReleaseConfig
): asserts config is CommaPackableReleaseConfig {
  if (!config.releaseChannel || !config.r2Path) {
    throw new Error(
      "Velopack releases are only enabled for COMMA_BUILD_FLAVOR=prod or staging."
    );
  }
}

export function getCommaReleaseConfig(
  flavor = parseCommaChannelStrict(readEnv("COMMA_BUILD_FLAVOR"))
): CommaReleaseConfig {
  const base = configs[flavor];
  const apiBaseUrl = readEnv("COMMA_API_BASE_URL") || base.apiBaseUrl;
  const explicitUpdateUrl = readEnv("COMMA_UPDATE_URL");
  const r2BaseUrl =
    readEnv("COMMA_R2_PUBLIC_BASE_URL") || readEnv("CLOUDFLARE_R2_PUBLIC_BASE_URL");
  const updateUrl =
    explicitUpdateUrl ||
    (base.r2Path && r2BaseUrl ? joinUrl(r2BaseUrl, base.r2Path) : undefined);

  const config: CommaReleaseConfig = {
    ...base,
    apiBaseUrl,
  };

  if (updateUrl) {
    config.updateUrl = updateUrl;
  }

  return config;
}

export function getPackableReleaseConfig(): CommaPackableReleaseConfig {
  const config = getCommaReleaseConfig();

  assertPackableReleaseConfig(config);

  return config;
}

export function getPublishedAssetUrl(path: string): string {
  const baseUrl =
    readEnv("COMMA_R2_PUBLIC_BASE_URL") || readEnv("CLOUDFLARE_R2_PUBLIC_BASE_URL");
  return baseUrl ? joinUrl(baseUrl, path) : "";
}
