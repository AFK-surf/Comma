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

const phone = (status: string, extra: Record<string, unknown> = {}) => ({
  id: "cap-p",
  type: "computer_use_start",
  status,
  outcome: null,
  expires_at: 2_000,
  created_at: 1_400,
  phone: {
    title: "Pixel 8 · Android 15",
    target: "android:3B162S00P0N00000",
    device_id: "dev_mac",
  },
  ...extra,
});

const ownAsked = (id: string, status: string) => ({
  id,
  type: "location",
  status,
  group_id: "group-2",
  conversation_id: "conversation-2",
  location: { reason: "Directions." },
});

function setup() {
  const host = new FakeHost({ time: new TestTime(1_500_000) });
  host.api.onStream(`${BASE}/events`);
  host.api.onStream("/v1/comma/location-requests/events");
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
      data: [github("pending"), { id: "cap-x", type: "camera", status: "pending" }],
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
    expect(requests()?.requests[0]).not.toHaveProperty("oauth.authorizationUrl");

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

  it("passes what a card filled in to the server, and shows the request it answers with", async () => {
    const t = setup();
    const secret = github("pending", {
      oauth: {
        provider: "secret",
        alias: "openai",
        reason: "The script needs it.",
        scopes: [],
        input: {
          kind: "secret",
          label: "OpenAI API Key",
          help_url: "http://not-https.example",
        },
      },
    });
    const get = t.watch({
      topic: "agentRequests",
      group: GROUP,
      conversation: CONVERSATION,
    });
    await t.time.pass(100);
    t.host.api.open(`${BASE}/events`)!.named("snapshot", { data: [secret] });
    await t.time.pass(100);
    // Only an https page opens.
    expect(get()?.requests[0]).toHaveProperty("oauth.input", {
      kind: "secret",
      label: "OpenAI API Key",
    });

    t.host.api.on("POST", `${BASE}/cap-1/input`, () =>
      json(200, github("completed", { outcome: "connected" }))
    );
    await t.client.call("agentRequests.fill", {
      group: GROUP,
      conversation: CONVERSATION,
      request: "cap-1",
      values: { value: "sk-typed" },
    });
    await t.time.pass(100);
    expect(get()?.requests[0]?.outcome).toBe("connected");
  });

  it("follows the person's own location requests while the app is open, in every Group", async () => {
    const t = setup();
    const own = t.watch({ topic: "agentLocationRequests" });
    await t.time.pass(100);
    const stream = t.host.api.open("/v1/comma/location-requests/events")!;
    stream.named("snapshot", { data: [ownAsked("cap-1", "pending")] });
    await t.time.pass(100);
    expect(own()?.requests).toEqual([
      { id: "cap-1", group: "group-2", conversation: "conversation-2" },
    ]);

    stream.named("request", ownAsked("cap-2", "pending"));
    stream.named("request", ownAsked("cap-1", "completed"));
    await t.time.pass(100);
    expect(own()?.requests).toEqual([
      { id: "cap-2", group: "group-2", conversation: "conversation-2" },
    ]);
  });

  it("shows a location request and sends the position once, keeping none of it", async () => {
    const t = setup();
    const requests = t.watch({
      topic: "agentRequests",
      group: GROUP,
      conversation: CONVERSATION,
    });
    await t.time.pass(100);
    const stream = t.host.api.open(`${BASE}/events`)!;
    const asked = {
      id: "cap-2",
      type: "location",
      status: "pending",
      outcome: null,
      expires_at: 2_000,
      created_at: 1_400,
      source_message_id: "msg-1",
      location: { reason: "Find cafes near you." },
    };
    stream.named("snapshot", { data: [asked] });
    await t.time.pass(100);
    expect(requests()?.requests).toEqual([
      {
        id: "cap-2",
        type: "location",
        status: "pending",
        outcome: null,
        expiresAt: 2_000_000,
        createdAt: 1_400_000,
        sourceMessageId: "msg-1",
        location: { reason: "Find cafes near you." },
      },
    ]);

    t.host.api.on("POST", `${BASE}/cap-2/location`, () =>
      json(200, { ...asked, status: "completed", outcome: "shared" })
    );
    await t.client.call("agentRequests.shareLocation", {
      group: GROUP,
      conversation: CONVERSATION,
      request: "cap-2",
      latitude: 35.67,
      longitude: 139.76,
      accuracy: 20,
    });
    expect(t.host.api.requests.at(-1)!.body).toEqual({
      latitude: 35.67,
      longitude: 139.76,
      accuracy_m: 20,
    });
    await t.time.pass(100);
    expect(requests()?.requests[0]).toMatchObject({
      status: "completed",
      outcome: "shared",
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

  it("shows a phone's consent and passes its owner's answer on", async () => {
    const t = setup();
    const requests = t.watch({
      topic: "agentRequests",
      group: GROUP,
      conversation: CONVERSATION,
    });
    await t.time.pass(100);
    t.host.api.open(`${BASE}/events`)!.named("snapshot", { data: [phone("pending")] });
    await t.time.pass(100);
    expect(requests()?.requests).toMatchObject([
      {
        id: "cap-p",
        type: "computer_use_start",
        status: "pending",
        phone: { title: "Pixel 8 · Android 15", deviceId: "dev_mac" },
      },
    ]);
    let asked: unknown;
    t.host.api.on("POST", `${BASE}/cap-p/decision`, (request) => {
      asked = request.body;
      return json(200, phone("completed", { outcome: "allowed" }));
    });
    await t.client.call("agentRequests.decide", {
      group: GROUP,
      conversation: CONVERSATION,
      request: "cap-p",
      approved: true,
    });
    await t.time.pass(100);
    expect(asked).toEqual({ approved: true });
    expect(requests()?.requests).toMatchObject([
      { id: "cap-p", status: "completed", outcome: "allowed" },
    ]);
  });

  it("shows a Router's plugin install request with the workspace it goes into", async () => {
    const t = setup();
    const requests = t.watch({
      topic: "agentRequests",
      group: GROUP,
      conversation: CONVERSATION,
    });
    await t.time.pass(100);
    t.host.api.open(`${BASE}/events`)!.named("snapshot", {
      data: [
        {
          id: "cap-n",
          type: "plugin_install",
          status: "pending",
          outcome: null,
          expires_at: 2_000,
          created_at: 1_400,
          source_message_id: "msg-1",
          plugin: {
            id: "notion",
            name: "Notion",
            reason: "To save the notes.",
            workspace_id: "wsp_1",
          },
        },
      ],
    });
    await t.time.pass(100);
    expect(requests()?.requests).toEqual([
      {
        id: "cap-n",
        type: "plugin_install",
        status: "pending",
        outcome: null,
        expiresAt: 2_000_000,
        createdAt: 1_400_000,
        sourceMessageId: "msg-1",
        plugin: {
          id: "notion",
          name: "Notion",
          reason: "To save the notes.",
          brand: null,
          workspace: "wsp_1",
        },
      },
    ]);
  });
});
