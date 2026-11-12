// Salix's tools in a Session of a Task Salix keeps (src/tools/salix.ts, src/tasks/tasks.ts `salixTools`,
// `salixToolCall`): offered to such a Session alone, asked of Salix as task.tools and task.tool_call for that Session,
// and the agent told the tool's result or why there was none. The `comma` command the station writes for its agents
// (src/connector/comma-cli-bin.ts).
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { commaOnPath } from "../src/connector/comma-cli-bin.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { Tasks } from "../src/tasks/tasks.ts";
import { salixTools } from "../src/tools/salix.ts";
import { Rig, settle } from "./hub-fakes.ts";

type Json = any;

const LISTED = [{ name: "fs.write_file", description: "Create a visible file, or replace one whole.", input_schema: { type: "object", properties: { path: { type: "string" }, content: { type: "string" } } } }];

/// A Rig of a managed station with Salix as a host, answering as `salix` does; what Salix was asked.
function rig(managed = true) {
  const b = new Rig();
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.offerSalixTools(managed);
  const asked: Json[] = [];
  const salix = async (request: Json): Promise<Json> => {
    asked.push(request);
    switch (request.method) {
      case "task.hello":
        return {};
      case "task.tools":
        return { tools: LISTED };
      case "task.tool_call":
        switch (request.tool) {
          case "fs.write_file":
            return { tool: request.tool, error: false, content: `wrote ${String(request.args.content ?? "").length} bytes to ${request.args.path}` };
          case "env.exec":
            return { error: "too_many_calls", message: "this station has 4 calls in flight; wait for one to answer" };
          case "fs.read_file":
            return { tool: request.tool, error: true, content: "error: no such file: /none" };
          case "web.read_pages":
            return { tool: request.tool, error: false, content: "a long page", truncated: true };
          default:
            throw new Error(`unexpected tool ${request.tool}`);
        }
      default:
        throw new Error(`unexpected request ${request.method}`);
    }
  };
  tasks.attachHost("salix", salix);
  return { b, tasks, asked, tools: salixTools(tasks) };
}

const run = (tools: ReturnType<typeof salixTools>, name: string, session: string, args: Json = {}) => tools.find((t) => t.name === name)!.run(session, args);

test("a Session of a Task Salix keeps is offered Salix's tools, and calls them as that Task's Worker", async () => {
  const r = rig();
  const { session } = await r.tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: { requester: "ann@example.com", runtime: "claude" } });
  assert.ok(r.tools.every((t) => t.offered!(session)), "offered to the Task's Session");

  assert.deepEqual(JSON.parse(await run(r.tools, "salix_tools", session)), LISTED);
  assert.deepEqual(r.asked.at(-1), { method: "task.tools", task: "cnv_1", session });

  assert.equal(await run(r.tools, "salix_call", session, { tool: "fs.write_file", args: { path: "/a.md", content: "hello" } }), "wrote 5 bytes to /a.md");
  assert.deepEqual(r.asked.at(-1), { method: "task.tool_call", task: "cnv_1", session, tool: "fs.write_file", args: { path: "/a.md", content: "hello" } });
  // No args: an empty input.
  assert.equal(await run(r.tools, "salix_call", session, { tool: "fs.write_file" }), "wrote 0 bytes to undefined");
  assert.deepEqual(r.asked.at(-1).args, {});

  // What Salix refused, or the tool failed, is a tool error; a cut result says so.
  await assert.rejects(run(r.tools, "salix_call", session, { tool: "env.exec", args: { cmd: "ls" } }), /refused \(too_many_calls\): this station has 4 calls in flight/);
  await assert.rejects(run(r.tools, "salix_call", session, { tool: "fs.read_file", args: { path: "/none" } }), /no such file: \/none/);
  assert.match(await run(r.tools, "salix_call", session, { tool: "web.read_pages", args: {} }), /^a long page\n\n\[truncated/);
  await assert.rejects(run(r.tools, "salix_call", session, { args: {} }), /tool is the name of a Salix tool/);
  await assert.rejects(run(r.tools, "salix_call", session, { tool: "fs.write_file", args: [] }), /args is an object/);

  // Its agent is told of them, with the station's instructions, once it takes a turn.
  await r.tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "write it up", declared: null, at: 0 }], through: 1 });
  await settle();
  const told = r.b.claude.last().options.instructions;
  assert.match(told, /# Comma tools/);
  assert.match(told, /salix_tools lists them/);
  assert.match(told, /`comma tools`/);
  await r.b.close();
});

test("on a person's own station, a Task Salix keeps has no Salix tools, and its agent is not told of them", async () => {
  const r = rig(false);
  const { session } = await r.tasks.handle("salix", { method: "task.invite", task: "cnv_3", start: { requester: "ann@example.com", runtime: "claude" } });
  assert.ok(r.tools.every((t) => !t.offered!(session)));
  await assert.rejects(run(r.tools, "salix_tools", session), /takes part in no Task Salix keeps/);
  await r.tasks.handle("salix", { method: "task.put", task: "cnv_3", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "write it up", declared: null, at: 0 }], through: 1 });
  await settle();
  assert.doesNotMatch(r.b.claude.last().options.instructions, /# Comma tools/);
  await r.b.close();
});

test("a Session of the station's own chat is told nothing of Salix's tools", async () => {
  const r = rig();
  const [own, chat] = newSession(r.b.hub, { runtime: "claude", createdBy: "ann@example.com", title: "own" });
  say(r.b.hub, chat.id, "ann@example.com", "hello");
  await settle();
  const told = r.b.claude.sessions.find((s) => s.options.route === own)?.options.instructions ?? "";
  assert.ok(told !== "", "the agent was opened");
  assert.doesNotMatch(told, /# Comma tools/);
  await r.b.close();
});

test("a Session of no such Task has no Salix tools, nor has one while Salix is not connected", async () => {
  const r = rig();
  const [own] = newSession(r.b.hub, { runtime: "claude", createdBy: "ann@example.com", title: "own" });
  assert.ok(r.tools.every((t) => !t.offered!(own)));
  await assert.rejects(run(r.tools, "salix_tools", own), /takes part in no Task Salix keeps/);

  const { session } = await r.tasks.handle("salix", { method: "task.invite", task: "cnv_2", start: { requester: "ann@example.com", runtime: "claude" } });
  assert.ok(r.tools.every((t) => t.offered!(session)));
  r.tasks.attachHost("salix", null);
  assert.ok(r.tools.every((t) => !t.offered!(session)), "not while Salix is away");
  await assert.rejects(run(r.tools, "salix_call", session, { tool: "fs.write_file" }), /takes part in no Task Salix keeps/);
  await r.b.close();
});

test("the station writes the agents' comma command, which runs this station, first on the PATH", () => {
  const data = mkdtempSync(join(tmpdir(), "comma-bin-"));
  const env: Record<string, string | undefined> = { PATH: "/usr/bin:/bin" };
  const bin = commaOnPath(data, env, ["/opt/comma-station/node/bin/node", "/opt/comma-station/station/main.js", "run"], "/opt/comma-station/node/bin/node");
  assert.equal(bin, join(data, "bin"));
  assert.equal(readFileSync(join(bin, "comma"), "utf8"), `#!/bin/sh\nexec '/opt/comma-station/node/bin/node' '/opt/comma-station/station/main.js' comma-client "$@"\n`);
  assert.equal(statSync(join(bin, "comma")).mode & 0o777, 0o700);
  assert.equal(env.PATH, `${bin}:/usr/bin:/bin`);
  // Written again (the station restarted): once on the PATH.
  commaOnPath(data, env, ["/opt/comma-station/node/bin/node", "/opt/comma-station/station/main.js"], "/opt/comma-station/node/bin/node");
  assert.equal(env.PATH, `${bin}:/usr/bin:/bin`);
});
