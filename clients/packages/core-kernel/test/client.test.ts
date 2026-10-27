import { test } from "vitest";
import assert from "node:assert/strict";
import { CoreClient, type CoreFailure, type Opener } from "../src/client/client.ts";

/** A channel the test speaks for the core on: what the client sends, and a way to answer it or fail it. */
function channel() {
  const sent: unknown[] = [];
  let deliver: ((data: unknown) => void) | undefined;
  let fail: ((reason: string, failure?: CoreFailure) => void) | undefined;
  let opened = 0;
  const open: Opener = (onMessage, onFail) => {
    opened++;
    deliver = onMessage;
    fail = onFail;
    return {
      post: (message: unknown) => void sent.push(message),
      close: () => undefined,
    };
  };
  return {
    open,
    sent,
    deliver: (data: unknown) => deliver?.(data),
    fail: (reason: string, failure?: CoreFailure) => fail?.(reason, failure),
    opened: () => opened,
  };
}

test("a UI hears why the channel to its core failed", () => {
  const c = channel();
  const pending: (() => void)[] = [];
  const faults: Error[] = [];
  const client = new CoreClient(c.open, {
    schedule: (_ms, run) => void pending.push(run),
    onFault: (error) => void faults.push(error),
  });

  c.fail("The core's worker did not load.", "worker_load");
  pending.splice(0).forEach((run) => run());
  c.deliver({ fatal: "the store is corrupt" });
  pending.splice(0).forEach((run) => run());
  c.fail("gone");

  assert.deepEqual(
    faults.map((fault) => [fault.name, (fault as { failure?: unknown }).failure]),
    [
      ["CoreFailed", "worker_load"],
      ["CoreFailed", "core_fatal"],
      ["CoreFailed", "channel"],
    ]
  );
  client.close();
});

test("a UI hears when the core forgot it: another tab runs it now, or it started again", () => {
  const c = channel();
  const pending: (() => void)[] = [];
  const client = new CoreClient(c.open, {
    schedule: (_ms, run) => void pending.push(run),
    onFault: () => undefined,
  });
  let rejoined = 0;
  client.onRejoin(() => rejoined++);
  client.subscribe(
    { topic: "rows" },
    () => undefined,
    () => undefined
  );
  assert.equal(rejoined, 0, "the first channel is no rejoin");

  c.deliver({ rejoin: true });
  assert.equal(rejoined, 1);

  c.fail("the core's process ended");
  pending.splice(0).forEach((run) => run());
  assert.equal(c.opened(), 2);
  assert.equal(rejoined, 2, "a channel to a core started again");
});

test("a core started again hears what the UI held there before what the UI asked while it was away", () => {
  const c = channel();
  const pending: (() => void)[] = [];
  const client = new CoreClient(c.open, {
    schedule: (_ms, run) => void pending.push(run),
    onFault: () => undefined,
  });
  // What the UI holds by a call (a window's lease), asked for again in each core that forgot it.
  client.onRejoin(() => void client.call("lease.retain").catch(() => undefined));
  c.fail("the core's process ended");
  // Asked while no core runs (a send during Electron's core restart): it waits for the next core.
  void client.call("lease.send").catch(() => undefined);
  pending.splice(0).forEach((run) => run());
  assert.equal(c.opened(), 2);
  const calls = c.sent
    .map((message) => (message as { call?: string }).call)
    .filter((name) => name !== undefined);
  assert.deepEqual(calls, ["lease.retain", "lease.send"]);
});
