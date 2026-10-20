// The client core's TokenDance sign-in with the utility process's real loopback listener and Main's real pages: only
// the Comma API and TokenDance's key exchange are isolated, so the test never authorizes or charges an account.
import { HostError, type ClientId, type CoreMessage } from "@comma/core-kernel";
import { CoreClient } from "@comma/core-kernel/client";
import { NodeSql } from "@comma/core-kernel/node-sql";
import { Effect } from "effect";
import { createHash, randomFillSync } from "node:crypto";
import { Core } from "../../../../packages/core/src/core";
import type {
  ApiRequest,
  ApiResponse,
  DesktopPorts,
  Host,
} from "../../../../packages/core/src/host";
import { listenLoopback } from "../../../../packages/core/src/hosts/loopback";
import { authorizationReturnCsp } from "../../src/main/authorization-return";
import { loopbackAuthorizationPages } from "../../src/main/subscription-authorization-page";

const answer = (value: unknown): ApiResponse => ({
  status: 200,
  headers: [["content-type", "application/json"]],
  body: new TextEncoder().encode(JSON.stringify(value)),
});

export function startTokenDance(returnUrl: string) {
  const opened = Promise.withResolvers<string>();
  let returns = 0;
  const listeners = new Map<ClientId, (message: CoreMessage) => void>();
  const pages = loopbackAuthorizationPages(returnUrl);
  const desktop: DesktopPorts = {
    app: { urlScheme: "comma-dev", productName: "Comma Dev" },
    presence: Effect.succeed({ idleSeconds: 0, homeRepliesShown: false }),
    openExternal: (url) => Effect.sync(() => opened.resolve(url)),
    returnToApp: Effect.sync(() => void (returns += 1)),
    pickAttachments: () => Effect.fail(new HostError("No file dialog in this test.")),
    saveDownload: () => Effect.fail(new HostError("No Downloads folder in this test.")),
    listen: (input) =>
      listenLoopback({
        port: input.port,
        path: input.path,
        pages: pages[input.source],
        csp: authorizationReturnCsp,
      }),
    providerFetch: () => Effect.succeed(answer({ key: "isolated-provider-key" })),
    sha256: (input) =>
      Effect.sync(
        () => new Uint8Array(createHash("sha256").update(input, "utf8").digest())
      ),
  };
  const fetch = (request: ApiRequest): Effect.Effect<ApiResponse, HostError> =>
    Effect.sync(() => {
      const path = request.path.split("?")[0]!;
      if (path.endsWith("/model-discovery")) return answer({ data: [{ id: "model" }] });
      if (path.endsWith("/subscription-accounts") && request.method === "POST")
        return answer({
          id: "sub_isolated",
          credential_kind: "provider_api_key",
          source: "custom",
          disabled: false,
          status: "active",
          version: "v1",
        });
      return { status: 404, headers: [], body: new Uint8Array() };
    });
  const host: Host = {
    sessionSource: "host",
    desktop,
    fetch,
    fetchStream: () => Effect.fail(new HostError("no streams here")),
    storageGet: () => Effect.succeed(null),
    storageSet: () => Effect.void,
    storageDelete: () => Effect.void,
    openDb: () => Effect.sync(() => NodeSql.memory()),
    memoryDb: Effect.sync(() => NodeSql.memory()),
    deleteDb: () => Effect.void,
    randomBytes: (buf) => void randomFillSync(buf),
    yieldTurn: Effect.callback<void>((resume) => {
      const handle = setImmediate(() => resume(Effect.void));
      return Effect.sync(() => clearImmediate(handle));
    }),
    emit: (client, message) => listeners.get(client)?.(structuredClone(message)),
  };
  const core = new Core(host);
  core.observeSession({
    authority: { authorityInstanceId: "authority-1", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: 1,
    revision: 1,
    phase: "signed_in",
    principal: { email: "isolated@example.test", userId: "isolated" },
    session: {
      audience: "https://api.comma.test",
      expiresAtEpochSeconds: 4_000_000_000,
      sessionId: "session-isolated",
    },
  });
  const client = new CoreClient((onMessage) => {
    const id = core.connect();
    listeners.set(id, (message) => queueMicrotask(() => onMessage(message)));
    return {
      post: (message) =>
        queueMicrotask(() => core.receive(id, structuredClone(message))),
      close: () => {
        listeners.delete(id);
        core.disconnect(id);
      },
    };
  });
  const cancel = new AbortController();
  const connected = client
    .call(
      "models.tokenDance.connect",
      { workspace: "isolated", name: "TokenDance" },
      undefined,
      cancel.signal
    )
    .then(
      () => "saved",
      (error: { code?: string }) => error.code ?? "failed"
    );
  return {
    /** The address the browser is sent to. */
    opened: opened.promise,
    returns: () => returns,
    connected,
    close: () => {
      cancel.abort();
      client.close();
      core.close();
    },
  };
}
