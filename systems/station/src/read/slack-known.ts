// What Slack calls people and channels, as the readers know it: the station's names book (<data>/slack-names.json,
// src/slack/names.ts, kept by the connects' connections) and the connects' Slack workspaces (config.json), each read
// again when its file changed. A name not in the book is not known yet: the connection looks it up when it hears of
// the person or channel, and the pages are told to read again then.
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import type { Json, Store } from "./store.ts";

type Cached<T> = { stamp: string; value: T };
const cache = new Map<string, Cached<unknown>>();

/// A JSON file of the data directory, read again when it changed; `empty` when it is not there or does not read.
function readJson<T>(path: string, empty: T, shape: (v: Json) => T): T {
  let stamp = "none";
  try {
    const st = statSync(path);
    stamp = `${st.size}:${st.mtimeMs}:${st.ino}`;
  } catch {}
  const had = cache.get(path) as Cached<T> | undefined;
  if (had && had.stamp === stamp) return had.value;
  let value = empty;
  if (stamp !== "none") {
    try {
      value = shape(JSON.parse(readFileSync(path, "utf8")));
    } catch {}
  }
  cache.set(path, { stamp, value });
  return value;
}

/// Each connect's Slack workspace (`slack.team`), as config.json has it.
function teams(s: Store): Map<string, { id: string; name: string }> {
  return readJson(join(s.dataDir, "config.json"), new Map(), (raw) => {
    const out = new Map<string, { id: string; name: string }>();
    for (const c of Array.isArray(raw?.connects) ? raw.connects : []) {
      const team = c?.slack?.team;
      if (typeof c?.id === "string" && typeof team?.id === "string" && team.id !== "") out.set(c.id, { id: team.id, name: typeof team.name === "string" ? team.name : "" });
    }
    return out;
  });
}

function book(s: Store): Record<string, Json> {
  return readJson(join(s.dataDir, "slack-names.json"), {}, (v) => (v !== null && typeof v === "object" && !Array.isArray(v) ? v : {}));
}

/// A connect's Slack workspace's name, when known.
export function teamName(s: Store, connect: string): string | null {
  const name = teams(s).get(connect)?.name ?? "";
  return name === "" ? null : name;
}

/// A Slack person of a connect, as far as known: their name and email.
export function knownPerson(s: Store, connect: string, user: string): { name: string; email: string } | null {
  const team = teams(s).get(connect)?.id ?? "?";
  const person = book(s)[`u:${team}:${user}`]?.person;
  return person && typeof person.name === "string" ? { name: person.name, email: typeof person.email === "string" ? person.email : "" } : null;
}

/// A channel's name of a connect's Slack, as far as known (null for a direct message, or not known yet).
export function knownChannel(s: Store, connect: string | null, channel: string): string | null {
  if (connect === null) return null;
  const team = teams(s).get(connect)?.id ?? "?";
  const name = book(s)[`c:${team}:${channel}`]?.channel;
  return typeof name === "string" ? name : null;
}

/// A creator reference `slack:<connect>:<user>` in words (views.rs `creator`): never waits on Slack — what is known
/// now; null when the reference is not a Slack one.
export function slackCreator(s: Store, reference: string): Json | null {
  if (!reference.startsWith("slack:")) return null;
  const rest = reference.slice("slack:".length);
  const colon = rest.indexOf(":");
  if (colon <= 0 || colon >= rest.length - 1) return null;
  const [connect, user] = [rest.slice(0, colon), rest.slice(colon + 1)];
  const person = knownPerson(s, connect, user);
  return { id: reference, name: person?.name ? person.name : user, email: person?.email ? person.email : null, via: "slack" };
}
