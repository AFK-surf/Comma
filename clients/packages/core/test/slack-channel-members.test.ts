import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  SLACK_MEMBERS_KEEP_MS,
  SLACK_MEMBERS_PACE_MS,
} from "../src/slack-channel-members.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../src/testing/index.ts";

const path = "/v1/comma/workspaces/wsp/plugins/slack/channels/C1/members";
const topic: Topic = { topic: "slackChannelMembers", workspace: "wsp", channel: "C1" };

function setup(answer: (request: SeenRequest) => unknown) {
  const host = new FakeHost();
  let next = answer;
  host.api.on("GET", path, (request: SeenRequest) => next(request));
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  let value: unknown;
  let stop: (() => void) | undefined;
  core.observeSession(signedIn());
  return {
    time: host.time!,
    answer: (a: (request: SeenRequest) => unknown) => (next = a),
    reads: () => host.api.requests.filter((r) => r.path.startsWith(path)).length,
    show: () => {
      stop = client.subscribe(
        topic,
        (v) => (value = v),
        () => undefined
      );
    },
    hide: () => stop?.(),
    value: () => value,
    key: topicKey(topic),
  };
}

const twoPages = (request: SeenRequest) =>
  request.path.includes("cursor=next")
    ? json(200, { data: ["U2"], next_cursor: null })
    : json(200, { data: ["U1"], next_cursor: "next" });

describe("who is in a Slack channel", () => {
  it("follows the cursor, shows pages as they come, and reads again only once the answer ran out", async () => {
    const t = setup(twoPages);
    t.show();
    await t.time.pass(100);
    expect(t.value()).toEqual(["U1"]);

    await t.time.pass(SLACK_MEMBERS_PACE_MS, 100);
    expect(t.value()).toEqual(["U1", "U2"]);
    expect(t.reads()).toBe(2);

    t.hide();
    t.show();
    await t.time.pass(100);
    expect(t.reads()).toBe(2);

    t.hide();
    await t.time.pass(SLACK_MEMBERS_KEEP_MS, 1_000);
    t.show();
    await t.time.pass(100);
    expect(t.reads()).toBe(3);
  });

  it("keeps what it got when a read fails, and reads again on a showing 30 seconds later", async () => {
    const t = setup(() => offline());
    t.show();
    await t.time.pass(100);
    expect(t.value()).toEqual([]);

    t.answer(() => json(200, { data: ["U1"], next_cursor: null }));
    t.hide();
    t.show();
    await t.time.pass(100);
    expect(t.reads()).toBe(1);

    t.hide();
    await t.time.pass(30_000, 1_000);
    t.show();
    await t.time.pass(100);
    expect(t.value()).toEqual(["U1"]);
  });
});
