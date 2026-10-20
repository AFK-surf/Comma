import { CoreClient } from "@comma/core-kernel/client";
import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import type { ApiResponse } from "../src/host.ts";
import { FakeDesktop } from "../src/testing/fake-desktop.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  signedOut,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const ws = "wsp_1";
const accounts = `/v1/comma/workspaces/${ws}/subscription-accounts`;
const oauth = `${accounts}/oauth`;
const discovery = `/v1/comma/workspaces/${ws}/model-discovery`;
const keys = "https://tokendance.space/portal/api/v1/auth/keys";
const profile = {
  id: "sub_1",
  source: "codex",
  name: "Codex",
  version: "v1",
  credential_kind: "subscription_oauth",
  disabled: false,
  status: "active",
};

function setup() {
  const host = new FakeHost();
  const desktop = new FakeDesktop();
  host.desktop = desktop;
  host.api.on("GET", accounts, { data: [], next: null });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  /** Starts `name`; its outcome (`value` or `error`) once it answers. */
  const start = (name: string, params: unknown, signal?: AbortSignal) => {
    const outcome: { value?: unknown; error?: { code: string; message: string } } = {};
    const done = client.call(name, params, undefined, signal).then(
      (value) => void (outcome.value = value),
      (error: { code: string; message: string }) => void (outcome.error = error)
    );
    return { outcome, done };
  };
  return { host, core, client, desktop, time: host.time!, api: host.api, start };
}

const providerPage = (provider: "codex" | "claude", state = "expected") => {
  const page =
    provider === "codex"
      ? new URL("https://auth.openai.com/oauth/authorize")
      : new URL("https://claude.ai/oauth/authorize");
  page.searchParams.set(
    "redirect_uri",
    provider === "codex"
      ? "http://localhost:1455/auth/callback"
      : "http://localhost:54545/callback"
  );
  page.searchParams.set("state", state);
  return page.href;
};

describe("a subscription's sign-in through the desktop's loopback listener", () => {
  it.each(["codex", "claude"] as const)(
    "%s: the browser's return with the sign-in's state finishes it, once; another state is shown invalid",
    async (provider) => {
      const t = setup();
      t.api.on("POST", oauth, {
        id: "attempt-1",
        url: providerPage(provider),
        expires_at: "2099-01-01T00:00:00Z",
        mode: "callback",
      });
      t.api.on("POST", `${oauth}/attempt-1`, { ...profile, source: provider });
      const callback =
        provider === "codex"
          ? "http://127.0.0.1:1455/auth/callback"
          : "http://127.0.0.1:54545/callback";
      const signIn = t.start("models.signIn.loopback", { workspace: ws, provider });
      await t.time.pass(100);
      expect(t.api.seen("POST", oauth)[0]!.body).toEqual({
        provider,
        mode: "callback",
      });
      expect(t.desktop.opened).toEqual([providerPage(provider)]);

      expect(await t.desktop.visit(`${callback}?state=other&code=secret`)).toBe(
        "invalid"
      );
      expect(await t.desktop.visit(`${callback.replace("callback", "other")}`)).toBe(
        "notFound"
      );
      await t.time.pass(100);
      expect(t.api.seen("POST", `${oauth}/attempt-1`)).toEqual([]);
      expect(t.desktop.returns).toBe(0);

      expect(await t.desktop.visit(`${callback}?state=expected&code=secret`)).toBe(
        "received"
      );
      await t.time.pass(100);
      await signIn.done;
      expect(t.desktop.returns).toBe(1);
      expect(signIn.outcome.value).toMatchObject({ id: "sub_1", source: provider });
      expect(t.api.seen("POST", `${oauth}/attempt-1`)).toHaveLength(1);
      expect(
        (t.api.seen("POST", `${oauth}/attempt-1`)[0]!.body as { code: string }).code
      ).toContain("code=secret");
      // The listener is gone with the sign-in.
      expect(t.desktop.listening.size).toBe(0);
      expect(await t.desktop.visit(`${callback}?state=expected&code=again`)).toBe(
        "closed"
      );
    }
  );

  it("names the profile it renews", async () => {
    const t = setup();
    t.api.on("POST", oauth, json(500, { error: "boom" }));
    const signIn = t.start("models.signIn.loopback", {
      workspace: ws,
      provider: "claude",
      account: "sub_9",
      version: "v3",
    });
    await t.time.pass(100);
    await signIn.done;
    expect(t.api.seen("POST", oauth)[0]!.body).toEqual({
      provider: "claude",
      mode: "callback",
      account_id: "sub_9",
      version: "v3",
    });
    expect(signIn.outcome.error?.code).toBe("authorization_failed");
    expect(t.desktop.opened).toEqual([]);
  });

  it("starts nothing when another app holds the port", async () => {
    const t = setup();
    t.desktop.taken.add(1455);
    const signIn = t.start("models.signIn.loopback", {
      workspace: ws,
      provider: "codex",
    });
    await t.time.pass(100);
    await signIn.done;
    expect(signIn.outcome.error?.code).toBe("authorization_port_in_use");
    expect(t.api.seen("POST", oauth)).toEqual([]);
    expect(t.desktop.opened).toEqual([]);
  });

  it("refuses a provider page that would not return here", async () => {
    const t = setup();
    t.api.on("POST", oauth, {
      id: "attempt-1",
      url: "https://evil.example/authorize?state=expected&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
      expires_at: "2099-01-01T00:00:00Z",
    });
    const signIn = t.start("models.signIn.loopback", {
      workspace: ws,
      provider: "codex",
    });
    await t.time.pass(100);
    await signIn.done;
    expect(signIn.outcome.error?.code).toBe("authorization_failed");
    expect(t.desktop.opened).toEqual([]);
    expect(t.desktop.listening.size).toBe(0);
  });

  it("shows a denied page, brings the app back and fails when the provider says no", async () => {
    const t = setup();
    t.api.on("POST", oauth, {
      id: "attempt-1",
      url: providerPage("codex"),
      expires_at: "2099-01-01T00:00:00Z",
    });
    const signIn = t.start("models.signIn.loopback", {
      workspace: ws,
      provider: "codex",
    });
    await t.time.pass(100);
    expect(
      await t.desktop.visit(
        "http://localhost:1455/auth/callback?state=expected&error=access_denied"
      )
    ).toBe("denied");
    await t.time.pass(100);
    await signIn.done;
    expect(signIn.outcome.error?.code).toBe("authorization_denied");
    expect(t.desktop.returns).toBe(1);
  });

  it("is cancelled with its call and can start again; one at a time", async () => {
    const t = setup();
    t.api.on("POST", oauth, {
      id: "attempt-1",
      url: providerPage("codex"),
      expires_at: "2099-01-01T00:00:00Z",
    });
    const cancel = new AbortController();
    const first = t.start(
      "models.signIn.loopback",
      { workspace: ws, provider: "codex" },
      cancel.signal
    );
    await t.time.pass(100);
    const second = t.start("models.signIn.loopback", {
      workspace: ws,
      provider: "codex",
    });
    await t.time.pass(100);
    await second.done;
    expect(second.outcome.error?.code).toBe("authorization_in_progress");
    cancel.abort();
    await t.time.pass(100);
    await first.done;
    expect(t.desktop.listening.size).toBe(0);
    const third = t.start("models.signIn.loopback", {
      workspace: ws,
      provider: "codex",
    });
    await t.time.pass(100);
    expect(t.desktop.listening.size).toBe(1);
    expect(t.desktop.opened).toHaveLength(2);
    expect(third.outcome).toEqual({});
  });

  it("expires after fifteen minutes and closes its listener", async () => {
    const t = setup();
    t.api.on("POST", oauth, {
      id: "attempt-1",
      url: providerPage("codex"),
      expires_at: "2099-01-01T00:00:00Z",
    });
    const abandoned = t.start("models.signIn.loopback", {
      workspace: ws,
      provider: "codex",
    });
    await t.time.pass(900_000 + 100, 10_000);
    await abandoned.done;
    expect(abandoned.outcome.error?.code).toBe("authorization_expired");
    expect(t.desktop.listening.size).toBe(0);
  });

  it("ends when the session ends, and finishes nothing after", async () => {
    const t = setup();
    t.api.on("POST", oauth, {
      id: "attempt-1",
      url: providerPage("codex"),
      expires_at: "2099-01-01T00:00:00Z",
    });
    const signedOutDuring = t.start("models.signIn.loopback", {
      workspace: ws,
      provider: "codex",
    });
    await t.time.pass(100);
    t.core.observeSession(signedOut());
    await t.time.pass(100);
    await signedOutDuring.done;
    expect(signedOutDuring.outcome.error?.code).toBe("authorization_expired");
    expect(
      await t.desktop.visit("http://localhost:1455/auth/callback?state=expected&code=x")
    ).toBe("closed");
    expect(t.api.seen("POST", `${oauth}/attempt-1`)).toEqual([]);
  });
});

const keyAnswer = (body: unknown, status = 200): ApiResponse => ({
  status,
  headers: [["content-type", "application/json"]],
  body: new TextEncoder().encode(JSON.stringify(body)),
});

describe("TokenDance through the desktop's loopback listener", () => {
  const key = "td-secret-key";
  const listed = {
    data: [
      { id: "chat-model", supported_protocols: ["responses", "chat_completions"] },
      { id: "any-model" },
      { id: "responses-only", supported_protocols: ["responses"] },
    ],
  };
  const connect = async (t: ReturnType<typeof setup>) => {
    const connecting = t.start("models.tokenDance.connect", {
      workspace: ws,
      name: "TokenDance",
    });
    await t.time.pass(100);
    const authorization = new URL(t.desktop.opened.at(-1)!);
    const callback = new URL(authorization.searchParams.get("callback_url")!);
    return { connecting, authorization, callback };
  };

  it("exchanges the code with PKCE, keeps the key in the core and saves one profile of its chat models", async () => {
    const t = setup();
    t.desktop.provider = () => keyAnswer({ key });
    t.api.on("POST", discovery, listed);
    t.api.on("POST", accounts, { ...profile, id: "sub_td", source: "custom" });
    const { connecting, authorization, callback } = await connect(t);
    expect(authorization.origin + authorization.pathname).toBe(
      "https://tokendance.space/auth"
    );
    expect(authorization.searchParams.get("code_challenge_method")).toBe("S256");
    expect(authorization.searchParams.get("app_url")).toBe("app://comma-test");
    expect(authorization.searchParams.get("key_name")).toBe("Comma Test");
    expect(callback.host).toMatch(/^127\.0\.0\.1:\d+$/);

    const wrong = new URL(callback);
    wrong.searchParams.set("state", "unrelated");
    wrong.searchParams.set("code", "code-1");
    expect(await t.desktop.visit(wrong.href)).toBe("invalid");
    const twice = new URL(callback);
    twice.searchParams.append("state", "again");
    twice.searchParams.set("code", "code-1");
    expect(await t.desktop.visit(twice.href)).toBe("invalid");
    expect(t.desktop.provided).toEqual([]);

    callback.searchParams.set("code", "code-1");
    expect(await t.desktop.visit(callback.href)).toBe("received");
    await t.time.pass(100);
    await connecting.done;
    expect(connecting.outcome.value).toMatchObject({ id: "sub_td" });

    const exchange = JSON.parse(new TextDecoder().decode(t.desktop.provided[0]!.body));
    expect(t.desktop.provided[0]!.url).toBe(keys);
    expect(exchange).toMatchObject({ code: "code-1", code_challenge_method: "S256" });
    expect(
      createHash("sha256").update(exchange.code_verifier).digest("base64url")
    ).toBe(authorization.searchParams.get("code_challenge"));
    expect(t.api.seen("POST", discovery)[0]!.body).toEqual({
      base_url: "https://tokendance.space/gateway/v1",
      api_key: key,
      protocol: "responses",
    });
    expect(t.api.seen("POST", accounts)[0]!.body).toEqual({
      credential_kind: "provider_api_key",
      source: "custom",
      name: "TokenDance",
      api_key: key,
      base_url: "https://tokendance.space/gateway/v1",
      protocol: "chat_completions",
      models: ["chat-model", "any-model"],
    });
    // No UI ever hears the key.
    expect(JSON.stringify(t.host.emitted)).not.toContain(key);
    expect(t.desktop.returns).toBe(1);
    expect(t.desktop.listening.size).toBe(0);
  });

  it("saves nothing without a chat model, and never shows the provider's words", async () => {
    const t = setup();
    t.desktop.provider = () => keyAnswer({ key });
    t.api.on("POST", discovery, {
      data: [{ id: "r", supported_protocols: ["responses"] }],
    });
    const first = await connect(t);
    first.callback.searchParams.set("code", "code-1");
    await t.desktop.visit(first.callback.href);
    await t.time.pass(100);
    await first.connecting.done;
    expect(first.connecting.outcome.error?.code).toBe("invalid_model_configuration");
    expect(t.api.seen("POST", accounts)).toEqual([]);

    t.desktop.provider = () => keyAnswer({ error: "provider secret detail" }, 400);
    const second = await connect(t);
    second.callback.searchParams.set("code", "code-2");
    await t.desktop.visit(second.callback.href);
    await t.time.pass(100);
    await second.connecting.done;
    expect(second.connecting.outcome.error?.code).toBe("authorization_failed");
    expect(JSON.stringify(second.connecting.outcome.error)).not.toContain(
      "provider secret"
    );
    expect(t.api.seen("POST", discovery)).toHaveLength(1);
  });

  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.desktop.provider = () => keyAnswer({ key });
    t.api.on("POST", discovery, listed);
    t.api.on("POST", accounts, { ...profile, id: "sub_td", source: "custom" });
    const { connecting, callback } = await connect(t);
    callback.searchParams.set("code", "code-1");
    await t.desktop.visit(callback.href);
    await t.time.pass(100);
    await connecting.done;
    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
