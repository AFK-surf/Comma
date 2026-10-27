import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { gunzipSync } from "node:zlib";

export type Event = {
  event: string;
  properties: Record<string, unknown>;
  $set_once?: Record<string, unknown>;
};

/**
 * The PostHog host of the analytics builds (./playwright.config.ts): a server
 * of the test itself. A batch the SDK sends with `sendBeacon` as its page
 * leaves reaches the server whole; Playwright's route of the request may have
 * no body for it by then, which lost the event.
 */
export const posthogHost = `http://127.0.0.1:${testPort("COMMA_ANALYTICS_POSTHOG_PORT")}`;
export const apiBaseUrl = `http://127.0.0.1:${testPort("COMMA_ANALYTICS_API_PORT")}`;
/** The website as built (./playwright.config.ts), on the app's host. */
export const websiteOrigin = `http://127.0.0.1:${testPort("COMMA_ANALYTICS_WEBSITE_PORT")}`;

// A free port, chosen once for the run: the config's process picks it, and
// the test workers it starts read it from their environment.
function testPort(variable: string) {
  process.env[variable] ??= execFileSync(
    process.execPath,
    [
      "-e",
      "const s=require('node:net').createServer().listen(0,'127.0.0.1',()=>{process.stdout.write(String(s.address().port));s.close()})",
    ],
    { encoding: "utf8" }
  );
  return process.env[variable];
}

/** Starts the test's PostHog: every event it receives, in arrival order, and each request's URL. */
export async function startPosthogCapture() {
  const events: Event[] = [];
  const requests: string[] = [];
  const observers = new Set<() => void>();
  const server = createServer((request, response) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => {
      requests.push(`${posthogHost}${request.url ?? "/"}`);
      let body = Buffer.concat(chunks);
      if (body.length > 0) {
        if (body[0] === 0x1f && body[1] === 0x8b) body = gunzipSync(body);
        const data = JSON.parse(body.toString());
        events.push(...(Array.isArray(data) ? data : (data.batch ?? [data])));
        for (const observe of observers) observe();
      }
      response.writeHead(request.method === "OPTIONS" ? 204 : 200, {
        "access-control-allow-origin": "*",
        "access-control-allow-headers": "*",
        "content-type": "application/json",
      });
      response.end(request.method === "OPTIONS" ? "" : JSON.stringify({ status: 1 }));
    });
  });
  await new Promise<void>((listening, failed) => {
    server.once("error", failed);
    server.listen(Number(new URL(posthogHost).port), "127.0.0.1", () => listening());
  });
  return {
    events,
    requests,
    waitForEvents: (name: string, count: number) =>
      new Promise<void>((resolve) => {
        const observe = () => {
          if (events.filter((event) => event.event === name).length < count) return;
          observers.delete(observe);
          resolve();
        };
        observers.add(observe);
        observe();
      }),
    close: () =>
      new Promise<void>((closed) => {
        server.closeAllConnections();
        server.close(() => closed());
      }),
  };
}
