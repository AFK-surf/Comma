import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { IMessageValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const WS = "ws-1";
const path = `/v1/comma/workspaces/${WS}/integrations/imessage`;
const phone = "+14155550123";
const line = "+15559990000";

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const key = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(key, v),
      (e) => values.set(key, { error: e.code })
    );
    return () => values.get(key) as T;
  };
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch };
}

/** The server's iMessage state: an attempt after a start, a link once `reply()` "arrives". */
function server(t: ReturnType<typeof setup>, ttlSeconds = 600) {
  const s = {
    attempt: null as null | Record<string, unknown>,
    link: null as null | Record<string, unknown>,
    failRead: false,
    refuse: null as null | string,
    reply() {
      s.link = {
        sender_handle: phone,
        transport: "photon",
        connection_id: "imc-1",
        connected_at: 1_700_000_000,
      };
      s.attempt = null;
    },
  };
  t.api.on("GET", path, () =>
    s.failRead
      ? offline()
      : json(200, {
          configured: true,
          photon_configured: true,
          connection_active: Boolean(s.link),
          photon_online: true,
          pending_claim: s.attempt,
          link: s.link,
        })
  );
  t.api.on("POST", `${path}/connect`, () => {
    if (s.refuse) return json(400, { error: s.refuse });
    s.attempt = {
      code: "CODE123",
      expires_at: Math.floor(t.time.now() / 1000) + ttlSeconds,
      transport: "photon",
      sender_handle: phone,
      line_handle: line,
    };
    return json(201, s.attempt);
  });
  t.api.on("DELETE", `${path}/connect`, () => {
    s.attempt = null;
    return json(200, { cancelled: true });
  });
  t.api.on("DELETE", path, () => {
    s.link = null;
    return json(200, { disconnected: true });
  });
  return s;
}

describe("iMessage over Photon", () => {
  it("starts with the phone, reads every 3 s while the code waits, stops once connected, and disconnects", async () => {
    const t = setup();
    const s = server(t);
    const shown = t.watch<IMessageValue>({ topic: "imessage", workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      state: { photon_configured: true, pending_claim: null, link: null },
      error: false,
      busy: false,
    });

    const started = t.client.call("imessage.start", { workspace: WS, handle: phone });
    await t.time.pass(100);
    await started;
    expect(t.api.seen("POST", `${path}/connect`).at(-1)!.body).toEqual({
      handle: phone,
    });
    expect(shown().state?.pending_claim).toMatchObject({
      code: "CODE123",
      line_handle: line,
      sender_handle: phone,
    });
    const reads = () => t.api.seen("GET", path).length;
    const before = reads();
    await t.time.pass(9_000, 500);
    expect(reads()).toBe(before + 3);

    // The person texts the code: the next read shows the link, and the reads stop.
    s.reply();
    await t.time.pass(3_000, 500);
    expect(shown().state).toMatchObject({
      pending_claim: null,
      link: { sender_handle: phone },
    });
    const settled = reads();
    await t.time.pass(30_000, 1_000);
    expect(reads()).toBe(settled);

    const disconnected = t.client.call("imessage.disconnect", { workspace: WS });
    await t.time.pass(100);
    await disconnected;
    expect(t.api.seen("DELETE", path)).toHaveLength(1);
    expect(shown().state?.link).toBeNull();
  });

  it("stops reading at expiry, keeps a refusal's code for the caller, and cancels the attempt by its code", async () => {
    const t = setup();
    const s = server(t, 10);
    const shown = t.watch<IMessageValue>({ topic: "imessage", workspace: WS });
    await t.time.pass(100);

    s.refuse = "invalid_imessage_handle";
    const refused = t.client
      .call("imessage.start", { workspace: WS, handle: phone })
      .catch((error: unknown) => error);
    await t.time.pass(100);
    expect(await refused).toMatchObject({ code: "invalid_imessage_handle" });
    expect(shown()).toMatchObject({ error: false, busy: false });

    s.refuse = null;
    const started = t.client.call("imessage.start", { workspace: WS, handle: phone });
    await t.time.pass(100);
    await started;
    await t.time.pass(15_000, 500);
    const reads = t.api.seen("GET", path).length;
    await t.time.pass(30_000, 1_000);
    // Past its expiry the attempt is not read again; the UI says it expired.
    expect(t.api.seen("GET", path).length).toBe(reads);

    const cancelled = t.client.call("imessage.cancel", { workspace: WS });
    await t.time.pass(100);
    await cancelled;
    expect(t.api.seen("DELETE", `${path}/connect`).at(-1)!.body).toEqual({
      code: "CODE123",
    });
    expect(shown().state?.pending_claim).toBeNull();
  });

  it("a failed read stops the reads until a refresh", async () => {
    const t = setup();
    const s = server(t);
    s.failRead = true;
    const shown = t.watch<IMessageValue>({ topic: "imessage", workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ state: null, error: true });
    s.failRead = false;
    const refreshed = t.client.call("imessage.refresh", { workspace: WS });
    await t.time.pass(100);
    await refreshed;
    expect(shown()).toMatchObject({ state: { photon_configured: true }, error: false });
  });
});
