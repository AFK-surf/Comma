// The address a widget must never reach (e2e/app-shell/dynamic-ui-runtime.chromium.test.ts):
// a server of the world. A request that reaches it is not one of the world's,
// and the realm fails the test with it (e2e/ui-runtime/node-realm.ts).
import { createServer } from "node:http";
import { realmOrigin, type NodeRealmEntry } from "../../../ui-runtime/node-realm";

export default async function start(): Promise<NodeRealmEntry> {
  const server = createServer((_request, response) => {
    response.writeHead(404).end();
  });
  await new Promise<void>((listening) =>
    server.listen(0, "127.0.0.1", () => listening())
  );
  return { info: { origin: realmOrigin() } };
}
