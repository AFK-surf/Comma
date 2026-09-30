import { CommaAppRuntime } from "@comma/app/host-runtime";
import { createCommaApi } from "@comma/app/api";
import type { ChatSessionBoundApi } from "@comma/app/chat-coordinator";
import { renderWebChatImagePreview } from "./chat-image-preview";
import {
  nativeCapabilityRegistry,
  nativeEventRegistry,
  sessionHistoryInputSchema,
  type SessionHistoryEnvelope,
} from "@comma/native-bridge";
import {
  sessionProductLeaseSchema,
  type SessionProductLease,
} from "@comma/session-contract";
import {
  WebCookieProductCredentialAuthority,
  WebMemoryProductInboxStorage,
} from "./product-inbox-host";

export type HostRequest =
  | { type: "configure"; apiBaseUrl: string }
  | { type: "call"; id: number; capability: string; input: unknown }
  | { type: "subscribe"; event: string; input: unknown }
  | { type: "unsubscribe"; event: string }
  | { type: "invalidate"; session: SessionProductLease }
  | { type: "disconnect" };
export type HostResponse =
  | { type: "result"; id: number; value: unknown }
  | { type: "failure"; id: number; error: string }
  | { type: "state"; event: string; value: unknown }
  | { type: "session-rejected"; session: SessionProductLease; status: 401 | 409 };

type PortState = {
  port: MessagePort;
  prefix: string;
  lease?: SessionProductLease;
  events: Set<string>;
  chatLeases: Map<string, Record<string, unknown>>;
  inboxRetained: boolean;
  closed: boolean;
  admissionVersion: number;
};
type Owner = {
  session: SessionProductLease;
  authority: WebCookieProductCredentialAuthority;
  runtime: CommaAppRuntime;
  binding: ChatSessionBoundApi;
  stopInboxSubscription?: (() => void) | undefined;
};
const supportedNamespaces = new Set(["chat", "productInbox", "sessionHistory"]);
const unsupportedChat = new Set([
  "pickAttachments",
  "attachLocalFiles",
  "presentInSideChat",
]);
const capabilities = new Map(
  nativeCapabilityRegistry
    .filter((leaf) => supportedNamespaces.has(leaf.bridge.namespace))
    .map((leaf) => [leaf.id, leaf])
);
const post = (client: PortState, message: HostResponse) => {
  // MessagePort is already a transferred capability; it has no targetOrigin argument.
  // oxlint-disable-next-line unicorn/require-post-message-target-origin
  if (!client.closed) client.port.postMessage(message);
};

/** Main's generated command/state contract over MessagePort. No view owns product effects.
 * Admission and stale-owner completion are modeled in tla/client-host/HostAdmission.tla.
 */
export function attachWebAppRuntime(
  scope: {
    addEventListener(type: "connect", listener: (event: MessageEvent) => void): void;
  },
  options: { fetch?: typeof fetch; apiBaseUrl?: string } = {}
) {
  const fetchImpl = options.fetch ?? fetch;
  let audience = options.apiBaseUrl ? new URL(options.apiBaseUrl).origin : "";
  let configured = options.apiBaseUrl !== undefined;
  const ports = new Set<PortState>();
  let active: Owner | undefined;
  let admissionTail: Promise<unknown> = Promise.resolve();
  let epoch = 0;

  const publish = (
    owner: Owner,
    event: string,
    value: { session: SessionProductLease; snapshot: unknown }
  ) => {
    if (active !== owner) return;
    for (const client of ports) {
      if (
        !client.events.has(event) ||
        client.lease?.sessionId !== owner.session.sessionId
      )
        continue;
      let snapshot = value.snapshot;
      if (event === "chat.state.changed") {
        const state = owner.runtime.chat.state();
        snapshot = {
          ...state,
          sessions: state.sessions.map((item) => ({
            ...item,
            ...(item.surfaceProjections
              ? {
                  surfaceProjections: item.surfaceProjections
                    .filter((p) => p.subscriberId.startsWith(client.prefix))
                    .map((p) => ({
                      ...p,
                      subscriberId: p.subscriberId.slice(client.prefix.length),
                    })),
                }
              : {}),
          })),
        };
      }
      post(client, {
        type: "state",
        event,
        value: { session: client.lease, snapshot },
      });
    }
  };
  const retire = () => {
    epoch += 1;
    const previous = active;
    active = undefined;
    previous?.authority.invalidate();
    previous?.runtime.close();
    for (const client of ports) {
      client.chatLeases.clear();
      client.inboxRetained = false;
    }
  };
  const rejectSession = (owner: Owner, status: 401 | 409) => {
    if (active !== owner) return;
    for (const client of ports)
      if (client.lease?.sessionId === owner.session.sessionId)
        post(client, { type: "session-rejected", session: client.lease, status });
    retire();
  };

  const createOwner = (sessionId: string): Owner => {
    const authority = new WebCookieProductCredentialAuthority();
    const session = {
      audience,
      sessionId,
      authorityInstanceId: crypto.randomUUID(),
      generation: 1,
    };
    authority.activate(session);
    const credential = authority.acquireProductCredential({
      authorityInstanceId: session.authorityInstanceId,
      expectedAudience: audience,
      expectedSessionId: sessionId,
      generation: 1,
    })!;
    let owner!: Owner;
    const isCurrent = () =>
      active === owner && authority.isCurrentProductCredential(credential);
    const assertCurrent = () => {
      if (!isCurrent()) throw new Error("Session is no longer active.");
    };
    // The existing API client owns HTTP/SSE parsing. The host supplies cookie
    // credentials and exact-session headers; JavaScript never reads the bearer.
    const api = createCommaApi({
      baseUrl: audience,
      token: "",
      fetch: fetchImpl,
      sessionTransport: {
        credentials: "include",
        signal: credential.signal,
        applyHeaders: (headers) => Object.assign(headers, credential.request!.headers),
        reportSessionRejection: (status) => rejectSession(owner, status),
      },
    });
    const binding = { api, session, isCurrent, assertCurrent };
    const runtime = new CommaAppRuntime({
      chat: {
        renderGroupImagePreview: renderWebChatImagePreview,
        createSessionBoundApi: () => {
          assertCurrent();
          return binding;
        },
      },
      productInbox: {
        authority,
        fetch: fetchImpl,
        localData: new WebMemoryProductInboxStorage(),
        reportUnauthorized: async () => rejectSession(owner, 401),
        reportSessionChanged: async () => rejectSession(owner, 409),
      },
      sessionHistory: {
        authority,
        fetch: async (input, init) => {
          const response = await fetchImpl(input, init);
          if (response.status === 401 || response.status === 409)
            rejectSession(owner, response.status);
          return response;
        },
      },
    });
    owner = { authority, binding, runtime, session };
    runtime.chat.subscribe((snapshot) =>
      publish(owner, "chat.state.changed", { session, snapshot })
    );
    runtime.chat.subscribeDrafts((snapshot) =>
      publish(owner, "chat.drafts.changed", { session, snapshot })
    );
    runtime.sessionHistory.subscribe((envelope) =>
      publish(owner, "sessionHistory.state.changed", envelope)
    );
    return owner;
  };

  const admit = (client: PortState, input: unknown): Promise<Owner> => {
    const lease = sessionProductLeaseSchema.parse(
      (input as { session?: unknown })?.session
    );
    if (lease.audience !== audience)
      return Promise.reject(new Error("Wrong API audience."));
    if (
      client.lease?.authorityInstanceId === lease.authorityInstanceId &&
      client.lease.generation > lease.generation
    )
      return Promise.reject(new Error("Stale view generation."));
    const admissionEpoch = epoch;
    const admissionVersion = client.admissionVersion;
    const run = async () => {
      if (client.closed || client.admissionVersion !== admissionVersion)
        throw new Error("View admission was cancelled.");
      if (
        client.lease?.authorityInstanceId === lease.authorityInstanceId &&
        client.lease.generation > lease.generation
      )
        throw new Error("Stale view generation.");
      if (active?.session.sessionId !== lease.sessionId) {
        // Only a change of cookie Session probes the server, never per record,
        // Conversation or poll. A stale tab cannot select the worker's owner.
        const response = await fetchImpl(`${audience}/v1/comma/auth/session`, {
          credentials: "include",
          cache: "no-store",
          redirect: "error",
          headers: {
            "x-comma-session-transport": "cookie",
            "x-comma-session-lifecycle-version": "1",
            "x-comma-expected-auth-session-id": lease.sessionId,
          },
          signal: AbortSignal.timeout(15_000),
        });
        if (!response.ok) {
          if (response.status === 401 || response.status === 409)
            post(client, {
              type: "session-rejected",
              session: lease,
              status: response.status,
            });
          throw new Error("Session admission failed.");
        }
        const projection = (await response.json()) as { session_id?: string };
        if (
          projection.session_id !== lease.sessionId ||
          client.closed ||
          client.admissionVersion !== admissionVersion ||
          admissionEpoch !== epoch
        )
          throw new Error("Session changed during admission.");
        retire();
        active = createOwner(lease.sessionId);
      }
      client.lease = lease;
      return active!;
    };
    const pending = admissionTail.then(run);
    admissionTail = pending.catch(() => undefined);
    return pending;
  };

  const cleanup = (client: PortState) => {
    const owner = active;
    if (owner && client.lease?.sessionId === owner.session.sessionId) {
      for (const lease of client.chatLeases.values())
        owner.runtime.chat.release(lease as never);
      owner.runtime.sessionHistory.releaseAll(client.prefix);
      if (client.inboxRetained) owner.runtime.productInbox.release(owner.session);
    }
    client.chatLeases.clear();
    client.inboxRetained = false;
  };
  const releaseUnusedInboxSubscription = () => {
    if (
      active &&
      ![...ports].some(
        (client) =>
          client.lease?.sessionId === active?.session.sessionId &&
          client.events.has("productInbox.state.changed")
      )
    ) {
      active.stopInboxSubscription?.();
      active.stopInboxSubscription = undefined;
    }
  };

  scope.addEventListener("connect", (event) => {
    const port = event.ports[0];
    if (!port) return;
    const client: PortState = {
      port,
      prefix: `${crypto.randomUUID()}:`,
      events: new Set(),
      chatLeases: new Map(),
      inboxRetained: false,
      closed: false,
      admissionVersion: 0,
    };
    ports.add(client);
    port.addEventListener("message", (message: MessageEvent<HostRequest>) => {
      const request = message.data;
      if (request.type === "configure") {
        if (!configured) {
          audience = new URL(request.apiBaseUrl).origin;
          configured = true;
        }
        return;
      }
      if (request.type === "disconnect") {
        cleanup(client);
        client.closed = true;
        client.events.clear();
        ports.delete(client);
        releaseUnusedInboxSubscription();
        port.close();
        return;
      }
      if (request.type === "invalidate") {
        client.admissionVersion += 1;
        if (
          active?.session.sessionId === request.session.sessionId &&
          client.lease?.sessionId === request.session.sessionId
        )
          retire();
        return;
      }
      if (request.type === "unsubscribe") {
        client.events.delete(request.event);
        releaseUnusedInboxSubscription();
        return;
      }
      const dispatch = async () => {
        if (request.type === "subscribe") {
          if (
            !nativeEventRegistry.some(
              (leaf) =>
                leaf.id === request.event &&
                supportedNamespaces.has(leaf.id.split(".")[0]!)
            )
          )
            throw new Error("Unsupported state.");
          // HostSubscription.tla: cancellation wins over delayed admission.
          client.events.add(request.event);
          const owner = await admit(client, request.input);
          if (!client.events.has(request.event)) return;
          if (
            request.event === "productInbox.state.changed" &&
            !owner.stopInboxSubscription
          ) {
            owner.stopInboxSubscription = owner.runtime.productInbox.subscribe(
              owner.session,
              (envelope) => publish(owner, request.event, envelope)
            );
          } else if (request.event === "productInbox.state.changed") {
            publish(
              owner,
              request.event,
              owner.runtime.productInbox.get(owner.session)
            );
          }
          if (request.event === "chat.state.changed") {
            publish(owner, request.event, {
              session: owner.session,
              snapshot: owner.runtime.chat.state(),
            });
          } else if (request.event === "chat.drafts.changed") {
            publish(owner, request.event, {
              session: owner.session,
              snapshot: owner.runtime.chat.drafts(),
            });
          } else if (request.event === "sessionHistory.state.changed") {
            publish(
              owner,
              request.event,
              owner.runtime.sessionHistory.state({
                ...sessionHistoryInputSchema.parse(request.input),
                session: owner.session,
              })
            );
          }
          return;
        }
        const leaf = capabilities.get(request.capability as never);
        if (!leaf) throw new Error("Unsupported host capability.");
        const parsed = leaf.input.parse(request.input) as Record<string, unknown> & {
          session: SessionProductLease;
        };
        const owner = await admit(client, parsed);
        const { session: uiSession, ...raw } = parsed;
        const input = { ...raw };
        if (typeof input.subscriberId === "string")
          input.subscriberId = client.prefix + input.subscriberId;
        if (typeof input.surfaceId === "string")
          input.surfaceId = client.prefix + input.surfaceId;
        const { namespace, method } = leaf.bridge;
        let value: unknown;
        if (namespace === "chat") {
          if (unsupportedChat.has(method))
            throw new Error("This operation requires native host capabilities.");
          if (method === "state") {
            const snapshot = owner.runtime.chat.state();
            value = {
              session: uiSession,
              snapshot: {
                ...snapshot,
                sessions: snapshot.sessions.map((item) => ({
                  ...item,
                  ...(item.surfaceProjections
                    ? {
                        surfaceProjections: item.surfaceProjections
                          .filter((p) => p.subscriberId.startsWith(client.prefix))
                          .map((p) => ({
                            ...p,
                            subscriberId: p.subscriberId.slice(client.prefix.length),
                          })),
                      }
                    : {}),
                })),
              },
            };
          } else if (method === "drafts") {
            value = { session: uiSession, snapshot: owner.runtime.chat.drafts() };
          } else {
            const operation = owner.runtime.chat[
              method as keyof typeof owner.runtime.chat
            ] as (input: never) => unknown;
            value = await operation.call(owner.runtime.chat, input as never);
            if (method === "retain")
              client.chatLeases.set(String(input.subscriberId), input);
            if (
              method === "release" &&
              client.chatLeases.get(String(input.subscriberId))?.leaseId ===
                input.leaseId
            )
              client.chatLeases.delete(String(input.subscriberId));
          }
        } else if (namespace === "sessionHistory") {
          const target = {
            ...input,
            session: owner.session,
            ...(typeof input.consumerId === "string"
              ? { consumerId: client.prefix + input.consumerId }
              : {}),
          };
          const operation = owner.runtime.sessionHistory[
            method as "load" | "retain" | "release" | "state"
          ] as (
            input: never
          ) => SessionHistoryEnvelope | boolean | Promise<SessionHistoryEnvelope>;
          const result = await operation.call(
            owner.runtime.sessionHistory,
            target as never
          );
          value =
            typeof result === "boolean" ? result : { ...result, session: uiSession };
        } else {
          if (method === "retain" && !client.inboxRetained) {
            owner.runtime.productInbox.retain(owner.session);
            client.inboxRetained = true;
          }
          if (method === "release") {
            if (client.inboxRetained) owner.runtime.productInbox.release(owner.session);
            client.inboxRetained = false;
            value = true;
          } else {
            const result =
              method === "state"
                ? owner.runtime.productInbox.get(owner.session)
                : await owner.runtime.productInbox.refresh({
                    ...input,
                    session: owner.session,
                  } as never);
            value = { ...result, session: uiSession };
          }
        }
        owner.binding.assertCurrent();
        post(client, {
          type: "result",
          id: request.id,
          value: leaf.output.parse(value),
        });
      };
      void dispatch().catch((error) => {
        if (request.type === "call")
          post(client, {
            type: "failure",
            id: request.id,
            error: error instanceof Error ? error.message : "Host unavailable.",
          });
      });
    });
    port.start();
  });
  return () => {
    retire();
    for (const client of ports) {
      client.closed = true;
      client.port.close();
    }
    ports.clear();
  };
}
