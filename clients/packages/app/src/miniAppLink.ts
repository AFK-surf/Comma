// An app link (`https://app.comma.surf/a/<token>`) opens the normal Comma SPA, not a page of the app: the web Worker
// serves the main document for `/a/<token>`. The app reads the token at boot and moves it into its own hash route
// (`#/apps/link/<token>`), which a signed-out viewer keeps through sign-in or "Continue as guest". On Mac, Main opens
// the same hash route in the main window.

const TOKEN = "[A-Za-z0-9_-]{8,256}";
const PATH = new RegExp(`^/a/(${TOKEN})/?$`);
const HASH = new RegExp(`^#/apps/link/(${TOKEN})(?:[/?].*)?$`);

/** The app link token the page was opened with: its `/a/<token>` path, or the hash route it moved to. */
export function miniAppLinkTokenFromLocation(
  location: Pick<Location, "pathname" | "hash">
): string | undefined {
  return PATH.exec(location.pathname)?.[1] ?? HASH.exec(location.hash)?.[1];
}

/** The hash route that opens an app link. */
export function miniAppLinkRoute(token: string): string {
  return `/apps/link/${encodeURIComponent(token)}`;
}

/**
 * At boot, before the router reads the URL: a page opened at `/a/<token>` continues at `/#/apps/link/<token>`, so
 * routing, sign-in and reloads keep the link. Nothing changes on any other URL.
 */
export function adoptMiniAppLinkLocation(
  location: Pick<Location, "pathname" | "hash">,
  history: Pick<History, "replaceState">
): void {
  const token = PATH.exec(location.pathname)?.[1];
  if (!token) return;
  history.replaceState(null, "", `/#${miniAppLinkRoute(token)}`);
}
