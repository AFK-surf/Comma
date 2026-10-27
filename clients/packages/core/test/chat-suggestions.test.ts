import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatSuggestion } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const path = "/v1/comma/groups/grp_1/conversations/cnv_1/suggestions";
const suggestions = [
  { id: "sug_1", label: "Ship it", prompt: "Open a PR", rank: 1 },
  { id: "sug_2", label: "Add tests", prompt: "Add tests" },
];
const turn = (message = "msg_1", locale = "en") => ({
  topic: "chatSuggestions",
  group: "grp_1",
  conversation: "cnv_1",
  message,
  locale,
});

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops: (() => void)[] = [];
  const watch = (topic: Topic) => {
    const k = topicKey(topic);
    stops.push(
      client.subscribe(
        topic,
        (v) => values.set(k, v),
        () => undefined
      )
    );
    return () => values.get(k) as ChatSuggestion[] | null | undefined;
  };
  const closeAll = async () => {
    for (const stop of stops.splice(0)) stop();
    await host.time!.pass(10);
  };
  core.observeSession(signedIn());
  return { host, core, time: host.time!, api: host.api, watch, closeAll };
}

describe("a settled turn's suggestions", () => {
  it("are asked once per turn and locale, and kept when the turn shows again", async () => {
    const t = setup();
    t.api.on("POST", path, { data: suggestions });
    const shown = t.watch(turn());
    await t.time.pass(10);
    expect(shown()).toEqual([
      { id: "sug_1", label: "Ship it", prompt: "Open a PR" },
      { id: "sug_2", label: "Add tests", prompt: "Add tests" },
    ]);
    expect(t.api.seen("POST", path).map((request) => request.path)).toEqual([
      `${path}?locale=en`,
    ]);

    // The same turn shown again costs no second model call.
    await t.closeAll();
    t.watch(turn());
    await t.time.pass(10);
    expect(t.api.seen("POST", path)).toHaveLength(1);

    // Another language or a newer turn is a new request.
    t.watch(turn("msg_1", "zh-CN"));
    t.watch(turn("msg_2"));
    await t.time.pass(10);
    expect(t.api.seen("POST", path).map((request) => request.path)).toEqual([
      `${path}?locale=en`,
      `${path}?locale=zh-CN`,
      `${path}?locale=en`,
    ]);
  });

  it("are none while asked and none when the server fails", async () => {
    const t = setup();
    t.api.on("POST", path, json(503, { error: "unavailable" }));
    const shown = t.watch(turn());
    expect(shown()).toBeUndefined();
    await t.time.pass(10);
    expect(shown()).toEqual([]);
  });

  it("are asked again for another account", async () => {
    const t = setup();
    t.api.on("POST", path, { data: suggestions });
    t.watch(turn());
    await t.time.pass(10);
    t.core.observeSession(signedIn("user-2"));
    await t.time.pass(10);
    expect(t.api.seen("POST", path)).toHaveLength(2);
  });
});
