import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { Aes128Gcm, CipherSuite, DhkemP256HkdfSha256, HkdfSha256 } from "@hpke/core";
import { managedAuthPollDelay, runtimeAuthAAD, runtimeAuthMaterial, runtimeAuthPollDelay, sealRuntimeAuth } from "./runtime_auth.mjs";

const fixture = JSON.parse(await readFile(new URL("../../../../connector/salix-connect/testdata/runtime-auth/hpke-js.json", import.meta.url), "utf8"));
test("browser uses the Go fixture context encoding and decrypts its HPKE envelope", async () => {
  assert.deepEqual(Buffer.from(runtimeAuthAAD(fixture.Context)), Buffer.from(fixture.AAD, "base64"));
  const suite = new CipherSuite({ kem: new DhkemP256HkdfSha256(), kdf: new HkdfSha256(), aead: new Aes128Gcm() });
  const key = await suite.kem.deserializePrivateKey(Buffer.from(fixture.Private, "base64"));
  const recipient = await suite.createRecipientContext({ recipientKey: key, enc: Buffer.from(fixture.Enc, "base64"), info: Buffer.from(fixture.Info, "base64") });
  assert.deepEqual(Buffer.from(await recipient.open(Buffer.from(fixture.Ciphertext, "base64"), runtimeAuthAAD(fixture.Context))), Buffer.from(fixture.Plaintext, "base64"));
  const context = { ...fixture.Context, expires_at: Date.now() + 60000 };
  const envelope = JSON.parse(await sealRuntimeAuth({ context, public_key: fixture.Public }, Buffer.from(fixture.Plaintext, "base64")));
  const receiver = await suite.createRecipientContext({ recipientKey: key, enc: Buffer.from(envelope.enc, "base64"), info: Buffer.from(fixture.Info, "base64") });
  assert.deepEqual(Buffer.from(await receiver.open(Buffer.from(envelope.ciphertext, "base64"), runtimeAuthAAD(context))), Buffer.from(fixture.Plaintext, "base64"));
  const wrongTarget = { ...context, workload_id: "another-workload" };
  const wrongReceiver = await suite.createRecipientContext({ recipientKey: key, enc: Buffer.from(envelope.enc, "base64"), info: Buffer.from(fixture.Info, "base64") });
  await assert.rejects(wrongReceiver.open(Buffer.from(envelope.ciphertext, "base64"), runtimeAuthAAD(wrongTarget)));
});

test("private material rejects unsupported executable fields and bounds plaintext", () => {
  for (const text of ["", "key\ncommand", "!command", "$TOKEN", "x".repeat(65536)]) assert.throws(() => runtimeAuthMaterial("api_key", "openrouter", text));
  assert.deepEqual(new TextDecoder().decode(runtimeAuthMaterial("authorization_code", "anthropic", "synthetic-code")), "synthetic-code");
  assert.throws(() => runtimeAuthMaterial("authorization_code", "anthropic", "code\ncommand"));
  for (const value of [{ type: "api_key", key: "safe", command: "run" }, { type: "oauth", access: "synthetic" }, { openrouter: { type: "api_key", key: "$TOKEN" } }]) {
    assert.throws(() => runtimeAuthMaterial("pi_auth_entry", "openrouter", JSON.stringify(value)));
  }
  const bytes = runtimeAuthMaterial("pi_auth_entry", "openrouter", JSON.stringify({ openrouter: { type: "api_key", key: "synthetic" }, other: { type: "oauth", access: "never-submitted" } }));
  assert.deepEqual(JSON.parse(new TextDecoder().decode(bytes)), { type: "api_key", key: "synthetic" });
  assert.throws(() => runtimeAuthMaterial("codex_auth_file", "openai", '{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic","hooks":{}}'));
  assert.deepEqual(JSON.parse(new TextDecoder().decode(runtimeAuthMaterial("claude_backend_config", "openrouter", '{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api","ANTHROPIC_AUTH_TOKEN":"synthetic","ANTHROPIC_API_KEY":""}}'))), {
    env: { ANTHROPIC_BASE_URL: "https://openrouter.ai/api", ANTHROPIC_AUTH_TOKEN: "synthetic", ANTHROPIC_API_KEY: "" },
  });
  const credentials = { claudeAiOauth: { accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: 4102444800000, scopes: ["user:inference"], subscriptionType: "max", rateLimitTier: "default_claude_max_20x" } };
  assert.deepEqual(JSON.parse(new TextDecoder().decode(runtimeAuthMaterial("claude_credentials_file", "anthropic", JSON.stringify(credentials)))), credentials);
  assert.throws(() => runtimeAuthMaterial("claude_credentials_file", "anthropic", JSON.stringify({ ...credentials, hooks: {} })));
  assert.throws(() => runtimeAuthMaterial("claude_credentials_file", "anthropic", JSON.stringify({ claudeAiOauth: { ...credentials.claudeAiOauth, scopes: ["user:inference", "user:inference"] } })));
});

test("active panel polling has one fixed five-minute bound", () => {
  assert.equal(runtimeAuthPollDelay({ attempt_id: "attempt", phase: "awaiting_user" }, 0), 5_000);
  assert.equal(runtimeAuthPollDelay({ attempt_id: "attempt", phase: "verifying" }, 59), 5_000);
  assert.equal(runtimeAuthPollDelay({ attempt_id: "attempt", phase: "applying" }, 60), null);
  assert.equal(runtimeAuthPollDelay({ attempt_id: "attempt", phase: "completed" }, 0), null);
  assert.equal(runtimeAuthPollDelay(null, 0), null);
  assert.equal(runtimeAuthPollDelay({ attempt_id: "attempt" }, -1), null);
  assert.equal(managedAuthPollDelay("installing", 0), 5_000);
  assert.equal(managedAuthPollDelay("revoking", 59), 5_000);
  assert.equal(managedAuthPollDelay("account_disabled", 60), null);
  assert.equal(managedAuthPollDelay("configured", 0), null);
});

test("Claude setup-token import preserves only the exact supported credential form", () => {
  const value = { env: { CLAUDE_CODE_OAUTH_TOKEN: "synthetic-token" } };
  assert.deepEqual(JSON.parse(new TextDecoder().decode(runtimeAuthMaterial("claude_backend_config", "anthropic", JSON.stringify(value)))), value);
  for (const env of [{ ...value.env, ANTHROPIC_API_KEY: "other" }, { ...value.env, ANTHROPIC_BASE_URL: "https://example.com" }, { CLAUDE_CODE_OAUTH_TOKEN: "" }]) {
    assert.throws(() => runtimeAuthMaterial("claude_backend_config", "anthropic", JSON.stringify({ env })));
  }
});
