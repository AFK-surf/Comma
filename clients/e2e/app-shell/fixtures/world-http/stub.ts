// A server with delays of its own, as a Node realm
// (e2e/ui-runtime/node-realm.ts): e2e/app-shell/world-http.chromium.test.ts
// runs it, a page and the page's worker as one world.
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import type { NodeRealmEntry } from "../../../ui-runtime/node-realm";

export default async function start(): Promise<NodeRealmEntry> {
  const seen: string[] = [];
  let open = 0;
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://stub");
    response.setHeader("access-control-allow-origin", "*");
    if (url.pathname === "/reply") {
      // A streamed reply: a part every 20 ms, the first 20 ms after the request.
      response.writeHead(200, { "content-type": "text/event-stream" });
      open += 1;
      response.once("close", () => {
        open -= 1;
        seen.push(`closed ${url.searchParams.get("of")}`);
      });
      let part = 0;
      // ast-grep-ignore: ts-test-timer
      const timer = setInterval(() => {
        part += 1;
        response.write(`data: part ${part} of ${url.searchParams.get("of")}\n\n`);
        if (part < 3) return;
        clearInterval(timer);
        response.end();
      }, 20);
      response.once("close", () => clearInterval(timer));
      return;
    }
    if (url.pathname === "/echo") {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("end", () => {
        const body = Buffer.concat(chunks).toString();
        seen.push(`echo ${body}`);
        // ast-grep-ignore: ts-test-timer
        setTimeout(
          () => {
            response.writeHead(200, { "content-type": "application/json" });
            response.end(JSON.stringify({ echo: body, order: seen.length }));
          },
          Number(url.searchParams.get("after") ?? 0)
        );
      });
      return;
    }
    response.writeHead(404).end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    info: { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}` },
    calls: {
      seen: () => [...seen],
      open: () => open,
    },
  };
}
