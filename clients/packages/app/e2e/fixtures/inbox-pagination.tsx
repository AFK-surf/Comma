import type { ProductInboxListResult } from "@comma/core-client";
import { CoreProvider } from "@comma/core-client";
// A fixture page builds with the web app's aliases, which leave test packages out.
import { createScriptedCore } from "../../../test-utils/src/scripted-core";
import { Toaster } from "@comma/ui/components/toast";
import type { CommaApiSessionTransport } from "../../src/session/controller";
import { CommaAuthContext } from "../../src/components/auth-context";
import { InboxRoute } from "../../src/components/inbox/InboxRoute";

const session = {
  audience: "https://api.comma.test",
  authorityInstanceId: "inbox-browser-test",
  generation: 1,
  sessionId: "11111111-1111-4111-8111-111111111111",
};
const transport: CommaApiSessionTransport = {
  credentials: "include",
  signal: new AbortController().signal,
  applyHeaders: () => undefined,
  reportSessionRejection: () => undefined,
};

async function read(cursor?: string): Promise<ProductInboxListResult> {
  const url = new URL("/test/inbox", location.origin);
  if (cursor) url.searchParams.set("cursor", cursor);
  return (await fetch(url)).json();
}

// The core's list as the page's test server answers it: the first page, then each page `tasks.more` reads after it.
let list: ProductInboxListResult | undefined;
const core = createScriptedCore({
  values: (topic) => (topic.topic === "tasks" ? list : undefined),
  onSubscribe: (topic) => {
    if (topic.topic === "tasks" && !list)
      void read().then((first) => {
        list = first;
        core.emit("tasks", list);
      });
  },
  calls: async (name) => {
    if (name !== "tasks.more" || !list?.nextCursor) return null;
    const next = await read(list.nextCursor);
    if (next.errorCode)
      throw Object.assign(new Error(next.errorCode), { code: next.errorCode });
    const { nextCursor: _consumed, ...shown } = list;
    list = {
      ...shown,
      items: [...list.items, ...next.items],
      hasMore: next.hasMore === true,
      ...(next.hasMore && next.nextCursor ? { nextCursor: next.nextCursor } : {}),
    };
    core.emit("tasks", list);
    return null;
  },
});
const controller = core.client;

export function InboxPaginationFixture() {
  return (
    <CommaAuthContext.Provider
      value={{
        apiBaseUrl: "",
        authenticated: true,
        productLease: session,
        sessionSignal: transport.signal,
        sessionTransport: transport,
        signOut: () => undefined,
        userEmail: "inbox-test@example.com",
      }}
    >
      <CoreProvider client={controller}>
        <div style={{ height: "100vh", display: "flex" }}>
          <InboxRoute />
        </div>
        <Toaster />
      </CoreProvider>
    </CommaAuthContext.Provider>
  );
}
