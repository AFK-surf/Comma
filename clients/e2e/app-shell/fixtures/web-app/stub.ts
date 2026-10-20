// The chat stub server the app's Playwright specs use, as a Node realm
// (e2e/ui-runtime/node-realm.ts): its delays run on world time, and its
// answers reach the app as the world hands them over.
import {
  createE2eSessionProjection,
  registerBrowserSessionFixture,
} from "../../../helpers/session-fixture";
import type { IncomingMessage, ServerResponse } from "node:http";
import { startChatSmokeStub } from "../../../p0/chat-stub";
import { realmOrigin, type NodeRealmEntry } from "../../../ui-runtime/node-realm";
import { agentBrowserRoutes } from "./routes/agent-browser";
import { recommendationsRoutes } from "./routes/recommendations";

// The APIs a spec adds to the stub's own, by name: they run in the stub's
// process, so a spec names them and reaches them through `calls`.
const routeSets = {
  "agent-browser": agentBrowserRoutes,
  recommendations: recommendationsRoutes,
};

export type WebAppStubOptions = {
  session: { email: string; token: string };
  stub?: Parameters<typeof startChatSmokeStub>[0];
  /** An API of the spec's own, beside the stub's (`routeSets`). */
  routes?: keyof typeof routeSets;
  /**
   * The product API beyond the session: `unavailable` answers every other
   * request 503, `unreachable` drops its connection, as a backend that is
   * down or a host that refuses connections.
   */
  api?: "unavailable" | "unreachable";
  /**
   * Requests the stub holds until the test releases them (the `release`
   * call); `held` tells whether one has arrived.
   */
  hold?: readonly ("workspaceChat" | "workspaceChatDetail")[];
  /** Fixed JSON answers to GET requests by path, before the stub's own routes. */
  responses?: Record<string, { status?: number; body: unknown }>;
};

export default async function start({
  session,
  stub: options,
  routes: routeSet,
  api,
  hold = [],
  responses = {},
}: WebAppStubOptions): Promise<NodeRealmEntry> {
  const holds = new Map<
    string,
    { arrived: boolean; released: Promise<void>; release: () => void }
  >(
    hold.map((name) => {
      let release!: () => void;
      const released = new Promise<void>((resolve) => {
        release = resolve;
      });
      return [name, { arrived: false, released, release }];
    })
  );
  const held = (name: "workspaceChat" | "workspaceChatDetail") => {
    const state = holds.get(name);
    if (!state) return undefined;
    return async () => {
      state.arrived = true;
      await state.released;
    };
  };
  const routes = routeSet ? routeSets[routeSet]() : undefined;
  const down = api
    ? (_request: IncomingMessage, url: URL, response: ServerResponse) => {
        if (url.pathname === "/v1/comma/auth/session") return false;
        if (api === "unreachable") response.destroy();
        else
          response.writeHead(503, { "content-type": "application/json" }).end(
            JSON.stringify({
              error: `product backend unavailable for ${url.pathname}`,
            })
          );
        return true;
      }
    : undefined;
  const beforeWorkspaceChat = held("workspaceChat");
  const beforeWorkspaceChatDetail = held("workspaceChatDetail");
  const projection = createE2eSessionProjection({ email: session.email });
  let accountLocale: string | undefined;
  // What the app saved to the account's profile, in order (the `profileWrites` call).
  const profileWrites: unknown[] = [];
  // Paths whose requests from now on lose their connection (the `dropRequests` call).
  const dropped = new Set<string>();
  // Every request's method and path, in order (the `requests` call).
  const requests: string[] = [];
  const extraRoutes = async (
    request: IncomingMessage,
    url: URL,
    response: ServerResponse
  ) => {
    requests.push(`${request.method} ${url.pathname}`);
    if (dropped.has(url.pathname)) {
      response.destroy();
      return true;
    }
    // The account's profile, as the Playwright session answers it
    // (e2e/helpers/browser-auth.ts): a language one page saves is the account's.
    if (url.pathname === "/v1/comma/me/profile") {
      const body: Buffer[] = [];
      for await (const chunk of request) body.push(chunk as Buffer);
      if (request.method === "PATCH") {
        const patch = JSON.parse(Buffer.concat(body).toString() || "{}") as {
          locale?: string;
        };
        profileWrites.push(patch);
        if (patch.locale) accountLocale = patch.locale;
      }
      response.writeHead(200, { "content-type": "application/json" }).end(
        JSON.stringify({
          avatar_id: null,
          email: session.email,
          id: projection.user.id,
          name: null,
          ...(accountLocale ? { locale: accountLocale } : {}),
        })
      );
      return true;
    }
    const answer = request.method === "GET" ? responses[url.pathname] : undefined;
    if (answer) {
      response
        .writeHead(answer.status ?? 200, { "content-type": "application/json" })
        .end(JSON.stringify(answer.body));
      return true;
    }
    if (down?.(request, url, response)) return true;
    return (await routes?.handle(request, url, response)) ?? false;
  };
  const stub = await startChatSmokeStub({
    ...options,
    ...(beforeWorkspaceChat ? { beforeWorkspaceChat } : {}),
    ...(beforeWorkspaceChatDetail ? { beforeWorkspaceChatDetail } : {}),
    origin: realmOrigin(),
    extraRoutes,
  });
  // What the stub's `waitFor…` promises wait for, from the first time a test
  // asks (the `observed` call): the test steps the world until it has, as a
  // call that waited would hold the world still.
  const observing = new Map<string, boolean>();
  const observed = (name: string) => {
    if (!observing.has(name)) {
      observing.set(name, false);
      void (stub as unknown as Record<string, () => Promise<void>>)[name]!().then(() =>
        observing.set(name, true)
      );
    }
    return observing.get(name)!;
  };
  registerBrowserSessionFixture(stub.baseUrl, session.token, projection);
  const explicit: Record<string, (...args: never[]) => unknown> = {
    chatMessageBodies: () => [...stub.chatMessageBodies],
    startStreamingReply: () => stub.startStreamingReply(),
    completeStreamingReply: () => stub.completeStreamingReply(),
    commitThinkingReply: () => stub.commitThinkingReply(),
    invalidateTaskList: () => stub.invalidateTaskList(),
    conversationListRequestCount: () => stub.conversationListRequestCount,
    setTaskPreviewsFailing: (failing: boolean) => stub.setTaskPreviewsFailing(failing),
    setTaskParticipants: (...args: Parameters<typeof stub.setTaskParticipants>) =>
      stub.setTaskParticipants(...args),
    requests: () => [...requests],
    profileWrites: () => structuredClone(profileWrites),
    observed,
    dropRequests: (path: string) => {
      dropped.add(path);
    },
    held: (name: string) => holds.get(name)?.arrived ?? false,
    // The held request goes on at the stub's next step on world time.
    release: (name: string) => {
      const state = holds.get(name);
      // ast-grep-ignore: ts-test-timer -- the realm's timers run on world time (e2e/ui-runtime/node-realm.ts).
      if (state) setTimeout(state.release, 0);
    },
    ...routes?.calls,
  };
  return {
    info: { origin: stub.baseUrl, userId: projection.user.id },
    // Any other call reads the stub's state, or runs its method, of that name.
    calls: new Proxy(explicit, {
      get: (calls, name: string) =>
        calls[name] ??
        ((...args: unknown[]) => {
          const value = (stub as unknown as Record<string, unknown>)[name];
          return typeof value === "function"
            ? (value as (...args: unknown[]) => unknown).apply(stub, args)
            : value;
        }),
    }),
  };
}
