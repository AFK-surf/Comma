import { useSyncExternalStore, type MouseEvent } from "react";
import type { BftSession } from "./api";

/*
 * Minimal History API router. The SPA owns `/` and `/orgs/:org`; every other
 * dashboard address is a LiveView page and is reached with a full page load.
 */

export type BftRoute =
  | { name: "root" }
  | { name: "org-overview"; org: string }
  | { name: "unknown" };

export function matchRoute(pathname: string): BftRoute {
  const path = pathname.length > 1 ? pathname.replace(/\/+$/, "") : pathname;
  if (path === "/") return { name: "root" };
  const org = /^\/orgs\/([^/]+)$/.exec(path)?.[1];
  if (org) {
    try {
      return { name: "org-overview", org: decodeURIComponent(org) };
    } catch {
      return { name: "unknown" };
    }
  }
  return { name: "unknown" };
}

export function isSpaPath(pathname: string) {
  return matchRoute(pathname).name !== "unknown";
}

export type RootRedirect =
  | { kind: "replace"; path: string }
  | { kind: "assign"; href: string };

/** `/` opens the first organization in place, or the LiveView org list. */
export function rootRedirect(session: BftSession): RootRedirect {
  const first = session.orgs[0];
  return first
    ? { kind: "replace", path: `/orgs/${encodeURIComponent(first.slug)}` }
    : { kind: "assign", href: "/orgs" };
}

const locationEvent = "bft:locationchange";

export function navigate(path: string, options: { replace?: boolean } = {}) {
  if (options.replace) window.history.replaceState(null, "", path);
  else window.history.pushState(null, "", path);
  window.dispatchEvent(new Event(locationEvent));
}

/** Route to an SPA page in place; anything else is a full page load. */
export function go(href: string) {
  if (isSpaPath(new URL(href, window.location.href).pathname)) navigate(href);
  else window.location.assign(href);
}

function subscribe(listener: () => void) {
  window.addEventListener("popstate", listener);
  window.addEventListener(locationEvent, listener);
  return () => {
    window.removeEventListener("popstate", listener);
    window.removeEventListener(locationEvent, listener);
  };
}

export function usePathname() {
  return useSyncExternalStore(subscribe, () => window.location.pathname);
}

/** Click handler for `<a href>` pointing at an SPA route. */
export function spaLinkClick(event: MouseEvent<HTMLAnchorElement>) {
  if (
    event.defaultPrevented ||
    event.button !== 0 ||
    event.metaKey ||
    event.ctrlKey ||
    event.shiftKey ||
    event.altKey
  ) {
    return;
  }
  event.preventDefault();
  navigate(event.currentTarget.getAttribute("href") ?? "/");
}
