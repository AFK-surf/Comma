// What the pages ask of the hub, the jobs and the files, as admin/mod.rs and admin/files.rs answer it (routes/hub.ts):
// new chats, uploads, messages, archiving, deleting, stopping, a session's settings, jobs. A real store in a temporary
// data directory, the real readers over it, a hub with runtimes scripted in-process (test/hub-fakes.ts).
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { test } from "node:test";
import { Admin } from "../src/api/admin.ts";
import type { Request } from "../src/api/request.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { tr } from "../src/ops/i18n.ts";
import { Readers } from "../src/read/pool.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { Store, newMessage } from "../src/store/store.ts";
import { FakeDriver, settle } from "./hub-fakes.ts";

const viewer = { sub: "u", email: "a@x", name: "A", role: "member", workspace: "w", device: "d" };
const en = (key: string, args: Record<string, unknown> = {}) => tr("en", key, args);

/// Looks every 25 ms until `f` holds (no deadline: it comes, however slow the machine, or the test hangs).
async function until(_what: string, f: () => boolean) {
  while (!f()) await new Promise((r) => setTimeout(r, 25));
}

function rig(withAgents = true) {
  const data = mkdtempSync(join(tmpdir(), "hr-"));
  const raw = { profiles: [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["opus"] }, { id: "cx", runtime: "codex", home: "homes/cx" }] };
  const config = hubConfig(raw, data);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const claude = new FakeDriver("claude");
  const codex = new FakeDriver("codex");
  const hub = new Hub({
    config: () => config,
    store,
    chats: () => undefined,
    drivers: [claude, codex],
    mcpUrl: "http://127.0.0.1:1/mcp",
    internal: new InternalChat(),
    runners: () => [],
  });
  const jobs = new Jobs({ store, data, notify: () => {}, link: () => null });
  hub.setJobs(jobs);
  const readers = new Readers(data, 1);
  readers.processes = () => hub.processes();
  const admin = new Admin(readers, { store, agents: withAgents ? ({ hub, jobs } as any) : undefined });
  const ask = async (method: string, path: string, body?: unknown, query: [string, string][] = []) => {
    const raw = Buffer.isBuffer(body) ? body : Buffer.from(body === undefined ? "" : typeof body === "string" ? body : JSON.stringify(body));
    const r: Request = { method, path, query, headers: {}, body: raw, viewer, lang: "en" };
    const a = await admin.handle(r);
    return [a.status, JSON.parse(String(a.body))] as const;
  };
  const close = async () => {
    await hub.shutdown();
    await jobs.shutdown();
    readers.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  };
  return { data, store, hub, jobs, claude, codex, ask, close };
}

test("a new chat: its session and its thread, refused without a runtime or with an unknown profile", async () => {
  const r = rig();
  try {
    assert.deepEqual(await r.ask("POST", "/sessions", { runtime: "gemini" }), [400, { error: en("station.admin.badRuntime") }]);
    assert.deepEqual(await r.ask("POST", "/sessions", "{"), [400, { error: "invalid JSON" }]);
    assert.deepEqual(await r.ask("POST", "/sessions", { runtime: "claude", profile: "nope" }), [400, { error: "no claude profile nope" }]);
    const [status, made] = await r.ask("POST", "/sessions", { runtime: "codex", title: "plans", fast: true, clientKey: "k1", profile: "" });
    assert.equal(status, 200);
    assert.deepEqual(Object.keys(made), ["key", "thread"]);
    const row = r.store.getSession(made.key)!;
    assert.deepEqual([row.runtime, row.profile, row.title, row.createdBy, row.fast], ["codex", "cx", "plans", "a@x", true]);
    assert.equal(made.thread.home, made.key);
    assert.equal(made.thread.title, "plans");
    assert.deepEqual(made.thread.sessions.map((m: any) => m.session), [made.key]);
    assert.equal(r.hub.clientKey(made.key), "k1");
  } finally {
    await r.close();
  }
});

test("another chat with a session, and a session brought into a chat", async () => {
  const r = rig();
  try {
    const [, a] = await r.ask("POST", "/sessions", { runtime: "claude" });
    const [, b] = await r.ask("POST", "/sessions", { runtime: "claude" });
    assert.deepEqual(await r.ask("POST", "/threads", { session: "nope" }), [404, { error: "unknown session nope" }]);
    const [status, chat] = await r.ask("POST", "/threads", { session: a.key, title: "  side  " });
    assert.equal(status, 200);
    assert.equal(chat.title, "side");
    assert.equal(chat.home, undefined, "a chat of its own");
    assert.deepEqual(await r.ask("POST", `/threads/${chat.id}/sessions`, { session: "nope" }), [404, { error: "unknown session nope" }]);
    assert.deepEqual(await r.ask("POST", "/threads/999/sessions", { session: b.key }), [404, { error: "unknown thread 999" }]);
    const [joined, view] = await r.ask("POST", `/threads/${chat.id}/sessions`, { session: b.key });
    assert.equal(joined, 200);
    assert.deepEqual(view.sessions.map((m: any) => m.session), [a.key, b.key]);
    const slack = r.store.openThread("slack:T1", "C1", "1.1", null, null);
    assert.deepEqual(await r.ask("POST", `/threads/${slack.id}/sessions`, { session: b.key }), [400, { error: `no still.fail chat ${slack.id}` }]);
  } finally {
    await r.close();
  }
});

test("uploads wait in the station's uploads, a message takes them into its chat and its agent hears it", async () => {
  const r = rig();
  try {
    const staged = join(r.data, "uploads");
    mkdirSync(staged, { recursive: true });
    writeFileSync(join(staged, "old"), "x");
    utimesSync(join(staged, "old"), new Date(Date.now() - 25 * 3600_000), new Date(Date.now() - 25 * 3600_000));
    const [status, up] = await r.ask("POST", "/uploads", Buffer.from("png"), [["name", "dir/..\\.a\u0001.png"]]);
    assert.equal(status, 200);
    assert.deepEqual(Object.keys(up), ["name", "path", "size"]);
    assert.equal(up.name, "a_.png");
    assert.equal(up.size, 3);
    assert.match(up.path, /[\\/]uploads[\\/]\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-[0-9a-f]{6}-a_\.png$/);
    assert.ok(!existsSync(join(staged, "old")), "a day-old upload is swept");
    const [, unnamed] = await r.ask("POST", "/uploads", Buffer.from(""));
    assert.match(unnamed.name, /^file$/);

    const [, made] = await r.ask("POST", "/sessions", { runtime: "claude" });
    const id = made.thread.id;
    const workspace = r.store.getSession(made.key)!.workspace;
    assert.deepEqual(await r.ask("POST", `/threads/${id}/messages`, { text: "  " }), [400, { error: en("station.admin.emptyMessage") }]);
    assert.deepEqual(await r.ask("POST", `/threads/${id}/messages`, { attachments: [{ path: "/etc/passwd" }] }), [400, { error: en("station.files.notUploaded") }]);
    const send = {
      text: " look ",
      attachments: [{ path: up.path, name: "a_.png", width: 10, height: 20, size: 3 }],
      quotes: [{ text: "earlier", ts: "1.2", role: "agent", file: "a_.png" }, { text: "  " }],
      client: " web\u0007 1.0 ",
    };
    const [sent, said] = await r.ask("POST", `/threads/${id}/messages`, send);
    assert.equal(sent, 200);
    const moved = join(workspace, "uploads", basename(up.path));
    assert.ok(existsSync(moved) && !existsSync(up.path), "moved into the session's uploads");
    assert.equal(readFileSync(moved, "utf8"), "png");
    const message = r.store.messagesBefore(id, null, 10).find((m) => m.n === said.n)!;
    assert.equal(message.text, "look");
    assert.deepEqual(message.attachments, [{ name: "a_.png", path: moved, size: 3, width: 10, height: 20 }]);
    assert.deepEqual(message.quotes, [{ author: "消息", text: "earlier", comment: "", ts: "1.2", role: "agent", file: "a_.png" }]);
    assert.equal(message.client, "web 1.0");
    await settle();
    await until("its turn starts", () => r.claude.count() === 1 && r.claude.last().prompts.length === 1);
    assert.match(r.claude.last().prompts[0]!, /look/);
    // Sent again (a retry): the file has moved already, and is found where it went.
    const [again] = await r.ask("POST", `/threads/${id}/messages`, send);
    assert.equal(again, 200);
    // Named by its place in the uploads when the page gives no name.
    const [, named] = await r.ask("POST", `/threads/${id}/messages`, { attachments: [{ path: moved, width: 5 }] });
    assert.deepEqual(r.store.messagesBefore(id, null, 10).find((m) => m.n === named.n)!.attachments, [{ name: basename(moved), path: moved, size: 0 }]);

    const slack = r.store.openThread("slack:T1", "C1", "1.1", null, null);
    assert.deepEqual(await r.ask("POST", `/threads/${slack.id}/messages`, { text: "hi" }), [400, { error: en("station.admin.postOnlyStillfail") }]);
    assert.deepEqual(await r.ask("POST", "/threads/x/messages", { text: "hi" }), [404, { error: "unknown thread x" }]);
    assert.equal((await r.ask("POST", "/uploads", Buffer.alloc(50 * 1024 * 1024 + 1)))[0], 413);
  } finally {
    await r.close();
  }
});

test("a file in parts: each added where the file ends, asked again or out of place it adds nothing, whole it is an upload", async () => {
  const r = rig();
  try {
    const part = (offset: number, body: string, size = 10, id = "abcdefgh12") =>
      r.ask("POST", "/uploads/parts", Buffer.from(body), [["id", id], ["name", "big.bin"], ["size", String(size)], ["offset", String(offset)]]);
    assert.deepEqual(await part(0, "0123"), [200, { have: 4 }]);
    // Its answer lost, asked again: nothing added.
    assert.deepEqual(await part(0, "0123"), [200, { have: 4 }]);
    // Ahead of the file's end: nothing added, the caller goes on from where it is.
    assert.deepEqual(await part(8, "89"), [200, { have: 4 }]);
    // Overlapping the end: only the rest of it added.
    assert.deepEqual(await part(2, "234567"), [200, { have: 8 }]);
    const staged = join(r.data, "uploads");
    assert.equal(readFileSync(join(staged, ".part-abcdefgh12"), "utf8"), "01234567");
    const [status, done] = await part(8, "89");
    assert.equal(status, 200);
    assert.equal(done.have, 10);
    assert.deepEqual([done.file.name, done.file.size], ["big.bin", 10]);
    assert.match(done.file.path, /[\\/]uploads[\\/]\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-[0-9a-f]{6}-big\.bin$/);
    assert.equal(readFileSync(done.file.path, "utf8"), "0123456789");
    assert.ok(!existsSync(join(staged, ".part-abcdefgh12")));
    // The last part asked again after it was put together: the same file.
    assert.deepEqual(await part(8, "89"), [200, done]);
    // A part file is never sent with a message.
    await part(0, "01", 10, "otherid123");
    const [, made] = await r.ask("POST", "/sessions", { runtime: "claude" });
    assert.deepEqual(await r.ask("POST", `/threads/${made.thread.id}/messages`, { attachments: [{ path: join(staged, ".part-otherid123") }] }), [400, { error: en("station.files.notUploaded") }]);
    // Bounds: the whole file, a part, the id.
    assert.deepEqual(await part(0, "x", 1024 * 1024 * 1024 + 1, "toolarge12"), [413, { error: en("station.files.tooLargeParts") }]);
    assert.equal((await part(0, "x", 10, "../../etc"))[0], 400);
    assert.equal((await part(0, "x".repeat(11), 10, "pastsize12"))[0], 413);
    assert.equal((await r.ask("POST", "/uploads/parts", Buffer.from("x"), [["id", "noquery123"]]))[0], 400);
  } finally {
    await r.close();
  }
});

test("a pending card: an option chosen by an old client is refused; an answer quoting it marks it read", async () => {
  const r = rig();
  try {
    const [, made] = await r.ask("POST", "/sessions", { runtime: "claude" });
    const id = made.thread.id;
    const [n] = r.store.insertMessage({
      ...newMessage(id, "1700000000.000100", "agent", made.key, "deploy?"),
      card: { type: "options", options: [{ label: "no", action: "close" }, { label: "yes", action: "reply" }] },
    });
    r.store.insertMessage(newMessage(id, "1700000000.000200", "agent", made.key, "later"));
    const quote = [{ text: "deploy?", ts: "1700000000.000100" }];
    assert.deepEqual(await r.ask("POST", `/threads/${id}/messages`, { text: "no", quotes: quote }), [409, { error: en("station.admin.updateClientForOption") }]);
    const [status] = await r.ask("POST", `/threads/${id}/messages`, { text: "yes", quotes: quote });
    assert.equal(status, 200);
    assert.equal(r.store.readPosition("a@x", id), n, "read up to the card, not past it");
  } finally {
    await r.close();
  }
});

test("archiving a session and a chat, and deleting a session", async () => {
  const r = rig();
  try {
    const [, made] = await r.ask("POST", "/sessions", { runtime: "claude" });
    const [status, summary] = await r.ask("POST", `/sessions/${made.key}/archive`);
    assert.equal(status, 200);
    assert.equal(summary.key, made.key);
    assert.equal(typeof summary.archivedAt, "number");
    assert.equal((await r.ask("DELETE", `/sessions/${made.key}/archive`))[1].archivedAt, null);
    assert.deepEqual(await r.ask("POST", "/sessions/nope/archive"), [404, { error: "unknown session nope" }]);

    const [, own] = await r.ask("POST", "/threads", { session: made.key });
    const [hidden, view] = await r.ask("POST", `/threads/${own.id}/archive`);
    assert.equal(hidden, 200);
    assert.equal(typeof view.hiddenAt, "number");
    assert.equal(r.store.getSession(made.key)!.archivedAt, null, "a chat of its own goes alone");
    assert.equal((await r.ask("DELETE", `/threads/${own.id}/archive`))[1].hiddenAt, undefined);
    const [, home] = await r.ask("POST", `/threads/${made.thread.id}/archive`);
    assert.equal(home.id, made.thread.id);
    assert.notEqual(r.store.getSession(made.key)!.archivedAt, null, "a session's own chat goes with it");
    const slack = r.store.openThread("slack:T1", "C1", "1.1", null, null);
    assert.deepEqual(await r.ask("POST", `/threads/${slack.id}/archive`), [400, { error: `no still.fail chat ${slack.id}` }]);

    const workspace = r.store.getSession(made.key)!.workspace;
    assert.deepEqual(await r.ask("DELETE", `/sessions/${encodeURIComponent(made.key)}`), [200, { ok: true }]);
    assert.equal(r.store.getSession(made.key), null);
    assert.ok(!existsSync(workspace));
    assert.deepEqual(await r.ask("DELETE", "/sessions/nope"), [404, { error: "unknown session nope" }]);
  } finally {
    await r.close();
  }
});

test("stopping, evicting, warming and changing a session", async () => {
  const r = rig();
  try {
    const [, made] = await r.ask("POST", "/sessions", { runtime: "claude" });
    assert.deepEqual(await r.ask("POST", "/sessions/nope/stop"), [500, { error: "unknown session nope" }]);
    assert.deepEqual(await r.ask("POST", "/sessions/nope/evict"), [200, { ok: true }]);
    assert.deepEqual(await r.ask("POST", "/sessions/nope/warm"), [404, { error: "unknown session nope" }]);
    assert.deepEqual(await r.ask("POST", `/sessions/${made.key}/warm`), [202, { ok: true }]);
    await until("it warms", () => r.claude.count() === 1);
    assert.deepEqual(await r.ask("POST", `/sessions/${made.key}/evict`), [200, { ok: true }]);
    await until("it is evicted", () => r.claude.last().disposed);
    assert.deepEqual(await r.ask("POST", `/sessions/${made.key}/stop`), [200, { ok: true }]);

    assert.deepEqual(await r.ask("POST", `/sessions/${made.key}/settings`, { fast: "yes" }), [400, { error: en("station.admin.badFast") }]);
    assert.equal((await r.ask("POST", "/sessions/nope/settings", { model: "opus" }))[0], 400);
    assert.deepEqual(await r.ask("POST", `/sessions/${made.key}/settings`, { model: "opus", profile: "cc" }), [200, { ok: true }]);
    const row = r.store.getSession(made.key)!;
    assert.deepEqual([row.model, row.profile, row.profilePinned], ["opus", "cc", true]);
    assert.deepEqual(await r.ask("POST", `/sessions/${made.key}/settings`, { profile: null }), [200, { ok: true }]);
    assert.equal(r.store.getSession(made.key)!.profilePinned, false);
  } finally {
    await r.close();
  }
});

test("a chat's ended jobs cleared, a job stopped from the pages", async () => {
  const r = rig();
  try {
    const [, made] = await r.ask("POST", "/sessions", { runtime: "claude" });
    const work = r.store.getSession(made.key)!.workspace;
    const done = r.jobs.start(made.key, "done", "true", work, null, false);
    // Never ends by itself: still running when it is stopped, however slow the machine.
    const live = r.jobs.start(made.key, "watch", "tail -f /dev/null", work, null, false);
    await until("it ends", () => r.store.getJob(done.id)!.state === "exited");
    assert.deepEqual(await r.ask("DELETE", "/sessions/nope/jobs"), [404, { error: "unknown session nope" }]);
    assert.deepEqual(await r.ask("DELETE", `/sessions/${made.key}/jobs`), [200, { removed: [done.id] }]);
    const [status, stopped] = await r.ask("POST", `/jobs/${live.id}/stop`);
    assert.equal(status, 200);
    assert.deepEqual([stopped.id, stopped.state, stopped.session], [live.id, "stopped", made.key]);
    assert.ok(Array.isArray(stopped.notices) && "outputAt" in stopped);
    assert.deepEqual(await r.ask("POST", "/jobs/nope/stop"), [500, { error: "no job nope" }]);
  } finally {
    await r.close();
  }
});

test("going on with one of the machine's own sessions", async () => {
  const r = rig();
  const home = process.env.HOME;
  try {
    process.env.HOME = join(r.data, "home");
    const project = join(r.data, "project");
    const dir = join(r.data, "home", ".claude", "projects", "-project");
    mkdirSync(project, { recursive: true });
    mkdirSync(dir, { recursive: true });
    const id = "11111111-aaaa-bbbb-cccc-000000000001";
    const records = [
      { type: "user", cwd: project, timestamp: "2026-09-01T00:00:02.000Z", message: { content: "fix the build" } },
      { type: "assistant", cwd: project, timestamp: "2026-09-01T00:00:06.000Z", message: { model: "claude-opus-5-5", content: [{ type: "text", text: "Fixed." }] } },
    ];
    writeFileSync(join(dir, `${id}.jsonl`), records.map((x) => JSON.stringify(x)).join("\n") + "\n");
    assert.deepEqual(await r.ask("POST", "/machine-sessions", { runtime: "x", id }), [400, { error: en("station.admin.badRuntime") }]);
    assert.deepEqual(await r.ask("POST", "/machine-sessions", { runtime: "claude", id: "nope" }), [404, { error: en("station.admin.noLocalSession", { id: "nope" }) }]);
    const [status, made] = await r.ask("POST", "/machine-sessions", { runtime: "claude", id });
    assert.equal(status, 200);
    assert.deepEqual(Object.keys(made), ["key", "thread"]);
    const row = r.store.getSession(made.key)!;
    assert.deepEqual([row.runtimeSessionId, row.cwd, row.title], [id, project, "fix the build"]);
    // Asked again: the session already going on with it.
    assert.equal((await r.ask("POST", "/machine-sessions", { runtime: "claude", id }))[1].key, made.key);
  } finally {
    process.env.HOME = home;
    await r.close();
  }
});

test("without the agents' side: the hub's routes answer that the station is starting", async () => {
  const r = rig(false);
  try {
    assert.deepEqual(await r.ask("POST", "/sessions", { runtime: "claude" }), [503, { error: "station starting" }]);
    assert.deepEqual(await r.ask("POST", "/jobs/x/stop"), [503, { error: "station starting" }]);
  } finally {
    await r.close();
  }
});
