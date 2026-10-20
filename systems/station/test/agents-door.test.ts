// The agents' door: /mcp to the endpoint, /jobs/notify to the jobs, /health; closing waits for the calls it has.
import assert from "node:assert/strict";
import { test } from "node:test";
import { openAgentsDoor } from "../src/tools/http.ts";
import { McpEndpoint } from "../src/tools/mcp.ts";
import { settle } from "./hub-fakes.ts";

test("the agents' door answers /mcp, /jobs/notify and /health, and finishes its calls when closed", async () => {
  let release: () => void = () => {};
  const slow = new Promise<void>((r) => (release = r));
  let arrived: () => void = () => {};
  const called = new Promise<void>((r) => (arrived = r));
  const mcp = new McpEndpoint((t) => (t === "tok" ? "s1" : undefined), [
    { name: "wait", description: "", inputSchema: {}, run: async (key) => (arrived(), await slow, `done ${key}`) },
  ]);
  const said: string[] = [];
  const door = await openAgentsDoor({ port: 0 }, mcp, (auth, body) => {
    if (auth !== "Bearer job") return { status: 400, body: { error: "unknown job token" } };
    said.push(body.toString());
    return { status: 200, body: { ok: true } };
  });
  const base = `http://127.0.0.1:${door.port}`;
  assert.deepEqual(await (await fetch(`${base}/health`)).json(), { ok: true });
  assert.equal((await fetch(`${base}/nothing`)).status, 404);
  const notify = await fetch(`${base}/jobs/notify`, { method: "POST", headers: { authorization: "Bearer job" }, body: "built" });
  assert.deepEqual([notify.status, said], [200, ["built"]]);
  assert.equal((await fetch(`${base}/jobs/notify`, { method: "POST", headers: { authorization: "Bearer job" }, body: "x".repeat(70_000) })).status, 400);
  assert.equal((await fetch(door.url, { method: "POST", body: "{}" })).status, 401);
  const call = fetch(door.url, {
    method: "POST",
    headers: { authorization: "Bearer tok", "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "wait", arguments: {} } }),
  });
  // Closed once the door has the call (not on a guess of how long it takes to get there: a busy machine took longer,
  // and the call came to a door already closed).
  await called;
  let closed = false;
  const closing = door.close().then(() => (closed = true));
  // What is queued runs (closing it with no call under way ends there): still open while the call is.
  await settle();
  assert.equal(closed, false);
  release();
  const answer: any = await (await call).json();
  assert.equal(answer.result.content[0].text, "done s1");
  await closing;
  await assert.rejects(fetch(`${base}/health`));
});
