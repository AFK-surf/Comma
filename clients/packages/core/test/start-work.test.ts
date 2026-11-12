// What the core does to start, counted: the schemas it makes as its modules load and before it knows who is signed in
// (each is made the first time it checks something: chat-contract lazy-schema.ts).
import { madeBefore } from "../src/testing/schemas-made-before.ts";
import { schemaChecks } from "@comma/chat-contract";
import { expect, test } from "vitest";
import { FakeHost, signedOut, startTestCore } from "../src/testing/index.ts";

const atLoad = schemaChecks.trace!.splice(0);
schemaChecks.trace = null;

// No more than now: the schemas the start checks something with.
const MADE_TO_START = 16;

test("the core makes no schema as its modules load, and few to start signed out", async () => {
  // Where each was made, when one was.
  expect(atLoad).toEqual([]);
  const host = new FakeHost();
  const core = startTestCore(host);
  core.observeSession(signedOut());
  await host.time!.pass(1_000);
  expect(schemaChecks.made - madeBefore).toBeLessThanOrEqual(MADE_TO_START);
});
