import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { BrowserViewValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { base64, fromBase64 } from "../src/record.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const path = "/v1/comma/workspaces/wsp/browsers/agent/session";
const events = `${path}/events`;
const ref = { workspace: "wsp", agent: "agent", session: "session", viewer: "v1" };
const view: Topic = { topic: "browserView", ...ref };
const binding = (control = "agent", updated = "2026-09-28T00:00:00Z") => ({
  agent_id: "agent",
  session_id: "session",
  status: "ready",
  control,
  busy: false,
  storage_error: null,
  updated_at: updated,
});
const tabs = [
  { tab_id: "t1", title: "First", url: "https://one.test" },
  { tab_id: "t2", title: "Second", url: "https://two.test" },
];
const frame = (data: string) => ({
  data,
  tab_id: "t1",
  metadata: { deviceWidth: 1280, deviceHeight: 720 },
});

function setup() {
  const host = new FakeHost();
  host.api.onStream(events);
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
    return () => values.get(key) as BrowserViewValue | null | undefined;
  };
  const unwatch = (topic: Topic) => stops.get(topicKey(topic))?.();
  /** What the browser was told, by operation. */
  const told = (operation: string) =>
    host.api
      .seen("POST", path)
      .map((r) => r.body as { operation: string; args: Record<string, unknown> })
      .filter((body) => body.operation === operation);
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch, unwatch, told };
}

describe("an agent's browser in its panel", () => {
  it("reads its tabs, streams the first one's newest frame, and stops when the panel closes", async () => {
    const t = setup();
    t.api.on("POST", path, { ...binding(), tabs });
    const value = t.watch(view);
    await t.time.pass(100);
    expect(value()).toMatchObject({ tabs, tab: "t1", status: "connecting" });
    expect(t.told("tabs")).toEqual([{ viewer_id: "v1", operation: "tabs", args: {} }]);
    expect(t.api.seen("GET", events)[0]!.path).toBe(`${events}?tab_id=t1&viewer_id=v1`);

    const stream = t.api.open(events)!;
    stream.event({ browser: binding(), can_control: false, frame: frame("AAA") });
    stream.event({ browser: binding(), can_control: false, frame: frame("BBB") });
    await t.time.pass(100);
    expect(value()).toMatchObject({
      status: "agent",
      controlling: false,
      storageError: null,
      frame: { seq: 2, data: "BBB", width: 1280, height: 720 },
    });

    t.unwatch(view);
    await t.time.pass(100);
    expect(stream.closed).toBe(true);
    await t.time.pass(10_000, 1_000);
    expect(t.api.seen("GET", events)).toHaveLength(1);
  });

  it("opens a stream that ended again 250 ms later, and stops on one that broke", async () => {
    const t = setup();
    t.api.on("POST", path, { ...binding(), tabs });
    const value = t.watch(view);
    await t.time.pass(100);
    t.api.open(events)!.end();
    await t.time.pass(200, 10);
    expect(t.api.seen("GET", events)).toHaveLength(1);
    await t.time.pass(100, 10);
    expect(t.api.seen("GET", events)).toHaveLength(2);

    t.api.open(events)!.fail();
    await t.time.pass(100);
    expect(value()).toMatchObject({
      status: "disconnected",
      controlling: false,
      error: "stream",
    });
    await t.time.pass(10_000, 1_000);
    expect(t.api.seen("GET", events)).toHaveLength(2);

    // The person reconnects: the tabs are read again and the stream opens again.
    await t.client.call("browserView.reconnect", ref);
    await t.time.pass(100);
    expect(t.told("tabs")).toHaveLength(2);
    expect(t.api.seen("GET", events)).toHaveLength(3);
    expect(value()).toMatchObject({ status: "connecting", error: null });
  });

  it("takes control, sends input in order while it does, and an older stream event cannot undo the grant", async () => {
    const t = setup();
    t.api.on("POST", path, (request) => {
      const body = request.body as { operation: string };
      if (body.operation === "take_control")
        return json(200, binding("human", "2026-09-28T00:00:01Z"));
      return json(200, { ...binding(), tabs });
    });
    const value = t.watch(view);
    await t.time.pass(100);
    // Input before control is not sent.
    await t.client.call("browserView.input", {
      ...ref,
      input: { type: "text", text: "early" },
    });
    expect(
      await t.client.call("browserView.command", { ...ref, operation: "take_control" })
    ).toEqual({ closed: false });
    await t.time.pass(100);
    expect(value()).toMatchObject({ controlling: true, pending: false });

    t.api.open(events)!.event({ browser: binding(), can_control: false, frame: null });
    await t.time.pass(100);
    expect(value()).toMatchObject({ controlling: true });

    await t.client.call("browserView.input", {
      ...ref,
      input: { type: "text", text: "中文" },
    });
    await t.client.call("browserView.input", {
      ...ref,
      input: { type: "keyDown", key: "Tab", code: "Tab", keyCode: 9, modifiers: 0 },
    });
    await t.time.pass(100);
    expect(t.told("input").map((body) => body.args)).toEqual([
      { tab_id: "t1", input: { type: "text", text: "中文" } },
      {
        tab_id: "t1",
        input: { type: "keyDown", key: "Tab", code: "Tab", keyCode: 9, modifiers: 0 },
      },
    ]);
  });

  it("lets go of control when input fails, and says when input piles up", async () => {
    const t = setup();
    const release = { input: () => undefined as void };
    t.api.on("POST", path, (request) => {
      const body = request.body as { operation: string };
      if (body.operation === "take_control")
        return json(200, binding("human", "2026-09-28T00:00:01Z"));
      if (body.operation === "input") return json(503, { error: "unavailable" });
      return json(200, { ...binding(), tabs });
    });
    const value = t.watch(view);
    await t.time.pass(100);
    await t.client.call("browserView.command", { ...ref, operation: "take_control" });
    release.input = t.api.hold("POST", path);
    for (let i = 0; i < 34; i++)
      await t.client.call("browserView.input", {
        ...ref,
        input: { type: "text", text: `${i}` },
      });
    await t.time.pass(100);
    expect(value()).toMatchObject({ error: "queueFull", controlling: true });
    release.input();
    await t.time.pass(100);
    expect(value()).toMatchObject({ error: "input", controlling: false });
    expect(t.told("input")).toHaveLength(1);
  });

  it("says a closed browser is closed, and a failed command is the view's error", async () => {
    const t = setup();
    t.api.on("POST", path, (request) => {
      const body = request.body as { operation: string };
      if (body.operation === "close")
        return json(200, { ...binding(), status: "closed" });
      if (body.operation === "return_control") return json(502, { error: "upstream" });
      return json(200, { ...binding(), tabs });
    });
    const value = t.watch(view);
    await t.time.pass(100);
    expect(
      await t.client.call("browserView.command", {
        ...ref,
        operation: "return_control",
      })
    ).toEqual({ closed: false });
    await t.time.pass(100);
    expect(value()).toMatchObject({ error: "control", pending: false });
    expect(
      await t.client.call("browserView.command", { ...ref, operation: "close" })
    ).toEqual({ closed: true });
    expect(t.told("close")[0]!.args).toEqual({ tab_id: "t1" });
    await t.time.pass(100);
    expect(value()).toMatchObject({ error: null, pending: false });
  });

  it("streams another tab once it is selected, letting go of control", async () => {
    const t = setup();
    t.api.on("POST", path, { ...binding(), tabs });
    const value = t.watch(view);
    await t.time.pass(100);
    await t.client.call("browserView.selectTab", { ...ref, tab: "t2" });
    await t.time.pass(100);
    expect(value()).toMatchObject({ tab: "t2", controlling: false });
    expect(t.api.seen("GET", events).map((r) => r.path)).toEqual([
      `${events}?tab_id=t1&viewer_id=v1`,
      `${events}?tab_id=t2&viewer_id=v1`,
    ]);
  });
});

describe("an agent's browser in its panel, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("POST", path, { ...binding(), tabs });
    t.watch(view);
    await t.time.pass(100);
    t.api
      .open(events)!
      .event({ browser: binding(), can_control: false, frame: frame("AAA") });
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const changed = structuredClone(recorded.inputs);
    const tabsRead = changed.find(
      (input) => input.kind === "response" && input.request.path === path
    );
    if (tabsRead?.kind !== "response") throw new Error("no tabs read");
    const body = new TextDecoder().decode(fromBase64(tabsRead.body));
    tabsRead.body = base64(new TextEncoder().encode(body.replaceAll("First", "Other")));
    const differs = await replay(
      { inputs: changed, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(differs.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
