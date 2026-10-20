// What the agents spent, as the usage page reads it (GET /usage): admin/views.rs `usage` over usage.rs `summary`,
// `price_table`, `price`, `cost` and store/usage.rs, with the same JSON field for field.
//
// The counting itself (src/usage/counter.ts, usage.rs `Usage::read`: the transcripts read into the `usage` table) is
// the running station's, not a read: what was counted is read here as it is in the database. `reading` is what the
// counter has in its memory (`readingAll`), given by the asker; not given, it is true (nothing read yet).
import { knownChannel, slackCreator } from "./slack-known.ts";
import { loadMesh } from "../mesh/native.ts";
import { unified } from "../agents/unified.ts";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { type Lang, tr } from "../ops/i18n.ts";
import { type Json, STILLFAIL_SURFACE, type Store, type UsageGroup, usageGroups, usageSince, usageThreads } from "./store.ts";
import { titleOf } from "./views.ts";

// ── prices (usage.rs) ──

/// A model's API prices, in dollars per million tokens. Writing to the cache costs 1.25× input for five minutes, 2× for
/// an hour; fast mode doubles all of it.
type Price = { input: number; output: number; cacheRead: number };

/// usage.rs PRICES: standard short-context API list prices (2026-10-02). Longer names first.
const PRICES: [string, Price][] = [
  ["gpt-6-astra", { input: 10.0, output: 50.0, cacheRead: 1.0 }],
  ["gpt-6.1-sol", { input: 2.0, output: 10.0, cacheRead: 0.1 }],
  ["gpt-6-sol", { input: 2.0, output: 10.0, cacheRead: 0.2 }],
  ["gpt-6-luna", { input: 0.1, output: 0.5, cacheRead: 0.01 }],
  ["gpt-5.6-sol", { input: 4.0, output: 20.0, cacheRead: 0.4 }],
  ["claude-fable-5-1", { input: 10.0, output: 50.0, cacheRead: 0.25 }],
  ["claude-mythos-5-1", { input: 10.0, output: 50.0, cacheRead: 0.25 }],
  ["claude-fable-5", { input: 10.0, output: 50.0, cacheRead: 1.0 }],
  ["claude-mythos-5", { input: 10.0, output: 50.0, cacheRead: 1.0 }],
  ["claude-opus-5-5", { input: 4.0, output: 20.0, cacheRead: 0.2 }],
  ["claude-opus-5", { input: 5.0, output: 25.0, cacheRead: 0.5 }],
  ["claude-opus-4-8", { input: 5.0, output: 25.0, cacheRead: 0.5 }],
  ["claude-opus-4-7", { input: 5.0, output: 25.0, cacheRead: 0.5 }],
  ["claude-opus-4-6", { input: 5.0, output: 25.0, cacheRead: 0.5 }],
  ["claude-opus-4-5", { input: 5.0, output: 25.0, cacheRead: 0.5 }],
  ["claude-sonnet-5-5", { input: 2.0, output: 10.0, cacheRead: 0.2 }],
  ["claude-sonnet-5", { input: 2.0, output: 10.0, cacheRead: 0.2 }],
  ["claude-sonnet-4-6", { input: 3.0, output: 15.0, cacheRead: 0.3 }],
  ["claude-sonnet-4-5", { input: 3.0, output: 15.0, cacheRead: 0.3 }],
  ["claude-haiku-4-5", { input: 1.0, output: 5.0, cacheRead: 0.1 }],
];

/// price_table: the very same table `cost` uses, for inspecting a station's calculation from the usage page.
export function priceTable(lang: Lang): Json {
  return {
    note: tr(lang, "station.usage.priceNote"),
    rows: PRICES.map(([model, p]) => ({
      model, input: p.input, cacheRead: p.cacheRead,
      cacheWrite: model.startsWith("claude-") ? p.input * 1.25 : null,
      cacheWriteLong: model.startsWith("claude-") ? p.input * 2.0 : null, output: p.output,
    })),
  };
}

/// What a model is, however it is spelled: lower case, without its provider's prefix, region, version stamp or date; a
/// `[1m]` context stays (systems/profiles model.rs `model_key`, Comma's too).
export function modelKey(spelled: string): string {
  return loadMesh().modelKey(spelled);
}

/// price: a model's prices, however a profile spells it (anthropic/claude-opus-5-5, claude-opus-5-5[1m]); none for a
/// model without a list price here.
export function price(model: string): Price | null {
  const name = modelKey(model);
  return PRICES.find(([prefix]) => name === prefix || (name.startsWith(prefix) && name.slice(prefix.length).startsWith("[")))?.[1] ?? null;
}

/// cost: what a day's calls of one model would cost at its API prices, in dollars (in the Rust's order of operations).
export function cost(g: UsageGroup): number | null {
  if (g.model === null) return null;
  const p = price(g.model);
  if (p === null) return null;
  const tokens = g.input * p.input + g.cacheWrite * p.input * 1.25 + g.cacheWriteLong * p.input * 2.0 + g.cacheRead * p.cacheRead + g.output * p.output;
  return (tokens / 1e6) * (g.fast ? 2.0 : 1.0);
}

/// Usage::summary: every day's calls from `from` until `to`, by thread, person, profile and model (UsageRow).
function summary(s: Store, from: bigint, to: bigint, utcOffsetMin: bigint): Json[] {
  return usageGroups(s, from, to, utcOffsetMin).map((g) => ({
    day: g.day, session: g.session, thread: g.thread, person: g.person, profile: g.profile, runtime: g.runtime, model: g.model,
    calls: g.calls, input: g.input, cacheRead: g.cacheRead, cacheWrite: g.cacheWrite + g.cacheWriteLong, output: g.output, cost: cost(g),
  }));
}

// ── the config's profiles (config.rs parse_config, what usage shows of them) ──

/// The profiles' ids, names and runtimes: a name is trimmed (else the id); the runtime is the first the account runs
/// (systems/profiles `runtimes`), Claude's in name for one that runs neither. No config: none.
export function configProfiles(dataDir: string): Record<string, Json> {
  const out: Record<string, Json> = {};
  let raw: Json;
  try {
    raw = JSON.parse(readFileSync(join(dataDir, "config.json"), "utf8"));
  } catch {
    return out;
  }
  for (const p of Array.isArray(raw?.profiles) ? raw.profiles : []) {
    if (typeof p?.id !== "string") continue;
    const runtimes = loadMesh().profileRuntimes(JSON.stringify(unified(p)));
    const name = typeof p.name === "string" && p.name.trim() !== "" ? p.name.trim() : p.id;
    out[p.id] = { name, runtime: runtimes[0] ?? "claude" };
  }
  return out;
}

// ── people (views.rs `creator`, as views.ts has it) ──

/// A creator reference in words. No Slack connection knows anyone: a Slack user goes by their id, with no email.
function creator(s: Store, lang: Lang, reference: string): Json {
  if (reference === "local") return { id: "local", name: tr(lang, "station.creator.localPage"), email: null, via: "local" };
  const slack = slackCreator(s, reference);
  if (slack !== null) return slack;
  return { id: reference, name: s.names.get(reference) ?? reference, email: reference, via: "cloud" };
}

/// Rust's String order (bytes of UTF-8), for a BTreeSet's.
const byBytes = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));

/// admin/views.rs `usage`: what the agents spent from `from` until `to` (ms), by day in the asker's time zone
/// (`utcOffsetMin`), with the threads, people and profiles the rows name. `from`/`to` are i64s, written as such.
/// `reading`: whether the counter is still reading everything for the first time (UsageCounter.readingAll).
export function usage(s: Store, lang: Lang, from: bigint, to: bigint, utcOffsetMin: bigint, reading = true): Json {
  const rows = summary(s, from, to, utcOffsetMin);
  const wanted = [...new Set(rows.map((r) => r.thread).filter((t): t is number => t !== null))];
  const threads: Record<string, Json> = {};
  for (const [t, first] of usageThreads(s, wanted)) {
    // A Slack channel's name, as far as known (`known_channel`).
    const title = titleOf(t, first, t.surface === STILLFAIL_SURFACE ? null : knownChannel(s, threadConnect(s, t.id), t.channel));
    threads[String(t.id)] = { title, surface: t.surface, home: t.home, archived: t.hiddenAt !== null };
  }
  const refs = [...new Set(rows.map((r) => r.person).filter((p): p is string => p !== null))].sort(byBytes);
  const people: Record<string, Json> = {};
  for (const r of refs) people[r] = creator(s, lang, r);
  const i64 = (n: bigint) => (JSON as any).rawJSON(String(n));
  return {
    from: i64(from),
    to: i64(to),
    since: usageSince(s),
    reading,
    prices: priceTable(lang),
    rows,
    threads,
    people,
    profiles: configProfiles(s.dataDir),
  };
}

/// The connect a Slack thread came in through: the first of its sessions' that is not the station's own.
function threadConnect(s: Store, thread: number): string | null {
  const row = s.db.prepare("SELECT connect FROM thread_sessions WHERE thread = ? AND connect != 'ember' ORDER BY joined_at, rowid LIMIT 1").get(thread) as { connect: string } | undefined;
  return row?.connect ?? null;
}
