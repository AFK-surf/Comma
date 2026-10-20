// Ported from systems/connector/salix-connect/request_operations_test.go (same test names).
// A request id is a stable operation across connection replacements: a running one replies on the replacement, a
// completed one replays its reply (sensitive ones excepted), a reused id with other params is refused, and a reply
// releases its admission slot before the caller sees it. A FIFO holds a read open until the test writes to it.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { Effect } from "effect";
import { type Message, makeConnector, recoverableRequest, requestFingerprint } from "../../src/connector/connector.ts";
import { eventually } from "./support/eventually.ts";
import { tempDir } from "./support/temp.ts";

const sink = () => {
  const replies: Message[] = [];
  return { replies, send: (m: Message) => Effect.sync(() => void replies.push(m)) };
};

test("TestRequestOperationRebindsRunningReplyToReplacement", { skip: process.platform === "win32" && "needs a FIFO" }, async () => {
  const root = tempDir();
  const fifo = join(root, "blocked-read.fifo");
  execFileSync("mkfifo", ["-m", "600", fifo]);
  const c = makeConnector({ name: "test", root });
  const oldSink = sink();
  const old = c.claimConnection(oldSink.send);
  const request: Message = { id: "stable-operation", type: "request", method: "read", params: { path: "blocked-read.fifo" } };
  assert.ok(old.startRequest(request), "old connection did not admit the request");
  await eventually(() => c.requestSlotsInUse() === 1, "running operation");
  const newSink = sink();
  const replacement = c.claimConnection(newSink.send);
  assert.ok(replacement.startRequest(request), "replacement did not rebind the stable operation");
  assert.equal(c.requestSlotsInUse(), 1, "duplicate operation consumed another execution slot");
  writeFileSync(fifo, "rebound");
  await eventually(() => newSink.replies.length === 1, "replacement reply");
  assert.equal(newSink.replies[0].id, request.id);
  assert.equal(newSink.replies[0].type, "response");
  assert.equal(oldSink.replies.length, 0, "the old reply sink received the result after the rebind");
  replacement.close("canceled");
});

test("TestRequestOperationReplaysCompletedResultAndRejectsIDConflict", async () => {
  const c = makeConnector({ name: "test", root: tempDir() });
  let executions = 0;
  const old = c.claimConnection(() => Effect.fail(new Error("reply lost with old transport")));
  const request: Message = { id: "completed-operation", type: "request", method: "process_list" };
  assert.ok(old.startRequest(request, () => executions++));
  await eventually(() => executions === 1 && c.requestSlotsInUse() === 0, "completed operation");
  const replies = sink();
  const replacement = c.claimConnection(replies.send);
  assert.ok(replacement.startRequest(request, () => (executions += 100)), "replacement did not replay the completed operation");
  await eventually(() => replies.replies.length === 1, "replayed reply");
  assert.equal(replies.replies[0].type, "response");
  const conflict: Message = { id: request.id, type: "request", method: "stat", params: { path: "." } };
  assert.ok(replacement.startRequest(conflict, () => (executions += 1000)), "an id conflict did not produce a bounded error reply");
  await eventually(() => replies.replies.length === 2, "conflict reply");
  assert.equal(replies.replies[1].type, "error");
  assert.equal(replies.replies[1].error, "request id reused with different method or params");
  assert.equal(executions, 1, "the stable operation ran more than once");
  replacement.close("canceled");
});

test("TestReplyReleasesRequestAdmissionBeforeCallerStartsNextRequest", async () => {
  const c = makeConnector({ name: "test", root: tempDir(), maxConcurrentRequests: 1 });
  const second: Message = { id: "second", type: "request", method: "process_list" };
  let secondAdmitted: boolean | undefined;
  const replies: Message[] = [];
  const session = c.claimConnection((reply) =>
    Effect.sync(() => {
      if (reply.id === "first") secondAdmitted = session.startRequest(second);
      replies.push(reply);
    }),
  );
  assert.ok(session.startRequest({ id: "first", type: "request", method: "process_list" }));
  await eventually(() => secondAdmitted !== undefined, "first reply");
  assert.equal(secondAdmitted, true, "the reply became visible before its admission was released");
  await eventually(() => replies.length === 2, "both replies");
  assert.deepEqual(new Set(replies.map((r) => r.id)), new Set(["first", "second"]));
  assert.ok(replies.every((r) => r.type === "response"));
  await eventually(() => c.requestSlotsInUse() === 0, "admission drain");
  session.close("canceled");
});

test("TestRuntimeAuthLoginStartRebindsRunningButDoesNotReplayCompletedCeremony", async () => {
  const c = makeConnector({ name: "test", root: tempDir() });
  const oldSink = sink();
  const old = c.claimConnection(oldSink.send);
  const request: Message = {
    id: "runtime-auth-start",
    type: "request",
    method: "runtime_auth_login_start",
    params: { provider: "codex", identity_material: "/usr/bin/codex", flow: "device_code" },
  };
  const fingerprint = requestFingerprint(request);
  assert.equal(c.bindRequestOperation(old, request, fingerprint), "execute");
  const newSink = sink();
  const replacement = c.claimConnection(newSink.send);
  assert.equal(c.bindRequestOperation(replacement, request, fingerprint), "rebound", "an in-flight replacement was not rebound");
  c.completeRequestOperation(request.id!, request.method!, {
    id: request.id,
    type: "response",
    result: { attempt_id: "attempt-secret", verification_url: "https://auth.openai.com/codex/device", user_code: "SECRET-CODE" },
  });
  await eventually(() => newSink.replies.length === 1, "rebound ceremony");
  assert.equal((newSink.replies[0].result as Record<string, unknown>).user_code, "SECRET-CODE");
  assert.equal(oldSink.replies.length, 0, "the old reply sink received the rebound ceremony");
  const completed = c.requestOperationForTest(request.id!);
  assert.ok(completed && completed.done && !completed.replayCompleted && completed.reply === null && completed.replyBytes === 0, "a completed sensitive operation retained its ceremony");
  assert.equal(c.bindRequestOperation(replacement, request, fingerprint), "execute", "a completed sensitive retry was not a fresh execution");
  replacement.close("canceled");
  await Effect.runPromise(c.close());
});

test("TestConnectionLocalRequestsAreNeverReplayCached", () => {
  for (const method of ["read_stream", "write_stream", "meeting_artifact_read"]) {
    assert.ok(!recoverableRequest({ id: "stable", method }), `${method} must not rebind or replay across connector sessions`);
  }
  assert.ok(recoverableRequest({ id: "stable", method: "stat" }), "ordinary bounded requests should remain recoverable");
});
