// What a viewer marks, as admin/mod.rs answers it: read positions, names, pins, keeping, dismissing, closing a card,
// widget states, a Task's status.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Admin } from "../src/api/admin.ts";
import type { Request } from "../src/api/request.ts";
import { Store, newMessage } from "../src/store/store.ts";

const viewer = { sub: "u", email: "a@x", name: "A", role: "member", workspace: "w", device: "d" };
const readers: any = { names: new Map(), read: async (op: string, a: any) => JSON.stringify({ op, id: a.id }) };

function rig(role = "member") {
  const store = Store.open(":memory:", null);
  store.insertSession({ key: "s1", connect: "ds", runtime: "claude", profile: "cc", workspace: "/w/s1", token: "t", createdAt: 1, lastActiveAt: 1 });
  const chat = store.openThread("ember", "EMBER", "1.1", null, "a@x");
  const slack = store.openThread("slack", "C1", "2.2", null, null);
  store.insertMessage(newMessage(chat.id, "1.2", "person", "a@x", "hi"));
  store.insertMessage(newMessage(chat.id, "1.3", "agent", "s1", "which one?"));
  const admin = new Admin(readers, { store });
  const ask = async (method: string, path: string, body?: unknown) => {
    const r: Request = { method, path, query: [], headers: {}, body: Buffer.from(body === undefined ? "" : typeof body === "string" ? body : JSON.stringify(body)), viewer: { ...viewer, role }, lang: "en" };
    const a = await admin.handle(r);
    return [a.status, JSON.parse(String(a.body))] as const;
  };
  return { store, chat, slack, ask };
}

test("read positions, names, keeping and dismissing", async () => {
  const { store, chat, slack, ask } = rig();
  assert.deepEqual(await ask("PUT", `/threads/${chat.id}/read`, { n: 1 }), [200, { viewer: "a@x", thread: chat.id, n: 1 }]);
  assert.deepEqual(await ask("PUT", `/threads/${chat.id}/read`, { n: 0 }), [200, { viewer: "a@x", thread: chat.id, n: 1 }]);
  assert.equal((await ask("PUT", `/threads/${chat.id}/read`, { n: 1.5 }))[0], 400);
  assert.equal((await ask("PUT", `/threads/${chat.id}/read`, "{")).join(), [400, { error: "invalid JSON" }].join());
  assert.deepEqual(await ask("PUT", `/threads/999/read`, { n: 1 }), [404, { error: "unknown thread 999" }]);
  assert.deepEqual(await ask("PUT", `/threads/${chat.id}/title`, { title: "  named  " }), [200, { op: "thread", id: String(chat.id) }]);
  assert.equal(store.getThread(chat.id)!.title, "named");
  assert.equal((await ask("PUT", `/threads/${slack.id}/title`, { title: "x" }))[0], 400);
  assert.deepEqual(await ask("PUT", `/threads/${chat.id}/keep`), [200, { kept: true }]);
  assert.equal((await ask("PUT", `/threads/${chat.id}/dismissed`, { n: 1 }))[0], 404);
  assert.deepEqual(await ask("PUT", `/threads/${chat.id}/dismissed`, { n: 2 }), [200, { dismissed: { thread: chat.id, n: 2 } }]);
  const [n] = store.insertMessage({ ...newMessage(chat.id, "1.4", "agent", "s1", "deploy?"), card: { type: "options", options: [{ label: "no", action: "close" }] } });
  assert.equal((await ask("PUT", `/threads/${chat.id}/closed-card`, { n }))[0], 400);
  assert.deepEqual(await ask("PUT", `/threads/${chat.id}/closed-card`, { n, option: " no " }), [200, { closedCard: { thread: chat.id, n } }]);
  assert.equal(store.readPosition("a@x", chat.id), n);
});

test("sessions' names, pins and widget states", async () => {
  const { store, ask } = rig();
  assert.deepEqual(await ask("POST", "/sessions/s1/title", { title: "x".repeat(100) }), [200, { ok: true }]);
  assert.equal(store.getSession("s1")!.title, "x".repeat(80));
  assert.deepEqual(await ask("POST", "/sessions/nope/title", {}), [404, { error: "unknown session nope" }]);
  assert.deepEqual(await ask("PUT", "/sessions/s1/pin"), [200, { session: "s1", pinned: true }]);
  assert.deepEqual(await ask("DELETE", "/sessions/s1/pin"), [200, { session: "s1", pinned: false }]);
  assert.deepEqual(await ask("PUT", "/sessions/s1/widget-state", { state: {} }), [400, { error: "path is required" }]);
  assert.deepEqual(await ask("PUT", "/sessions/s1/widget-state", { path: "w.html", state: { modelContent: { a: 1 } } }), [200, { ok: true }]);
  assert.equal(store.widgetState("s1", "w.html"), '{"modelContent":{"a":1}}');
  assert.equal((await ask("PUT", "/sessions/s1/widget-state", { path: "w.html", state: "x".repeat(17000) }))[0], 400);
});

test("a Task marked done or cancelled, and left to its chat again; not by a read-only member, nor on another thread", async () => {
  const { store, chat, slack, ask } = rig();
  assert.deepEqual(await ask("PUT", `/threads/${chat.id}/status`, { status: "done" }), [200, { thread: chat.id, status: "done" }]);
  assert.deepEqual(await ask("PUT", `/threads/${chat.id}/status`, { status: "cancelled" }), [200, { thread: chat.id, status: "cancelled" }]);
  assert.deepEqual(await ask("PUT", `/threads/${chat.id}/status`, { status: "in_progress" }), [200, { thread: chat.id, status: "in_progress" }]);
  for (const status of ["needs_review", "archived", "toString", 1, undefined]) {
    assert.deepEqual(await ask("PUT", `/threads/${chat.id}/status`, { status }), [400, { error: "status must be done, cancelled or in_progress" }]);
  }
  assert.deepEqual(await ask("PUT", `/threads/${slack.id}/status`, { status: "done" }), [400, { error: "Only still.fail's own chats have a Task status" }]);
  assert.deepEqual(await ask("PUT", "/threads/999/status", { status: "done" }), [404, { error: "unknown thread 999" }]);
  const viewer = rig("viewer");
  assert.deepEqual(await viewer.ask("PUT", `/threads/${viewer.chat.id}/status`, { status: "done" }), [403, { error: "read-only members cannot change this station" }]);
  assert.equal(viewer.store.taskStatus(viewer.chat.id), "in_progress");
  assert.equal(store.taskStatus(chat.id), "in_progress");
});
