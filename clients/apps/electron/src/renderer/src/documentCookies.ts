/**
 * The renderer keeps no cookies: product requests go through Main, and
 * analytics persists to localStorage. Reading `document.cookie` is a
 * synchronous call into the cookie store, and on a cold start the first one
 * waits while the store fetches its encryption key from the macOS keychain
 * (2.8 s in a staging build), freezing the window and its boot logo.
 * posthog-js reads cookies as soon as its module loads, so the cookie property
 * of this document never reaches the store.
 */
export function closeDocumentCookies() {
  Object.defineProperty(document, "cookie", {
    configurable: true,
    get: () => "",
    set: () => {},
  });
}
