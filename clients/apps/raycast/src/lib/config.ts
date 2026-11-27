// Which Comma app and server the extension talks to. These repeat the flavors of @comma/config
// (clients/packages/config): the extension is its own npm project and bundles nothing from the workspace.

export type Environment = "production" | "staging" | "development";

export interface EnvironmentConfig {
  /** The URL scheme of that flavor's desktop app. */
  scheme: string;
  /** The origin of that flavor's API. A link or a server answer never changes it. */
  apiOrigin: string;
}

export const environments: Record<Environment, EnvironmentConfig> = {
  production: { scheme: "comma", apiOrigin: "https://salix.comma.surf" },
  staging: { scheme: "comma-staging", apiOrigin: "https://salix-staging.comma.surf" },
  development: { scheme: "comma-dev", apiOrigin: "http://127.0.0.1:4200" },
};

export function environmentOf(value: unknown): Environment {
  return value === "staging" || value === "development" ? value : "production";
}
