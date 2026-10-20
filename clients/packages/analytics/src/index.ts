import type { PostHog, PostHogConfig } from "posthog-js";

export const attributionKeys = [
  "initial_utm_source",
  "initial_utm_medium",
  "initial_utm_campaign",
  "initial_referrer_host",
  "initial_landing_page",
] as const;

const publicPages = new Set([
  "/",
  "/app",
  "/agent",
  "/pricing",
  "/enterprise",
  "/download",
  "/docs",
  "/blog",
  "/self-host",
  "/security",
  "/data-use",
  "/privacy",
  "/terms",
  "/contact",
  "/teams",
]);
// A documentation page, blog post or comparison: the path names only the public page.
const sectionPage = /^\/(?:docs|blog|alternatives)(?:\/[a-z0-9-]{1,64}){1,3}$/;
const localePrefix = /^[a-z]{2}(?:-[A-Za-z0-9]{2,3})?$/;
const slug = /^[a-zA-Z0-9_.-]{1,64}$/;
const host = (value: string) => value.length <= 253 && /^[a-z0-9.-]+$/.test(value);

const isPublicRoute = (route: string) =>
  publicPages.has(route) || sectionPage.test(route);

/** A website page without its language prefix, or "/other" for any other path. */
export function websiteRoute(pathname: string): string {
  const parts = pathname.split("/").filter(Boolean);
  if (parts[0] && localePrefix.test(parts[0])) parts.shift();
  const route = `/${parts.join("/")}`;
  return isPublicRoute(route) ? route : "/other";
}

/** The website language a path is in: its prefix, or "en" without one. */
export function websiteLocale(pathname: string): string {
  const first = pathname.split("/").filter(Boolean)[0];
  return first && localePrefix.test(first) ? first : "en";
}

export function sanitizeAttribution(input: unknown): Record<string, string> {
  if (!input || typeof input !== "object") return {};
  return Object.fromEntries(
    Object.entries(input).filter(([key, value]) => {
      if (typeof value !== "string") return false;
      if (key === "initial_landing_page")
        return isPublicRoute(value) || value === "/other";
      if (key === "initial_referrer_host") return host(value);
      return (
        ["initial_utm_source", "initial_utm_medium", "initial_utm_campaign"].includes(
          key
        ) && slug.test(value)
      );
    })
  );
}

/** Where one visit came from: the referring host and the link's campaign. */
export function sanitizeVisit(input: unknown): Record<string, string> {
  if (!input || typeof input !== "object") return {};
  return Object.fromEntries(
    Object.entries(input).filter(([key, value]) => {
      if (typeof value !== "string") return false;
      if (key === "referrer_host") return host(value);
      return (
        ["utm_source", "utm_medium", "utm_campaign"].includes(key) && slug.test(value)
      );
    })
  );
}

export function visitSource(): Record<string, string> {
  const params = new URLSearchParams(location.search);
  let referrer = "direct";
  try {
    if (document.referrer) referrer = new URL(document.referrer).hostname;
  } catch {
    /* invalid referrer */
  }
  return sanitizeVisit({
    referrer_host: referrer,
    utm_source: params.get("utm_source"),
    utm_medium: params.get("utm_medium"),
    utm_campaign: params.get("utm_campaign"),
  });
}

// The SDK owns anonymous identity and its cookie. Only these public campaign
// fields travel with it between the website and the web app.
export function webPersistence(channel: string): Partial<PostHogConfig> {
  return {
    persistence: "localStorage+cookie",
    persistence_name: `comma_${channel}_web_main-window`,
    cross_subdomain_cookie: true,
    cookieWinsOnConflict: true,
    cookie_persisted_properties: attributionKeys,
  };
}

export function firstTouch(
  client: PostHog,
  landingPage: string
): Record<string, string> {
  const saved = sanitizeAttribution(
    Object.fromEntries(attributionKeys.map((key) => [key, client.get_property(key)]))
  );
  if (saved.initial_landing_page) return saved;
  const visit = visitSource();
  const properties = sanitizeAttribution({
    initial_utm_source: visit.utm_source,
    initial_utm_medium: visit.utm_medium,
    initial_utm_campaign: visit.utm_campaign,
    initial_referrer_host: visit.referrer_host,
    initial_landing_page: landingPage,
  });
  client.register_once(properties);
  return properties;
}
