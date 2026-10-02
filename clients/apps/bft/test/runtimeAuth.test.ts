import { readFileSync } from "node:fs";
import { Aes128Gcm, CipherSuite, DhkemP256HkdfSha256, HkdfSha256 } from "@hpke/core";
import { describe, expect, it } from "vitest";
import {
  managedAuthPollDelay,
  runtimeAuthAAD,
  runtimeAuthMaterial,
  runtimeAuthPollDelay,
  sealRuntimeAuth,
} from "../src/runtimeAuth";

// The native owner's fixture: the browser must encode the same context bytes
// and produce an envelope the owner opens.
const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../../../../systems/connector/salix-connect/testdata/runtime-auth/hpke-js.json",
      import.meta.url
    ),
    "utf8"
  )
) as {
  Context: Record<string, unknown>;
  AAD: string;
  Private: string;
  Public: string;
  Info: string;
  Enc: string;
  Ciphertext: string;
  Plaintext: string;
};

const bytes = (base64: string) => new Uint8Array(Buffer.from(base64, "base64"));
const arrayBuffer = (value: Uint8Array) => value.slice().buffer;
const suite = new CipherSuite({
  kem: new DhkemP256HkdfSha256(),
  kdf: new HkdfSha256(),
  aead: new Aes128Gcm(),
});
const text = (value: Uint8Array) => new TextDecoder().decode(value);

async function open(
  envelope: { enc: Uint8Array; ciphertext: Uint8Array },
  context: Record<string, unknown>
) {
  const recipientKey = await suite.kem.deserializePrivateKey(
    arrayBuffer(bytes(fixture.Private))
  );
  const recipient = await suite.createRecipientContext({
    recipientKey,
    enc: arrayBuffer(envelope.enc),
    info: arrayBuffer(bytes(fixture.Info)),
  });
  return new Uint8Array(
    await recipient.open(
      arrayBuffer(envelope.ciphertext),
      arrayBuffer(runtimeAuthAAD(context))
    )
  );
}

describe("runtime authentication sealing", () => {
  it("encodes the Go fixture context and seals an envelope only that target opens", async () => {
    expect(Buffer.from(runtimeAuthAAD(fixture.Context))).toEqual(
      Buffer.from(fixture.AAD, "base64")
    );
    expect(
      await open(
        { enc: bytes(fixture.Enc), ciphertext: bytes(fixture.Ciphertext) },
        fixture.Context
      )
    ).toEqual(bytes(fixture.Plaintext));

    const context = { ...fixture.Context, expires_at: Date.now() + 60_000 };
    const sealed = JSON.parse(
      await sealRuntimeAuth(
        { context, public_key: fixture.Public },
        bytes(fixture.Plaintext)
      )
    ) as { enc: string; ciphertext: string };
    expect(Object.keys(sealed).toSorted()).toEqual(["ciphertext", "enc"]);
    const envelope = { enc: bytes(sealed.enc), ciphertext: bytes(sealed.ciphertext) };
    expect(await open(envelope, context)).toEqual(bytes(fixture.Plaintext));
    await expect(
      open(envelope, { ...context, workload_id: "another-workload" })
    ).rejects.toThrow();
  });

  it("refuses an expired offer", async () => {
    const context = { ...fixture.Context, expires_at: Date.now() - 1 };
    await expect(
      sealRuntimeAuth({ context, public_key: fixture.Public }, bytes(fixture.Plaintext))
    ).rejects.toThrow("invalid_format");
  });
});

describe("runtime authentication material", () => {
  it("rejects executable fields and bounds plaintext", () => {
    for (const value of ["", "key\ncommand", "!command", "$TOKEN", "x".repeat(65536)]) {
      expect(() => runtimeAuthMaterial("api_key", "openrouter", value)).toThrow();
    }
    expect(
      text(runtimeAuthMaterial("authorization_code", "anthropic", "synthetic-code"))
    ).toBe("synthetic-code");
    expect(() =>
      runtimeAuthMaterial("authorization_code", "anthropic", "code\ncommand")
    ).toThrow();
    for (const value of [
      { type: "api_key", key: "safe", command: "run" },
      { type: "oauth", access: "synthetic" },
      { openrouter: { type: "api_key", key: "$TOKEN" } },
    ]) {
      expect(() =>
        runtimeAuthMaterial("pi_auth_entry", "openrouter", JSON.stringify(value))
      ).toThrow();
    }
    const entry = runtimeAuthMaterial(
      "pi_auth_entry",
      "openrouter",
      JSON.stringify({
        openrouter: { type: "api_key", key: "synthetic" },
        other: { type: "oauth", access: "never-submitted" },
      })
    );
    expect(JSON.parse(text(entry))).toEqual({ type: "api_key", key: "synthetic" });
    expect(() =>
      runtimeAuthMaterial(
        "codex_auth_file",
        "openai",
        '{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic","hooks":{}}'
      )
    ).toThrow();
    const openrouter = {
      env: {
        ANTHROPIC_BASE_URL: "https://openrouter.ai/api",
        ANTHROPIC_AUTH_TOKEN: "synthetic",
        ANTHROPIC_API_KEY: "",
      },
    };
    expect(
      JSON.parse(
        text(
          runtimeAuthMaterial(
            "claude_backend_config",
            "openrouter",
            JSON.stringify(openrouter)
          )
        )
      )
    ).toEqual(openrouter);
    const credentials = {
      claudeAiOauth: {
        accessToken: "synthetic-access",
        refreshToken: "synthetic-refresh",
        expiresAt: 4102444800000,
        scopes: ["user:inference"],
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_20x",
      },
    };
    expect(
      JSON.parse(
        text(
          runtimeAuthMaterial(
            "claude_credentials_file",
            "anthropic",
            JSON.stringify(credentials)
          )
        )
      )
    ).toEqual(credentials);
    expect(() =>
      runtimeAuthMaterial(
        "claude_credentials_file",
        "anthropic",
        JSON.stringify({ ...credentials, hooks: {} })
      )
    ).toThrow();
    expect(() =>
      runtimeAuthMaterial(
        "claude_credentials_file",
        "anthropic",
        JSON.stringify({
          claudeAiOauth: {
            ...credentials.claudeAiOauth,
            scopes: ["user:inference", "user:inference"],
          },
        })
      )
    ).toThrow();
  });

  it("keeps a Claude setup token only in its exact supported form", () => {
    const value = { env: { CLAUDE_CODE_OAUTH_TOKEN: "synthetic-token" } };
    expect(
      JSON.parse(
        text(
          runtimeAuthMaterial(
            "claude_backend_config",
            "anthropic",
            JSON.stringify(value)
          )
        )
      )
    ).toEqual(value);
    for (const env of [
      { ...value.env, ANTHROPIC_API_KEY: "other" },
      { ...value.env, ANTHROPIC_BASE_URL: "https://example.com" },
      { CLAUDE_CODE_OAUTH_TOKEN: "" },
    ]) {
      expect(() =>
        runtimeAuthMaterial(
          "claude_backend_config",
          "anthropic",
          JSON.stringify({ env })
        )
      ).toThrow();
    }
  });

  it("polls an active panel for at most five minutes", () => {
    expect(
      runtimeAuthPollDelay({ attempt_id: "attempt", phase: "awaiting_user" }, 0)
    ).toBe(5_000);
    expect(
      runtimeAuthPollDelay({ attempt_id: "attempt", phase: "verifying" }, 59)
    ).toBe(5_000);
    expect(
      runtimeAuthPollDelay({ attempt_id: "attempt", phase: "applying" }, 60)
    ).toBeNull();
    expect(
      runtimeAuthPollDelay({ attempt_id: "attempt", phase: "completed" }, 0)
    ).toBeNull();
    expect(runtimeAuthPollDelay(null, 0)).toBeNull();
    expect(runtimeAuthPollDelay({ attempt_id: "attempt" }, -1)).toBeNull();
    expect(managedAuthPollDelay("installing", 0)).toBe(5_000);
    expect(managedAuthPollDelay("revoking", 59)).toBe(5_000);
    expect(managedAuthPollDelay("account_disabled", 60)).toBeNull();
    expect(managedAuthPollDelay("configured", 0)).toBeNull();
  });
});
