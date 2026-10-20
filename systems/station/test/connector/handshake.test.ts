// Salix refusing the connection's upgrade, over a real WebSocket on loopback: a refused credential (401, 403) is
// written as `auth_required`, which the desktop app answers by minting another credential; any other refusal is
// `reconnecting`. The status file is what the app reads.
import assert from "node:assert/strict";
import { readFileSync, watch } from "node:fs";
import { createServer, type Server } from "node:http";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { Effect, Fiber } from "effect";
import { makeConnector } from "../../src/connector/connector.ts";
import { tempDir } from "./support/temp.ts";

const isolated = { env: { HOME: tempDir(), PATH: "/usr/bin:/bin:/usr/sbin:/sbin" } };

async function refusing(status: number): Promise<{ server: Server; url: string }> {
  const server = createServer((_req, res) => res.writeHead(404).end());
  server.on("upgrade", (_req, socket) => {
    socket.end(`HTTP/1.1 ${status} Refused\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: close\r\n\r\nrefused`);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("no port");
  return { server, url: `http://127.0.0.1:${address.port}` };
}

/** The first status the connector writes once the connection failed (it is written by a rename into its directory). */
function failedStatus(statusPath: string): Promise<any> {
  return new Promise((resolve) => {
    const read = () => {
      try {
        const written = JSON.parse(readFileSync(statusPath, "utf8"));
        if (written.state === "starting" || written.state === "connecting") return;
        watcher.close();
        resolve(written);
      } catch {
        // Not written yet.
      }
    };
    const watcher = watch(dirname(statusPath), read);
    read();
  });
}

async function statusAfterRefusal(status: number) {
  const { server, url } = await refusing(status);
  const statusPath = join(tempDir(), "connector.status.json");
  const c = makeConnector({ ...isolated, root: tempDir(), name: "refused", server: url, token: "expired-token", reconnect: true, statusPath, testClock: true });
  const failed = failedStatus(statusPath);
  const remote = Effect.runFork(c.runRemote);
  try {
    return await failed;
  } finally {
    await Effect.runPromise(Fiber.interrupt(remote));
    await Effect.runPromise(c.close());
    server.close();
  }
}

test("a 401 to the upgrade is a refused credential: auth_required", async () => {
  const status = await statusAfterRefusal(401);
  assert.equal(status.state, "auth_required");
  assert.equal(status.last_error_class, "auth");
  assert.match(status.last_error_message, /\(401\): refused/);
});

test("a 403 to the upgrade is a refused credential: auth_required", async () => {
  assert.equal((await statusAfterRefusal(403)).state, "auth_required");
});

test("a 503 to the upgrade is not about the credential: reconnecting", async () => {
  const status = await statusAfterRefusal(503);
  assert.equal(status.state, "reconnecting");
  assert.equal(status.last_error_class, "server");
});
