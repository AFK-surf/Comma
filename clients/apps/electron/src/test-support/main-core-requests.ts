// The client core as Main's own channel reaches it, making its product requests through `fetch`: a Main test that
// stubs the workspace service over HTTP keeps doing so while the requests are the core's. The core's session is the
// one Main's session double says now (read again before each call), on the real clock.
import { FakeHost, inProcessOpener, startTestCore } from "@comma/core/testing";
import { HostError } from "@comma/core-kernel";
import { CoreClient } from "@comma/core-kernel/client";
import { Effect } from "effect";

type MainSessionState = {
  phase?: string;
  authority?: { authorityInstanceId?: string };
  generation?: number;
  session?: { audience?: string; sessionId?: string } | null;
};

/** `session`'s state as the core's session snapshot. */
function snapshotOf(state: MainSessionState) {
  const signedIn = state.phase === "signed_in" && state.session;
  return {
    authority: {
      authorityInstanceId: state.authority?.authorityInstanceId ?? "authority",
      kind: "electron_main",
    },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: state.generation ?? 1,
    revision: state.generation ?? 1,
    phase: signedIn ? "signed_in" : "signed_out",
    principal: signedIn ? { email: "main@example.test", userId: "main-user" } : null,
    session: signedIn
      ? {
          audience: state.session!.audience,
          expiresAtEpochSeconds: 4_000_000_000,
          sessionId: state.session!.sessionId,
        }
      : null,
  };
}

class FetchHost extends FakeHost {
  constructor(private readonly fetcher: typeof fetch) {
    super({ time: null });
  }

  override fetch(request: Parameters<FakeHost["fetch"]>[0]) {
    return Effect.tryPromise({
      try: async () => {
        const response = await this.fetcher(
          new URL(request.path, request.lease.audience),
          {
            method: request.method,
            // Main's `/v1` proxy adds the bearer of this lease's session; a test sees which session it was.
            headers: {
              ...Object.fromEntries(request.headers),
              "x-comma-test-session": request.lease.sessionId,
            },
            ...(request.body ? { body: new TextDecoder().decode(request.body) } : {}),
          }
        );
        return {
          status: response.status,
          headers: [...response.headers] as [string, string][],
          body: new Uint8Array(await response.arrayBuffer()),
        };
      },
      catch: (error) =>
        new HostError(error instanceof Error ? error.message : String(error)),
    });
  }
}

/** Main's channel to a core whose requests go to `fetcher`, signed in as `session` says. */
export function mainCoreRequests(
  session: { state(): unknown },
  fetcher: typeof fetch = fetch
): () => CoreClient {
  const host = new FetchHost(fetcher);
  const core = startTestCore(host, { replays: false });
  const client = new CoreClient(
    inProcessOpener(core, host, undefined, { host: true }),
    {
      schedule: () => undefined,
    }
  );
  let told = "";
  return () => {
    const snapshot = snapshotOf(session.state() as MainSessionState);
    const key = JSON.stringify(snapshot);
    if (key !== told) {
      told = key;
      core.observeSession(snapshot);
    }
    return client;
  };
}
