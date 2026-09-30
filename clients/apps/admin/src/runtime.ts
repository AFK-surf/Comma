declare const COMMA_DEFINED_API_BASE_URL: string | undefined;

export function resolveAdminApiBaseUrl(value: string | undefined) {
  const apiBaseUrl = value?.trim();
  if (!apiBaseUrl) {
    throw new Error("Comma Admin API base URL was not injected by the build.");
  }

  return apiBaseUrl;
}

export function adminApiBaseUrl() {
  return resolveAdminApiBaseUrl(
    typeof COMMA_DEFINED_API_BASE_URL === "undefined"
      ? undefined
      : COMMA_DEFINED_API_BASE_URL
  );
}
