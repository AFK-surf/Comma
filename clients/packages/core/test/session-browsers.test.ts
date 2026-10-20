import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { SessionBrowserValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const path = "/v1/comma/workspaces/wsp/browsers";
const shown: Topic = {
  topic: "sessionBrowser",
  workspace: "wsp",
  conversation: "cnv",
  participant: "prt",
};
const binding = (session: string, status = "ready") => ({
  agent_id: "agent",
  session_id: session,
  status,
  control: "agent",
  busy: false,
  updated_at: "2026-09-28T00:00:00Z",
});

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops = new Map<string, () => void>();
  const watch = (topic: Topic) => {
    const key = topicKey(topic);
    stops.set(
      key,
      client.subscribe(
        topic,
        (v) => values.set(key, v),
        () => undefined
      )
    );
    return () => values.get(key) as SessionBrowserValue | undefined;
  };
  const unwatch = (topic: Topic) => stops.get(topicKey(topic))?.();
  core.observeSession(signedIn());
  return { client, time: host.time!, api: host.api, watch, unwatch };
}

describe("a conversation's browser", () => {
  it("is read while shown and every 10 seconds, at once on a refresh, and no more once unshown", async () => {
    const t = setup();
    t.api.on("GET", path, {
      browsers: [binding("starting", "starting"), binding("s1")],
    });
    const value = t.watch(shown);
    await t.time.pass(100);
    expect(value()).toEqual({ browser: binding("s1") });
    expect(t.api.seen("GET", path)[0]!.path).toBe(
      `${path}?conversation_id=cnv&participant_id=prt`
    );

    await t.time.pass(10_000, 1_000);
    expect(t.api.seen("GET", path)).toHaveLength(2);
    await t.time.pass(3_000, 1_000);
    await t.client.call("sessionBrowser.refresh", {
      workspace: "wsp",
      conversation: "cnv",
      participant: "prt",
    });
    await t.time.pass(100);
    expect(t.api.seen("GET", path)).toHaveLength(3);
    // The next read is 10 seconds after the refresh.
    await t.time.pass(9_000, 1_000);
    expect(t.api.seen("GET", path)).toHaveLength(3);
    await t.time.pass(1_000, 500);
    expect(t.api.seen("GET", path)).toHaveLength(4);

    t.unwatch(shown);
    await t.time.pass(30_000, 1_000);
    expect(t.api.seen("GET", path)).toHaveLength(4);
  });

  it("shows no browser when none is ready or the read fails", async () => {
    const t = setup();
    t.api.on("GET", path, { browsers: [binding("s1", "stopped")] });
    const value = t.watch(shown);
    await t.time.pass(100);
    expect(value()).toEqual({ browser: null });

    t.api.on("GET", path, offline());
    await t.time.pass(10_000, 1_000);
    expect(value()).toEqual({ browser: null });

    t.api.on("GET", path, json(200, { browsers: [binding("s2")] }));
    await t.time.pass(10_000, 1_000);
    expect(value()).toEqual({ browser: binding("s2") });
  });
});
