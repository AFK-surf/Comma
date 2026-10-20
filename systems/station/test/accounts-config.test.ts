// config.rs parse_config's refusals (accounts/check.ts) and what profiles.rs says of access kinds, as their Rust tests
// have them.
import assert from "node:assert/strict";
import { test } from "node:test";
import { checkConfig } from "../src/accounts/check.ts";
import { needsKey, runtimesOf } from "../src/accounts/profiles.ts";
import { accessEnv, codexOverrides, OPENCODE } from "../src/agents/profiles.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { profileEnv } from "../src/agents/profiles.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { temp } from "./accounts-fakes.ts";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const err = (raw: unknown) => {
  try {
    checkConfig(raw, "/data");
  } catch (e) {
    return (e as Error).message;
  }
  return "accepted";
};

test("a config is filled in from what it says", () => {
  const raw = {
    profiles: [
      { id: "cc", runtime: "claude", home: "homes/cc", credential: "subscription", source: "claude" },
      { id: "og", home: "/abs/og", credential: "api_key", source: "opencode-go", key: " k ", models: ["a", " a", "b", ""], env: { X: "1" } },
    ],
    connects: [{ id: "ds", mode: "single-session", requireMention: false, bind: { runtime: "codex", effort: "high" }, slack: { appToken: "xapp", botToken: "xoxb", team: { id: "T1", name: "Acme" }, botName: "helper" } }],
    warmMinutes: 5,
  };
  checkConfig(raw, "/data");
  const config = hubConfig(raw, "/data");
  assert.equal(config.profiles[0]!.home, join("/data", "homes", "cc"));
  assert.deepEqual(config.profiles[0]!.runtimes, ["claude"]);
  const og = config.profiles[1]!;
  assert.deepEqual([og.home, og.models], ["/abs/og", ["a", "b"]]);
  assert.deepEqual(og.runtimes, ["claude", "codex"]);
  assert.equal(profileEnv(og, "codex").X, "1");
  assert.equal(profileEnv(og, "codex").OPENCODE_GO_KEY, "k");
  assert.equal(config.warmMs, 300_000);
});

test("what cannot run is refused in words", () => {
  assert.equal(err({ profiles: [{ id: "A", home: "h" }] }), 'profile id "A": use lowercase letters, digits and dashes');
  assert.equal(err({ profiles: [{ id: "a", home: "h" }] }), "profile a: env needs a runtime (claude or codex)");
  assert.equal(err({ profiles: [{ id: "a", home: "" , runtime: "claude" }] }), "profile a: home is required");
  assert.equal(err({ profiles: [{ id: "a", home: "h", credential: "api_key", source: "opencode-go" }] }), "profile a: access opencode-go needs a key");
  assert.equal(err({ profiles: [{ id: "a", home: "h", runtime: "codex", credential: "api_key", source: "anthropic", key: "k" }] }), "accepted", "an Anthropic key runs Claude Code whatever runtime is named");
  assert.equal(err({ connects: [{ id: "c", bind: { runtime: "claude", effort: "minimal" } }] }), "connect c: claude has no effort minimal; use low, medium, high, xhigh, max");
  assert.equal(err({ connects: [{ id: "c", bind: { runtime: "codex", effort: "ultra" } }] }), "accepted", "codex's levels are its models' own");
  assert.equal(err({ connects: [{ id: "c", bind: { runtime: "claude" } }, { id: "c", bind: { runtime: "claude" } }] }), "duplicate connect id c");
  assert.equal(err({ profiles: [{ id: "a", home: "h", runtime: "claude" }, { id: "a", home: "h", runtime: "claude" }] }), "duplicate profile id a");
  assert.equal(err({ connects: [{ id: "c", kind: "teams", bind: { runtime: "claude" } }] }), "connect c: unknown kind teams");
  assert.equal(err({ profiles: [{ id: "p", home: "h", credential: "api_key", source: "nope", key: "k" }] }), "profile p: api-provider needs a known provider");
  assert.equal(err({ profiles: [{ id: "p", home: "h", credential: "api_key", source: "azure-openai", key: "k" }] }), "profile p: Azure OpenAI needs an endpoint address");
  assert.match(err({ connects: [{ id: "c", bind: { runtime: "nope" } }] }), /unknown variant `nope`/);
  assert.match(err({ automaticDecisions: { completion: { enabled: true, model: "m", extra: 1 } } }), /unknown field `extra`/);
});

test("the cloudflare access setting of before, and what the station does not know, pass", () => {
  assert.equal(err({ admin: { access: { teamDomain: "afk", aud: "a" } }, connects: [], future: { x: 1 } }), "accepted");
  assert.equal(err({}), "accepted");
});

test("a config from before providers loads as it was", () => {
  const raw = {
    profiles: [
      { id: "go", home: "homes/go", credential: "api_key", source: "opencode-go", key: "k" },
      { id: "an", home: "homes/an", credential: "api_key", source: "anthropic", key: "k" },
      { id: "e", home: "homes/e", runtime: "codex", credential: "env", source: "custom" },
      { id: "p", home: "homes/p", credential: "api_key", source: "deepseek", key: "k" },
    ],
  };
  checkConfig(raw, "/x");
  assert.deepEqual(hubConfig(raw, "/x").profiles.map((p) => p.runtimes.length), [2, 1, 1, 0]);
});

test("a key runs every runtime it can and a subscription its own", () => {
  assert.deepEqual(runtimesOf("opencode-go", undefined), ["claude", "codex"]);
  assert.deepEqual(runtimesOf("anthropic-api", "codex"), ["claude"]);
  assert.deepEqual(runtimesOf("subscription", "codex"), ["codex"]);
  assert.deepEqual(runtimesOf("env", undefined), []);
});

test("a provider is set up for each runtime from where it speaks", () => {
  const router = accessEnv("claude", "api-provider", "k", "small", { provider: "openrouter" });
  assert.deepEqual([router.ANTHROPIC_BASE_URL, router.ANTHROPIC_AUTH_TOKEN, router.ANTHROPIC_API_KEY], ["https://openrouter.ai/api", "k", ""]);
  assert.equal(router.ANTHROPIC_SMALL_FAST_MODEL, "small");
  assert.deepEqual(accessEnv("codex", "api-provider", "k", undefined, { provider: "openrouter" }), {}, "no Responses endpoint");
  const openai = Object.fromEntries(codexOverrides("api-provider", "gpt-x", { provider: "openai" }));
  assert.equal(openai["model_providers.api.base_url"], '"https://api.openai.com/v1"');
  assert.deepEqual([openai.model_provider, openai["model_providers.api.wire_api"], openai.model], ['"api"', '"responses"', '"gpt-x"']);
  assert.equal(openai["model_providers.api.env_http_headers"], undefined);
  assert.equal(accessEnv("codex", "api-provider", "k", undefined, { provider: "openai" }).EMBER_API_KEY, "k");
  const zen = Object.fromEntries(codexOverrides("api-provider", undefined, { provider: "opencode" }));
  assert.equal(zen["model_providers.api.env_http_headers"], '{"x-opencode-session"="OPENCODE_SESSION"}');
  const azure = Object.fromEntries(codexOverrides("api-provider", undefined, { provider: "azure-openai", endpoint: "https://r.openai.azure.com/openai/v1/" }));
  assert.equal(azure["model_providers.api.base_url"], '"https://r.openai.azure.com/openai/v1"');
  assert.deepEqual(accessEnv("claude", "api-provider", "k", undefined, { provider: "groq" }), {});
  assert.equal(codexOverrides("api-provider", undefined, { provider: "groq" }).length, 3);
  assert.equal(accessEnv("codex", "api-provider", "", undefined, { provider: "custom", endpoint: "http://localhost:4000/v1", protocol: "responses" }).EMBER_API_KEY, "none");
  assert.ok(!needsKey("api-provider", "custom") && needsKey("api-provider", "groq") && needsKey("opencode-go", undefined));
});

test("opencode go sets up each runtime its own way", () => {
  const claude = accessEnv("claude", "opencode-go", "k", undefined, {});
  assert.equal(claude.ANTHROPIC_BASE_URL, OPENCODE);
  assert.equal(claude.ANTHROPIC_SMALL_FAST_MODEL, "deepseek-flash");
  assert.equal(accessEnv("codex", "opencode-go", "k", undefined, {}).OPENCODE_SESSION, "ember-{route}");
  assert.equal(Object.fromEntries(codexOverrides("opencode-go", "m", {})).model, '"m"');
  assert.equal(codexOverrides("subscription", undefined, {}).length, 3);
});

test("an edit the check refuses is not written", () => {
  const data = temp("config");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }] }));
  const file = new ConfigFile(data);
  file.check = checkConfig;
  const before = readFileSync(file.path, "utf8");
  assert.throws(() => file.update((raw) => raw.profiles.push({ id: "Bad", home: "h" })), /profile id "Bad"/);
  assert.equal(readFileSync(file.path, "utf8"), before);
  file.update((raw) => raw.profiles.push({ id: "ok", runtime: "codex", home: "homes/ok" }));
  assert.equal(file.raw().profiles.length, 2);
});
