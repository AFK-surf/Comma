import { app, net } from "electron";
import { writeSync } from "node:fs";
import { sessionPresenceExpectationHeader } from "@comma/session-contract";
import {
  proxyCommaApiRequest,
  registerAppProtocol,
  registerPrivilegedSchemes,
  type CommaApiCredentialAuthority,
} from "../../src/main/protocol";
import { MAIN_SHUTDOWN_COMPLETE_LINE } from "../../src/main/e2e-shutdown-report";

process.on("exit", () => writeSync(1, `${MAIN_SHUTDOWN_COMPLETE_LINE}\n`));
app.on("window-all-closed", () => {});
registerPrivilegedSchemes();

function fixture(origin: string) {
  const leaseController = new AbortController();
  const lease = {
    audience: origin,
    authorityInstanceId: "transport-fixture",
    generation: 1,
    sessionId: "fixture-session",
    token: "fixture-main-bearer",
    signal: leaseController.signal,
  };
  const authority: CommaApiCredentialAuthority = {
    acquireProductCredential: () => lease,
    isCurrentProductCredential: (candidate) =>
      candidate === lease && !leaseController.signal.aborted,
    admissionFailure: () => ({
      code: "session_product_lease_unavailable",
      recovery: {
        authorityInstanceId: lease.authorityInstanceId,
        generation: 1,
        revision: 1,
      },
    }),
  };
  registerAppProtocol(undefined, { getCredentialAuthority: () => authority });
  const readers: {
    reader: ReadableStreamDefaultReader<Uint8Array>;
    controller: AbortController;
  }[] = [];
  const request = (path: string, viaProtocol: boolean, init: RequestInit = {}) => {
    const headers = new Headers(init.headers);
    headers.set(
      sessionPresenceExpectationHeader,
      JSON.stringify({
        authorityInstanceId: lease.authorityInstanceId,
        expectedAudience: lease.audience,
        expectedSessionId: lease.sessionId,
        generation: lease.generation,
      })
    );
    // Renderer-supplied credentials must not become the upstream credential, in either pool.
    headers.set("authorization", "Bearer renderer-supplied");
    headers.set("cookie", "renderer-cookie=1");
    const url = new URL(path, "assets://.");
    const input = { ...init, headers };
    return viaProtocol
      ? net.fetch(url.toString(), input)
      : proxyCommaApiRequest(new Request(url, input), url, authority);
  };
  return {
    async open() {
      await Promise.all(
        Array.from({ length: 6 }, async (_, index) => {
          const controller = new AbortController();
          const response = await request(`/v1/comma/events/${index}`, index % 2 === 0, {
            headers: { accept: "text/event-stream" },
            signal: controller.signal,
          });
          const reader = response.body!.getReader();
          readers.push({ reader, controller });
          await reader.read();
        })
      );
    },
    async transcribe() {
      return Promise.all(
        [false, true].map(async (viaProtocol) => {
          const response = await request(
            "/v1/comma/me/recordings/transcribe",
            viaProtocol,
            {
              method: "POST",
              headers: { accept: "text/event-stream", "content-type": "audio/mp4" },
              body: new Uint8Array([1, 2, 3]),
              // The real Quick Chat deadline: held subscriptions must not consume it before upload starts.
              signal: AbortSignal.timeout(10_000),
            }
          );
          return response.text();
        })
      );
    },
    async read() {
      const response = await request("/v1/comma/workspaces", true, {
        signal: AbortSignal.timeout(10_000),
      });
      return response.json();
    },
    async close() {
      for (const { controller } of readers) controller.abort();
      await Promise.all(
        readers.map(({ reader }) => reader.cancel().catch(() => undefined))
      );
    },
  };
}

const ready = app.whenReady();
(
  globalThis as typeof globalThis & {
    transportFixture: (origin: string) => Promise<ReturnType<typeof fixture>>;
  }
).transportFixture = async (origin) => {
  await ready;
  return fixture(origin);
};
