// The loopback port (the Rust station's local.rs). The station has no page of its own any more (its pages are still.fail
// cloud's): the port is kept so that links to the page it had, sent to Slack and kept in browsers, still lead
// somewhere: `/admin/...` is sent to the same page in the cloud's web app, or, while the station is in no workspace,
// told how to join one. `/healthz` says whether the station answers. Nothing on it reaches the admin API.
import { type Lang, langOf, tr } from "./i18n.ts";

/// Where the station is, as far as its old links care (cloud.json, as it is now).
export type Place = { origin: string; workspace: string; workspace_name: string; station: string; removed_at?: number };

export type Reply = { status: number; headers: Record<string, string>; body: string };

const plain = (status: number, body: string): Reply => ({ status, headers: { "content-type": "text/plain; charset=utf-8" }, body });

/// The language a browser asks in: `stillfail-lang`, else its Accept-Language (the first named; `*` names none).
export function langOfBrowser(headers: Record<string, string | string[] | undefined>): Lang {
  const get = (name: string) => {
    const v = headers[name];
    return Array.isArray(v) ? v[0] : v;
  };
  const said = get("stillfail-lang");
  if (said !== undefined) return langOf(said);
  const first = (get("accept-language") ?? "").split(/[,;]/)[0].trim();
  return langOf(first === "*" ? "" : first);
}

/// What the port says to `path`?`query`.
export function answer(path: string, query: string | null, ready: boolean, place: Place | null, lang: Lang): Reply {
  if (path === "/healthz") return plain(ready ? 200 : 503, "");
  if (path.startsWith("/admin/api/") || path === "/admin/api") {
    return { status: 404, headers: { "content-type": "application/json" }, body: JSON.stringify({ error: tr(lang, "station.local.noAdminApi") }) };
  }
  if (path !== "/" && path !== "/admin" && !path.startsWith("/admin/")) return plain(404, "");
  if (place && place.removed_at === undefined && place.origin !== "" && place.workspace !== "") {
    const to = moved(path.startsWith("/admin") ? path.slice("/admin".length) : path, query, place);
    return { status: 302, headers: { location: to, "cache-control": "no-store" }, body: "" };
  }
  return plain(404, unbound(place, lang));
}

/// Where a page of the station's old page is in the cloud's web app: `path` under /admin, the query kept as it was.
/// A station's pages there are under /w/<workspace>/s/<station>, the workspace's own under /w/<workspace>.
export function moved(path: string, query: string | null, place: Place): string {
  const w = `${place.origin.replace(/\/+$/, "")}/w/${place.workspace}`;
  const s = place.station;
  const parts = path.split("/").filter((p) => p !== "");
  const [a, b, c] = parts;
  let to: string;
  if (parts.length === 2 && a === "chats") to = `${w}/s/${s}/chats/${b}`;
  else if (parts.length === 2 && a === "services") to = `${w}/s/${s}/services/${b}`;
  // Bots became connects: their old links too.
  else if (parts.length === 2 && (a === "connects" || a === "bots")) to = `${w}/s/${s}/connects/${b}`;
  else if (parts.length === 2 && a === "settings" && b === "accounts") to = `${w}/s/${s}/settings/accounts`;
  else if (parts.length === 3 && a === "settings" && b === "accounts") to = `${w}/s/${s}/settings/accounts/${c}`;
  else if (parts.length === 2 && a === "settings" && ["connects", "memory", "appearance", "shortcuts"].includes(b)) to = `${w}/settings/${b}`;
  // The machine's page is its station's card among the workspace's.
  else if (parts.length === 2 && a === "settings" && b === "device") to = `${w}/settings/stations`;
  else if (parts.length === 1 && a === "settings") to = `${w}/settings`;
  else if (parts.length === 1 && a === "new") to = `${w}/new`;
  else if (parts.length === 1 && a === "archive") to = `${w}/archive`;
  else to = `${w}/`;
  return query ? `${to}?${query}` : to;
}

/// What the port says while the station is in no workspace: that it is not, and how to join one.
function unbound(place: Place | null, lang: Lang): string {
  if (place?.removed_at !== undefined) {
    return tr(lang, "station.local.removed", { workspace: place.workspace_name, at: new Date(place.removed_at * 1000).toISOString() });
  }
  return tr(lang, "station.local.unjoined");
}
