import { once } from "node:events";
import { createServer, type RequestListener, type Server } from "node:http";
import type { AddressInfo } from "node:net";

export interface E2eTestServer {
  /** `http://<host>:<port>`. No trailing slash. */
  origin: string;
  port: number;
  server: Server;
  /** Ends its open connections and resolves once it no longer listens. Safe to call twice. */
  close(): Promise<void>;
}

/**
 * A local HTTP server for a web spec, on a port the system picks. The page
 * keeps its connections to the server open after the test's last request, so
 * closing it ends those connections first; a plain `server.close()` would wait
 * for them until the test's limit.
 */
export async function startE2eTestServer(
  handler: RequestListener,
  /** `127.0.0.1` unless a test needs another site, such as `localhost`. */
  host = "127.0.0.1"
): Promise<E2eTestServer> {
  const server = createServer(handler);
  server.listen(0, host);
  // Rejects if the listen fails.
  await once(server, "listening");
  const { port } = server.address() as AddressInfo;
  return {
    origin: `http://${host}:${port}`,
    port,
    server,
    async close() {
      if (!server.listening) return;
      server.closeAllConnections();
      await new Promise<void>((closed) => server.close(() => closed()));
    },
  };
}
