import { createServer, request as httpRequest } from "node:http";
import { connect, type AddressInfo } from "node:net";
import type { playwright } from "@vitest/browser-playwright";

// The browser tests' pages have one origin, whatever port the run's server
// listens on: the runner and every test page are documents of
// `http://app-shell.localhost`: a name of this machine, so a secure context
// (Chromium's headless shell ignores --unsafely-treat-insecure-origin-as-secure,
// and a page of `http://app-shell.test` would have no `crypto.subtle`).
// Chromium reaches every host but this machine's own addresses through a
// proxy of the run (`--proxy-server`); the proxy carries that origin's
// requests, and its WebSockets (CONNECT), to the run's server and fails every
// other host's, as a name that does not resolve. What a page
// stores, the links it compares and the media URLs it builds stay the same
// from run to run.

/** The origin of the runner and of every test page. */
export const appShellOrigin = "http://app-shell.localhost";
const appShellHost = new URL(appShellOrigin).host;

// The world's servers (e2e/ui-runtime/node-realm-host.ts), by host name.
const servers = new Map<string, number>();

/**
 * The origin of the world's server `name`: a site of the pages' own, so the
 * session cookie it sets goes with their requests.
 */
export function worldServerOrigin(name: string): string {
  return `http://${name}.${appShellHost}`;
}

/** From now on the proxy carries `origin`'s requests to `port`, or no longer. */
export function routeWorldServer(origin: string, port: number | undefined) {
  const host = new URL(origin).host;
  if (port === undefined) servers.delete(host);
  else servers.set(host, port);
}

/**
 * Starts the run's proxy: requests for `appShellOrigin` go to the server at
 * `127.0.0.1:port`; any other host fails. Resolves to the proxy's port.
 */
export function startAppShellProxy(port: number): Promise<number> {
  const portOf = (host: string) => (host === appShellHost ? port : servers.get(host));
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? "/", appShellOrigin);
    const target = portOf(url.host);
    // Another host's request fails as a network error, not an HTTP answer.
    if (target === undefined) {
      request.socket.destroy();
      return;
    }
    const forwarded = httpRequest(
      {
        host: "127.0.0.1",
        port: target,
        method: request.method,
        path: `${url.pathname}${url.search}`,
        headers: { ...request.headers, host: `127.0.0.1:${target}` },
      },
      (answer) => {
        response.writeHead(answer.statusCode ?? 502, answer.headers);
        answer.pipe(response);
        // A response the server cut short is cut short for the browser too.
        answer.on("close", () => {
          if (!answer.complete) response.destroy();
        });
      }
    );
    forwarded.on("error", () => response.destroy());
    // The browser let go of the request: so does the server's connection.
    response.on("close", () => {
      if (!response.writableFinished) forwarded.destroy();
    });
    request.pipe(forwarded);
  });
  server.on("connect", (request, socket, head) => {
    const [host, tunnelPort] = (request.url ?? "").split(":");
    const target = tunnelPort === "80" ? portOf(host ?? "") : undefined;
    if (target === undefined) {
      socket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
      return;
    }
    const upstream = connect(target, "127.0.0.1", () => {
      socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
    upstream.on("error", () => socket.destroy());
    socket.on("error", () => upstream.destroy());
  });
  // The run ends with its process: the proxy keeps nothing alive.
  server.unref();
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () =>
      resolve((server.address() as AddressInfo).port)
    );
  });
}

type Provider = ReturnType<typeof playwright>;
type Internal = {
  options: { launchOptions?: { args?: string[] } };
  openBrowser(options: unknown): Promise<unknown>;
  openPage(sessionId: string, url: string, options: unknown): Promise<void>;
};

/**
 * The provider, with its browser reaching the run's server as
 * `appShellOrigin` (`startAppShellProxy`) and its runner opened there.
 */
export function onAppShellOrigin(base: Provider, port: number): Provider {
  return {
    ...base,
    providerFactory(project) {
      const provider = base.providerFactory(project);
      const internal = provider as unknown as Internal;
      const openBrowser = internal.openBrowser.bind(provider);
      let proxy: Promise<number> | undefined;
      internal.openBrowser = async (options) => {
        if (!proxy) {
          proxy = startAppShellProxy(port);
          const launch = (internal.options.launchOptions ??= {});
          launch.args = [
            ...(launch.args ?? []),
            `--proxy-server=http://127.0.0.1:${await proxy}`,
            // Names under `localhost` go to the proxy too; this machine's
            // addresses (the world's servers) do not.
            "--proxy-bypass-list=<-loopback>;127.0.0.1;localhost;[::1]",
          ];
        }
        await proxy;
        return openBrowser(options);
      };
      const openPage = internal.openPage.bind(provider);
      internal.openPage = (sessionId, url, options) => {
        const runner = new URL(url);
        return openPage(
          sessionId,
          `${appShellOrigin}${runner.pathname}${runner.search}${runner.hash}`,
          options
        );
      };
      return provider;
    },
  };
}
