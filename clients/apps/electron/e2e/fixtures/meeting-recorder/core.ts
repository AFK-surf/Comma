// Test-only: the client core in the fixture's Main process, on a host whose Comma API is the fixture's and whose
// meeting parts are Main's own (`MeetingRecorderMain`). Windows reach it through the real `core.open` channel.
import { randomFillSync } from "node:crypto";
import type { MessagePortMain } from "electron";
import { Core, type ApiResponse, type Host, type MeetingPorts } from "@comma/core";
import type { ClientId, CoreMessage } from "@comma/core-kernel";
import { CoreClient } from "@comma/core-kernel/client";
import { NodeSql } from "@comma/core-kernel/node-sql";
import { Effect } from "effect";

export type FixtureApi = (request: { method: string; path: string; body: unknown }) => {
  status: number;
  body: unknown;
};

export function startFixtureCore(options: { api: FixtureApi; meeting: MeetingPorts }) {
  const sinks = new Map<ClientId, (message: CoreMessage) => void>();
  const storage = new Map<string, Uint8Array>();
  const answer = (request: { method: string; path: string; body: Uint8Array | null }) =>
    Effect.sync((): ApiResponse => {
      const text = request.body ? new TextDecoder().decode(request.body) : "";
      const out = options.api({
        method: request.method,
        path: request.path,
        body: text ? JSON.parse(text) : undefined,
      });
      return {
        status: out.status,
        headers: [["content-type", "application/json"]],
        body: new TextEncoder().encode(JSON.stringify(out.body ?? null)),
      };
    });
  const host: Host = {
    sessionSource: "host",
    meeting: options.meeting,
    fetch: (request) => answer(request),
    fetchStream: (request) =>
      answer(request).pipe(
        Effect.map((response) => {
          let sent = false;
          return {
            status: response.status,
            headers: response.headers,
            body: {
              take: Effect.sync(() => (sent ? null : ((sent = true), response.body))),
            },
          };
        })
      ),
    storageGet: (key) => Effect.sync(() => storage.get(key) ?? null),
    storageSet: (key, value) => Effect.sync(() => void storage.set(key, value)),
    storageDelete: (key) => Effect.sync(() => void storage.delete(key)),
    openDb: () => Effect.sync(() => NodeSql.memory()),
    memoryDb: Effect.sync(() => NodeSql.memory()),
    deleteDb: () => Effect.void,
    randomBytes: (buf) => void randomFillSync(buf),
    yieldTurn: Effect.callback<void>((resume) => {
      const handle = setImmediate(() => resume(Effect.void));
      return Effect.sync(() => clearImmediate(handle));
    }),
    emit: (client: ClientId, message: CoreMessage) => sinks.get(client)?.(message),
  };
  const core = new Core(host, { coalesceMs: 0 });
  core.runner.onDefect = (error) =>
    console.error("fixture core: a fiber failed", error);
  // Main's own client of the core (the recorder window follows its meeting recorder), as `CoreHostService.client()`.
  const main = new CoreClient(
    (onMessage) => {
      const id = core.connect();
      sinks.set(id, (message) =>
        queueMicrotask(() => onMessage(structuredClone(message)))
      );
      return {
        post: (message) =>
          queueMicrotask(() => core.receive(id, structuredClone(message))),
        close: () => {
          sinks.delete(id);
          core.disconnect(id);
        },
      };
    },
    { schedule: () => undefined }
  );
  return {
    core,
    client: main,
    /** `CoreChannelService`'s host: a window's port, attached as that window's channel. */
    channelHost: {
      attach(port: MessagePortMain, surface?: string, session = true) {
        const client = core.connect(surface, session ? {} : { session: false });
        // oxlint-disable-next-line unicorn/require-post-message-target-origin -- a port has no target origin
        sinks.set(client, (message) => port.postMessage(message));
        port.on("message", (event) => core.receive(client, event.data));
        port.on("close", () => {
          sinks.delete(client);
          core.disconnect(client);
        });
        port.start();
        return true;
      },
      onExit: () => () => undefined,
    },
  };
}
