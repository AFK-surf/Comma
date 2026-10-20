import { CoreClient } from "@comma/core-kernel/client";
import { NodeSql } from "@comma/core-kernel/node-sql";
import { settle } from "@comma/core-kernel/testing";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";
import { Effect } from "effect";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, onTestFinished, vi } from "vitest";
import {
  CORE_START,
  startCoreUtility,
  type CoreToMain,
  type MainToCore,
  type UtilityPort,
} from "../src/hosts/node.ts";
import { FakeMain } from "../src/testing/fake-main.ts";
import { FakeHost, json } from "../src/testing/index.ts";

const PATH = "/v1/comma/me/recordings/transcribe?purpose=dictation";
const words = { transcript: "Book the room", duration_seconds: 2, chunks: [] };
const audio = new Uint8Array([1, 2, 3]);

/** Runs the real utility entry point, including its request and stream ownership over Main's port. */
async function setup() {
  // The unit harness keeps temporary paths in memory; this exercises stream ownership, not disk persistence.
  const databases: NodeSql[] = [];
  const openDatabase = vi.spyOn(NodeSql, "file").mockImplementation(() => {
    const database = NodeSql.memory();
    databases.push(database);
    return database;
  });
  const dataDir = mkdtempSync(join(tmpdir(), "comma-utility-stream-"));
  const host = new FakeHost({ sessionSource: "core" });
  const main = new FakeMain(host);
  main.active = {
    audience: main.origin,
    token: "fixture-token",
    sessionId: "session-1",
    userId: "user-1",
    email: "peng@example.com",
    expiresAtEpochSeconds: 1_900_000_000,
  };
  host.api.on(
    "GET",
    "/v1/comma/auth/session",
    json(200, {
      expires_at: 1_900_000_000,
      session_id: "session-1",
      user: {
        id: "user-1",
        email: "peng@example.com",
        name: "Peng",
        status: "active",
      },
    })
  );
  const messages: CoreToMain[] = [];
  const replies: unknown[] = [];
  const clocks = new Map<number, () => void>();
  let nextClock = 0;
  const parent = Object.assign(new EventEmitter(), {
    postMessage(raw: unknown) {
      const message = raw as CoreToMain;
      messages.push(message);
      queueMicrotask(() => {
        if (message.type === "gate") {
          host.bearerSession!.gate(
            message.snapshot as SessionLifecycleSnapshot,
            message.lease
          );
        } else if (message.type === "session") {
          const ports = host.bearerSession!;
          const answer: Effect.Effect<unknown, unknown> =
            message.op === "vault"
              ? ports.vault
              : message.op === "change"
                ? ports.change(message.input)
                : message.op === "auth"
                  ? main.authFetch(message.input)
                  : Effect.die(
                      new Error(`Unexpected session operation: ${message.op}`)
                    );
          void Effect.runPromise(answer).then(
            (value) => send({ type: "session-done", id: message.id, value }),
            (error: unknown) =>
              send({
                type: "session-done",
                id: message.id,
                error: String(error),
              })
          );
        } else if (message.type === "clock-done") {
          expect(message.error).toBeUndefined();
          clocks.get(message.id)!();
          clocks.delete(message.id);
        }
      });
    },
  });
  function send(data: MainToCore, ports: UtilityPort[] = []) {
    parent.emit("message", { data, ports });
  }
  startCoreUtility(parent);
  send({
    type: CORE_START,
    dataDir,
    session: {
      apiOrigin: main.origin,
      clientPlatform: "macos",
      resumed: {
        authorityInstanceId: "main",
        generation: 0,
        revision: 0,
        sessionId: null,
      },
    },
    testClock: true,
  });
  const client = new CoreClient(
    (onMessage) => {
      const port = Object.assign(new EventEmitter(), {
        postMessage(message: unknown) {
          replies.push(message);
          queueMicrotask(() => onMessage(message));
        },
        start() {},
        close() {
          port.emit("close");
        },
      });
      send({ type: "client" }, [port]);
      return {
        post(message) {
          port.emit("message", { data: message });
        },
        close() {
          port.close();
        },
      };
    },
    { schedule: () => undefined }
  );
  onTestFinished(async () => {
    for (const message of messages) {
      if (message.type === "fetch")
        send({ type: "fail", id: message.id, message: "test ended" });
    }
    client.close();
    await settle();
    for (const database of databases) database.close();
    openDatabase.mockRestore();
    rmSync(dataDir, { recursive: true, force: true });
  });
  await settle();
  expect(main.gateLease()?.sessionId).toBe("session-1");
  return {
    messages,
    replies,
    send,
    client,
    revoke() {
      send({ type: "rejected", lease: main.gateLease()!, status: 401 });
    },
    async advance(ms: number) {
      const id = ++nextClock;
      const done = new Promise<void>((resolve) => clocks.set(id, resolve));
      send({ type: "clock", id, ms });
      await done;
    },
    async transcribe() {
      const outcome: {
        value?: unknown;
        error?: { code: string; message: string };
      } = {};
      const done = client
        .call("recordings.transcribe", { audio, purpose: "dictation" })
        .then(
          (value) => {
            outcome.value = value;
          },
          (error) => {
            outcome.error = error;
          }
        );
      await settle();
      const request = messages
        .filter(
          (m): m is Extract<CoreToMain, { type: "fetch" }> =>
            m.type === "fetch" && m.path === PATH
        )
        .at(-1);
      expect(request).toBeDefined();
      return { id: request!.id, outcome, done };
    },
    head(id: number) {
      send({
        type: "head",
        id,
        status: 200,
        headers: [["content-type", "text/event-stream"]],
      });
    },
    words(id: number) {
      send({
        type: "chunk",
        id,
        bytes: new TextEncoder().encode(
          `event: transcription\ndata: ${JSON.stringify({ status: "ready", result: words })}\n\n`
        ),
      });
    },
  };
}

describe("utility stream lifetime", () => {
  it.each(["session revocation", "timeout"] as const)(
    "aborts before the response head on %s and ignores a late response",
    async (stop) => {
      const t = await setup();
      const request = await t.transcribe();
      if (stop === "session revocation") {
        t.revoke();
        await settle();
      } else await t.advance(10_000);

      expect(t.messages).toContainEqual({ type: "abort", id: request.id });
      expect(request.outcome).toMatchObject({
        error: {
          code: "transcription_failed",
          message: expect.stringContaining(
            stop === "timeout" ? "too long" : "unavailable"
          ),
        },
      });
      const replies = [...t.replies];
      t.head(request.id);
      t.words(request.id);
      t.send({ type: "end", id: request.id });
      await settle();
      expect(t.replies).toEqual(replies);
      expect(request.outcome).not.toHaveProperty("value");
      await request.done;
    }
  );

  it("releases the open stream once its transcription was delivered", async () => {
    const t = await setup();
    const request = await t.transcribe();
    t.head(request.id);
    t.words(request.id);
    await settle();
    expect(request.outcome).toEqual({ value: words });
    expect(t.messages).toContainEqual({ type: "abort", id: request.id });
    await request.done;
  });
});
