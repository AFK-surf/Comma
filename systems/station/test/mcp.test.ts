// The MCP endpoint, as the Rust station's mcp.rs's tests have it.
import assert from "node:assert/strict";
import { test } from "node:test";
import { McpEndpoint, OUTWARD, type Tool, UNBOUND_REFUSAL } from "../src/tools/mcp.ts";

const echo: Tool = {
  name: "echo",
  description: "echo",
  inputSchema: { type: "object" },
  run: async (key, args) => {
    if ("fail" in args) throw new Error("nope");
    return `${key}:${typeof args.text === "string" ? args.text : ""}`;
  },
};
const endpoint = () => new McpEndpoint((token) => (token === "good" ? "session-1" : undefined), [echo]);
const rpc = (e: McpEndpoint, token: string | undefined, body: unknown) => e.handle("POST", token ? `Bearer ${token}` : undefined, JSON.stringify(body));
const tools = (names: string[]): Tool[] => names.map((name) => ({ name, description: "", inputSchema: { type: "object" }, run: async () => `${name} ran` }));

test("requests without a known token are refused", async () => {
  const e = endpoint();
  assert.equal((await rpc(e, undefined, { jsonrpc: "2.0", id: 1, method: "tools/list" })).status, 401);
  assert.equal((await rpc(e, "bad", { jsonrpc: "2.0", id: 1, method: "tools/list" })).status, 401);
});

test("initialize, list and call run on behalf of the token's session", async () => {
  const e = endpoint();
  const init: any = (await rpc(e, "good", { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } })).body;
  assert.equal(init.result.protocolVersion, "2025-06-18");
  assert.equal(init.result.serverInfo.name, "still.fail");
  assert.equal((await rpc(e, "good", { jsonrpc: "2.0", method: "notifications/initialized" })).status, 202);
  const list: any = (await rpc(e, "good", { jsonrpc: "2.0", id: 2, method: "tools/list" })).body;
  assert.equal(list.result.tools[0].name, "echo");
  const call: any = (await rpc(e, "good", { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "echo", arguments: { text: "hi" } } })).body;
  assert.deepEqual(call.result, { content: [{ type: "text", text: "session-1:hi" }] });
  const failed: any = (await rpc(e, "good", { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "echo", arguments: { fail: true } } })).body;
  assert.deepEqual([failed.result.isError, failed.result.content[0].text], [true, "nope"]);
  assert.equal((await e.handle("GET", "Bearer good", "")).status, 405);
});

test("while the station is in no workspace, outward tools are refused and the rest run", async () => {
  const names = ["chat_post", "slack_api", "job_start", "station_list", "station_job", "station_file", "chat_state", "chat_history", "chat_list", "chat_read", "session_history", "job_list", "job_log", "job_stop"];
  let out = true;
  const e = new McpEndpoint(() => "s", tools(names), () => (out ? UNBOUND_REFUSAL : undefined));
  const call = async (name: string) => ((await rpc(e, "t", { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: {} } })).body as any).result;
  for (const name of names) {
    const result = await call(name);
    if (OUTWARD.includes(name)) assert.deepEqual([result.isError, result.content[0].text], [true, UNBOUND_REFUSAL], name);
    else assert.deepEqual(result, { content: [{ type: "text", text: `${name} ran` }] }, name);
  }
  assert.deepEqual(OUTWARD, ["chat_post", "slack_api", "job_start", "station_list", "station_job", "station_file"]);
  // Listed all the same: an agent that read the list before keeps the same tools.
  const list: any = (await rpc(e, "t", { jsonrpc: "2.0", id: 2, method: "tools/list" })).body;
  assert.equal(list.result.tools.length, names.length);
  out = false;
  for (const name of OUTWARD) assert.equal((await call(name)).content[0].text, `${name} ran`);
});
