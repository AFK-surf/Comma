// Signing in from the pages, and the machine's own logins (login.rs, machine_logins.rs tests): with stand-in CLIs in
// temp homes.
import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdirSync, readlinkSync, lstatSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { deviceCode, LoginManager, type LoginState, stripAnsi } from "../src/accounts/login.ts";
import { MachineLogins } from "../src/accounts/machine.ts";
import { linkCodexAuth } from "../src/agents/machine-logins.ts";
import { approval, exe, fakeLogin, idToken, machine, sameAs, script, temp, upon } from "./accounts-fakes.ts";

test("a subscription sign-in relays the link, the code and the result", async () => {
  const dir = temp("login");
  const fake = join(dir, "fake-login");
  const approved = approval(dir);
  script(fake, fakeLogin(approved.path));
  const logins = new LoginManager(dir, { claude: exe(fake), codex: exe(fake) });
  const heard: string[] = [];
  logins.changes((id) => heard.push(id));
  const wait = (profile: string, state: LoginState) =>
    upon((wake) => logins.changes(wake), () => (logins.get(profile)?.state === state ? logins.get(profile) : undefined), `${profile} ${state}`);
  try {
    const sub = { id: "sub", runtime: "claude" as const, home: join(dir, "homes", "sub") };
    await logins.start(sub, "zh");
    const job = await wait("sub", "needs_code");
    assert.ok(job.url!.startsWith("https://claude.com/cai/oauth/authorize?"), JSON.stringify(job));
    assert.equal(heard[0], "sub");
    await logins.submitCode("sub", "wrong", "zh");
    assert.ok((await wait("sub", "failed")).error!.includes("invalid code"));
    await assert.rejects(logins.submitCode("sub", "x", "zh"), /没有在等授权码/);
    await logins.start(sub, "zh");
    await wait("sub", "needs_code");
    await assert.rejects(logins.submitCode("sub", "  ", "zh"), /空/);
    await logins.submitCode("sub", " good-code ", "zh");
    await wait("sub", "done");

    const cxs = { id: "cxs", runtime: "codex" as const, home: join(dir, "homes", "cxs") };
    await logins.start(cxs, "zh");
    const device = await wait("cxs", "needs_approval");
    assert.deepEqual([device.url, device.userCode], ["https://auth.openai.com/codex/device", "ABCD-12345"]);
    await approved.approve();
    await wait("cxs", "done");

    // A cancelled sign-in stops its command and says so.
    await logins.start(sub, "zh");
    await wait("sub", "needs_code");
    logins.cancel("sub");
    assert.equal(logins.get("sub")!.state, "cancelled");

    // A command that cannot run is a failed sign-in that says why.
    const none = new LoginManager(dir, { claude: join(dir, "no-such-command"), codex: "x" });
    const failed = await none.start(sub, "zh");
    assert.equal(failed.state, "failed");
    assert.ok(failed.error!.startsWith("无法运行登录命令"), failed.error!);
    await none.close();
  } finally {
    await logins.close();
  }
});

test("device codes and escapes are read", () => {
  assert.equal(deviceCode("enter\n   ABCD-12345\n"), "ABCD-12345");
  assert.equal(deviceCode("a one-time code"), null);
  assert.equal(stripAnsi("\u001b[94mhttps://x\u001b[0m"), "https://x");
});

test("the machine's own logins are read from the machine's own homes", async () => {
  const m = machine({
    // Only answers for the machine's own home: no CLAUDE_CONFIG_DIR may reach it.
    claude: `[ -n "$CLAUDE_CONFIG_DIR" ] && exit 3; echo '{"loggedIn":true,"authMethod":"claude.ai","email":"a@x.com","subscriptionType":"max"}'`,
    codex: `${sameAs("CODEX_HOME", ".codex")} || exit 3; echo "Logged in using ChatGPT"`,
  });
  mkdirSync(join(m.home, ".codex"));
  mkdirSync(join(m.home, ".claude"));
  writeFileSync(join(m.home, ".claude/.credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "at", expiresAt: Date.now() + 3_600_000 } }));
  writeFileSync(join(m.home, ".codex/auth.json"), JSON.stringify({ tokens: { id_token: idToken({ email: "b@x.com", "https://api.openai.com/auth": { chatgpt_plan_type: "plus" } }) } }));
  const logins = new MachineLogins({ ...m.env, CLAUDE_CONFIG_DIR: "/elsewhere" }, async (runtime) => ({ state: "ok", detail: runtime === "claude" ? "Claude" : "Codex" }), () => "zh");
  let heard = 0;
  logins.changes(() => heard++);
  await logins.refresh();
  await logins.refresh();
  assert.equal(heard, 1, "the pages hear of the first reading, and not of one that says the same");
  const got = logins.get();
  assert.equal(got[0]!.text, "Claude Code 已登录 a@x.com（Max）");
  assert.deepEqual([got[0]!.usable, got[0]!.quota.detail], [true, "Claude"]);
  assert.deepEqual([got[1]!.email, got[1]!.plan, got[1]!.text], ["b@x.com", "plus", "Codex 已登录 b@x.com（Plus）"]);
});

test("signed out, not installed and keychain only are said as such", async () => {
  let m = machine({ claude: `echo '{"loggedIn":false}'; exit 1` });
  let logins = new MachineLogins(m.env, undefined, () => "zh");
  await logins.refresh();
  let got = logins.get();
  assert.deepEqual([got[0]!.installed, got[0]!.loggedIn, got[0]!.text], [true, false, "Claude Code 没有登录"]);
  assert.deepEqual([got[1]!.installed, got[1]!.text], [false, "没有装 Codex"]);
  m = machine({ claude: `echo '{"loggedIn":true,"email":"a@x.com","subscriptionType":"pro"}'`, codex: `echo "Logged in using ChatGPT"` });
  logins = new MachineLogins(m.env, undefined, () => "zh");
  await logins.refresh();
  got = logins.get();
  assert.deepEqual([got[0]!.usable, got[0]!.text], [false, "Claude Code 已登录 a@x.com（Pro），登录在钥匙串里，station 读不到"]);
  assert.deepEqual([got[1]!.usable, got[1]!.text], [false, "Codex 已登录，登录存在钥匙串里"]);
});

test("a machine profile's codex home links the machine's auth.json", () => {
  const m = machine();
  const profile = join(m.home, "profile");
  linkCodexAuth(profile, m.env);
  assert.equal(readlinkSync(join(profile, "auth.json")), join(m.home, ".codex/auth.json"));
  unlinkSync(join(profile, "auth.json"));
  writeFileSync(join(profile, "auth.json"), "{}");
  linkCodexAuth(profile, m.env);
  assert.ok(lstatSync(join(profile, "auth.json")).isSymbolicLink());
});
