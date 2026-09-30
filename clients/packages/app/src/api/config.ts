import { getActiveCommaConfig } from "@comma/config";

declare const COMMA_DEFINED_API_BASE_URL: string | undefined;

export const apiBaseUrlStorageKey = "comma.apiBaseUrl";
const legacySessionTokenStorageKey = "comma.sessionToken";
const legacyUserEmailStorageKey = "comma.userEmail";
const legacyUserAdminStorageKey = "comma.userAdmin";

export function defaultApiBaseUrl() {
  const activeConfig = getActiveCommaConfig();
  const releaseApiBaseUrl =
    normalizeStoredApiBaseUrl(definedCommaApiBaseUrl()) || activeConfig.apiBaseUrl;

  if (activeConfig.channel !== "dev") {
    localStorage.removeItem(apiBaseUrlStorageKey);
    return releaseApiBaseUrl;
  }

  return (
    normalizeStoredApiBaseUrl(localStorage.getItem(apiBaseUrlStorageKey)) ||
    releaseApiBaseUrl
  );
}

export function storeCommaApiBaseUrl(baseUrl: string) {
  localStorage.setItem(apiBaseUrlStorageKey, baseUrl);
}

// One-way cleanup for renderer-owned auth metadata left by builds before the
// HttpOnly-cookie/Main-owned bearer migration. CommaRootLayout runs it for both
// browser and Electron hosts when the app mounts.
export function scrubLegacyRendererAuthMetadata() {
  localStorage.removeItem(legacySessionTokenStorageKey);
  localStorage.removeItem(legacyUserEmailStorageKey);
  localStorage.removeItem(legacyUserAdminStorageKey);
}

function definedCommaApiBaseUrl() {
  return typeof COMMA_DEFINED_API_BASE_URL === "undefined"
    ? undefined
    : COMMA_DEFINED_API_BASE_URL.trim() || undefined;
}

function normalizeStoredApiBaseUrl(baseUrl: string | null | undefined) {
  if (!baseUrl || baseUrl === "/") {
    return undefined;
  }

  return baseUrl;
}
