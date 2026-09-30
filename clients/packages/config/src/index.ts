export type CommaChannel = "dev" | "staging" | "prod";

export interface CommaConfig {
  channel: CommaChannel;
  productName: string;
  apiBaseUrl: string;
}

export const commaLogoUrl = "brand/comma/icon.png";

/** Shared vector geometry for the compact Comma product mark. */
export const commaProductMarkPathData =
  "M10 2a8 8 0 0 1 7.81 9.732c-.04.177-.29.19-.372.03a4.3 4.3 0 0 0-1.67-1.752 4.3 4.3 0 0 0-5.875 1.575 4.3 4.3 0 0 0 1.575 5.874l.057.033c.159.088.138.336-.04.37A8 8 0 1 1 10 2Zm1.399 10.27a2.87 2.87 0 0 1 3.92-1.05 2.87 2.87 0 0 1 1.142 3.749l.005.005a3.786 3.786 0 0 1-.096.166 2.868 2.868 0 0 1-.538.673 4.79 4.79 0 0 1-3.314 1.698c-.06.008-.093-.065-.048-.105.28-.253.608-.554.933-.871a2.87 2.87 0 0 1-2.004-4.265Z";

declare const COMMA_DEFINED_BUILD_FLAVOR: string | undefined;

const commaConfigs: Record<CommaChannel, CommaConfig> = {
  dev: {
    channel: "dev",
    productName: "Comma Dev",
    apiBaseUrl: "http://127.0.0.1:4200",
  },
  staging: {
    channel: "staging",
    productName: "Comma Staging",
    apiBaseUrl: "https://salix-staging.comma.surf",
  },
  prod: {
    channel: "prod",
    productName: "Comma",
    apiBaseUrl: "https://salix.comma.surf",
  },
};

export function parseCommaChannel(channel: string | undefined): CommaChannel {
  if (channel === "prod" || channel === "staging" || channel === "dev") {
    return channel;
  }

  return "dev";
}

export function parseCommaChannelStrict(
  channel: string | undefined,
  label = "COMMA_BUILD_FLAVOR"
): CommaChannel {
  if (!channel) {
    return "dev";
  }

  if (channel === "prod" || channel === "staging" || channel === "dev") {
    return channel;
  }

  throw new Error(`Invalid ${label} "${channel}". Expected prod, staging, or dev.`);
}

export function getCommaConfig(channel?: string): CommaConfig {
  return commaConfigs[parseCommaChannel(channel)];
}

export function getActiveCommaConfig(): CommaConfig {
  return getCommaConfig(
    typeof COMMA_DEFINED_BUILD_FLAVOR === "undefined"
      ? undefined
      : COMMA_DEFINED_BUILD_FLAVOR
  );
}
