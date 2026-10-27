// Each desktop Workspace's account source (src/accounts/sources.ts, RFC43 §3.1): the machine's own logins untouched
// until a person chooses them, Sessions kept to the chosen source, and the local admin interface (local-admin.ts).
import assert from "node:assert/strict";
import fs, { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { syncBuiltinESMExports } from "node:module";
import { join } from "node:path";
import { after, mock, test } from "node:test";
import { Accounts, type CheckRequest, checkConfig, Refusal } from "../src/accounts/index.ts";
import { addressFile, localAdminAddress, serveLocalAdmin, tokenFile } from "../src/accounts/local-admin.ts";
import { find as findMachineSession, roots as machineRoots } from "../src/read/machine.ts";
import { MachineLogins } from "../src/accounts/machine.ts";
import type { ProfileCheck } from "../src/accounts/profiles.ts";
import { AccountSources, SourceRefusal } from "../src/accounts/sources.ts";
import { fingerprint } from "../src/sessions/decision.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { newSession } from "../src/sessions/lifecycle.ts";
import { Store } from "../src/store/store.ts";
import { Tasks } from "../src/tasks/tasks.ts";
import { approval, exe, fakeLogin, machine, script, temp, until } from "./accounts-fakes.ts";
import { Rig, settle, testClock } from "./hub-fakes.ts";

type Json = any;

/// A desktop connection `id` of Workspace `workspace`, as the desktop app writes it.
function instance(data: string, id: string, workspace: string) {
  mkdirSync(join(data, "connector", "instances"), { recursive: true });
  writeFileSync(join(data, "connector", "instances", `${id}.json`), JSON.stringify({ comma: { workspace_id: workspace }, connector: { connector_token: "t" } }));
}

const lentBy = (id: string, host: string, runtime = "claude") => ({
  id, name: `${id} account`, runtime, credential: "subscription", source: runtime, home: `homes/${id}`,
  share: { id: `sh-${id.replace(/[^a-z0-9]/g, "")}0123456789`, borrowed: true, host },
});
const machineProfile = (runtime: string) => ({ id: `machine-${runtime}`, name: `${runtime} (local)`, runtime, credential: "machine", home: `homes/machine-${runtime}`, env: {} });

/// A machine whose Claude Code and Codex are signed in, each with its login in a file; each CLI run noted in `ran`.
function signedInMachine() {
  const ran = join(temp("ran"), "ran");
  const m = machine({
    claude: `echo claude >> "${ran}"; echo '{"loggedIn": true, "email": "b@x.com", "subscriptionType": "max"}'`,
    codex: `echo codex >> "${ran}"; echo 'Logged in using ChatGPT'`,
    security: `echo security >> "${ran}"; exit 44`,
  });
  mkdirSync(join(m.home, ".claude"));
  writeFileSync(join(m.home, ".claude/.credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "fake-access", expiresAt: 4_102_444_800_000 } }));
  mkdirSync(join(m.home, ".codex"));
  writeFileSync(join(m.home, ".codex/auth.json"), "{}");
  return { ...m, ran: () => (existsSync(ran) ? readFileSync(ran, "utf8").split("\n").filter(Boolean) : []), forget: () => writeFileSync(ran, "") };
}

/// The paths under `home` read through node:fs from now on (sync and promise forms).
function readsUnder(home: string): () => string[] {
  const seen: string[] = [];
  const note = (p: unknown) => {
    const path = String(p);
    if (path.startsWith(join(home, ".claude")) || path.startsWith(join(home, ".codex"))) seen.push(path);
  };
  for (const name of ["readFileSync", "existsSync", "statSync", "openSync", "readdirSync", "realpathSync", "lstatSync"] as const) {
    const original = (fs as Json)[name];
    mock.method(fs, name, (p: unknown, ...rest: unknown[]) => (note(p), original.call(fs, p, ...rest)));
  }
  const readFile = fs.promises.readFile;
  mock.method(fs.promises, "readFile", (p: unknown, ...rest: unknown[]) => (note(p), (readFile as Json).call(fs.promises, p, ...rest)));
  syncBuiltinESMExports();
  return () => [...seen];
}
after(() => {
  mock.restoreAll();
  syncBuiltinESMExports();
});

function accounts(data: string, o: { env: Record<string, string>; managed?: boolean; machine?: MachineLogins; clock?: Json; checkOnStart?: boolean; checked?: string[]; asked?: string[]; approval?: string; check?: (r: CheckRequest) => ProfileCheck }) {
  const config = new ConfigFile(data);
  config.check = checkConfig;
  const fake = join(data, "fake-login");
  script(fake, fakeLogin(o.approval));
  const a = new Accounts({
    data,
    store: Store.open(":memory:", null),
    config,
    env: o.env,
    managed: o.managed,
    loginCommands: { claude: exe(fake), codex: exe(fake) },
    ...(o.machine ? { machine: o.machine } : {}),
    checkOnStart: o.checkOnStart ?? false,
    clock: o.clock,
    check: async (r) => (o.checked?.push(r.home), o.check?.(r) ?? { state: "ok", detail: "fake", models: [], checkedAt: 0 }),
    quota: async (p) => (o.asked?.push(p.id), { state: "ok", windows: [], detail: null, checkedAt: 0 }),
    discover: async (profile) => ({ state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: fingerprint(profile) }),
  });
  a.start();
  return Object.assign(a, { file: config });
}

test("until a Workspace chooses the local sign-in, nothing of the machine's own logins is read, checked, asked or used; an upgraded machine profile included", async () => {
  const m = signedInMachine();
  const data = temp("none");
  // From before account sources: a profile on the machine's Codex, no choice recorded.
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [machineProfile("codex"), { id: "cc", runtime: "claude", home: "homes/cc", env: { ANTHROPIC_API_KEY: "sk-1234567890" } }], connects: [] }));
  instance(data, "inst-a", "ws-a");
  const reads = readsUnder(m.home);
  const time = testClock();
  const checked: string[] = [];
  const asked: string[] = [];
  // The station's own MachineLogins (with the allowance reads), as it runs.
  const a = accounts(data, { env: m.env, clock: time.clock, checkOnStart: true, checked, asked });
  await time.adjust(3_000);
  await settle();
  a.refreshQuotas(true);
  await settle();
  await a.machine!.refresh();
  assert.deepEqual([...new Set(checked)], [join(data, "homes/cc")], "only the profile not on the machine's login checked");
  assert.deepEqual([...new Set(asked)], ["cc"]);
  assert.deepEqual(a.machineLogins(), []);
  await assert.rejects(a.machineToken(), Refusal);
  await assert.rejects(a.check("machine-codex"), (e: Refusal) => e.status === 409);
  assert.deepEqual(a.decisionModels(), []);
  assert.deepEqual(reads(), [], "no file of ~/.claude or ~/.codex touched");
  assert.deepEqual(m.ran(), [], "no CLI asked who is signed in");
  // The upgrade keeps the profile, under `none`: not offered to a Session from the Workspace, nor to any other.
  const view = await a.localAccounts("zh");
  assert.deepEqual(view.workspaces.map((w: Json) => [w.workspaceId, w.runtimes.codex.source, w.runtimes.codex.chosen, w.runtimes.codex.local]), [["ws-a", "none", false, null]]);
  assert.ok(a.profiles().some((p) => p.id === "machine-codex"));
  const profiles = a.profiles();
  assert.throws(() => a.sources.eligible(profiles, "codex", "salix:inst-a", "en"), (e: Error) => e instanceof SourceRefusal && /No account is chosen to run Codex/.test(e.message));
  assert.deepEqual(a.sources.eligible(profiles, "codex", null, "en").map((p) => p.id), []);
  // Chosen: that runtime's login alone is read. Then left: not read any more.
  await a.localSetSource("ws-a", "codex", { source: "local" }, "zh");
  await until(() => m.ran().includes("codex"), "the machine's Codex read");
  assert.equal(m.ran().includes("claude"), false);
  assert.ok(reads().some((p) => p.startsWith(join(m.home, ".codex"))), "what would have been seen is seen now");
  assert.equal(reads().some((p) => p.startsWith(join(m.home, ".claude"))), false);
  assert.equal(a.machineAllowed("codex"), true);
  await a.localSetSource("ws-a", "codex", { source: "none" }, "zh");
  m.forget();
  await a.machine!.refresh();
  assert.deepEqual([m.ran(), a.machineLogins(), a.machineAllowed("codex")], [[], [], false]);
  await a.close();
});

test("a managed Workload ignores desktop local choices and runs Sessions and Tasks only on its connection's cloud accounts", async () => {
  const m = signedInMachine();
  const data = temp("managed");
  const models = (p: Json, model: string) => ({ ...p, models: [model] });
  const profiles = [
    models(machineProfile("claude"), "machine-model"),
    models({ id: "personal-claude", runtime: "claude", home: "homes/personal-claude" }, "personal-claude-model"),
    models({ id: "personal-codex", runtime: "codex", home: "homes/personal-codex" }, "personal-codex-model"),
    models(lentBy("cloud-claude", "salix"), "cloud-claude-model"),
    models(lentBy("cloud-codex", "salix", "codex"), "cloud-codex-model"),
    models(lentBy("other-workspace", "salix:inst-a"), "other-model"),
  ];
  writeFileSync(join(data, "config.json"), JSON.stringify({
    profiles, connects: [],
    accountSources: { "ws-a": { claude: { source: "local", by: "ann", at: 1 }, codex: { source: "local", by: "ann", at: 1 } } },
  }));
  instance(data, "inst-a", "ws-a");
  const reads = readsUnder(m.home);
  const time = testClock();
  const checked: string[] = [];
  const asked: string[] = [];
  const a = accounts(data, {
    env: m.env,
    managed: true,
    machine: new MachineLogins(m.env, async (runtime) => (asked.push(`machine-${runtime}`), null), () => "en", time.clock),
    clock: time.clock, checkOnStart: true, checked, asked,
  });
  const rig = new Rig({ eligible: (p, r, h, l) => a.sources.eligible(p, r, h, l) });
  try {
    rig.edit((raw) => { raw.profiles = profiles; });
    await time.adjust(3_000);
    await settle();
    a.refreshQuotas(true);
    await settle();
    await a.machine!.refresh();
    await a.localAccounts("en");
    assert.deepEqual([a.machineAllowed("claude"), a.machineAllowed("codex"), a.machineLogins()], [false, false, []]);
    assert.ok(checked.includes(join(data, "homes/cloud-claude")), "the startup checks ran");
    assert.equal(checked.includes(join(data, "homes/machine-claude")), false);
    assert.equal(asked.includes("machine-claude"), false);
    await assert.rejects(a.machineToken(), Refusal);
    await assert.rejects(a.check("machine-claude"), (e: Refusal) => e.status === 409);
    assert.equal(a.profiles().some((p) => p.id === "machine-codex"), false, "the signed-in Codex account was not imported");

    const tasks = new Tasks(rig.hub, () => null);
    rig.hub.setTasks(tasks);
    assert.deepEqual(tasks.models("salix"), { claude: ["cloud-claude-model"], codex: ["cloud-codex-model"] });
    for (const runtime of ["claude", "codex"] as const) {
      for (const host of [null, "salix"]) {
        assert.deepEqual(rig.hub.accounts.candidates(runtime, host).map((p) => p.id), [`cloud-${runtime}`]);
        const [key] = newSession(rig.hub, { runtime, createdBy: "ann", host });
        assert.equal(rig.session(key).profile, `cloud-${runtime}`);
        assert.equal(rig.hub.accounts.runOn(key).id, `cloud-${runtime}`);
      }
      const { session } = await tasks.handle("salix", { method: "task.invite", task: `managed-${runtime}`, start: { requester: "ann", runtime } });
      assert.equal(rig.hub.accounts.runOn(session).id, `cloud-${runtime}`);
    }
    assert.deepEqual(rig.hub.accounts.candidates("claude", "salix:inst-a").map((p) => p.id), ["other-workspace"]);
    assert.deepEqual(rig.hub.accounts.candidates("claude", "salix:missing"), []);
    assert.throws(() => newSession(rig.hub, { runtime: "claude", createdBy: "ann", host: "salix", profile: "personal-claude" }), /no claude profile personal-claude/);
    assert.throws(() => newSession(rig.hub, { runtime: "claude", createdBy: "ann", host: "salix", profile: "other-workspace" }), /no claude profile other-workspace/);
    assert.deepEqual(reads(), [], "no personal Claude or Codex login file was read");
    assert.deepEqual(m.ran(), [], "no CLI inspected the machine's sign-in");
  } finally {
    await rig.close();
    await a.close();
  }
});

test("a desktop Workspace's Sessions run only on its chosen source; with none a new one is refused with the reason, and one there stays", async () => {
  const data = temp("pick");
  const sources = new AccountSources({ config: new ConfigFile(data), data });
  for (const [id, ws] of [["inst-a", "ws-a"], ["inst-b", "ws-b"], ["inst-c", "ws-c"]]) instance(data, id, ws);
  sources.set("ws-a", "claude", "local", "ann");
  sources.set("ws-b", "claude", "workspace", "ann");
  const rig = new Rig({ eligible: (p, r, h, l) => sources.eligible(p, r, h, l) });
  rig.edit((raw) => {
    const models = (p: Json, ...m: string[]) => ({ ...p, models: m });
    raw.profiles = [
      models({ id: "cc", runtime: "claude", home: "homes/cc" }, "own"),
      models(machineProfile("claude"), "local"),
      models(lentBy("lent-a", "salix:inst-a"), "lent-a"),
      models(lentBy("lent-b", "salix:inst-b"), "lent-b"),
      models({ id: "cx", runtime: "codex", home: "homes/cx" }, "gpt"),
    ];
  });
  const ids = (host: string | null) => rig.hub.accounts.candidates("claude", host).map((p) => p.id);
  assert.deepEqual(ids("salix:inst-a"), ["machine-claude"]);
  assert.deepEqual(ids("salix:inst-b"), ["lent-b"]);
  // The station's own chats: no Workspace's lent account.
  assert.deepEqual(ids(null), ["cc", "machine-claude"]);
  for (let i = 0; i < 3; i++) {
    assert.equal(rig.session(newSession(rig.hub, { runtime: "claude", createdBy: "ann", host: "salix:inst-a" })[0]).profile, "machine-claude");
    assert.equal(rig.session(newSession(rig.hub, { runtime: "claude", createdBy: "ann", host: "salix:inst-b" })[0]).profile, "lent-b");
  }
  // None: refused, saying why; nothing made.
  const made = rig.store.listSessions().length;
  assert.throws(() => newSession(rig.hub, { runtime: "claude", createdBy: "ann", host: "salix:inst-c" }), /这台电脑没有为这个工作区选择运行 Claude Code 的账号/);
  assert.equal(rig.store.listSessions().length, made);
  // Through the Task path, the host hears the same reason.
  const tasks = new Tasks(rig.hub, () => null);
  rig.hub.setTasks(tasks);
  // What each connection's Salix is told its Tasks may choose: its eligible accounts' models only.
  assert.deepEqual(tasks.models("salix:inst-a"), { claude: ["local"], codex: [] });
  assert.deepEqual(tasks.models("salix:inst-b"), { claude: ["lent-b"], codex: [] });
  assert.deepEqual(tasks.models("salix:inst-c"), { claude: [], codex: [] });
  assert.deepEqual(tasks.models("salix"), { claude: ["own", "local"], codex: ["gpt"] });
  await assert.rejects(tasks.handle("salix:inst-c", { method: "task.invite", task: "t0", start: { requester: "ann", runtime: "claude" } }), /没有为这个工作区选择/);
  const { session } = await tasks.handle("salix:inst-b", { method: "task.invite", task: "t1", start: { requester: "ann", runtime: "claude" } });
  assert.equal(rig.hub.accounts.runOn(session).id, "lent-b");
  // The Workspace's source left for none: the Session there stays on what it runs on.
  sources.set("ws-b", "claude", "none", "ann");
  assert.equal(rig.hub.accounts.runOn(session).id, "lent-b");
  // Moved to the local sign-in: it moves with it, never back to a lent one.
  sources.set("ws-b", "claude", "local", "ann");
  assert.equal(rig.hub.accounts.runOn(session).id, "machine-claude");
  assert.equal(rig.hub.accounts.spend(session), null, "no other source to fall over to");
  await rig.close();
});

test("a model server on this computer: its address checked at the runtime's protocol and kept here, its models what the Workspace's Tasks may run", async () => {
  const data = temp("endpoint");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [], connects: [] }));
  instance(data, "inst-a", "ws-a");
  instance(data, "inst-b", "ws-b");
  const asked: Json[] = [];
  const a = accounts(data, {
    env: {},
    machine: new MachineLogins({}, undefined, () => "en"),
    check: (r) => {
      asked.push({ runtime: r.runtime, kind: r.kind, key: r.key, via: r.via });
      return r.via.endpoint?.includes("ollama.test")
        ? { state: "ok", detail: "2 models", models: r.runtime === "claude" ? ["qwen3:8b", "gemma3"] : ["gpt-oss:20b"], checkedAt: 0 }
        : { state: "failed", detail: "connection refused", models: null, checkedAt: 0 };
    },
  });
  try {
    await assert.rejects(a.localSetSource("ws-a", "claude", { source: "endpoint" }, "en"), (e: Refusal) => e.status === 409 && e.code === "endpoint_missing");
    await assert.rejects(a.localSetSource("ws-a", "claude", { source: "endpoint", endpoint: "ollama.test" }, "en"), (e: Refusal) => e.status === 400);
    assert.deepEqual([asked, a.sources.source("ws-a", "claude")], [[], "none"], "nothing asked or chosen");
    // Claude Code speaks Anthropic's protocol at the server's root, Codex Responses under /v1, however it was typed; both
    // read its models from its OpenAI-style list.
    const view = await a.localSetSource("ws-a", "claude", { source: "endpoint", endpoint: " http://ollama.test/v1/ " }, "en");
    await a.localSetSource("ws-a", "codex", { source: "endpoint", endpoint: "http://ollama.test" }, "en");
    assert.deepEqual(asked, [
      { runtime: "claude", kind: "api-provider", key: "", via: { provider: "custom", endpoint: "http://ollama.test/v1", protocol: "responses" } },
      { runtime: "codex", kind: "api-provider", key: "", via: { provider: "custom", endpoint: "http://ollama.test/v1", protocol: "responses" } },
    ]);
    assert.deepEqual(view.workspaces[0].runtimes.claude, {
      source: "endpoint", chosen: true, workspaceAvailable: false, workspaceAccounts: [], local: null,
      endpoint: { address: "http://ollama.test", keyed: false, state: "ok", detail: "2 models", models: ["qwen3:8b", "gemma3"] },
    });
    const server = a.profiles().find((p) => p.id === "local-model-claude")!;
    assert.deepEqual([server.runtimes, server.model, server.key], [["claude"], "qwen3:8b", undefined], "keyless, its first model by default");
    // Its Tasks run on the server alone; the other Workspace, with no choice, on nothing.
    const rig = new Rig({ eligible: (p, r, h, l) => a.sources.eligible(p, r, h, l) });
    try {
      rig.edit((raw) => { raw.profiles = a.file.raw().profiles; });
      const tasks = new Tasks(rig.hub, () => null);
      rig.hub.setTasks(tasks);
      assert.deepEqual(tasks.models("salix:inst-a"), { claude: ["qwen3:8b", "gemma3"], codex: ["gpt-oss:20b"] });
      assert.deepEqual(tasks.models("salix:inst-b"), { claude: [], codex: [] });
      const { session } = await tasks.handle("salix:inst-a", { method: "task.invite", task: "t-local", start: { requester: "ann", runtime: "claude", model: "gemma3" } });
      assert.deepEqual([rig.hub.accounts.runOn(session).id, rig.session(session).model], ["local-model-claude", "gemma3"]);
    } finally {
      await rig.close();
    }
    // Another Workspace takes the same server without giving its address again.
    const [b] = (await a.localSetSource("ws-b", "claude", { source: "endpoint" }, "en")).workspaces.filter((w: Json) => w.workspaceId === "ws-b");
    assert.equal(b.runtimes.claude.endpoint.address, "http://ollama.test");
    assert.equal(asked.length, 2);
    // A server that does not answer is still kept, saying why, with none of the old one's models.
    const moved = await a.localSetSource("ws-a", "claude", { source: "endpoint", endpoint: "http://lmstudio.test" }, "en");
    assert.deepEqual(moved.workspaces[0].runtimes.claude.endpoint, { address: "http://lmstudio.test", keyed: false, state: "failed", detail: "connection refused", models: [] });
    // A proxy that asks for a key (CLIProxyAPI, LiteLLM): checked and run with it; the view says only that it has one.
    const keyed = await a.localSetSource("ws-a", "claude", { source: "endpoint", endpoint: "http://ollama.test", key: " sk-local " }, "en");
    assert.deepEqual([asked.at(-1)?.key, keyed.workspaces[0].runtimes.claude.endpoint.keyed, a.profiles().find((p) => p.id === "local-model-claude")!.key], ["sk-local", true, "sk-local"]);
    assert.equal(JSON.stringify(keyed).includes("sk-local"), false);
    // The address saved again without one keeps it; an empty one removes it.
    await a.localSetSource("ws-a", "claude", { source: "endpoint", endpoint: "http://ollama.test" }, "en");
    assert.equal(asked.at(-1)?.key, "sk-local");
    const unkeyed = await a.localSetSource("ws-a", "claude", { source: "endpoint", endpoint: "http://ollama.test", key: "" }, "en");
    assert.deepEqual([asked.at(-1)?.key, unkeyed.workspaces[0].runtimes.claude.endpoint.keyed], ["", false]);
    assert.throws(() => a.sources.eligible(a.profiles(), "codex", "salix:inst-b", "en"), (e: Error) => e instanceof SourceRefusal && /No account is chosen/.test(e.message));
  } finally {
    await a.close();
  }
});

/// One request to the local admin interface.
function ask(socketPath: string, method: string, path: string, token: string | null, body?: unknown): Promise<[number, Json]> {
  return new Promise((resolve, reject) => {
    const req = request({ socketPath, method, path, headers: token === null ? {} : { authorization: `Bearer ${token}` } }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve([res.statusCode ?? 0, JSON.parse(Buffer.concat(chunks).toString("utf8"))]));
    });
    req.on("error", reject);
    req.end(body === undefined ? undefined : JSON.stringify(body));
  });
}

test("the local admin interface: refused without its token; each Workspace's runtimes, their source set, the local sign-in started and stopped", { skip: process.platform === "win32" }, async () => {
  const m = signedInMachine();
  const data = temp("local-admin");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [], connects: [] }));
  instance(data, "inst-a", "ws-a");
  const approved = approval(data);
  const a = accounts(data, { env: m.env, machine: new MachineLogins(m.env, undefined, () => "zh"), approval: approved.path });
  const served = await serveLocalAdmin(data, a);
  // Main finds where it listens in the address file.
  const socket = readFileSync(addressFile(data), "utf8");
  assert.equal(socket, join(data, "run", "local-admin.sock"));
  assert.equal(served.address, socket);
  const token = readFileSync(tokenFile(data), "utf8").trim();
  assert.equal(statSync(tokenFile(data)).mode & 0o777, 0o600);
  try {
    assert.deepEqual(await ask(socket, "GET", "/local/accounts", null), [401, { error: "unauthorized" }]);
    assert.deepEqual(await ask(socket, "GET", "/local/accounts", "wrong"), [401, { error: "unauthorized" }]);
    const none = { source: "none", chosen: false, workspaceAvailable: false, workspaceAccounts: [], local: null, endpoint: null };
    assert.deepEqual(await ask(socket, "GET", "/local/accounts", token), [200, { workspaces: [{ workspaceId: "ws-a", name: "ws-a", runtimes: { codex: none, claude: none } }] }]);
    const [unavailable, why] = await ask(socket, "PUT", "/local/accounts/ws-a/claude", token, { source: "workspace" });
    assert.deepEqual([unavailable, why.error], [409, "workspace_accounts_unavailable"]);
    assert.deepEqual((await ask(socket, "POST", "/local/accounts/ws-a/codex/sign-in", token))[1].error, "source_not_local");
    assert.equal((await ask(socket, "POST", "/local/accounts/ws-a/codex/sign-in", token))[0], 409);
    assert.equal((await ask(socket, "PUT", "/local/accounts/ws-x/codex", token, { source: "local" }))[0], 404);
    assert.equal((await ask(socket, "PUT", "/local/accounts/ws-a/codex", token, { source: "elsewhere" }))[0], 400);
    // Local: the machine's login shows, and is used.
    const [status, local] = await ask(socket, "PUT", "/local/accounts/ws-a/codex", token, { source: "local" });
    assert.equal(status, 200);
    assert.deepEqual(local.workspaces[0].runtimes.codex, { source: "local", chosen: true, workspaceAvailable: false, workspaceAccounts: [], local: { installed: true, loggedIn: true, email: null, usable: true, signIn: null }, endpoint: null });
    assert.equal(local.workspaces[0].runtimes.claude.local, null);
    assert.equal(a.sources.choice("ws-a", "codex")?.by, "local-admin");
    await until(() => a.profiles().some((p) => p.id === "machine-codex"), "the machine's Codex taken up");
    // An explicit none is a choice; the default is not.
    const [, explicit] = await ask(socket, "PUT", "/local/accounts/ws-a/claude", token, { source: "none" });
    assert.deepEqual([explicit.workspaces[0].runtimes.claude.source, explicit.workspaces[0].runtimes.claude.chosen], ["none", true]);
    // Its sign-in started, then stopped.
    const [started, signing] = await ask(socket, "POST", "/local/accounts/ws-a/codex/sign-in", token);
    assert.equal(started, 200);
    assert.equal(signing.workspaces[0].runtimes.codex.local.signIn.state, "running");
    const [stopped, after] = await ask(socket, "DELETE", "/local/accounts/ws-a/codex/sign-in", token);
    assert.deepEqual([stopped, after.workspaces[0].runtimes.codex.local.signIn], [200, null]);
    // Once the Workspace lent an account, its source can be chosen.
    a.file.update((raw) => void raw.profiles.push(lentBy("lent-a", "salix:inst-a")));
    // Lent for Claude Code only: not offered, nor taken, for Codex.
    const [, offered] = await ask(socket, "GET", "/local/accounts", token);
    assert.deepEqual([offered.workspaces[0].runtimes.claude.workspaceAvailable, offered.workspaces[0].runtimes.codex.workspaceAvailable], [true, false]);
    assert.equal((await ask(socket, "PUT", "/local/accounts/ws-a/codex", token, { source: "workspace" }))[1].error, "workspace_accounts_unavailable");
    const [chosen, lent] = await ask(socket, "PUT", "/local/accounts/ws-a/claude", token, { source: "workspace" });
    assert.equal(chosen, 200);
    assert.deepEqual(lent.workspaces[0].runtimes.claude, { source: "workspace", chosen: true, workspaceAvailable: true, workspaceAccounts: [{ name: "lent-a account" }], local: null, endpoint: null });
  } finally {
    served.close();
    await a.close();
  }
});

test("on Windows the interface is a pipe of the user's own station, named after its data directory", () => {
  const one = localAdminAddress("C:\\Users\\ann\\AppData\\Roaming\\Comma\\station", "windows");
  assert.match(one, /^\\\\\.\\pipe\\stillfail-local-admin-[0-9a-f]{24}$/);
  assert.equal(localAdminAddress("C:\\Users\\ann\\AppData\\Roaming\\Comma\\station", "windows"), one);
  assert.notEqual(localAdminAddress("C:\\Users\\bob\\AppData\\Roaming\\Comma\\station", "windows"), one);
  assert.equal(localAdminAddress("/data", "macos"), join("/data", "run", "local-admin.sock"));
});

test("the machine's own sessions are read only for a runtime whose local sign-in a Workspace chose", () => {
  const home = temp("sessions-home");
  const id = "11111111-aaaa-bbbb-cccc-000000000002";
  mkdirSync(join(home, ".claude", "projects", "-p"), { recursive: true });
  writeFileSync(join(home, ".claude", "projects", "-p", `${id}.jsonl`), JSON.stringify({ type: "user", cwd: home, timestamp: "2026-09-01T00:00:02.000Z", message: { content: "hi" } }) + "\n");
  const was = process.env.HOME;
  process.env.HOME = home;
  try {
    const opened: string[] = [];
    for (const name of ["opendirSync", "statSync", "openSync"] as const) {
      const original = (fs as Json)[name];
      mock.method(fs, name, (p: unknown, ...rest: unknown[]) => (String(p).startsWith(home) && opened.push(String(p)), original.call(fs, p, ...rest)));
    }
    syncBuiltinESMExports();
    assert.deepEqual(machineRoots([]), { claude: null, codex: null });
    assert.equal(findMachineSession(machineRoots(["codex"]), "claude", id), null);
    assert.deepEqual(opened, [], "nothing of the machine's sessions opened");
    assert.equal(findMachineSession(machineRoots(["claude"]), "claude", id)?.id, id);
    assert.ok(opened.length > 0);
  } finally {
    process.env.HOME = was;
  }
});
