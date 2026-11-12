import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { LineValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const WS = "ws-1";
const path = `/v1/comma/workspaces/${WS}/integrations/line`;

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

/** The server's LINE state: an attempt after a start, a link once `send()` "arrives" from LINE. */
function server(t: ReturnType<typeof setup>, ttlSeconds = 600) {
  const s = {
    attempt: null as null | Record<string, unknown>,
    link: null as null | Record<string, unknown>,
    failRead: false,
    send() {
      s.link = {
        line_user_id: "U1234",
        line_display_name: "Alice",
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
          basic_id: "@comma",
          add_friend_url: "https://line.me/R/ti/p/%40comma",
          workspace_id: WS,
          connection_active: Boolean(s.link),
          pending_claim: s.attempt,
          link: s.link,
        })
  );
  t.api.on("POST", `${path}/connect`, () => {
    s.attempt = {
      code: "ABCD2345",
      expires_at: Math.floor(t.time.now() / 1000) + ttlSeconds,
      message_url: "https://line.me/R/oaMessage/%40comma/?link%20ABCD2345",
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

describe("LINE", () => {
  it("starts, reads every 3 s while the code waits, stops once connected, and disconnects", async () => {
    const t = setup();
    const s = server(t);
    const shown = t.watch<LineValue>({ topic: "line", workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      state: { configured: true, basic_id: "@comma", pending_claim: null, link: null },
      error: false,
      busy: false,
    });

    const started = t.client.call("line.start", { workspace: WS });
    await t.time.pass(100);
    await started;
    expect(shown().state?.pending_claim).toMatchObject({
      code: "ABCD2345",
      message_url: expect.stringContaining("link%20ABCD2345"),
    });
    const reads = () => t.api.seen("GET", path).length;
    const before = reads();
    await t.time.pass(9_000, 500);
    expect(reads()).toBe(before + 3);

    // The person sends `link <code>` in LINE: the next read shows the link, and the reads stop.
    s.send();
    await t.time.pass(3_000, 500);
    expect(shown().state).toMatchObject({
      pending_claim: null,
      connection_active: true,
      link: { line_display_name: "Alice" },
    });
    const settled = reads();
    await t.time.pass(30_000, 1_000);
    expect(reads()).toBe(settled);

    const disconnected = t.client.call("line.disconnect", { workspace: WS });
    await t.time.pass(100);
    await disconnected;
    expect(t.api.seen("DELETE", path)).toHaveLength(1);
    expect(shown().state?.link).toBeNull();
  });

  it("stops reading at expiry and cancels the attempt", async () => {
    const t = setup();
    server(t, 10);
    const shown = t.watch<LineValue>({ topic: "line", workspace: WS });
    await t.time.pass(100);

    const started = t.client.call("line.start", { workspace: WS });
    await t.time.pass(100);
    await started;
    const reads = () => t.api.seen("GET", path).length;
    await t.time.pass(15_000, 500);
    const expired = reads();
    await t.time.pass(15_000, 500);
    expect(reads()).toBe(expired);

    const cancelled = t.client.call("line.cancel", { workspace: WS });
    await t.time.pass(100);
    await cancelled;
    expect(t.api.seen("DELETE", `${path}/connect`)).toHaveLength(1);
    expect(shown().state?.pending_claim).toBeNull();
  });

  it("a failed read stops the reads until a refresh", async () => {
    const t = setup();
    const s = server(t);
    s.failRead = true;
    const shown = t.watch<LineValue>({ topic: "line", workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ state: null, error: true });
    const reads = () => t.api.seen("GET", path).length;
    const stopped = reads();
    await t.time.pass(15_000, 500);
    expect(reads()).toBe(stopped);

    s.failRead = false;
    const refreshed = t.client.call("line.refresh", { workspace: WS });
    await t.time.pass(100);
    await refreshed;
    expect(shown()).toMatchObject({ state: { configured: true }, error: false });
  });
});
