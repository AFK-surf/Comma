// The accounts' admin routes (admin/tests.rs: profiles, sign-ins, allowances, machine profiles, automatic decisions),
// on a station of the test's own: a config.json in a temp directory, a store, stand-in checks, allowances and login
// commands. Nothing reaches a provider, a keychain or a real login.
import type { Clock } from "effect";
import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Accounts, type AccountsDeps } from "../src/accounts/index.ts";
import { checkConfig } from "../src/accounts/check.ts";
import { MachineLogins } from "../src/accounts/machine.ts";
import { accessKind, isMachine } from "../src/agents/profiles.ts";
import { routes } from "../src/api/routes/accounts.ts";
import type { Request } from "../src/api/request.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { profileEnv } from "../src/agents/profiles.ts";
import { fingerprint } from "../src/sessions/decision.ts";
import { DEFAULT_POLICY } from "../src/sessions/archive-policy.ts";
import { Store } from "../src/store/store.ts";
import { approval, exe, fakeLogin, machine as fakeMachine, script, temp, until, upon } from "./accounts-fakes.ts";
import { settle, testClock } from "./hub-fakes.ts";

const viewer = (email: string, role: string) => ({ sub: `sub-${email}`, email, name: "", role, workspace: "ws", device: "d" });
const owner = viewer("owner@example.com", "owner");
const member = viewer("dev@example.com", "member");

type Rig = Awaited<ReturnType<typeof rig>>;

async function rig(o: { approval?: string; data?: string; store?: Store; quota?: { n: number }; resetQuota?: AccountsDeps["resetQuota"]; machine?: MachineLogins; discover?: AccountsDeps["discover"]; check?: AccountsDeps["check"]; clock?: Clock.Clock } = {}) {
  const data = o.data ?? temp("routes");
  const path = join(data, "config.json");
  if (!existsSync(path)) {
    writeFileSync(
      path,
      JSON.stringify({
        profiles: [
          { id: "cc", runtime: "claude", home: "homes/cc", env: { ANTHROPIC_API_KEY: "sk-very-secret-value", ANTHROPIC_BASE_URL: "https://example" } },
          { id: "cx", runtime: "codex", home: "homes/cx" },
        ],
        connects: [{ id: "ds", kind: "slack", mode: "multi-session", bind: { runtime: "claude" }, slack: { appToken: "xapp-1-aaaaaaaaaaaa", botToken: "xoxb-bbbbbbbbbbbb", appId: "A0DS", team: { id: "T0", name: "Acme" }, botName: "ember" } }],
      }),
    );
  }
  const config = new ConfigFile(data);
  config.check = checkConfig;
  const store = o.store ?? Store.open(":memory:", null);
  const fake = join(data, "fake-login");
  script(fake, fakeLogin(o.approval));
  const quota = o.quota;
  const accounts = new Accounts({
    data,
    store,
    config,
    loginCommands: { claude: exe(fake), codex: exe(fake) },
    machine: o.machine ?? null,
    checkOnStart: false,
    check: o.check ?? (async () => ({ state: "ok", detail: "fake", models: [], checkedAt: Date.now() })),
    quota: quota
      ? async () => {
          quota.n++;
          return { state: "ok", windows: [{ label: "5 小时", usedPercent: 12, resetsAt: null }], detail: null, checkedAt: Date.now() };
        }
      : null,
    resetQuota: o.resetQuota ?? null,
    discover: o.discover ?? (async (profile) => ({ state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: fingerprint(profile) })),
    clock: o.clock,
  });
  accounts.start();
  const table = routes({
    accounts,
    overview: (r) => ({ profiles: accounts.profilesView(), logins: accounts.loginsView(), apiProviders: accounts.apiProviders(), automaticDecisions: accounts.automaticDecisionsView(r.viewer) }),
  });
  const call = async (method: string, path: string, body?: unknown, as = owner, headers: Record<string, string> = {}): Promise<[number, any]> => {
    const r: Request = { method, path, query: [], headers, body: Buffer.from(body === undefined ? "" : JSON.stringify(body)), viewer: as, lang: "zh" };
    for (const route of table) {
      const found = route.method === method ? route.pattern.exec(path) : null;
      if (found) {
        const a = await route.handle(r, found.slice(1));
        return [a.status, JSON.parse(String(a.body))];
      }
    }
    return [404, { error: `no route ${method} ${path}` }];
  };
  const profile = (id: string) => accounts.profiles().find((p) => p.id === id);
  const view = (id: string) => accounts.profilesView().find((p) => p.id === id);
  return { data, path, config, store, accounts, call, profile, view, close: () => accounts.close() };
}

describe("the accounts routes", { concurrency: true }, () => {
  test("invalid edits are refused and leave the config unchanged", async () => {
    const t = await rig();
    const before = readFileSync(t.path, "utf8");
    const last = await t.call("DELETE", "/profiles/cc");
    assert.equal(last[0], 400);
    assert.ok(last[1].error.includes("最后一个 claude 的 Profile，ember 还要用它运行"), last[1].error);
    assert.deepEqual(await t.call("DELETE", "/profiles/nope"), [400, { error: "unknown profile nope" }]);
    assert.equal(readFileSync(t.path, "utf8"), before);
    await t.close();
  });

  test("profile env: strings set, null removes, omitted keys stay", async () => {
    const t = await rig();
    await t.call("PUT", "/profiles/cc", { env: { ANTHROPIC_BASE_URL: null, EXTRA: "1" } });
    assert.deepEqual(profileEnv(t.profile("cc")!, "claude"), { ANTHROPIC_API_KEY: "sk-very-secret-value", EXTRA: "1" });
    assert.equal((await t.call("PUT", "/profiles/cc", { env: { "BAD NAME": "x" } }))[0], 400);
    await t.call("PUT", "/profiles/new-one", { runtime: "codex" });
    assert.equal(t.accounts.profiles().at(-1)!.home, join(t.data, "homes/new-one"));
    // Secrets are masked for the pages.
    const env = t.view("cc")!.env;
    assert.deepEqual(env, [
      { key: "ANTHROPIC_API_KEY", secret: true, value: "sk-ve…alue" },
      { key: "EXTRA", secret: false, value: "1" },
    ]);
    await t.close();
  });

  test("editing a profile's access keeps a blank key but never carries it to another kind", async () => {
    const t = await rig();
    assert.equal((await t.call("PUT", "/profiles/cx", { access: { kind: "opencode-go", key: "ocg-key-123456" } }))[0], 200);
    assert.equal(profileEnv(t.profile("cx")!, "codex").OPENCODE_GO_KEY, "ocg-key-123456");
    await t.call("PUT", "/profiles/cx", { name: "Codex OCG", access: { kind: "opencode-go", key: "" } });
    assert.deepEqual([t.profile("cx")!.key, t.profile("cx")!.name], ["ocg-key-123456", "Codex OCG"]);
    assert.equal((await t.call("PUT", "/profiles/cx", { access: { kind: "subscription", key: "" } }))[0], 200);
    assert.equal(t.profile("cx")!.key, undefined);
    assert.equal(t.view("cx")!.loginCommand, `CODEX_HOME=${join(t.data, "homes/cx")} codex login`);
    await t.close();
  });

  test("a key on a listed provider makes a profile that runs what its endpoints speak", async () => {
    const t = await rig();
    // Chat completions only: no runtime, but a profile all the same (it serves the automatic decisions).
    const [status, body] = await t.call("POST", "/profiles", { access: { kind: "api-provider", provider: "groq", key: "gsk-123456" } });
    assert.equal(status, 200, JSON.stringify(body));
    assert.equal(body.id, "groq");
    const groq = t.profile("groq")!;
    assert.deepEqual([accessKind(groq as any), groq.source, groq.runtimes, groq.name], ["api-provider", "groq", [], "Groq"]);
    assert.equal((await t.call("POST", "/profiles", { access: { kind: "api-provider", provider: "jev", key: "jev-key-1" } }))[0], 200);
    assert.deepEqual(t.profile("jev")!.runtimes, []);
    assert.equal((await t.call("POST", "/profiles", { access: { kind: "api-provider", provider: "opencode", key: "oc-key-1" } }))[0], 200);
    const zen = t.profile("opencode")!;
    assert.deepEqual(zen.runtimes, ["claude", "codex"]);
    assert.equal(profileEnv(zen, "claude").ANTHROPIC_BASE_URL, "https://opencode.ai/zen");
    assert.equal(profileEnv(zen, "claude").ANTHROPIC_CUSTOM_HEADERS, "x-opencode-session: {route}");
    assert.equal(profileEnv(zen, "codex").EMBER_API_KEY, "oc-key-1");
    // A second key on the same provider is a profile of its own.
    assert.equal((await t.call("POST", "/profiles", { access: { kind: "api-provider", provider: "groq", key: "gsk-other" } }))[0], 200);
    assert.equal(t.accounts.profiles().filter((p) => p.source === "groq").length, 2);
    // The address is the person's where the provider has none; a key is optional only for a server of one's own.
    assert.equal((await t.call("POST", "/profiles", { access: { kind: "api-provider", provider: "azure-openai", key: "k" } }))[0], 400);
    assert.equal((await t.call("POST", "/profiles", { access: { kind: "api-provider", provider: "custom", endpoint: "http://127.0.0.1:4000/v1", protocol: "anthropic" } }))[0], 200);
    const custom = t.profile("custom")!;
    assert.deepEqual([custom.key, custom.endpoint, custom.runtimes], [undefined, "http://127.0.0.1:4000/v1", ["claude"]]);
    assert.equal((await t.call("POST", "/profiles", { access: { kind: "api-provider", provider: "groq" } }))[0], 400, "a key is needed");
    assert.equal((await t.call("POST", "/profiles", { access: { kind: "api-provider", provider: "nope", key: "k" } }))[0], 400);
    assert.equal((await t.call("POST", "/profiles", { access: { kind: "api-provider", provider: "anthropic", key: "k" } }))[0], 400, "Anthropic is its own kind");
    assert.deepEqual(await t.call("POST", "/profiles", { access: { kind: "subscription" } }), [400, { error: "订阅账号用登录来添加" }]);
    assert.deepEqual(await t.call("POST", "/profiles", { access: { kind: "nope" } }), [400, { error: 'unknown access "nope"' }]);
    // What an older core is shown: `env`, with the provider beside it; the list leaves out the two kinds from before.
    const view = t.view("groq")!;
    assert.deepEqual([view.access.kind, view.access.provider, view.access.key.includes("123456")], ["env", "groq", false]);
    const listed = t.accounts.apiProviders().map((p) => p.id);
    assert.ok(listed.includes("deepseek") && listed.includes("opencode") && !listed.includes("anthropic") && !listed.includes("opencode-go"));
    // Its address can be changed, its key kept; it can be deleted although it runs no runtime.
    assert.equal((await t.call("PUT", "/profiles/custom", { access: { kind: "api-provider", endpoint: "http://127.0.0.1:5000/v1" } }))[0], 200);
    assert.equal(t.profile("custom")!.endpoint, "http://127.0.0.1:5000/v1");
    assert.equal((await t.call("DELETE", "/profiles/groq"))[0], 200);
    // The trial homes became the profiles' own.
    assert.ok(existsSync(join(t.data, "homes", "opencode")));
    await t.close();
  });

  test("a subscription sign-in runs on the station's machine and relays the link, the code and the result", async () => {
    const dir = temp("routes");
    const approved = approval(dir);
    const t = await rig({ data: dir, approval: approved.path });
    const wait = (id: string, state: string) => waitFor(t, id, state);
    await t.call("PUT", "/profiles/sub", { runtime: "claude", access: { kind: "subscription" } });
    assert.equal((await t.call("POST", "/profiles/cc/login"))[0], 400, "keyed profiles do not sign in");
    assert.deepEqual(await t.call("GET", "/profiles/nope/login"), [404, { error: "unknown profile nope" }]);
    await t.call("POST", "/profiles/sub/login");
    const job = await wait("sub", "needs_code");
    assert.ok(job.url.startsWith("https://claude.com/cai/oauth/authorize?"));
    await t.call("POST", "/profiles/sub/login-code", { code: "wrong" });
    assert.ok((await wait("sub", "failed")).error.includes("invalid code"));
    assert.equal((await t.call("POST", "/profiles/sub/login-code", { code: "again" }))[0], 400);
    await t.call("POST", "/profiles/sub/login");
    await wait("sub", "needs_code");
    await t.call("POST", "/profiles/sub/login-code", { code: " good-code " });
    await wait("sub", "done");

    await t.call("PUT", "/profiles/cxs", { runtime: "codex", access: { kind: "subscription" } });
    await t.call("POST", "/profiles/cxs/login");
    const device = await wait("cxs", "needs_approval");
    assert.deepEqual([device.url, device.userCode], ["https://auth.openai.com/codex/device", "ABCD-12345"]);
    await approved.approve();
    await wait("cxs", "done");
    assert.equal(t.view("cxs")!.login.state, "done");
    // Cancelled from the page.
    await t.call("POST", "/profiles/sub/login");
    await wait("sub", "needs_code");
    assert.equal((await t.call("DELETE", "/profiles/sub/login"))[1].job.state, "cancelled");
    await t.close();
  });

  /// The sign-in as its page reads it, once in `state`: read again each time the accounts say something changed.
  async function waitFor(t: Rig, id: string, state: string): Promise<any> {
    let last: any;
    try {
      return await upon(
        (wake) => t.accounts.onChange(wake),
        async () => {
          [, last] = await t.call("GET", `/profiles/${id}/login`);
          return last.job?.state === state ? last.job : undefined;
        },
        `${id} ${state}`,
      );
    } catch {
      throw new Error(`login of ${id} never reached ${state}: ${JSON.stringify(last)}`);
    }
  }

  test("a sign-in after its profile was deleted makes a profile beside the home left behind", async () => {
    const t = await rig();
    const signedIn = async () => {
      const [status, body] = await t.call("POST", "/logins", { runtime: "codex" });
      assert.equal(status, 200, JSON.stringify(body));
      const id = body.id;
      return upon(
        (wake) => t.accounts.onChange(wake),
        () => {
          const login = t.accounts.loginsView().find((l) => l.id === id);
          assert.equal(login?.error, null, JSON.stringify(login));
          return login?.created as string | undefined;
        },
        `the sign-in ${id} made a profile`,
      );
    };
    const first = await signedIn();
    assert.equal(t.profile(first)!.name, "ChatGPT 订阅");
    assert.equal((await t.call("DELETE", `/profiles/${first}`))[0], 200);
    assert.ok(existsSync(join(t.data, "homes", first)), "a deleted profile's home stays");
    const second = await signedIn();
    assert.notEqual(second, first);
    assert.ok(t.profile(second));
    // A sign-in is dropped from its page; another id is no route.
    const [, made] = await t.call("POST", "/logins", { runtime: "claude" });
    assert.deepEqual(await t.call("DELETE", `/logins/${made.id}`), [200, { ok: true }]);
    assert.equal((await t.call("DELETE", `/logins/${made.id}`))[0], 404);
    assert.deepEqual(await t.call("POST", "/logins", { runtime: "nope" }), [400, { error: "unknown runtime nope" }]);
    await t.close();
  });

  test("profile checks and quotas are kept so a restart shows them at once", async () => {
    const data = temp("restart");
    const db = join(data, "stillfail.db");
    const first = await rig({ data, store: Store.open(db, null), quota: { n: 0 } });
    await first.call("POST", "/profiles/cc/check");
    await first.call("POST", "/profiles/cc/quota");
    await first.close();
    const again = await rig({ data, store: Store.open(db, null) });
    assert.equal(again.view("cc")!.check.detail, "fake");
    assert.equal(again.view("cc")!.quota.windows[0].usedPercent, 12);
    assert.deepEqual(again.accounts.health("cc").quota.windows[0].usedPercent, 12);
    await again.close();
  });

  test("a profile on the machine's own login: made from a login kept in a file, its models chosen, never renamed or signed in, stopped", async () => {
    const m = fakeMachine({ claude: `echo '{"loggedIn": true, "email": "b@x.com", "subscriptionType": "pro"}'`, codex: "echo 'Logged in using ChatGPT'" });
    const { mkdirSync } = await import("node:fs");
    mkdirSync(join(m.home, ".claude"));
    writeFileSync(join(m.home, ".claude/.credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "fake-access", expiresAt: Date.now() + 3_600_000 } }));
    const s = await rig({ machine: new MachineLogins(m.env, undefined, () => "zh") });
    // Kept elsewhere than a file: not one to use.
    const keychain = await s.call("POST", "/profiles/machine", { runtime: "codex" });
    assert.equal(keychain[0], 400);
    assert.ok(keychain[1].error.includes("钥匙串"), keychain[1].error);
    const made = await s.call("POST", "/profiles/machine", { runtime: "claude" });
    assert.equal(made[0], 200, JSON.stringify(made[1]));
    assert.equal(made[1].id, "machine-claude");
    const profile = () => s.profile("machine-claude")!;
    assert.equal(isMachine(profile()), true);
    assert.equal(profile().name, "b@x.com（本机）");
    assert.equal(accessKind(profile() as any), "subscription");
    assert.equal((await s.call("POST", "/profiles/machine", { runtime: "claude" }))[0], 409);
    // Only its models are chosen here.
    assert.equal((await s.call("PUT", "/profiles/machine-claude", { name: "renamed", models: ["claude-x"], access: { kind: "opencode-go", key: "k" } }))[0], 200);
    assert.deepEqual([profile().name, profile().models, accessKind(profile() as any), isMachine(profile())], ["b@x.com（本机）", ["claude-x"], "subscription", true]);
    assert.equal(s.view("machine-claude")!.machine, true);
    // And how it runs: on by default, turned off and on here; other edits keep it.
    assert.equal(profile().backgroundOnMessage, true);
    assert.equal((await s.call("PUT", "/profiles/machine-claude", { backgroundOnMessage: false }))[0], 200);
    assert.equal(profile().backgroundOnMessage, false);
    assert.equal((await s.call("PUT", "/profiles/machine-claude", { models: ["claude-y"] }))[0], 200);
    assert.equal(s.view("machine-claude")!.backgroundOnMessage, false);
    assert.equal((await s.call("PUT", "/profiles/machine-claude", { backgroundOnMessage: true }))[0], 200);
    assert.equal(profile().backgroundOnMessage, true);
    assert.equal((await s.call("POST", "/profiles/machine-claude/login"))[0], 400);
    // Stopped: the profile goes; it can be made again from the machine's login.
    assert.equal((await s.call("DELETE", "/profiles/machine-claude"))[0], 200);
    assert.equal(s.profile("machine-claude"), undefined);
    assert.equal((await s.call("POST", "/profiles/machine", { runtime: "claude" }))[0], 200);
    await s.close();
  });

  test("the desktop app's station takes up the machine's logins no profile runs, with every model their check finds", async () => {
    const m = fakeMachine({ claude: `echo '{"loggedIn": true, "email": "b@x.com", "subscriptionType": "max"}'`, codex: "echo 'Logged in using ChatGPT'" });
    const { mkdirSync } = await import("node:fs");
    mkdirSync(join(m.home, ".claude"));
    writeFileSync(join(m.home, ".claude/.credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "fake-access", expiresAt: 4_102_444_800_000 } }));
    mkdirSync(join(m.home, ".codex"));
    writeFileSync(join(m.home, ".codex/auth.json"), "{}");
    // Codex has a profile already; Claude Code has none.
    const data = temp("machine-adopt");
    writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [{ id: "cx", runtime: "codex", home: "homes/cx" }], connects: [] }));
    const s = await rig({
      data,
      machine: new MachineLogins(m.env, undefined, () => "zh"),
      check: async (r) => ({ state: "ok", detail: "fake", models: r.runtime === "claude" ? ["claude-opus-5-5", "claude-sonnet-5-5"] : ["gpt-6"], checkedAt: 0 }),
    });
    s.accounts.useMachineLogins();
    const made = await until(() => (s.profile("machine-claude")?.models.length ?? 0) > 0 && s.profile("machine-claude"), "the machine's Claude Code taken up");
    assert.deepEqual([isMachine(made), made.models], [true, ["claude-opus-5-5", "claude-sonnet-5-5"]]);
    await s.close();
    assert.deepEqual(s.accounts.profiles().map((p) => p.id), ["cx", "machine-claude"]);
  });

  test("a machine login whose models could not be listed has them listed when the station starts again, and later ones as they come", async () => {
    const m = fakeMachine({ claude: `echo '{"loggedIn": true, "email": "b@x.com", "subscriptionType": "max"}'` });
    const { mkdirSync } = await import("node:fs");
    mkdirSync(join(m.home, ".claude"));
    writeFileSync(join(m.home, ".claude/.credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "fake-access", expiresAt: 4_102_444_800_000 } }));
    const data = temp("machine-offline");
    writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [], connects: [] }));
    // Offline: the profile is made, with no model.
    const offline = await rig({ data, machine: new MachineLogins(m.env, undefined, () => "zh"), check: async () => ({ state: "failed", detail: "offline", models: null, checkedAt: 0 }) });
    offline.accounts.useMachineLogins();
    await until(() => offline.profile("machine-claude"), "the profile made");
    await offline.close();
    assert.deepEqual(offline.profile("machine-claude")!.models, []);
    let listed = ["claude-opus-5-5"];
    const online = await rig({ data, machine: new MachineLogins(m.env, undefined, () => "zh"), check: async () => ({ state: "ok", detail: "fake", models: listed, checkedAt: 0 }) });
    online.accounts.useMachineLogins();
    await until(() => (online.profile("machine-claude")?.models.length ?? 0) > 0, "its models listed");
    // A model its account gains later is enabled when it is checked again.
    listed = ["claude-opus-6", "claude-opus-5-5"];
    await online.accounts.check("machine-claude");
    await online.close();
    assert.deepEqual(online.accounts.profiles().map((p) => [p.id, p.models]), [["machine-claude", ["claude-opus-5-5", "claude-opus-6"]]]);
  });

  test("a profile just made has its allowance read at once, without waiting for a round", async () => {
    const quota = { n: 0 };
    // Its time never moves: no round comes.
    const t = await rig({ quota, clock: testClock().clock });
    const made = await t.call("PUT", "/profiles/linked", { name: "Linked", runtime: "codex", access: { kind: "subscription" }, home: "homes/linked" });
    assert.equal(made[0], 200);
    await until(() => quota.n > 0, "the allowance read");
    await settle();
    assert.equal(quota.n, 1);
    assert.equal(t.view("linked")!.quota.windows[0].usedPercent, 12);
    await t.close();
  });

  test("an OpenAI reset keeps its redemption key and reads the allowance again even without a reset", async () => {
    const keys: string[] = [];
    const quota = { n: 0 };
    const t = await rig({
      quota,
      resetQuota: async (p, key) => {
        assert.equal(p.id, "cx");
        keys.push(key);
        return { outcome: ({ empty: "noCredit", unused: "nothingToReset", again: "alreadyRedeemed", odd: "what" } as Record<string, string>)[key] ?? "reset" };
      },
    });
    await t.call("PUT", "/profiles/cx", { access: { kind: "subscription" } });
    const redeem = async (id: string, key: string) => (await t.call("POST", `/profiles/${id}/reset-quota`, undefined, owner, { "Idempotency-Key": key }))[0];
    assert.deepEqual(await t.call("POST", "/profiles/cx/reset-quota"), [400, { error: "reset requires an idempotency key" }]);
    assert.equal(await redeem("cc", "wrong-provider"), 400);
    assert.equal(await redeem("cx", "one"), 200);
    assert.deepEqual(keys, ["one"]);
    assert.equal(await redeem("cx", "again"), 200);
    assert.equal(await redeem("cx", "empty"), 409);
    assert.equal(await redeem("cx", "unused"), 409);
    assert.equal(await redeem("cx", "odd"), 502);
    assert.equal(await redeem("nope", "x"), 404);
    assert.ok(quota.n >= 4);
    await t.close();
  });

  test("OpenAI fast defaults off, survives other edits and can be turned off", async () => {
    const t = await rig();
    assert.equal(t.profile("cx")!.fast, undefined);
    assert.equal(t.view("cx")!.fast, null, "only a ChatGPT subscription has it");
    assert.equal((await t.call("PUT", "/profiles/cx", { fast: true, access: { kind: "subscription" } }))[0], 200);
    assert.equal(t.profile("cx")!.fast, true);
    await t.call("PUT", "/profiles/cx", { name: "OpenAI" });
    assert.equal(t.view("cx")!.fast, true);
    await t.call("PUT", "/profiles/cx", { fast: false });
    assert.equal(t.view("cx")!.fast, false);
    assert.deepEqual(await t.call("PUT", "/profiles/cx", { fast: "yes" }), [400, { error: "fast must be a boolean" }]);
    await t.close();
  });

  test("the automatic decisions use a model a profile verified, set by a workspace manager", async () => {
    const t = await rig({
      discover: async (profile) =>
        profile.source === "groq"
          ? { state: "ready", detail: "", model: "qwen3.8-flash", provider: "chat_logprobs", models: ["qwen3.8-flash"], fingerprint: fingerprint(profile) }
          : { state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: fingerprint(profile) },
    });
    assert.deepEqual(await t.call("PUT", "/automatic-decisions", { completion: { enabled: true, model: "qwen3.8-flash" } }, member), [403, { error: "只有 workspace 管理员能配置自动决策" }]);
    assert.deepEqual(await t.call("POST", "/automatic-decisions/refresh", undefined, member), [403, { error: "只有 workspace 管理员能刷新决策模型" }]);
    assert.deepEqual(await t.call("PUT", "/automatic-decisions", { completion: { enabled: true, model: "qwen3.8-flash" } }), [400, { error: "请选择现有 Profile 中已验证可用的决策模型" }]);
    assert.deepEqual(await t.call("PUT", "/automatic-decisions", { completion: { enabled: "yes" } }), [400, { error: "自动决策配置格式不正确" }]);
    assert.equal((await t.call("POST", "/profiles", { access: { kind: "api-provider", provider: "groq", key: "gsk-123456" } }))[0], 200);
    // What the decisions can use is found after the profile is made.
    await until(() => t.accounts.decisionModels().length > 0, "the decision model found");
    assert.deepEqual(t.accounts.decisionModels(), [{ id: "qwen3.8-flash", name: "Qwen3.8 Flash", profiles: ["Groq"] }]);
    const [status, overview] = await t.call("PUT", "/automatic-decisions", { completion: { enabled: true, model: "qwen3.8-flash" } });
    assert.equal(status, 200);
    assert.deepEqual(overview.automaticDecisions.settings, { completion: { enabled: true, model: "qwen3.8-flash" } });
    assert.deepEqual(t.config.raw().automaticDecisions, { completion: { enabled: true, model: "qwen3.8-flash" } });
    assert.deepEqual(t.accounts.automaticDecisionsView(member), { canEdit: false, settings: {}, models: [], recent: [] });
    // The view hides what the capability was found for; an edited profile waits for its next check.
    assert.equal(t.view("groq")!.check.decision.fingerprint, undefined);
    await t.call("PUT", "/profiles/groq", { models: ["other"] });
    const decision = t.view("groq")!.check.decision;
    assert.ok(decision.state === "pending" || decision.state === "ready", JSON.stringify(decision));
    assert.equal((await t.call("POST", "/automatic-decisions/refresh"))[0], 200);
    await t.close();
  });

  test("the archive policy page: its options with the chats last put there, who changed it, and edits by managers", async () => {
    const store = Store.open(":memory:", null);
    store.insertSession({ key: "titled", connect: "ds", runtime: "claude", profile: "cc", workspace: "/w/a", token: "t", createdAt: 1, lastActiveAt: 1 });
    store.insertSession({ key: "loose", connect: "ds", runtime: "claude", profile: "cc", workspace: "/w/b", token: "t2", createdAt: 1, lastActiveAt: 1 });
    store.insertSession({ key: "old", connect: "ds", runtime: "claude", profile: "cc", workspace: "/w/c", token: "t3", createdAt: 1, lastActiveAt: 1 });
    const thread = store.openThread("slack:T1", "C1", "1.1", null, null);
    store.joinThread(thread.id, "titled", "ds");
    store.setThreadTitle(thread.id, "修登录页");
    const result = (selected: string) => ({ selected, probabilities: { [selected]: 1 }, model: "m", source: "native", retainedMass: 1 });
    const base = { purpose: "archive", version: 3, model: "m", threshold: 0.9, elapsedMs: 1 };
    store.recordDecision("titled", { ...base, accepted: false, option: { id: "awaiting_review", name: "等人看结果", archive: false }, result: result("awaiting_review") });
    store.recordDecision("titled", { ...base, accepted: true, option: { id: "landed", name: "已落地", archive: true }, result: result("landed") });
    store.recordDecision("loose", { ...base, accepted: false, result: null, error: "timeout" });
    store.recordDecision("old", { ...base, version: 2, accepted: true, result: result("complete") });
    const t = await rig({ store });
    const view = t.accounts.automaticDecisionsView(owner);
    // Pages from before the policy list the checks one by one.
    assert.deepEqual(view.recent.map((r: any) => [r.title, r.label]), [["old", "已做完 · 推荐归档"], ["loose", "没检查成"], ["修登录页", "已落地 · 推荐归档"], ["修登录页", "等人看结果 · 不推荐"]]);
    const policy = view.policy;
    assert.equal(policy.text, DEFAULT_POLICY.policy);
    assert.equal(policy.edited, false);
    assert.equal(policy.change, null);
    assert.deepEqual([policy.checked, policy.failed], [3, 1]);
    // Each chat counted once, by its latest check.
    const landed = policy.options.find((o: any) => o.id === "landed");
    assert.equal(landed.count, 1);
    assert.deepEqual(landed.chats.map((c: any) => [c.title, c.recommended]), [["修登录页", true]]);
    assert.equal(policy.options.find((o: any) => o.id === "awaiting_review").count, 0);
    // Changed by a manager: kept by who, with what changed; a member is refused, and so is a policy that cannot be.
    const options = DEFAULT_POLICY.options.filter((o) => o.id !== "uncertain");
    assert.deepEqual(await t.call("PUT", "/automatic-decisions/policy", { policy: "x", options }, member), [403, { error: "只有 workspace 管理员能改归档策略" }]);
    assert.deepEqual(await t.call("PUT", "/automatic-decisions/policy", { policy: "x", options: options.map((o) => ({ ...o, archive: true })) }), [400, { error: "至少要有一个不推荐的选项" }]);
    const [status, overview] = await t.call("PUT", "/automatic-decisions/policy", { policy: "只看用户最初要的东西", options });
    assert.equal(status, 200);
    const after = overview.automaticDecisions.policy;
    assert.equal(after.text, "只看用户最初要的东西");
    assert.equal(after.options.length, DEFAULT_POLICY.options.length - 1);
    assert.deepEqual(after.change.by, { kind: "person", email: "owner@example.com", name: null });
    assert.equal(after.change.summary, "改了策略，删了「看不出来」");
    await t.close();
  });
});
