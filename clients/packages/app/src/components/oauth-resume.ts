/**
 * Frontend half of the OAuth IdP logged-out round trip
 * (docs/identity-security.md, design "方案A").
 *
 * The API's authorize endpoint stashes a logged-out authorization
 * request server-side and redirects the browser here with only an
 * opaque handle: `{web_origin}/login?oauth_handle={uuid}`. This module
 * captures that handle into sessionStorage (scoped to the tab, gone on
 * close), and once a session exists the auth gate navigates top-level
 * to `{apiBaseUrl}/oauth2/authorize?resume={handle}` so the Lax session
 * cookie rides along and the server resumes the consent flow.
 *
 * The handle is untrusted input from the URL: anything that is not a
 * UUID is dropped on capture, and the navigation target is always the
 * configured API origin — the URL never contributes a destination.
 */

export const oauthResumeStorageKey = "comma.oauth_resume_handle";

const oauthHandleParam = "oauth_handle";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type WebStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;

/**
 * Pulls a valid `oauth_handle` out of the URL into storage. Returns the
 * cleaned-up URL (handle removed) when one was captured so the caller
 * can `history.replaceState` it away — keeping the handle out of
 * subsequent navigation, referrers, and browser history — or undefined
 * when the URL carried none. A malformed handle is discarded but still
 * scrubbed from the URL.
 */
export function captureOauthResumeHandle(
  currentUrl: string,
  storage: WebStorage
): string | undefined {
  let url: URL;
  try {
    url = new URL(currentUrl);
  } catch {
    return undefined;
  }

  if (!url.searchParams.has(oauthHandleParam)) {
    return undefined;
  }

  const handle = url.searchParams.get(oauthHandleParam) ?? "";
  if (uuidPattern.test(handle)) {
    storage.setItem(oauthResumeStorageKey, handle.toLowerCase());
  }

  url.searchParams.delete(oauthHandleParam);
  return url.toString();
}

/** The pending handle, if a valid one was captured this tab. */
export function peekOauthResumeHandle(storage: WebStorage): string | undefined {
  const handle = storage.getItem(oauthResumeStorageKey);
  return handle && uuidPattern.test(handle) ? handle : undefined;
}

/** Removes and returns the pending handle (single use, like the server side). */
export function consumeOauthResumeHandle(storage: WebStorage): string | undefined {
  const handle = peekOauthResumeHandle(storage);
  storage.removeItem(oauthResumeStorageKey);
  return handle;
}

/** Absolute resume URL on the configured API origin. */
export function oauthResumeUrl(apiBaseUrl: string, handle: string): string {
  const origin = apiBaseUrl.replace(/\/+$/, "");
  return `${origin}/oauth2/authorize?resume=${encodeURIComponent(handle)}`;
}
