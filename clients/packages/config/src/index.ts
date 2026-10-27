export type CommaChannel = "dev" | "staging" | "prod";

export interface CommaConfig {
  channel: CommaChannel;
  productName: string;
  apiBaseUrl: string;
  webBaseUrl: string;
  /** The URL scheme the desktop app of this channel registers. */
  urlScheme: string;
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
    webBaseUrl: "http://127.0.0.1:5173",
    urlScheme: "comma-dev",
  },
  staging: {
    channel: "staging",
    productName: "Comma Staging",
    apiBaseUrl: "https://salix-staging.comma.surf",
    webBaseUrl: "https://app-staging.comma.surf",
    urlScheme: "comma-staging",
  },
  prod: {
    channel: "prod",
    productName: "Comma",
    apiBaseUrl: "https://salix.comma.surf",
    webBaseUrl: "https://app.comma.surf",
    urlScheme: "comma",
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

export type MiniAppRunLink =
  | { kind: "run"; workspace_id: string; app_id: string; route: string }
  | { kind: "invalid" };

/** Hosted channels, loopback development, and explicitly configured renderer origins own App links. */
export function parseMiniAppRunLink(
  value: string,
  rendererOrigins: readonly string[] = []
): MiniAppRunLink | undefined {
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password)
      return undefined;
    const origins = [
      ...Object.values(commaConfigs).map((config) => config.webBaseUrl),
      ...rendererOrigins,
    ];
    const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
    if (
      !local &&
      !origins.some((origin) => {
        try {
          return new URL(origin).origin === url.origin;
        } catch {
          return false;
        }
      })
    )
      return undefined;
    if (url.pathname !== "/") return undefined;
    if (!url.hash.startsWith("#/apps/")) return undefined;
    const route = new URL(url.hash.slice(1), "https://route.invalid");
    if (!route.pathname.startsWith("/apps/") || !/\/run\/?$/.test(route.pathname))
      return undefined;
    const match = /^\/apps\/([^/]+)\/([^/]+)\/run\/?$/.exec(route.pathname);
    if (!match) return { kind: "invalid" };
    let workspace_id: string;
    let app_id: string;
    try {
      workspace_id = decodeURIComponent(match[1]!);
      app_id = decodeURIComponent(match[2]!);
    } catch {
      return { kind: "invalid" };
    }
    if (
      [workspace_id, app_id].some(
        (id) =>
          !id.trim() ||
          id.includes("/") ||
          id.includes("\\") ||
          [...id].some((character) => character.charCodeAt(0) < 32)
      )
    )
      return { kind: "invalid" };
    return {
      kind: "run",
      workspace_id,
      app_id,
      route: `/apps/${encodeURIComponent(workspace_id)}/${encodeURIComponent(app_id)}/run${route.search}`,
    };
  } catch {
    return undefined;
  }
}
