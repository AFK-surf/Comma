// ExUnit starts the real loopback Comma Router and independent scripted providers for this driver.
import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Effect } from "effect";
import { HostError } from "@comma/core-kernel";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  sessionExpectation,
  type TerminalSessionSnapshot,
} from "@comma/session-contract";
import type { SessionValue } from "@comma/core";
import type { SessionEmailChallenge } from "@comma/core/contract";

vi.mock("electron", () => ({
  app: { getPath: () => tmpdir() },
  safeStorage: {
    isEncryptionAvailable: () => true,
    encryptString: (value: string) => Buffer.from(value),
    decryptString: (value: Buffer) => value.toString(),
  },
}));
vi.mock("electron-log/main", () => ({ default: { warn: vi.fn() } }));

import { MainSessionHost } from "../src/main/modules/session/session-host";
import { SecureSessionStore } from "../src/main/secure-store";
import { startInProcessCore } from "../src/test-support/in-process-core";

const origin = process.env.COMMA_AUTH_CHAIN_API_ORIGIN;
const enforced = process.env.COMMA_AUTH_CHAIN_ENFORCE !== "false";
const emailFor = (name: string) =>
  `${enforced ? "" : "observed-"}${name}-chain@example.test`;
type ChainClient = ReturnType<typeof startInProcessCore> & {
  session: MainSessionHost;
  store: SecureSessionStore;
  directory: string;
};
const clients: ChainClient[] = [];

async function start(
  kind: "electron" | "ios" | "android",
  proof: "pass" | "unavailable" = "pass"
): Promise<ChainClient> {
  if (
    !origin ||
    !["127.0.0.1", "localhost", "[::1]"].includes(new URL(origin).hostname)
  )
    throw new Error("The auth chain needs its ExUnit loopback API.");
  const directory = await mkdtemp(join(tmpdir(), "comma-auth-abuse-chain-"));
  const store = await SecureSessionStore.open(join(directory, "session.bin"));
  const session = new MainSessionHost({ store, trustedAudience: origin, fetch });
  const core = startInProcessCore(session, {
    clientKind: kind,
    clientPlatform: kind === "electron" ? "macos" : kind,
    sha256: (inputs) =>
      Effect.succeed(
        inputs.map(
          (input) => new Uint8Array(createHash("sha256").update(input).digest())
        )
      ),
    abuseProof: (challenge) => {
      if (proof === "unavailable")
        return Effect.fail(new HostError("scripted provider unavailable"));
      const requestHash = createHash("sha256")
        .update(`comma-abuse:${challenge.id}:${challenge.secret}`)
        .digest("base64url");
      return kind === "android"
        ? Effect.succeed({ provider: "play", play_token: `local-play:${requestHash}` })
        : Effect.tryPromise({
            try: async () => {
              const answer = await fetch(
                new URL("/_test/auth-abuse/apple-proof", origin),
                {
                  method: "POST",
                  headers: { "content-type": "application/json" },
                  body: JSON.stringify(challenge),
                }
              );
              if (!answer.ok)
                throw new Error("The test Apple proof fixture was unavailable.");
              return (await answer.json()) as {
                provider: "apple";
                apple: { key_id: string; attestation?: string; assertion?: string };
              };
            },
            catch: () => new HostError("scripted provider unavailable"),
          });
    },
  });
  const result = { ...core, session, store, directory };
  clients.push(result);
  await until(result, (value) => value.lifecycle?.phase === "signed_out");
  return result;
}

function until(
  client: ReturnType<typeof startInProcessCore>,
  predicate: (value: SessionValue) => boolean
): Promise<SessionValue> {
  return new Promise((resolve) => {
    const check = () => {
      const value = client.core.session.value();
      if (predicate(value)) {
        stop();
        resolve(value);
      }
    };
    const stop = client.core.session.onChange(check);
    check();
  });
}

async function completeCaptcha(client: ReturnType<typeof startInProcessCore>) {
  const shown = await until(client, (value) => value.attempt?.captcha !== undefined);
  const attempt = shown.attempt!;
  const challenge = attempt.captcha!;
  const page = await fetch(challenge.url);
  expect(page.status).toBe(200);
  expect(await page.text()).not.toContain("challenge_secret");
  expect(
    await client.client.call("session.captcha.answer", {
      attempt: attempt.ref,
      challengeId: challenge.challengeId,
      token: `local-captcha:${challenge.challengeId}`,
    })
  ).toBe(true);
}

async function emailLogin(
  client: Awaited<ReturnType<typeof start>>,
  email: string,
  captcha: boolean
) {
  const expected = sessionExpectation(
    client.core.electronSession!.snapshot() as TerminalSessionSnapshot
  );
  const pending = client.client.call("session.email.request", { email, expected });
  if (captcha) await completeCaptcha(client);
  const requested = (await pending) as { ok: true; value: SessionEmailChallenge };
  expect(requested.ok).toBe(true);
  if (!captcha) expect(client.core.session.value().attempt?.captcha).toBeUndefined();
  const mailbox = await fetch(
    new URL(`/_test/auth-abuse/code?email=${encodeURIComponent(email)}`, origin)
  );
  expect(mailbox.ok).toBe(true);
  const { code } = (await mailbox.json()) as { code: string };
  expect(
    await client.client.call("session.email.verify", {
      attempt: requested.value.attempt,
      challengeId: requested.value.challengeId,
      code,
    })
  ).toMatchObject({ ok: true, value: { phase: "signed_in", principal: { email } } });
  const vault = client.store.getVaultSnapshot();
  if (vault.status !== "readable" || !vault.active)
    throw new Error("Main did not commit its issued credential.");
  expect(JSON.stringify(client.core.session.value())).not.toContain(vault.active.token);
  const check = await fetch(new URL("/v1/comma/auth/session", origin), {
    headers: {
      authorization: `Bearer ${vault.active.token}`,
      "x-comma-session-transport": "bearer",
    },
  });
  expect(check.status).toBe(200);
}

afterEach(async () => {
  for (const client of clients.splice(0)) {
    client.close();
    await client.session.close();
    await rm(client.directory, { recursive: true, force: true });
  }
});

describe(`client core through Main and the real Comma HTTP Router (${enforced ? "enforced" : "observed"})`, () => {
  it("keeps the issued bearer in Main through the configured Electron flow", async () => {
    await emailLogin(await start("electron"), emailFor("electron"), enforced);
  });
  it.each(["ios", "android"] as const)(
    "completes %s PoW plus server-verified platform evidence without CAPTCHA",
    async (kind) => {
      await emailLogin(await start(kind), emailFor(kind), false);
    }
  );
  it("keeps the original action through native provider failure under the configured policy", async () => {
    await emailLogin(
      await start("android", "unavailable"),
      emailFor("fallback"),
      enforced
    );
  });
});
