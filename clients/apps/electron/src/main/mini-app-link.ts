import { parseMiniAppRunLink } from "@comma/config";
/**
 * A Mini App link page on the web offers `<scheme>://apps/link/<token>` to open the app in Comma on Mac.
 * This is a navigation hint only: the app route resolves the token through the server, which authorizes it.
 */
const linkToken = /^[A-Za-z0-9_-]{43}$/;

/** The main window route for a Mini App link URL of this app's scheme, or undefined. */
export function miniAppLinkRoute(
  value: string,
  expectedScheme: string
): string | undefined {
  try {
    const url = new URL(value);
    if (url.protocol !== `${expectedScheme}:` || url.hostname !== "apps")
      return undefined;
    if (url.username || url.password || url.port || url.search || url.hash)
      return undefined;
    const match = /^\/link\/([^/]+)$/.exec(url.pathname);
    if (!match || !linkToken.test(match[1]!)) return undefined;
    return `/apps/link/${match[1]}`;
  } catch {
    return undefined;
  }
}

/** Returns whether the URL belongs to the App route, including an invalid App address. */
export function dispatchMiniAppRunLink(
  value: string,
  origins: readonly string[],
  open: (route: string) => void,
  unavailable: () => void
): boolean {
  const link = parseMiniAppRunLink(value, origins);
  if (!link) return false;
  if (link.kind === "invalid") unavailable();
  else open(link.route);
  return true;
}
