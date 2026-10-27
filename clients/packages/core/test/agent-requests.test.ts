import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { AgentRequestsValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  signedOut,
  startTestCore,
  TestTime,
} from "../src/testing/index.ts";

const GROUP = "grp_1";
const CONVERSATION = "cnv_1";
const BASE = `/v1/comma/groups/${GROUP}/conversations/${CONVERSATION}/requests`;

const github = (status: string, extra: Record<string, unknown> = {}) => ({
  id: "cap-1",
  type: "oauth_authorization",
  status,
  outcome: null,
  expires_at: 2_000,
  created_at: 1_400,
  source_message_id: "msg-1",
  oauth: {
    provider: "github",
    alias: "github",
    reason: "An app keeps its code in GitHub.",
    scopes: ["repo"],
    authorization_url: "https://github.com/login/oauth/authorize?state=s",
  },
  ...extra,
});

function setup() {
  const host = new FakeHost({ time: new TestTime(1_500_000) });
  host.api.onStream(`${BASE}/events`);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const unsubscribes = new Map<string, () => void>();
  const watch = (topic: Topic) => {
    const key = topicKey(topic);
    unsubscribes.set(
      key,
      client.subscribe(
        topic,
        (v) => values.set(key, v),
        () => undefined
      )
    );
    return () => values.get(key) as AgentRequestsValue | undefined;
  };
  const unwatch = (topic: Topic) => unsubscribes.get(topicKey(topic))?.();
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, watch, unwatch };
}

describe("An Agent's requests in a conversation", () => {
  it("shows the server's requests, follows each change, and passes a decline on", async () => {
    const t = setup();
    const requests = t.watch({
      topic: "agentRequests",
      group: GROUP,
      conversation: CONVERSATION,
    });
    await t.time.pass(100);
    const stream = t.host.api.open(`${BASE}/events`)!;

    stream.named("snapshot", {
      data: [github("pending"), { id: "cap-x", type: "location", status: "pending" }],
    });
    await t.time.pass(100);
    // A kind the app draws no card for is left out.
    expect(requests()).toMatchObject({
      loading: false,
      error: false,
      requests: [
        {
          id: "cap-1",
          status: "pending",
          expiresAt: 2_000_000,
          sourceMessageId: "msg-1",
          oauth: {
            provider: "github",
            authorizationUrl: "https://github.com/login/oauth/authorize?state=s",
          },
        },
      ],
    });

    // The provider's callback ended it: every device hears the same ending.
    stream.named(
      "request",
      github("completed", {
        outcome: "connected",
        oauth: {
          ...github("x").oauth,
          authorization_url: undefined,
          account: "octocat",
        },
      })
    );
    await t.time.pass(100);
    expect(requests()?.requests).toMatchObject([
      {
        id: "cap-1",
        status: "completed",
        outcome: "connected",
        oauth: { account: "octocat" },
      },
    ]);
    expect(requests()?.requests[0]?.oauth.authorizationUrl).toBeUndefined();

    // A second request, which the person declines; the answer replaces it at once.
    stream.named("request", github("pending", { id: "cap-2", created_at: 1_450 }));
    await t.time.pass(100);
    t.host.api.on("POST", `${BASE}/cap-2/decline`, () =>
      json(200, github("completed", { id: "cap-2", outcome: "declined" }))
    );
    await t.client.call("agentRequests.decline", {
      group: GROUP,
      conversation: CONVERSATION,
      request: "cap-2",
    });
    await t.time.pass(100);
    expect(requests()?.requests.find((r) => r.id === "cap-2")).toMatchObject({
      status: "completed",
      outcome: "declined",
    });
  });

  it("opens the stream again after it ends, and the snapshot replaces what was kept", async () => {
    const t = setup();
    const requests = t.watch({
      topic: "agentRequests",
      group: GROUP,
      conversation: CONVERSATION,
    });
    await t.time.pass(100);
    t.host.api.open(`${BASE}/events`)!.named("snapshot", { data: [github("pending")] });
    await t.time.pass(100);
    t.host.api.open(`${BASE}/events`)!.end();
    await t.time.pass(1_100);

    const reopened = t.host.api.open(`${BASE}/events`)!;
    reopened.named("snapshot", { data: [github("expired")] });
    await t.time.pass(100);
    expect(requests()?.requests).toMatchObject([{ id: "cap-1", status: "expired" }]);
  });

  it("does not follow, for the next account, a conversation the last account's window no longer shows", async () => {
    const t = setup();
    const topic = { topic: "agentRequests", group: GROUP, conversation: CONVERSATION };
    t.watch(topic);
    await t.time.pass(100);
    expect(t.host.api.streams).toHaveLength(1);

    // Signing out closes the conversation's window; within the topic's eviction grace another account signs in.
    t.unwatch(topic);
    await t.time.pass(100);
    t.core.observeSession(signedOut());
    await t.time.pass(100);
    t.core.observeSession(signedIn("user-2", { generation: 3 }));
    await t.time.pass(10_000);
    expect(t.host.api.streams).toHaveLength(1);

    // Shown again, it is followed for the account there is now.
    t.watch(topic);
    await t.time.pass(100);
    expect(t.host.api.streams).toHaveLength(2);
    expect(t.host.api.open(`${BASE}/events`)).toBeDefined();
  });
});
