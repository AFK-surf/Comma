import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TailnetValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const tailnetPath = (ws: string) => `/v1/comma/workspaces/${ws}/integrations/tailnet`;
const status = (extra: Record<string, unknown> = {}) => ({
  enabled: false,
  state: "disabled",
  approved: false,
  login_url: null,
  tailnet: null,
  node_name: null,
  login_name: null,
  node_tags: [],
  addresses: [],
  key_expiry: null,
  error: null,
  settings: { tags: ["tag:comma-agent"], accept_routes: false, expected_tailnet: null },
  updated_at: null,
  ...extra,
});

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: "ws-1", group_id: "g-1", name: "One" }],
  });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const k = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return () => values.get(k) as T;
  };
  core.observeSession(signedIn());
  return { client, time: host.time!, api: host.api, watch };
}

describe("tailnet", () => {
  it("connects, reads every 3 s while the node waits, then reads the peers once it runs", async () => {
    const t = setup();
    let current = status();
    t.api.on("GET", tailnetPath("ws-1"), () => json(200, current));
    t.api.on("PUT", tailnetPath("ws-1"), () => {
      current = status({
        enabled: true,
        state: "needs_login",
        login_url: "https://login.tailscale.com/a/abc",
      });
      return json(200, current);
    });
    t.api.on("GET", `${tailnetPath("ws-1")}/peers`, {
      peers: [
        {
          name: "nas",
          dns_name: "nas.example.ts.net",
          ips: ["100.64.0.1"],
          online: true,
        },
      ],
      next: 0,
    });
    const shown = t.watch<TailnetValue>({ topic: "tailnet", prefer: "ws-1" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ workspace: "ws-1", status: { state: "disabled" } });

    const connected = t.client.call("tailnet.connect", {
      workspace: "ws-1",
      tags: ["tag:comma-agent"],
      accept_routes: true,
      expected_tailnet: " acme.com ",
    });
    await t.time.pass(100);
    expect(await connected).toMatchObject({ state: "needs_login" });
    expect(t.api.seen("PUT", tailnetPath("ws-1"))[0]!.body).toEqual({
      tags: ["tag:comma-agent"],
      accept_routes: true,
      expected_tailnet: "acme.com",
    });
    expect(shown().status?.login_url).toBe("https://login.tailscale.com/a/abc");

    // A tailnet admin approves; the next 3 s read finds the node running.
    const reads = t.api.seen("GET", tailnetPath("ws-1")).length;
    current = status({ enabled: true, state: "running", tailnet: "acme.com" });
    await t.time.pass(3_100);
    expect(t.api.seen("GET", tailnetPath("ws-1")).length).toBeGreaterThan(reads);
    expect(shown()).toMatchObject({
      status: { state: "running", login_url: null },
      peers: [{ name: "nas", online: true }],
    });

    // Running: no more reads until something changes.
    const settled = t.api.seen("GET", tailnetPath("ws-1")).length;
    await t.time.pass(10_000);
    expect(t.api.seen("GET", tailnetPath("ws-1")).length).toBe(settled);
  });

  it("refuses tags that are not tags before asking the server", async () => {
    const t = setup();
    t.api.on("GET", tailnetPath("ws-1"), status());
    t.watch<TailnetValue>({ topic: "tailnet", prefer: "ws-1" });
    await t.time.pass(100);
    await expect(
      t.client.call("tailnet.connect", {
        workspace: "ws-1",
        tags: ["ops"],
        accept_routes: false,
        expected_tailnet: null,
      })
    ).rejects.toMatchObject({ code: "invalid_params" });
    expect(t.api.seen("PUT", tailnetPath("ws-1"))).toEqual([]);
  });

  it("says a failed read and reads again on refresh", async () => {
    const t = setup();
    let up = false;
    t.api.on("GET", tailnetPath("ws-1"), () => (up ? json(200, status()) : offline()));
    const shown = t.watch<TailnetValue>({ topic: "tailnet", prefer: "ws-1" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ error: true, status: null });
    up = true;
    await t.client.call("tailnet.refresh", { workspace: "ws-1" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ error: false, status: { state: "disabled" } });
  });
});
