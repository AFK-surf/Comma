// A loopback listener a browser returns to after a sign-in (hosts/node.ts's `DesktopPorts.listen`), in the utility
// process: `127.0.0.1:<port>`, open while its scope is. Each GET of its path from `localhost:<port>` or
// `127.0.0.1:<port>` waits for the core to say which page it is shown; anything else is answered here (not found, or
// invalid for an address too long to be a callback). The pages are Main's (it renders them); none loads anything else.
import { HostError } from "@comma/core-kernel";
import { Effect, type Scope } from "effect";
import { createServer, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import type { Loopback, LoopbackPage, LoopbackVisit } from "../host.ts";

/** The most callbacks waiting for the core at once: more are shown the invalid page. */
const MAX_WAITING = 8;

/** Answers `response` with `page`: done once it went out (or the response had ended). */
function send(response: ServerResponse, status: number, page: string): Promise<void> {
  return new Promise<void>((done) => {
    if (response.writableEnded) return done();
    response.writeHead(status).end(page, () => done());
  });
}

export type LoopbackPages = Record<LoopbackPage | "notFound", string>;

export function listenLoopback(input: {
  port: number;
  path: string;
  pages: LoopbackPages;
  csp: string;
}): Effect.Effect<Loopback, HostError, Scope.Scope> {
  return Effect.acquireRelease(
    Effect.callback<{ loopback: Loopback; close: () => void }, HostError>((resume) => {
      const queue: LoopbackVisit[] = [];
      let waiting: ((visit: LoopbackVisit) => void) | null = null;
      const server = createServer((request, response) => {
        response.setHeader("Cache-Control", "no-store");
        response.setHeader("Content-Type", "text/html; charset=utf-8");
        response.setHeader("Content-Security-Policy", input.csp);
        const port = (server.address() as AddressInfo).port;
        let url: URL;
        try {
          if ((request.url?.length ?? 0) > 8192) throw new Error("too long");
          url = new URL(request.url ?? "/", `http://localhost:${port}`);
        } catch {
          void send(response, 400, input.pages.invalid);
          return;
        }
        const host = request.headers.host;
        if (
          request.method !== "GET" ||
          url.pathname !== input.path ||
          (host !== `localhost:${port}` && host !== `127.0.0.1:${port}`)
        ) {
          void send(response, 404, input.pages.notFound);
          return;
        }
        if (queue.length >= MAX_WAITING) {
          void send(response, 400, input.pages.invalid);
          return;
        }
        const visit: LoopbackVisit = {
          url: url.href,
          reply: (page) =>
            Effect.promise(() =>
              send(response, page === "received" ? 200 : 400, input.pages[page])
            ),
        };
        if (waiting) {
          const take = waiting;
          waiting = null;
          take(visit);
        } else queue.push(visit);
      });
      const close = () => {
        server.close();
        server.closeAllConnections();
      };
      server.once("error", (error: NodeJS.ErrnoException) =>
        resume(
          Effect.fail(
            new HostError(
              error.code === "EADDRINUSE" ? "authorization_port_in_use" : error.message
            )
          )
        )
      );
      server.listen(input.port, "127.0.0.1", () => {
        const port = (server.address() as AddressInfo).port;
        resume(
          Effect.succeed({
            close,
            loopback: {
              port,
              next: Effect.callback<LoopbackVisit, HostError>((take) => {
                const next = queue.shift();
                if (next) take(Effect.succeed(next));
                else {
                  waiting = (visit) => take(Effect.succeed(visit));
                  return Effect.sync(() => void (waiting = null));
                }
              }),
            },
          })
        );
      });
      return Effect.sync(close);
    }),
    (open) => Effect.sync(open.close)
  ).pipe(Effect.map((open) => open.loopback));
}
