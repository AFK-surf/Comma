// The local admin interface (RFC43 §3.3): what the desktop app's Main reads and sets of this computer's account sources
// (sources.ts) without the mesh or the network. HTTP on the Unix socket <data>/run/local-admin.sock (on Windows the
// named pipe \\.\pipe\stillfail-local-admin-<hash of the data directory>, one per user's station), each request
// carrying `Authorization: Bearer <token>`, the token in <data>/local-admin.token (0600, made at the first start; on
// Windows the data directory's own access, under the user's profile). Where it listens is written to
// <data>/run/local-admin.address once it does. Only a process that can read the station's data directory can ask.
//
//   GET    /local/accounts                                  every Workspace's runtimes: source, whether chosen, lent accounts, the local login, the model server
//   PUT    /local/accounts/<workspace>/<runtime>            {"source": "none"|"local"|"endpoint"|"workspace", "endpoint"?: address, "key"?}
//   POST   /local/accounts/<workspace>/<runtime>/sign-in    the machine's sign-in started (under `local` only)
//   DELETE /local/accounts/<workspace>/<runtime>/sign-in    that sign-in stopped
//
// Each answers the GET view. Refused: 401 `unauthorized`; 409 `workspace_accounts_unavailable` (the Workspace lent no
// account that runs the runtime), `endpoint_missing` (`endpoint` chosen with no model server's address given before)
// and `source_not_local`; 404 `unknown_workspace`; 400 for a runtime, source or address it does not know.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeSync, closeSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { join } from "node:path";
import { Effect, Layer } from "effect";
import { langOfBrowser } from "../ops/loopback.ts";
import type { Lang } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { runtimeDir, writePrivate } from "../ops/files.ts";
import { wall } from "../ops/fibers.ts";
import { platform } from "../platform/index.ts";
import { Paths } from "../services.ts";
import { Agents } from "../sessions/agents.ts";
import { Refusal } from "./index.ts";

type Json = any;

/// What the interface asks of the accounts (index.ts).
export type LocalAccounts = {
  localAccounts(lang: Lang): Promise<Json>;
  localSetSource(workspace: string, runtime: string, input: Record<string, unknown>, lang: Lang): Promise<Json>;
  localSignIn(workspace: string, runtime: string, lang: Lang): Promise<Json>;
  localStopSignIn(workspace: string, runtime: string, lang: Lang): Promise<Json>;
};

const MAX_BODY = 64 * 1024;
export const tokenFile = (data: string) => join(data, "local-admin.token");
export const socketFile = (data: string) => join(runtimeDir(data), "local-admin.sock");
/// The file that says where the interface listens (the socket's path, or the pipe's).
export const addressFile = (data: string) => join(runtimeDir(data), "local-admin.address");
/// Where the interface listens on a machine (`os` as platform.ts names it): the socket in the data directory, or a pipe
/// named after it.
export function localAdminAddress(data: string, os: string): string {
  if (os !== "windows") return socketFile(data);
  return `\\\\.\\pipe\\stillfail-local-admin-${createHash("sha256").update(data).digest("hex").slice(0, 24)}`;
}
/// How long a pipe still held by the station process before (a handover) is waited for.
const PIPE_WAIT_MS = 60_000;

/// The token, made (0600) when there is none.
export function localAdminToken(data: string): string {
  const path = tokenFile(data);
  mkdirSync(data, { recursive: true });
  if (!existsSync(path)) {
    try {
      const fd = openSync(path, "wx", 0o600);
      try {
        writeSync(fd, randomBytes(32).toString("hex"));
      } finally {
        closeSync(fd);
      }
    } catch (e) {
      // Made by another station process at the same moment: its token is the one.
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
    }
  }
  chmodSync(path, 0o600);
  return readFileSync(path, "utf8").trim();
}

const send = (res: ServerResponse, status: number, body: Json) => {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }).end(JSON.stringify(body));
};

function authorized(header: string | undefined, token: string): boolean {
  const given = Buffer.from(header ?? "");
  const expected = Buffer.from(`Bearer ${token}`);
  return token !== "" && given.length === expected.length && timingSafeEqual(given, expected);
}

function readBody(req: IncomingMessage): Promise<Json> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Refusal(413, "the request is too large", "too_large"));
        req.destroy();
      } else chunks.push(c);
    });
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      if (text.trim() === "") return resolve({});
      try {
        const v = JSON.parse(text);
        resolve(v !== null && typeof v === "object" && !Array.isArray(v) ? v : {});
      } catch {
        reject(new Refusal(400, "the body is not JSON", "bad_request"));
      }
    });
    req.on("error", reject);
  });
}

const ROUTE = /^\/local\/accounts\/([^/]+)\/([^/]+)(\/sign-in)?$/;

/// Answers one request of the interface.
export function localAdminHandler(accounts: LocalAccounts, token: () => string) {
  return async (req: IncomingMessage, res: ServerResponse) => {
    if (!authorized(req.headers.authorization, token())) return send(res, 401, { error: "unauthorized" });
    const lang = langOfBrowser(req.headers);
    const path = new URL(req.url ?? "/", "http://local").pathname;
    try {
      if (path === "/local/accounts" && req.method === "GET") return send(res, 200, await accounts.localAccounts(lang));
      const found = ROUTE.exec(path);
      if (!found) return send(res, 404, { error: "not_found" });
      const [workspace, runtime] = [decodeURIComponent(found[1]!), decodeURIComponent(found[2]!)];
      if (found[3] === undefined && req.method === "PUT") return send(res, 200, await accounts.localSetSource(workspace, runtime, await readBody(req), lang));
      if (found[3] !== undefined && req.method === "POST") return send(res, 200, await accounts.localSignIn(workspace, runtime, lang));
      if (found[3] !== undefined && req.method === "DELETE") return send(res, 200, await accounts.localStopSignIn(workspace, runtime, lang));
      return send(res, 405, { error: "method_not_allowed" });
    } catch (e) {
      if (e instanceof Refusal) return send(res, e.status, { error: e.code ?? "refused", message: e.message });
      log.warn("local-admin", "a request failed", { path, error: (e as Error).message });
      return send(res, 500, { error: "failed", message: (e as Error).message });
    }
  };
}

const listen = (server: Server, path: string) =>
  new Promise<void>((resolve, reject) => {
    const failed = (e: Error) => reject(e);
    server.once("error", failed);
    server.listen(path, () => (server.off("error", failed), resolve()));
  });

/// The interface listening, its address written. On a socket, a next station process takes it over in one step (bound
/// under its own name, then renamed in place), so the one before, closing, removes nothing of it. A pipe has one
/// holder: one still held by the process before is waited for.
export async function serveLocalAdmin(data: string, accounts: LocalAccounts, os: string = platform.os): Promise<{ server: Server; address: string; close(): void }> {
  const token = localAdminToken(data);
  const address = localAdminAddress(data, os);
  mkdirSync(runtimeDir(data), { recursive: true, mode: 0o700 });
  const server = createServer(localAdminHandler(accounts, () => token));
  if (os === "windows") {
    const until = wall.now() + PIPE_WAIT_MS;
    for (;;) {
      try {
        await listen(server, address);
        break;
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "EADDRINUSE" || wall.now() > until) throw e;
        await wall.sleep(1000);
      }
    }
    writePrivate(addressFile(data), address);
    return { server, address, close: () => void server.close() };
  }
  const own = join(runtimeDir(data), `local-admin.${process.pid}.sock`);
  rmSync(own, { force: true });
  await listen(server, own);
  chmodSync(own, 0o600);
  renameSync(own, address);
  const ino = statSync(address).ino;
  writePrivate(addressFile(data), address);
  return {
    server,
    address,
    close() {
      server.close();
      try {
        if (statSync(address).ino === ino) rmSync(address, { force: true });
      } catch {}
    },
  };
}

/// The interface, for as long as the station runs.
export const LocalAdminLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const { data } = yield* Paths;
    const agents = yield* Agents;
    // Not waited for: a pipe the station before still holds keeps nothing else from starting.
    const state: { served: { close(): void } | null; closed: boolean } = { served: null, closed: false };
    yield* Effect.addFinalizer(() =>
      Effect.sync(() => {
        state.closed = true;
        state.served?.close();
      }),
    );
    void serveLocalAdmin(data, agents.accounts).then(
      (served) => {
        if (state.closed) return served.close();
        state.served = served;
        log.info("local-admin", "listening", { address: served.address });
      },
      (error: Error) => log.error("local-admin", "the local admin interface is not had", { error: error.message }),
    );
  }),
);
