// Checking a profile (profiles.rs check_profile) against local providers and stand-in CLIs, and finding what it can
// decide with (decision/profiles.rs discover).
import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { checkProfile, URLS } from "../src/accounts/profiles.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { byDecisionPriority, discover, resolvedModel } from "../src/sessions/decision.ts";
import { machine, provider, sameAs, temp } from "./accounts-fakes.ts";

const base = { runtime: "claude" as const, key: "k", via: {}, home: "/nonexistent-check-test", env: {}, machine: false, lang: "zh" as const };

test("a decision-only provider is checked without asking it anything", async (t) => {
  const asked = t.mock.method(globalThis, "fetch", () => Promise.reject(new Error("asked")));
  const check = await checkProfile({ ...base, kind: "api-provider", via: { provider: "jev" } });
  assert.equal(check.state, "ok", check.detail);
  assert.equal(asked.mock.callCount(), 0);
});

test("a key is tried where its provider says whether it works", async () => {
  const p = await provider((asked) => {
    if (asked.headers.authorization !== "Bearer good") return { status: 401, body: { error: "no" } };
    if (asked.url === "/zen/go/v1/usage") return { status: 200, body: {} };
    return { status: 200, body: { data: [{ id: "m-b" }, { id: "m-a" }] } };
  });
  const urls = { ...URLS, opencode: `${p.base}/zen/go`, anthropic: p.base };
  const good = await checkProfile({ ...base, kind: "opencode-go", key: "good", urls });
  assert.deepEqual([good.state, good.detail, good.models], ["ok", "可用，2 个模型", ["m-a", "m-b"]]);
  const bad = await checkProfile({ ...base, kind: "opencode-go", key: "bad", urls });
  assert.deepEqual([bad.state, bad.detail], ["failed", "OpenCode Go 拒绝了这个 key（401）"]);
  const anthropic = await checkProfile({ ...base, kind: "anthropic-api", key: "bad", urls });
  assert.equal(anthropic.state, "failed");
  assert.equal(p.asked.at(-1)!.headers["x-api-key"], "bad");
  await p.close();
  // A provider at the person's own address: asked at its list, its refusal a failed key, no list only unchecked.
  const own = await provider((asked) => (asked.headers.authorization === "Bearer good" ? { status: 404, body: {} } : { status: 403, body: {} }));
  const via = { provider: "custom", endpoint: `${own.base}/v1`, protocol: "chat_completions" };
  assert.equal((await checkProfile({ ...base, kind: "api-provider", key: "good", via })).state, "unknown");
  assert.equal((await checkProfile({ ...base, kind: "api-provider", key: "bad", via })).state, "failed");
  assert.equal(own.asked[0]!.url, "/v1/models");
  assert.equal((await checkProfile({ ...base, kind: "api-provider", via: { provider: "azure-openai" } })).detail, "需要填一个可用的接口地址（http 或 https 开头）");
  await own.close();
});

test("a subscription is checked by its runtime's own status command, in the profile's home", async () => {
  const m = machine({
    claude: `${sameAs("CLAUDE_CONFIG_DIR", "profile")} || exit 3; echo '{"loggedIn":true,"email":"a@x.com","subscriptionType":"max"}'`,
    codex: `${sameAs("CODEX_HOME", "cx")} || exit 3; echo "Not logged in"; exit 1`,
  });
  const home = join(m.home, "profile");
  mkdirSync(home);
  // Its login in the file (so no keychain is looked in), with a token Anthropic lists models for.
  writeFileSync(join(home, ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "tok", expiresAt: Date.now() + 3_600_000 } }));
  const p = await provider((asked) => (asked.headers.authorization === "Bearer tok" ? { status: 200, body: { data: [{ id: "claude-opus-5-5" }] } } : { status: 401, body: {} }));
  const urls = { ...URLS, anthropic: p.base };
  const claude = await checkProfile({ ...base, kind: "subscription", home, env: m.env, urls });
  assert.deepEqual([claude.state, claude.detail, claude.models], ["ok", "已登录，a@x.com，max", ["claude-opus-5-5"]]);
  const codex = await checkProfile({ ...base, runtime: "codex", kind: "subscription", home: join(m.home, "cx"), env: m.env, urls });
  assert.deepEqual([codex.state, codex.detail], ["login", "还没登录"]);
  // A machine profile is handed the machine's token, and never looks in its home's file.
  const machineCheck = await checkProfile({ ...base, kind: "subscription", home: join(m.home, "elsewhere"), env: { ...m.env }, machine: true, machineToken: async () => ({ token: "tok" }), urls });
  assert.equal(machineCheck.state, "failed", "its home is not the one the stand-in answers for");
  await p.close();
  const env = await checkProfile({ ...base, kind: "env" });
  assert.equal(env.state, "unknown");
});

// ── what a profile can decide with ──

const logprobs = (best: string) => ({
  choices: [{ logprobs: { content: [{ top_logprobs: ["A", "B", "C", "D"].map((token) => ({ token, logprob: Math.log(token === best ? 0.97 : 0.01) })) }] } }],
});

test("decision discovery uses the profile's credentials and requires real logprobs", async () => {
  let valid = false;
  const p = await provider((asked) => {
    assert.equal(asked.url, "/chat/completions");
    assert.equal(asked.headers.authorization, "Bearer private-profile-key");
    assert.equal(asked.body.model, "gpt-6-luna");
    assert.equal(asked.body.reasoning_effort, "none");
    assert.equal(asked.body.max_completion_tokens, 1);
    return { status: 200, body: valid ? logprobs("B") : { choices: [{ message: { content: "B" } }] } };
  });
  const raw = { profiles: [{ id: "existing", home: "homes/existing", runtime: "codex", credential: "env", source: "custom", env: { OPENAI_API_KEY: "private-profile-key", OPENAI_BASE_URL: p.base }, models: ["gpt-6-luna"] }] };
  const profile = hubConfig(raw, "/nonexistent-decision-test").profiles[0]!;
  const check = { state: "unknown", models: null };
  assert.notEqual((await discover(profile, check)).state, "ready", "a model name and a generated answer are not logprobs");
  valid = true;
  const capability = await discover(profile, check);
  assert.equal(capability.state, "ready");
  assert.equal(resolvedModel(profile, capability, capability.model)!.apiKey, "private-profile-key");
  assert.ok(!JSON.stringify(capability).includes("private-profile-key"));
  const moved = { ...profile, env: { ...(profile.env as any), OPENAI_BASE_URL: "https://another.example/v1" } };
  assert.equal(resolvedModel(moved, capability, capability.model), undefined, "changing the destination invalidates the capability");
  await p.close();
});

test("a provider profile is probed at its chat endpoint with its own key, small models first", async () => {
  const p = await provider(() => ({ status: 200, body: logprobs("B") }));
  const raw = { profiles: [{ id: "api", home: "homes/api", credential: "api_key", source: "custom", endpoint: `${p.base}/v1`, key: "provider-key" }] };
  const profile = hubConfig(raw, "/nonexistent-decision-test").profiles[0]!;
  const capability = await discover(profile, { state: "unknown", models: ["big-model", "qwen3.8-flash"] });
  assert.equal(capability.state, "ready");
  assert.equal(capability.model, "qwen3.8-flash", "the small model that does not think is asked first");
  assert.equal(p.asked[0]!.url, "/v1/chat/completions");
  assert.equal(p.asked[0]!.headers.authorization, "Bearer provider-key");
  assert.equal(p.asked[0]!.headers["x-opencode-session"], undefined);
  await p.close();
  // A subscription's model names are not API access.
  const sub = hubConfig({ profiles: [{ id: "s", home: "homes/s", runtime: "claude", credential: "subscription", source: "claude" }] }, "/x").profiles[0]!;
  assert.equal((await discover(sub, { state: "ok", models: ["claude-opus-5-5"] })).state, "unsupported");
});

test("small models that do not think come first", () => {
  const models = ["glm-5.1", "deepseek-v4-pro", "gpt-6-luna", "deepseek-flash", "qwen3.7-max", "qwen3.8-flash", "deepseek-v4.1-flash", "kimi-k2.7-thinking"];
  assert.deepEqual(models.sort(byDecisionPriority), ["qwen3.8-flash", "deepseek-flash", "deepseek-v4.1-flash", "deepseek-v4-pro", "gpt-6-luna", "qwen3.7-max", "glm-5.1", "kimi-k2.7-thinking"]);
});

void temp;
