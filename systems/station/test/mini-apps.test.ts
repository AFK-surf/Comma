// Mini App tools (src/tools/apps.ts) of a coding Session whose Salix Task builds a Mini App (`start.mini_app`):
// app_deploy saves and pushes the worktree before it packs, names the packed files in task.app_deploy and serves them
// to Salix through task.posted_file under the request's key, asked once more with the same key when it did not get
// through; app_logs reads the app's backend log; neither is offered to other Sessions. "GitHub" is a local bare
// repository.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { Coding, repoOf } from "../src/tasks/coding.ts";
import { Tasks } from "../src/tasks/tasks.ts";
import { appTools } from "../src/tools/apps.ts";
import { McpEndpoint, type Tool } from "../src/tools/mcp.ts";
import { Rig } from "./hub-fakes.ts";

type Json = any;

const git = (cwd: string, ...args: string[]) =>
  execFileSync("git", args, { cwd, encoding: "utf8", env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" } }).trim();

const APP = "0b8f8f5e-6a43-4c51-9b7c-1f2f3a4b5c6d";

/// A bare "GitHub" repository acme/app whose main holds comma-app.json and a .gitignore leaving out the builds.
function origin(manifest: Json): { root: string; bare: string } {
  const root = mkdtempSync(join(tmpdir(), "miniapp-origin-"));
  const bare = join(root, "acme", "app.git");
  mkdirSync(bare, { recursive: true });
  git(bare, "init", "--bare", "-b", "main");
  const seed = join(root, "seed");
  git(root, "clone", bare, seed);
  writeFileSync(join(seed, "comma-app.json"), JSON.stringify(manifest));
  writeFileSync(join(seed, ".gitignore"), "dist/\ndist-worker/\n");
  writeFileSync(join(seed, "main.ts"), "console.log(1);\n");
  git(seed, "add", ".");
  git(seed, "commit", "-m", "from the template");
  git(seed, "push", "origin", "HEAD:main");
  return { root, bare };
}

const start = (branch: string, miniApp: boolean) => ({
  requester: "ann@example.com", runtime: "claude",
  repo: { owner: "acme", name: "app", base_ref: "main", branch },
  ...(miniApp ? { mini_app: { app_id: APP } } : {}),
});

/// A Rig whose Sessions work in checkouts of acme/app, with a Salix host answering as `salix` does.
async function rig(manifest: Json, salix: (request: Json, tasks: Tasks) => Promise<Json>) {
  const { root, bare } = origin(manifest);
  const b = new Rig();
  b.hub.coding = new Coding({ reposDir: join(b.dir, "repos"), remote: (o, n) => "file://" + join(root, o, `${n}.git`), givenToken: join(b.dir, "token"), ghConfigDir: join(b.dir, "gh") });
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", (request: Json) => (request.method === "task.hello" ? Promise.resolve({}) : salix(request, tasks)));
  const join_ = async (task: string, branch: string, miniApp: boolean) => {
    const { session } = await tasks.handle("salix", { method: "task.invite", task, start: start(branch, miniApp) });
    const workspace = b.store.getSession(session)!.workspace;
    await b.hub.coding!.checkout(session, workspace, repoOf(start(branch, miniApp))!);
    return { session, workspace };
  };
  return { b, tasks, bare, join: join_, tools: appTools(tasks) };
}

/// Reads every file a task.app_deploy names, as Salix does: a part at a time, through task.posted_file.
async function readFiles(tasks: Tasks, request: Json): Promise<Record<string, Buffer>> {
  const read: Record<string, Buffer> = {};
  for (const file of request.files) {
    const parts: Buffer[] = [];
    for (let offset = 0; offset < file.size; ) {
      const part = await tasks.handle("salix", { method: "task.posted_file", task: request.task, session: request.session, key: request.key, index: file.index, offset });
      assert.equal(part.missing, undefined, `${file.name} is served`);
      const data = Buffer.from(part.data, "base64");
      parts.push(data);
      offset += data.length;
    }
    read[file.name] = Buffer.concat(parts);
  }
  return read;
}

const run = (tools: Tool[], name: string, session: string, args: Json) => tools.find((t) => t.name === name)!.run(session, args);

/// The entries of a tar archive, as tar lists them.
function listTar(bytes: Buffer, gz = false): string[] {
  const dir = mkdtempSync(join(tmpdir(), "miniapp-tar-"));
  const file = join(dir, gz ? "a.tar.gz" : "a.tar");
  writeFileSync(file, bytes);
  return execFileSync("tar", [gz ? "-tzf" : "-tf", file], { encoding: "utf8" }).split("\n").filter((l) => l !== "").sort();
}

test("app_deploy saves and pushes the worktree, then packs what was built and serves it to Salix under the deploy's key", async () => {
  const manifest = { name: "Habit tracker", capabilities: [], storage: ["app"], backend: { entry: "worker/index.ts" } };
  let pushedAtAsk: string | null = null;
  const asked: Json[] = [];
  let read: Record<string, Buffer> = {};
  let bare = "";
  const r = await rig(manifest, async (request, tasks) => {
    asked.push(request);
    // What is deployed is on GitHub already when Salix is asked.
    pushedAtAsk = git(bare, "rev-parse", "comma/app1");
    read = await readFiles(tasks, request);
    return { app_id: request.app_id, version: 3, state: "ready", name: "Habit tracker", summary: "Habit tracker — preview version 3" };
  });
  bare = r.bare;
  const { session, workspace } = await r.join("cnv_1", "comma/app1", true);
  // What the agent built, and a change it did not commit.
  mkdirSync(join(workspace, "dist", "assets", "x".repeat(90)), { recursive: true });
  writeFileSync(join(workspace, "dist", "index.html"), "<!doctype html><div id=root></div>");
  const big = Buffer.alloc(1024 * 1024 + 300, 5);
  writeFileSync(join(workspace, "dist", "assets", "x".repeat(90), "app-with-a-long-name.js"), big);
  symlinkSync("/etc/passwd", join(workspace, "dist", "leak"));
  mkdirSync(join(workspace, "dist-worker"));
  writeFileSync(join(workspace, "dist-worker", "index.js"), "export default { fetch() {} };\n");
  writeFileSync(join(workspace, "main.ts"), "console.log(2);\n");

  const result = JSON.parse(await run(r.tools, "app_deploy", session, { notes: "Add streaks" }));
  assert.deepEqual(result, { app_id: APP, version: 3, state: "ready", name: "Habit tracker", summary: "Habit tracker — preview version 3" });

  const request = asked[0];
  assert.equal(asked.length, 1);
  assert.equal(request.method, "task.app_deploy");
  assert.deepEqual([request.task, request.session, request.app_id, request.notes], ["cnv_1", session, APP, "Add streaks"]);
  // Committed and pushed before it was packed: the commit named is the branch's head on GitHub, with the change.
  assert.equal(request.commit, git(workspace, "rev-parse", "HEAD"));
  assert.equal(pushedAtAsk, request.commit);
  assert.equal(git(r.bare, "show", `${request.commit}:main.ts`), "console.log(2);");
  assert.equal(git(r.bare, "log", "-1", "--format=%s", "comma/app1"), "Deploy: Add streaks");
  assert.deepEqual(request.files.map((f: Json) => f.name), ["comma-app.json", "bundle.tar", "source.tar.gz", "worker.js"]);
  assert.deepEqual(request.files.map((f: Json) => f.size), request.files.map((f: Json) => read[f.name]!.length));
  assert.deepEqual(JSON.parse(read["comma-app.json"]!.toString()), manifest);
  assert.equal(read["worker.js"]!.toString(), "export default { fetch() {} };\n");
  // dist/ as ustar, paths relative to it, regular files only (the symbolic link is left out).
  const long = `assets/${"x".repeat(90)}/app-with-a-long-name.js`;
  assert.deepEqual(listTar(read["bundle.tar"]!), [long, "index.html"]);
  const extracted = mkdtempSync(join(tmpdir(), "miniapp-x-"));
  writeFileSync(join(extracted, "b.tar"), read["bundle.tar"]!);
  execFileSync("tar", ["-xf", "b.tar"], { cwd: extracted });
  assert.deepEqual(readFileSync(join(extracted, long)), big);
  // The source is the commit's, without the builds.
  assert.deepEqual(listTar(read["source.tar.gz"]!, true), [".gitignore", "comma-app.json", "main.ts"]);
  // Answered, the deploy's files are no longer served, nor kept.
  assert.deepEqual(await r.tasks.handle("salix", { method: "task.posted_file", task: "cnv_1", key: request.key, index: 0, offset: 0 }), { missing: "no such post" });
  assert.equal(existsSync(join(dirname(workspace), "app-deploys", request.key)), false);
  await r.b.close();
});

test("a push that fails deploys nothing: Salix is not asked and nothing is packed", async () => {
  let asked = 0;
  const r = await rig({ name: "A" }, async () => (asked++, {}));
  const { session, workspace } = await r.join("cnv_2", "comma/app2", true);
  mkdirSync(join(workspace, "dist"));
  writeFileSync(join(workspace, "dist", "index.html"), "<p>x</p>");
  writeFileSync(join(workspace, "main.ts"), "console.log(3);\n");
  // GitHub refuses the push.
  writeFileSync(join(r.bare, "hooks", "pre-receive"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  await assert.rejects(run(r.tools, "app_deploy", session, {}), /push/);
  assert.equal(asked, 0);
  assert.equal(existsSync(join(dirname(workspace), "app-deploys")), false);
  await r.b.close();
});

test("a build that is missing is said, with what to do, and Salix is not asked", async () => {
  let asked = 0;
  const r = await rig({ name: "A", backend: { entry: "worker/index.ts" } }, async () => (asked++, {}));
  const { session, workspace } = await r.join("cnv_3", "comma/app3", true);
  await assert.rejects(run(r.tools, "app_deploy", session, {}), /dist\/index\.html is missing\. Build the app first/);
  mkdirSync(join(workspace, "dist"));
  writeFileSync(join(workspace, "dist", "index.html"), "<p>x</p>");
  await assert.rejects(run(r.tools, "app_deploy", session, {}), /dist-worker\/index\.js is missing/);
  assert.equal(asked, 0);
  await r.b.close();
});

test("a deploy that did not get through is asked once more with the same key; Salix's validation errors are what the agent is told", async () => {
  const asked: Json[] = [];
  const reads: Record<string, Buffer>[] = [];
  let answer: Json = { error: "invalid", errors: ["name: at most 60 characters", "index.html: over 8 MiB"] };
  const r = await rig({ name: "A" }, async (request, tasks) => {
    asked.push(request);
    reads.push(await readFiles(tasks, request));
    if (asked.length === 1) throw new Error("the connection closed");
    return answer;
  });
  const { session, workspace } = await r.join("cnv_4", "comma/app4", true);
  mkdirSync(join(workspace, "dist"));
  writeFileSync(join(workspace, "dist", "index.html"), "<p>x</p>");
  await assert.rejects(run(r.tools, "app_deploy", session, { notes: "first" }), (error: Error) => {
    assert.match(error.message, /The deploy was refused/);
    assert.match(error.message, /- name: at most 60 characters\n- index\.html: over 8 MiB/);
    return true;
  });
  assert.equal(asked.length, 2);
  assert.equal(new Set(asked.map((a) => a.key)).size, 1, "one key: one Version");
  assert.deepEqual(asked[1], asked[0]);
  // The retry is served the same files.
  assert.deepEqual(reads[1], reads[0]);
  // A refusal is not asked again.
  answer = { app_id: APP, version: 1, state: "ready", name: "A", summary: "A" };
  asked.length = 0;
  const { Refused } = await import("../src/sessions/neighbours.ts");
  const refusing = await rig({ name: "A" }, async (request) => {
    asked.push(request);
    throw new Refused("mini_app_mismatch");
  });
  const other = await refusing.join("cnv_5", "comma/app5", true);
  mkdirSync(join(other.workspace, "dist"));
  writeFileSync(join(other.workspace, "dist", "index.html"), "<p>x</p>");
  await assert.rejects(run(refusing.tools, "app_deploy", other.session, {}), /mini_app_mismatch/);
  assert.equal(asked.length, 1);
  await r.b.close();
  await refusing.b.close();
});

test("app_deploy and app_logs are offered only to a coding Session of a Task with a Mini App, and kept across a restart", async () => {
  const asked: Json[] = [];
  const r = await rig({ name: "A" }, async (request) => (asked.push(request), { lines: ["TypeError: x is undefined", "at fetch (index.js:3)"] }));
  const app = await r.join("cnv_6", "comma/app6", true);
  const plain = await r.join("cnv_7", "comma/app7", false);
  const tokens: Record<string, string> = { app: app.session, plain: plain.session };
  const endpoint = (tools: Tool[]) => new McpEndpoint((token) => tokens[token], tools);
  const rpc = async (e: McpEndpoint, token: string, body: Json) => ((await e.handle("POST", `Bearer ${token}`, JSON.stringify(body))).body as Json);
  const other: Tool = { name: "chat_state", description: "", inputSchema: { type: "object" }, run: async () => "ran" };
  const e = endpoint([other, ...r.tools]);
  const listed = async (token: string) => (await rpc(e, token, { jsonrpc: "2.0", id: 1, method: "tools/list" })).result.tools.map((t: Json) => t.name);
  assert.deepEqual(await listed("app"), ["chat_state", "app_deploy", "app_logs"]);
  assert.deepEqual(await listed("plain"), ["chat_state"]);
  // Not offered: not run either.
  const refused = await rpc(e, "plain", { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "app_logs", arguments: {} } });
  assert.match(refused.error.message, /unknown tool app_logs/);
  await assert.rejects(run(r.tools, "app_logs", plain.session, {}), /has no Mini App/);
  assert.equal(asked.length, 0);

  const logs = await rpc(e, "app", { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "app_logs", arguments: { version: 2 } } });
  assert.equal(logs.result.content[0].text, "TypeError: x is undefined\nat fetch (index.js:3)");
  assert.deepEqual(asked, [{ method: "task.app_logs", task: "cnv_6", session: app.session, app_id: APP, version: 2 }]);

  // A station started again (new Tasks over the same records) still offers them, to the same Sessions.
  const again = new Tasks(r.b.hub, () => null);
  again.attachHost("salix", async () => ({}));
  assert.notEqual(again.miniApp(app.session), null);
  assert.equal(again.miniApp(plain.session), null);
  assert.equal(again.miniApp(app.session)?.appId, APP);
  await r.b.close();
});
