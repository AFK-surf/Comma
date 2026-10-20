// The usage counter (src/usage/counter.ts): the Rust station's usage/tests.rs ported, the push-driven reads, and (when a
// copy of a real station is at $USAGE_WORK, default /tmp/usage-work) what it records against what the Rust recorded.
import type { Clock } from "effect";
import assert from "node:assert/strict";
import { appendFileSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { monitorEventLoopDelay } from "node:perf_hooks";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { zstdCompressSync, zstdDecompressSync } from "node:zlib";
import { cost, price, priceTable } from "../src/read/usage.ts";
import { iso, parseIso } from "../src/read/transcript.ts";
import { type StoreChange, type UsageGroup, Store, newMessage } from "../src/store/store.ts";
import { type CallState, UsageCounter, callsOf, claudeFiles, claudeProject, readFrom } from "../src/usage/counter.ts";
import { testClock } from "./hub-fakes.ts";

const dirs: string[] = [];
const stores: Store[] = [];
const counters: UsageCounter[] = [];
after(async () => {
  for (const c of counters) await c.stop();
  for (const s of stores) {
    try {
      s.close();
    } catch {}
  }
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function tempdir(): string {
  const d = mkdtempSync(join(tmpdir(), "usage-test-"));
  dirs.push(d);
  return d;
}

const claudeLine = (id: string, at: number, model: string, usage: unknown) =>
  JSON.stringify({ type: "assistant", timestamp: iso(at), isSidechain: false, message: { id, model, usage } });

const usage = (input: number, read: number, short: number, long: number, output: number) => ({
  input_tokens: input,
  cache_read_input_tokens: read,
  cache_creation_input_tokens: short + long,
  cache_creation: { ephemeral_5m_input_tokens: short, ephemeral_1h_input_tokens: long },
  output_tokens: output,
});

const fresh = (): CallState => ({ model: null, codexId: null });

test("a Claude response written as several lines counts once, with its cache split by how long", () => {
  const text = [
    claudeLine("m1", 1000, "claude-opus-5-5", usage(2, 100, 0, 50, 10)),
    claudeLine("m1", 1001, "claude-opus-5-5", usage(2, 100, 0, 50, 30)),
    JSON.stringify({ type: "user", message: { content: "usage" } }),
    claudeLine("m2", 2000, "<synthetic>", usage(0, 0, 0, 0, 0)),
    claudeLine("m3", 3000, "claude-sonnet-5-5", { input_tokens: 5, cache_creation_input_tokens: 7, output_tokens: 1, speed: "fast" }),
  ].join("\n");
  const calls = callsOf("claude", text, false, fresh());
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0], {
    id: "m1", at: 1000, model: "claude-opus-5-5", subagent: false, fast: false, input: 2, cacheRead: 100, cacheWrite: 0, cacheWriteLong: 50, output: 30,
  });
  // Without the split, what was written to the cache is taken as written for five minutes.
  assert.deepEqual([calls[1]!.cacheWrite, calls[1]!.cacheWriteLong, calls[1]!.fast], [7, 0, true]);
});

test("Codex calls are its token counts, told once each, with the model its turn named", () => {
  const count = (total: number, input: number, cached: number, output: number) =>
    JSON.stringify({
      timestamp: iso(5000), type: "event_msg",
      payload: { type: "token_count", info: { total_token_usage: { total_tokens: total }, last_token_usage: { input_tokens: input, cached_input_tokens: cached, output_tokens: output } } },
    });
  const text = [
    JSON.stringify({ timestamp: iso(4000), type: "session_meta", payload: { id: "th1", cwd: "/w" } }),
    JSON.stringify({ timestamp: iso(4000), type: "turn_context", payload: { model: "gpt-6" } }),
    count(120, 100, 60, 20),
    // The same count again, told with the rate limits.
    count(120, 100, 60, 20),
    JSON.stringify({ timestamp: iso(5000), type: "event_msg", payload: { type: "token_count", info: null } }),
    count(200, 70, 10, 10),
  ].join("\n");
  const state = fresh();
  const calls = callsOf("codex", text, false, state);
  assert.deepEqual(calls.map((c) => c.id), ["codex:th1:120", "codex:th1:120", "codex:th1:200"], "repeats are left to the store, which keeps one");
  assert.deepEqual([calls[0]!.input, calls[0]!.cacheRead, calls[0]!.output, calls[0]!.model], [40, 60, 20, "gpt-6"]);
  assert.equal(state.model, "gpt-6");
});

const group = (g: Partial<UsageGroup>): UsageGroup => ({
  day: "", session: "", thread: null, person: null, profile: null, runtime: "", model: null, fast: false, calls: 0, input: 0, cacheRead: 0,
  cacheWrite: 0, cacheWriteLong: 0, output: 0, ...g,
});

test("prices are found however a profile spells the model, and cost counts each kind of token", () => {
  assert.equal(price("claude-opus-5-5")?.input, 4.0);
  assert.equal(price("anthropic/claude-opus-5-5[1m]")?.cacheRead, 0.2);
  assert.equal(price("claude-opus-5")?.input, 5.0);
  assert.equal(price("claude-fable-5-1")?.cacheRead, 0.25);
  assert.equal(price("gpt-6"), null);
  const g = group({ model: "claude-opus-5-5", input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000, cacheWriteLong: 1_000_000, output: 1_000_000 });
  // 4 + 0.2 + 5 + 8 + 20
  assert.ok(Math.abs(cost(g)! - 37.2) < 1e-9);
  assert.ok(Math.abs(cost({ ...g, fast: true })! - 74.4) < 1e-9);
  assert.equal(cost({ ...g, model: "gpt-6" }), null);
});

test("GPT usage has a price, and unknown variants do not borrow one", () => {
  for (const [model, input, cached, output] of [
    ["gpt-6-astra", 10.0, 1.0, 50.0],
    ["gpt-6.1-sol", 2.0, 0.1, 10.0],
    ["gpt-6-sol", 2.0, 0.2, 10.0],
    ["gpt-6-luna", 0.1, 0.01, 0.5],
    ["gpt-5.6-sol", 4.0, 0.4, 20.0],
  ] as const) {
    const g = group({ model, input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000 });
    assert.ok(Math.abs(cost(g)! - (input + cached + output)) < 1e-9, model);
  }
  assert.deepEqual(price("openai/gpt-6-astra-2026-08-21"), price("gpt-6-astra"));
  assert.equal(price("gpt-6-astra-unknown"), null);
  assert.equal(price("gpt-6-astra:free"), null);
  const astra = (priceTable("en") as any).rows.find((r: any) => r.model === "gpt-6-astra");
  assert.deepEqual([astra.input, astra.cacheRead, astra.output], [10.0, 1.0, 50.0]);
  // Actual recorded GPT token totals: cached input is already separate from uncached input.
  const g = group({ model: "gpt-6-astra", input: 1_916_566, cacheRead: 71_041_792, output: 245_251 });
  assert.ok(Math.abs(cost(g)! - 102.470002) < 1e-9);
});

type Rig = { data: string; store: Store; usage: UsageCounter };

function rig(options: { settleMs?: number; safetyMs?: number; clock?: Clock.Clock } = {}): Rig {
  const data = tempdir();
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }] }));
  const store = Store.open(":memory:", null, options.clock);
  stores.push(store);
  const usage = new UsageCounter({ store, config: () => ({ dataDir: data, profiles: [{ home: join(data, "homes/cc") }] }), ...options });
  counters.push(usage);
  return { data, store, usage };
}

function session(store: Store, key: string, workspace: string, createdAt: number) {
  store.insertSession({ key, connect: "ember", createdBy: "creator@x", runtime: "claude", profile: "cc", workspace, token: `t-${key}`, createdAt, lastActiveAt: createdAt });
}

function append(path: string, lines: string[]) {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, lines.map((l) => `${l}\n`).join(""));
}

const MAX = Number.MAX_SAFE_INTEGER;

/// A TestClock at a day of 2026 (on its own it starts at 1970).
async function today() {
  const time = testClock();
  await time.adjust(Date.parse("2026-10-06T08:00:00Z"));
  return time;
}

test("each call is counted once, for whom its turn worked, where and on what", async () => {
  const time = await today();
  const pause = () => time.adjust(15);
  const r = rig({ clock: time.clock });
  const workspace = join(r.data, "sessions/ember/c-1/workspace");
  const created = r.store.now();
  session(r.store, "ember:c-1", workspace, created);
  const chat = r.store.openThreadOf("ember", "ember", "1.0", null, "creator@x", "ember:c-1");
  r.store.joinThread(chat.id, "ember:c-1", "ember");
  await pause();
  // A turn from before turns said whom they were for: its first person's message says.
  r.store.startTurn("t1", "ember:c-1", "input");
  const [n] = r.store.insertMessage(newMessage(chat.id, "2.0", "person", "b@x", "hi"));
  r.store.deliver(chat.id, n, ["ember:c-1"]);
  r.store.markDelivered("ember:c-1", [[chat.id, n]]);
  r.store.endTurn("t1", "completed", null, null, null);
  await pause();
  r.store.startTurnFor("t2", "ember:c-1", "input", { profile: "cc2", person: "a@x", thread: chat.id });
  r.store.endTurn("t2", "completed", null, null, null);
  await pause();
  // A job's notice goes on with the work of the turn before.
  r.store.startTurn("t3", "ember:c-1", "job");
  const starts = r.store.listTurns("ember:c-1").map((t) => t.summary.startedAt);

  const project = join(r.data, "transcripts/claude", claudeProject(workspace));
  const main = join(project, "r1.jsonl");
  append(main, [
    // From a terminal, before the station had it: not counted.
    claudeLine("m0", created - 60_000, "claude-opus-5-5", usage(1, 0, 0, 0, 1)),
    claudeLine("m1", starts[0]! + 1, "claude-opus-5-5", usage(10, 0, 0, 0, 1)),
    claudeLine("m2", starts[1]! + 1, "claude-opus-5-5", usage(20, 0, 0, 0, 2)),
  ]);
  append(join(project, "r1/subagents/agent-a.jsonl"), [claudeLine("s1", starts[1]! + 2, "claude-haiku-4-5", usage(5, 0, 0, 0, 5))]);
  assert.equal(r.usage.readingAll(), true);
  assert.equal(await r.usage.read(), 3);
  assert.equal(r.usage.readingAll(), false);

  const rows = r.store.usageGroups(0, MAX, 0).sort((a, b) => a.input - b.input);
  assert.deepEqual(rows.map((g) => [g.input, g.person, g.profile, g.thread]), [[5, "a@x", "cc2", chat.id], [10, "b@x", "cc", chat.id], [20, "a@x", "cc2", chat.id]]);

  // Read again: only what was written since, and nothing twice (the last line of a response written again too).
  append(main, [claudeLine("m2", starts[1]! + 1, "claude-opus-5-5", usage(20, 0, 0, 0, 9)), claudeLine("m3", starts[2]! + 1, "claude-opus-5-5", usage(30, 0, 0, 0, 3))]);
  assert.equal(await r.usage.read(), 1);
  const all = r.store.usageGroups(0, MAX, 0);
  const total = (f: (g: UsageGroup) => number) => all.reduce((s, g) => s + f(g), 0);
  assert.deepEqual([total((g) => g.calls), total((g) => g.input), total((g) => g.output)], [4, 65, 1 + 9 + 5 + 3]);
  const job = all.find((g) => g.input === 30)!;
  assert.deepEqual([job.person, job.thread], ["a@x", chat.id]);
  assert.equal(r.store.usageSince(), starts[0]! + 1);

  // Its session gone, what it spent stays.
  r.store.deleteSession("ember:c-1");
  assert.equal(r.store.usageGroups(0, MAX, 0).reduce((s, g) => s + g.calls, 0), 4);
});

test("days are the asker's own", async () => {
  const r = rig();
  const workspace = join(r.data, "w");
  session(r.store, "k", workspace, 0);
  // 2026-10-01T23:30Z: still the 1st in UTC, the 2nd in UTC+8.
  const at = parseIso("2026-10-01T23:30:00.000Z")!;
  append(join(r.data, "transcripts/claude", claudeProject(workspace), "r.jsonl"), [claudeLine("m", at, "claude-opus-5-5", usage(1, 0, 0, 0, 1))]);
  await r.usage.read();
  assert.equal(r.store.usageGroups(0, MAX, 0)[0]!.day, "2026-10-01");
  assert.equal(r.store.usageGroups(0, MAX, 480)[0]!.day, "2026-10-02");
  assert.deepEqual(r.store.usageGroups(at + 1, MAX, 0), []);
});

/// All of a read_from: its text and where it ends; null for nothing.
async function readAll(path: string, offset: number): Promise<[string, number] | null> {
  let text = "";
  let end: number | null = null;
  for await (const part of readFrom(path, offset)) {
    text += part.text;
    end = part.offset;
  }
  return end === null ? null : [text, end];
}

const pack = (path: string) => {
  writeFileSync(`${path}.zst`, zstdCompressSync(readFileSync(path)));
  unlinkSync(path);
};
const restore = (path: string) => {
  writeFileSync(path, zstdDecompressSync(readFileSync(`${path}.zst`)));
  unlinkSync(`${path}.zst`);
};

test("compressed history keeps usage offsets and sub-agent discovery", async () => {
  const root = tempdir();
  const main = join(root, "session.jsonl");
  const sub = join(root, "session/subagents/agent.jsonl");
  mkdirSync(dirname(sub), { recursive: true });
  writeFileSync(main, "first\nsecond\n");
  writeFileSync(sub, "child\n");
  pack(main);
  pack(sub);
  assert.deepEqual(await readAll(main, 6), ["second\n", 13]);
  assert.equal(await readAll(main, 13), null);
  const files = await claudeFiles(root, "session");
  assert.ok(files.some(([p, s]) => p === main && !s));
  assert.ok(files.some(([p, s]) => p === sub && s));
  restore(main);
  appendFileSync(main, "third\n");
  assert.deepEqual(await readAll(main, 13), ["third\n", 19]);
});

test("a file read in parts records each part's whole lines and leaves a partial last line for later", async () => {
  const root = tempdir();
  const path = join(root, "big.jsonl");
  // Lines past a part's size (1 MiB), and one unfinished.
  const line = `${"x".repeat(300_000)}\n`;
  writeFileSync(path, `${line.repeat(8)}partial`);
  const parts: number[] = [];
  for await (const p of readFrom(path, 0)) parts.push(p.offset);
  assert.ok(parts.length > 1);
  assert.equal(parts.at(-1), line.length * 8);
});

test("a turn's end is read shortly after, and the pages are told", async () => {
  const time = await today();
  const r = rig({ settleMs: 20, safetyMs: 60_000, clock: time.clock });
  const workspace = join(r.data, "w");
  session(r.store, "k", workspace, r.store.now() - 1000);
  const told: StoreChange[] = [];
  r.store.subscribe((c) => told.push(c));
  r.usage.start();
  // Everything read once, it waits (the first wait: the round's).
  await time.begun(1);
  assert.equal(r.usage.readingAll(), false);
  const calls = () => r.store.usageGroups(0, MAX, 0).reduce((s, g) => s + g.calls, 0);
  assert.equal(calls(), 0);
  r.store.startTurn("t1", "k", "input");
  append(join(r.data, "transcripts/claude", claudeProject(workspace), "r.jsonl"), [claudeLine("m", r.store.now() + 1, "claude-opus-5-5", usage(1, 0, 0, 0, 1))]);
  // Woken, it lets the burst settle; a turn starting is not its end: it waits again, nothing read (a read would come
  // before that wait).
  await time.begun(2);
  await time.adjust(20);
  await time.begun(3);
  assert.equal(calls(), 0);
  r.store.endTurn("t1", "completed", null, null, null);
  await time.begun(4);
  await time.adjust(20);
  await time.begun(5);
  assert.equal(calls(), 1);
  // Told once the read is over (the rows are there a moment before).
  assert.ok(told.some((c) => c.type === "usage"));
  await r.usage.stop();
});

// ── against the Rust's own count, on a copy of a real station ──

const WORK = process.env.USAGE_WORK ?? "/tmp/usage-work";
const SNAPSHOT = join(WORK, "transcripts");

type DayTotal = { day: string; calls: number; input: number; cacheRead: number; cacheWrite: number; cacheWriteLong: number; output: number };
const DAYS = `SELECT strftime('%Y-%m-%d', at / 1000, 'unixepoch') AS day, COUNT(*) AS calls, SUM(input) AS input, SUM(cache_read) AS cacheRead,
  SUM(cache_write) AS cacheWrite, SUM(cache_write_long) AS cacheWriteLong, SUM(output) AS output FROM usage GROUP BY day ORDER BY day`;
const ROWS = "SELECT id, at, session, turn, thread, person, profile, runtime, model, subagent, fast, input, cache_read, cache_write, cache_write_long, output FROM usage";

test("on a real station's copy, the calls counted are the Rust's", { skip: !existsSync(SNAPSHOT) && `no ${SNAPSHOT}` }, async (t) => {
  // The copy holds what the Rust recorded; its transcripts (cut where the Rust's offsets stood) are at SNAPSHOT.
  const dir = tempdir();
  copyFileSync(join(WORK, "stillfail.db"), join(dir, "stillfail.db"));
  if (existsSync(join(WORK, "stillfail.db-wal"))) copyFileSync(join(WORK, "stillfail.db-wal"), join(dir, "stillfail.db-wal"));
  symlinkSync(SNAPSHOT, join(dir, "transcripts"));
  const store = Store.open(join(dir, "stillfail.db"), join(dir, "archive"));
  stores.push(store);
  store.db.exec("DELETE FROM usage; DELETE FROM usage_files");
  const counter = new UsageCounter({ store, config: () => ({ dataDir: dir, profiles: [] }) });

  // How long the main thread is held while it reads: a 1 ms timer's lateness, and the event loop's delay.
  const delay = monitorEventLoopDelay({ resolution: 1 });
  delay.enable();
  let worst = 0;
  let previous = performance.now();
  const probe = setInterval(() => {
    const now = performance.now();
    worst = Math.max(worst, now - previous);
    previous = now;
  }, 1);
  const began = performance.now();
  const added = await counter.read();
  const took = performance.now() - began;
  clearInterval(probe);
  delay.disable();
  const again = performance.now();
  const more = await counter.read();
  const tookAgain = performance.now() - again;
  t.diagnostic(`first read: ${added} calls in ${Math.round(took)} ms; longest gap between 1 ms ticks ${worst.toFixed(1)} ms; ` +
    `loop delay p50 ${(delay.percentile(50) / 1e6).toFixed(1)} ms, p99 ${(delay.percentile(99) / 1e6).toFixed(1)} ms, max ${(delay.max / 1e6).toFixed(1)} ms`);
  t.diagnostic(`second read: ${more} new calls in ${Math.round(tookAgain)} ms`);

  const rust = new DatabaseSync(join(WORK, "stillfail.db"), { readOnly: true });
  const theirs = rust.prepare(DAYS).all() as DayTotal[];
  const ours = store.db.prepare(DAYS).all() as DayTotal[];
  const byId = (db: DatabaseSync) => new Map((db.prepare(ROWS).all() as any[]).map((r) => [r.id, r]));
  const [a, b] = [byId(rust), byId(store.db)];
  const missing = [...a.keys()].filter((id) => !b.has(id));
  const extra = [...b.keys()].filter((id) => !a.has(id));
  const fields = ["at", "session", "turn", "thread", "person", "profile", "runtime", "model", "subagent", "fast", "input", "cache_read", "cache_write", "cache_write_long", "output"];
  const differ = new Map<string, number>();
  for (const [id, r] of a) {
    const o = b.get(id);
    if (!o) continue;
    for (const f of fields) if (r[f] !== o[f]) differ.set(f, (differ.get(f) ?? 0) + 1);
  }
  t.diagnostic(`rows: Rust ${a.size}, TS ${b.size}; only the Rust's ${missing.length}, only the TS's ${extra.length}; fields differing: ${JSON.stringify(Object.fromEntries(differ))}`);
  t.diagnostic(`days: ${theirs.length}; differing: ${JSON.stringify(theirs.filter((d, i) => JSON.stringify(d) !== JSON.stringify(ours[i])).map((d) => d.day))}`);
  rust.close();
  assert.deepEqual(ours, theirs);
  assert.equal(more, 0);
});
