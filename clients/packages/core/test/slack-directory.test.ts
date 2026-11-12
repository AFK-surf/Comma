import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { SlackDirectory } from "../src/contract.ts";
import {
  SLACK_DIRECTORY_KEEP_MS,
  SLACK_DIRECTORY_PACE_MS,
} from "../src/slack-directory.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../src/testing/index.ts";

const channels = "/v1/comma/workspaces/wsp/plugins/slack/channels";
const people = "/v1/comma/workspaces/wsp/plugins/slack/people";
const menu: Topic = { topic: "slackDirectory", workspace: "wsp" };

const channel = (name: string, member = false) => ({
  id: `C-${name}`,
  name,
  member,
  team_id: "T1",
});
const amy = { id: "U1", name: "Amy", handle: "amy", avatar_ref: "ref", team_id: "T1" };
const lastPage = (data: unknown[]) => json(200, { data, next_cursor: null });

function setup(answer: (request: SeenRequest) => unknown) {
  const host = new FakeHost();
  let next = answer;
  host.api.on("GET", channels, (request: SeenRequest) => next(request));
  host.api.on("GET", people, () => lastPage([amy]));
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  let stop: (() => void) | undefined;
  core.observeSession(signedIn());
  return {
    time: host.time!,
    answer: (value: (request: SeenRequest) => unknown) => (next = value),
    seen: () =>
      host.api.requests.filter((r) => r.path.startsWith(channels)).map((r) => r.path),
    show: () => {
      stop = client.subscribe(
        menu,
        (v) => values.set(topicKey(menu), v),
        () => undefined
      );
    },
    hide: () => stop?.(),
    reread: () => client.call("slackDirectory.reread", { workspace: "wsp" }),
    names: () =>
      (values.get(topicKey(menu)) as SlackDirectory | null)?.channels.map(
        (c) => c.name
      ),
    value: () => values.get(topicKey(menu)) as SlackDirectory | null | undefined,
  };
}

/** Two pages of channels: `alpha`, then `beta` at the cursor `next`. */
const twoPages = (request: SeenRequest) =>
  request.path.includes("cursor=next")
    ? lastPage([channel("beta", true)])
    : json(200, { data: [channel("alpha")], next_cursor: "next" });

describe("the Slack channels and people a message can name", () => {
  it("reads once while the answer is kept, and again once it ran out", async () => {
    const t = setup(() => lastPage([channel("bugs", true)]));
    t.show();
    await t.time.pass(100);
    expect(t.value()).toEqual({
      channels: [{ id: "C-bugs", name: "bugs", member: true, teamId: "T1" }],
      people: [
        { id: "U1", name: "Amy", handle: "amy", avatarRef: "ref", teamId: "T1" },
      ],
    });

    await t.reread();
    t.hide();
    t.show();
    await t.time.pass(100);
    expect(t.seen()).toHaveLength(1);

    await t.time.pass(SLACK_DIRECTORY_KEEP_MS, 1_000);
    await t.reread();
    await t.time.pass(100);
    expect(t.seen()).toHaveLength(2);
  });

  it("follows the cursor at Slack's pace, shows the pages as they come, joined channels first", async () => {
    const t = setup(twoPages);
    t.show();
    await t.time.pass(100);
    expect(t.names()).toEqual(["alpha"]);
    expect(t.seen()).toHaveLength(1);

    await t.time.pass(SLACK_DIRECTORY_PACE_MS, 1_000);
    expect(t.seen()).toEqual([channels, `${channels}?cursor=next`]);
    expect(t.names()).toEqual(["beta", "alpha"]);
    // People had one page: only channels were asked again.
    expect(t.value()?.people).toHaveLength(1);
  });

  it("goes on from its place after a failure, 30 seconds later", async () => {
    const t = setup(twoPages);
    t.show();
    await t.time.pass(100);

    t.answer(() => offline());
    await t.time.pass(SLACK_DIRECTORY_PACE_MS, 1_000);
    expect(t.names()).toEqual(["alpha"]);
    const failedAt = t.seen().length;

    t.answer(twoPages);
    await t.reread();
    await t.time.pass(100);
    expect(t.seen()).toHaveLength(failedAt);

    await t.time.pass(30_000, 1_000);
    await t.reread();
    await t.time.pass(100);
    expect(t.seen().at(-1)).toBe(`${channels}?cursor=next`);
    expect(t.names()).toEqual(["beta", "alpha"]);
  });

  it("starts over after three failures in a row", async () => {
    const t = setup(() => offline());
    t.show();
    await t.time.pass(100);
    for (let i = 0; i < 2; i++) {
      await t.time.pass(30_000, 1_000);
      await t.reread();
      await t.time.pass(100);
    }
    expect(t.value()).toEqual({
      channels: [],
      people: [
        { id: "U1", name: "Amy", handle: "amy", avatarRef: "ref", teamId: "T1" },
      ],
    });

    t.answer(() => lastPage([channel("bugs")]));
    await t.time.pass(30_000, 1_000);
    await t.reread();
    await t.time.pass(100);
    expect(t.names()).toEqual(["bugs"]);
    expect(t.value()?.people).toHaveLength(1);
  });

  it("keeps a complete answer shown until the next one is complete", async () => {
    const t = setup(() => lastPage([channel("old")]));
    t.show();
    await t.time.pass(100);
    expect(t.names()).toEqual(["old"]);

    t.answer(twoPages);
    await t.time.pass(SLACK_DIRECTORY_KEEP_MS, 1_000);
    await t.reread();
    await t.time.pass(100);
    expect(t.names()).toEqual(["old"]);

    await t.time.pass(SLACK_DIRECTORY_PACE_MS, 1_000);
    expect(t.names()).toEqual(["beta", "alpha"]);
  });

  it("keeps a complete answer shown when the next read fails and goes on", async () => {
    const t = setup(() => lastPage([channel("old")]));
    t.show();
    await t.time.pass(100);

    t.answer((request) =>
      request.path.includes("cursor=next")
        ? offline()
        : json(200, { data: [channel("alpha")], next_cursor: "next" })
    );
    await t.time.pass(SLACK_DIRECTORY_KEEP_MS, 1_000);
    await t.reread();
    await t.time.pass(SLACK_DIRECTORY_PACE_MS, 1_000);
    expect(t.names()).toEqual(["old"]);

    // Goes on with another page to come: the old answer still stands.
    t.answer((request) =>
      request.path.includes("cursor=last")
        ? lastPage([channel("gamma")])
        : json(200, { data: [channel("beta")], next_cursor: "last" })
    );
    await t.time.pass(30_000, 1_000);
    await t.reread();
    await t.time.pass(100);
    expect(t.names()).toEqual(["old"]);

    await t.time.pass(SLACK_DIRECTORY_PACE_MS, 1_000);
    expect(t.names()).toEqual(["alpha", "beta", "gamma"]);
  });
});
