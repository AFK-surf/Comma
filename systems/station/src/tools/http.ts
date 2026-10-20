// The agents' door (server.rs `serve_mcp`): loopback only. /mcp is the MCP endpoint, /jobs/notify what a job says
// (`stillfail-job notify`), /health that the station answers. Its socket is the launcher's (fd 3), so a handover has
// no gap: the old station stops taking connections and finishes the calls it has; the new one takes the next.
import { type IncomingMessage, type Server, createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { log } from "../ops/log.ts";
import type { McpEndpoint } from "./mcp.ts";
import { wall } from "../ops/fibers.ts";

/// What /jobs/notify does with a job's words: a status and a body (jobs.ts `notifyEndpoint`).
export type Notified = (authorization: string | undefined, body: Buffer) => { status: number; body: unknown };

/// A job's words: no more than this is read.
const NOTIFY_LIMIT = 64 * 1024;

export type AgentsDoor = {
  /// Where agents reach it: `http://127.0.0.1:<port>/mcp` (the launcher's entrance's port when it has one).
  url: string;
  /// Where it listens.
  port: number;
  /// Stops taking connections; done once the calls it has are answered (or after `graceMs`).
  close(graceMs?: number): Promise<void>;
};

/// A request's body, up to `limit` bytes (null when longer).
function bodyOf(req: IncomingMessage, limit: number): Promise<Buffer | null> {
  return new Promise((resolve, reject) => {
    const parts: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size <= limit) parts.push(chunk);
    });
    req.on("end", () => resolve(size > limit ? null : Buffer.concat(parts)));
    req.on("error", reject);
  });
}

/// Opens the door on the launcher's fd, or on `port` at 127.0.0.1 (0: any free one): with no launcher, or behind a
/// launcher's entrance (`shown`, its port, is then the one agents are told: launcher.ts `ports`).
export function openAgentsDoor(at: { fd: number } | { port: number; shown?: number }, mcp: McpEndpoint, notified: Notified): Promise<AgentsDoor> {
  let busy = 0;
  let idle: (() => void) | null = null;
  const server: Server = createServer(async (req, res) => {
    busy++;
    const send = (status: number, body: unknown) => {
      if (body === undefined) res.writeHead(status).end();
      else res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
    };
    try {
      const path = new URL(req.url ?? "/", "http://agents").pathname;
      if (path === "/health") send(200, { ok: true });
      else if (path === "/jobs/notify" && req.method === "POST") {
        const body = await bodyOf(req, NOTIFY_LIMIT);
        if (body === null) send(400, { error: "length limit exceeded" });
        else {
          const answer = notified(req.headers.authorization, body);
          send(answer.status, answer.body);
        }
      } else if (path === "/mcp") {
        const body = (await bodyOf(req, Number.MAX_SAFE_INTEGER))!;
        const reply = await mcp.handle(req.method ?? "GET", req.headers.authorization, body);
        send(reply.status, reply.body);
      } else res.writeHead(404, { "content-type": "text/plain" }).end();
    } catch (error) {
      log.warn("mcp", "a request to the agents' door failed", { error: (error as Error).message });
      if (!res.headersSent) send(500, { error: (error as Error).message });
      else res.destroy();
    } finally {
      if (--busy === 0) idle?.();
    }
  });
  // Agents call one after another on a kept connection: an idle one is not kept past the calls.
  server.keepAliveTimeout = 5_000;
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.once("listening", () => {
      server.off("error", reject);
      server.on("error", (e) => log.error("mcp", "the agents' door failed", { error: e.message }));
      const port = (server.address() as AddressInfo).port;
      resolve({
        url: `http://127.0.0.1:${"shown" in at && at.shown !== undefined ? at.shown : port}/mcp`,
        port,
        close: (graceMs = 30_000) =>
          new Promise<void>((done) => {
            server.close();
            server.closeIdleConnections();
            if (busy === 0) return done();
            // How long the agents' calls under way are given: their time, the machine's.
            const timer = wall.after(graceMs, () => {
              server.closeAllConnections();
              done();
            });
            idle = () => {
              timer();
              server.closeAllConnections();
              done();
            };
          }),
      });
    });
    if ("fd" in at) server.listen({ fd: at.fd });
    else server.listen(at.port, "127.0.0.1");
  });
}
