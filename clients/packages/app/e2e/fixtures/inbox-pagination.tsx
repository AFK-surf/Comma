import { Toaster } from "@comma/ui";
import { createCommaApi, type CommaApiSessionTransport } from "../../src/api";
import { CommaAuthContext } from "../../src/components/auth-context";
import { InboxRoute } from "../../src/components/inbox/InboxRoute";
import {
  createProductInboxProjectionController,
  ProductInboxProjectionProvider,
  type ProductInboxProjectionEnvelope,
} from "../../src/product-inbox";

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

async function read(cursor?: string): Promise<ProductInboxProjectionEnvelope> {
  const url = new URL("/test/inbox", location.origin);
  if (cursor) url.searchParams.set("cursor", cursor);
  return { session, snapshot: await (await fetch(url)).json() };
}

const controller = createProductInboxProjectionController({
  bridge: {
    retain: () => read(),
    release: async () => true,
    state: Object.assign(() => read(), {
      get: () => read(),
      subscribe: () => () => undefined,
    }),
    refresh: (input) => read(input.cursor),
  },
});

export function InboxPaginationFixture() {
  return (
    <CommaAuthContext.Provider
      value={{
        api: createCommaApi({ baseUrl: "", token: "", sessionTransport: transport }),
        apiBaseUrl: "",
        authenticated: true,
        productLease: session,
        sessionSignal: transport.signal,
        sessionTransport: transport,
        signOut: () => undefined,
        userEmail: "inbox-test@example.com",
      }}
    >
      <ProductInboxProjectionProvider controller={controller}>
        <div style={{ height: "100vh", display: "flex" }}>
          <InboxRoute />
        </div>
        <Toaster />
      </ProductInboxProjectionProvider>
    </CommaAuthContext.Provider>
  );
}
