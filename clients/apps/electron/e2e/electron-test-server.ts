import { once } from "node:events";
import { createServer, type RequestListener, type Server } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import type { AddressInfo } from "node:net";
import { electronTestCertificate, trackElectronTestResource } from "./electron-test";

export interface ElectronTestServer {
  /** `http://127.0.0.1:<port>` or `https://127.0.0.1:<port>`. No trailing slash. */
  origin: string;
  port: number;
  server: Server;
  /** Ends its open connections and resolves once it no longer listens. Safe to call twice. */
  close(): Promise<void>;
}

/**
 * A local HTTP server for a spec, on a port the system picks. A test that starts one closes it: a test that passes
 * with its server still listening fails and names it.
 */
export function startElectronTestServer(
  handler: RequestListener,
  /** A worker fixture's server, which no test ends (`trackElectronTestResource`). */
  owner: { worker?: boolean } = {}
): Promise<ElectronTestServer> {
  return start(createServer(handler), "http", owner);
}

/**
 * The same over HTTPS, with the certificate every app launched through `electron.launch` trusts from its start.
 */
export function startElectronTlsTestServer(
  handler: RequestListener
): Promise<ElectronTestServer> {
  const { key, cert } = electronTestCertificate();
  return start(createHttpsServer({ key, cert }, handler), "https", {});
}

async function start(
  server: Server,
  scheme: "http" | "https",
  owner: { worker?: boolean }
): Promise<ElectronTestServer> {
  server.listen(0, "127.0.0.1");
  // Rejects if the listen fails.
  await once(server, "listening");
  const { port } = server.address() as AddressInfo;
  const origin = `${scheme}://127.0.0.1:${port}`;
  const close = async () => {
    forget();
    if (!server.listening) return;
    // A kept-alive connection of the app would hold the close open.
    server.closeAllConnections();
    await new Promise<void>((closed) => server.close(() => closed()));
  };
  const forget = trackElectronTestResource(
    {
      name: `test server ${origin}`,
      open: () => server.listening,
      dispose: close,
    },
    owner
  );
  return { origin, port, server, close };
}
