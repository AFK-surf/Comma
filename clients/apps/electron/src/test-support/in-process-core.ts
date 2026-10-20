// The client core, in this process, on Main's real session host: what the utility process does over its parent port
// (packages/core/src/hosts/node.ts), here as direct calls, so a Main test can sign in as the app does and see what
// crosses the boundary. The core's other host parts (storage, databases, its own product requests) are the core's test
// host's.
import { Core, type BearerSessionPorts } from "@comma/core";
import { FakeHost, inProcessOpener, Recorder } from "@comma/core/testing";
import { HostError } from "@comma/core-kernel";
import { CoreClient } from "@comma/core-kernel/client";
import { Effect } from "effect";
import type { MainSessionHost } from "../main/modules/session/session-host";

const fromPromise = <A>(run: (signal: AbortSignal) => Promise<A>) =>
  Effect.tryPromise({
    try: run,
    catch: (error) =>
      new HostError(error instanceof Error ? error.message : String(error)),
  });

/** Starts a core on `session` (Main's session host), on the real clock; `client` is a window's channel to it. */
export function startInProcessCore(session: MainSessionHost) {
  const host = new FakeHost({ sessionSource: "core", time: null });
  let requestId = 0;
  const ports: BearerSessionPorts = {
    apiOrigin: session.apiOrigin,
    clientPlatform: "macos",
    resumed: session.resume(),
    vault: fromPromise(() => session.vault()),
    change: (change) => fromPromise(() => session.change(change)),
    gate: (snapshot, lease) => session.gate(snapshot, lease),
    google: (input) => fromPromise((signal) => session.google(input, signal)),
    googleDone: (grant, ok) => Effect.sync(() => session.googleDone(grant, ok)),
  };
  host.bearerSession = ports;
  host.authFetch = (request) => {
    const id = ++requestId;
    return fromPromise((signal) =>
      session.authFetch(
        {
          body: request.body,
          headers: request.headers,
          method: request.method,
          path: request.path,
          ...(request.credential ? { credential: request.credential } : {}),
        },
        { requestId: id, signal }
      )
    );
  };
  const recorder = new Recorder();
  const core = new Core(host, { coalesceMs: 0, recorder });
  const rejected = session.onRejected((lease) => core.hostRejected(lease, 401));
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  return {
    client,
    core,
    /** Everything the core was told, sent and asked, as text: no bearer may be in it. */
    log: () => recorder.dump(),
    close() {
      rejected();
      client.close();
      core.close();
    },
  };
}
