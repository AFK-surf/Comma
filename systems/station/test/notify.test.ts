// What the chats' people hear about (admin/notify.rs): a turn told by how it ended, a person's message to the others,
// the station's ⚠️ to everyone; gathered and handed on once.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { Notifier } from "../src/cloud/notify.ts";
import { ops } from "../src/read/ops.ts";
import { openStore } from "../src/read/store.ts";
import { turnNotice, wentWrong } from "../src/read/notices.ts";
import { Store, newMessage } from "../src/store/store.ts";

const turn = (declared: string | null, outcome: string, need?: string) => ({ kind: "message", outcome, declared, need, startedAt: 100, endedAt: 200 });
const said = (authorKind: any, author: string, createdAt: number) =>
  ({ agentIdentity: null, thread: 1, n: 3, ts: "1.1", authorKind, author, text: "修好了", attachments: [], quotes: [], declared: null, client: null, createdAt, editedAt: null }) as any;

test("a turn is told by how it ended", () => {
  const mine = said("agent", "k", 150);
  assert.deepEqual(turnNotice(turn("final", "completed"), mine, "k", "file"), ["done", "修好了"]);
  assert.deepEqual(turnNotice(turn("block", "completed"), mine, "k", "file"), ["block", "修好了"]);
  assert.deepEqual(turnNotice(turn("block", "completed", "要 Stripe 的测试 key"), mine, "k", "file"), ["block", "要 Stripe 的测试 key"]);
  const old = said("agent", "k", 50);
  assert.equal(turnNotice(turn("final", "completed"), old, "k", "file"), null);
  assert.equal(turnNotice(turn(null, "failed"), old, "k", "file"), null);
  assert.equal(wentWrong("⚠️ 无法启动 agent：没有 claude"), "无法启动 agent：没有 claude");
  assert.equal(wentWrong("已停止当前任务"), null);
  assert.equal(turnNotice(turn("final", "completed"), said("person", "a@b.c", 150), "k", "file"), null);
  assert.equal(turnNotice(turn(null, "completed"), mine, "k", "file"), null);
  assert.equal(turnNotice(turn("waiting", "completed"), mine, "k", "file"), null);
});

test("a chat's people hear of its turns and of each other, once, gathered", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "notify-"));
  const store = Store.open(join(dir, "stillfail.db"), join(dir, "archive"));
  const reader = openStore(dir);
  // What the notifier asks of the readers, followed: the notices it gathers are all made once none is left.
  let asking = 0;
  const readers: any = {
    read: async (op: string, a: any) => {
      asking++;
      try {
        return JSON.stringify(ops[op]!(reader, a));
      } finally {
        asking--;
      }
    },
  };
  const cloud: any = { state: { origin: "http://x", station: "s" }, removed: () => false };
  // Its gathering second, on a clock of the test's.
  const scope = Effect.runSync(Scope.make());
  t.after(() => Effect.runPromise(Scope.close(scope, Exit.void)));
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const notifier = new Notifier(store, readers, cloud, null as any, { clock });
  const posted: any[][] = [];
  notifier.post = async (n) => void posted.push(n);
  store.insertSession({ key: "k", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: "t", createdAt: 1, lastActiveAt: 1, createdBy: "ada@x.com" } as any);
  const chat = store.openThread("ember", "EMBER", "1.1", null, "ada@x.com");
  store.joinThread(chat.id, "k", "ember");
  store.insertMessage(newMessage(chat.id, "1.2", "person", "bob@x.com", "看一下"));
  store.startTurn("t1", "k", "input");
  store.insertMessage({ ...newMessage(chat.id, "1.3", "agent", "k", "好了"), declared: "final" });
  store.endTurn("t1", "completed", null, "final", null);
  store.insertMessage(newMessage(chat.id, "1.4", "ember", "ember", "⚠️ 没能启动"));
  const settle = () => new Promise((r) => setImmediate(r));
  for (let i = 0; i < 5 || asking > 0; i++) await settle();
  assert.equal(posted.length, 0, "nothing before the second is up");
  // The second goes by (again, should its wait have begun only after the clock moved).
  for (let i = 0; i < 100 && posted.length === 0; i++) {
    await Effect.runPromise(clock.adjust("1 second"));
    for (let j = 0; j < 5; j++) await settle();
  }
  const all = posted.flat().map((n) => [n.kind, n.to.join(","), n.text]);
  assert.equal(posted.length, 1, "gathered into one post");
  assert.deepEqual(all.sort(), [
    ["done", "ada@x.com,bob@x.com", "好了"],
    ["failed", "ada@x.com,bob@x.com", "没能启动"],
    ["message", "ada@x.com", "看一下"],
  ]);
  notifier.close();
});
