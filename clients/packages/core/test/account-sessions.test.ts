import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { AccountSessionsValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const CURRENT = "/v1/comma/auth/session";
const LIST = "/v1/comma/auth/sessions";

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = (topic: Topic) => {
    const k = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return () => values.get(k) as AccountSessionsValue;
  };
  core.observeSession(signedIn());
  const now = Math.floor(host.time!.now() / 1000);
  return { host, client, time: host.time!, api: host.api, watch, now };
}

const row = (id: string, lastSeen: number, extra: Record<string, unknown> = {}) => ({
  id,
  device_label: `${id} device`,
  client_kind: "web",
  client_platform: "android",
  authenticated_at: lastSeen - 100,
  last_seen_at: lastSeen,
  expires_at: null,
  revoked_at: null,
  ...extra,
});

describe("the account's signed-in devices", () => {
  it("lists the open sessions once each, this one first, then the most recently active", async () => {
    const t = setup();
    t.api.on("GET", CURRENT, { session_id: "ses-this" });
    t.api.on("GET", LIST, (request) =>
      request.path.includes("cursor=")
        ? json(200, {
            has_more: false,
            next_cursor: null,
            data: [row("ses-mac", t.now - 60)],
          })
        : json(200, {
            has_more: true,
            next_cursor: "page-2",
            data: [
              row("ses-old", t.now - 5_000),
              row("ses-this", t.now - 10),
              row("ses-revoked", t.now - 20, { revoked_at: t.now - 1 }),
              row("ses-expired", t.now - 30, { expires_at: t.now - 1 }),
              row("ses-old", t.now - 5_000),
            ],
          })
    );
    const shown = t.watch({ topic: "accountSessions" });
    await t.time.pass(100);
    expect(shown().status).toBe("ready");
    expect(shown().sessions.map((s) => [s.id, s.current])).toEqual([
      ["ses-this", true],
      ["ses-mac", false],
      ["ses-old", false],
    ]);
    expect(shown().sessions[1]).toMatchObject({
      deviceLabel: "ses-mac device",
      clientKind: "web",
      clientPlatform: "android",
      lastSeenAt: t.now - 60,
    });
  });

  it("signs out another device at once, keeps this one when signing out the others, and reads the list again", async () => {
    const t = setup();
    let rows = [
      row("ses-this", t.now - 10),
      row("ses-a", t.now - 20),
      row("ses-b", t.now - 30),
    ];
    t.api.on("GET", CURRENT, { session_id: "ses-this" });
    t.api.on("GET", LIST, () => json(200, { has_more: false, data: rows }));
    t.api.on("DELETE", `${LIST}/ses-a`, () => {
      rows = rows.filter((r) => r.id !== "ses-a");
      return json(200, { revoked: true });
    });
    // A session already gone is no failure.
    t.api.on("DELETE", `${LIST}/ses-gone`, () => json(404, { error: "not_found" }));
    t.api.on("POST", `${LIST}/revoke-all`, () => {
      rows = rows.filter((r) => r.id === "ses-this");
      return json(200, { revoked_count: 1 });
    });
    const shown = t.watch({ topic: "accountSessions" });
    await t.time.pass(100);
    const release = t.api.hold("DELETE", `${LIST}/ses-a`);
    const revoked = t.client.call("accountSessions.revoke", { id: "ses-a" });
    // Shown gone while the server is still asked.
    await t.time.pass(100);
    expect(shown().sessions.map((s) => s.id)).toEqual(["ses-this", "ses-b"]);
    release();
    await t.time.pass(100);
    await revoked;
    await expect(
      Promise.all([
        t.client.call("accountSessions.revoke", { id: "ses-gone" }),
        t.time.pass(100),
      ])
    ).resolves.toBeDefined();

    const others = t.client.call("accountSessions.revokeOthers", {});
    await t.time.pass(100);
    expect(await others).toBe(1);
    // Anything but `true` would end this session as well.
    expect(t.api.seen("POST", `${LIST}/revoke-all`)[0]!.body).toEqual({
      keep_current: true,
    });
    expect(shown().sessions.map((s) => s.id)).toEqual(["ses-this"]);
  });

  it("asks for a one-time Apple Watch pairing for this session", async () => {
    const t = setup();
    t.api.on("POST", "/v1/comma/auth/watch/pairing", () =>
      json(201, {
        pairing_id: "pair-1",
        pairing_secret: "secret-1",
        expires_at: t.now + 300,
      })
    );
    const pairing = t.client.call("accountSessions.pairWatch", {});
    await t.time.pass(100);
    expect(await pairing).toEqual({
      pairingId: "pair-1",
      pairingSecret: "secret-1",
      expiresAt: t.now + 300,
    });
    expect(t.api.seen("POST", "/v1/comma/auth/watch/pairing")).toHaveLength(1);
  });

  it("says a first read that failed, and reads again on refresh", async () => {
    const t = setup();
    let up = false;
    t.api.on("GET", CURRENT, () =>
      up ? json(200, { session_id: "ses-this" }) : offline()
    );
    t.api.on("GET", LIST, { has_more: false, data: [row("ses-this", t.now - 10)] });
    const shown = t.watch({ topic: "accountSessions" });
    await t.time.pass(100);
    expect(shown()).toEqual({ status: "error", sessions: [] });
    up = true;
    const again = t.client.call("accountSessions.refresh", {});
    await t.time.pass(100);
    await again;
    expect(shown().sessions.map((s) => s.id)).toEqual(["ses-this"]);
  });
});
