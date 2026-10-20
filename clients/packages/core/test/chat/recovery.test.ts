import { CoreClient } from "@comma/core-kernel/client";
import type { ChatViewValue } from "../../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";
import { describe, expect, it } from "vitest";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const events = `${base}/events`;
const view = {
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};
const message = (id: string, text: string, clientRequestId?: string) => ({
  message_id: id,
  kind: "message",
  actor_type: "user",
  content: [{ type: "text", text }],
  created_at: 1,
  ...(clientRequestId ? { client_request_id: clientRequestId } : {}),
});
const conversation = (messages: unknown[]) => ({
  group_id: "grp_1",
  id: "cnv_1",
  kind: "user_chat",
  title: "Chat",
  status: "open",
  messages,
});

const participant = (state: "active" | "stopped", updatedAt: number) => ({
  type: "participant_status",
  conversation_id: "cnv_1",
  participant_id: "ptp_1",
  state,
  status: state === "active" ? "is thinking..." : "",
  updated_at: updatedAt,
});

function setup() {
  const host = new FakeHost();
  host.api
    .on("GET", base, conversation([]))
    .onStream(events)
    .onStream("/v1/comma/groups/grp_1/conversations/events");
  const core = startTestCore(host, { coalesceMs: 0 });
  const client = new CoreClient(inProcessOpener(core, host, view.surface), {
    schedule: () => undefined,
  });
  let shown: ChatViewValue | undefined;
  client.subscribe(
    { topic: "chatView", ...view },
    (value) => (shown = value as ChatViewValue),
    () => undefined
  );
  core.observeSession(signedIn());
  return {
    api: host.api,
    client,
    time: host.time!,
    shown: () => shown?.state,
    call: (name: string, params: Record<string, unknown>) =>
      client.call(`chatView.${name}`, { ...view, ...params }),
  };
}

// ConversationRuntime.test.tsx checks the renderer side of these protocol states.
// startTestCore replays each completed run and compares every recorded output.
describe("chat recovery on the core clock", () => {
  it.each([500, 402])(
    "retries a %i with the same request id and one message",
    async (status) => {
      const t = setup();
      t.api.on(
        "POST",
        `${base}/messages`,
        json(status, {
          error: status === 402 ? "billing_unavailable" : "runtime_message_500",
        })
      );
      await t.time.pass(0);
      const release = t.api.hold("POST", `${base}/messages`);
      await t.call("setDraft", { draft: "Please try again" });
      const sending = expect(
        t.call("send", { text: "Please try again" })
      ).rejects.toMatchObject({ code: "chat_refused", status });
      await t.time.pass(0);
      expect(t.shown()?.draft).toBe("");
      expect(t.shown()?.pending).toMatchObject([{ status: "sending" }]);

      release();
      await t.time.pass(0);
      await sending;
      expect(t.shown()?.pending).toMatchObject([
        { status: "failed", text: "Please try again" },
      ]);
      expect(t.shown()?.messages).toHaveLength(1);
      const error =
        status === 402
          ? "Billing is temporarily unavailable. Try again later."
          : undefined;
      expect(t.shown()?.pending[0]?.error).toBe(error);
      expect(t.shown()?.messages[0]?.error).toBe(error);
      const first = t.api.seen("POST", `${base}/messages`)[0]!.body as {
        client_request_id: string;
      };
      expect(first.client_request_id).toBeTruthy();

      // Waiting alone must not submit a failed write again.
      await t.time.pass(60_000);
      expect(t.api.seen("POST", `${base}/messages`)).toHaveLength(1);
      t.api.on("POST", `${base}/messages`, (request) => {
        const sent = request.body as { client_request_id: string };
        return json(
          200,
          conversation([
            message("msg_sent", "Please try again", sent.client_request_id),
          ])
        );
      });
      await t.call("retry", { clientRequestId: first.client_request_id });
      await t.time.pass(0);
      const attempts = t.api.seen("POST", `${base}/messages`);
      expect(attempts).toHaveLength(2);
      expect(attempts[1]!.body).toEqual(attempts[0]!.body);
      expect(t.shown()?.pending).toEqual([]);
      expect(t.shown()?.messages).toMatchObject([
        { messageId: "msg_sent", text: "Please try again" },
      ]);
      expect(t.shown()?.messages).toHaveLength(1);
      t.client.close();
    }
  );

  it.each(["end", "fail"] as const)(
    "resubscribes after stream %s and publishes the stopped participant",
    async (ending) => {
      const t = setup();
      const source = message("msg_source", "Reconnect this reply");
      t.api.on("GET", base, conversation([source]));
      await t.time.pass(0);
      const first = t.api.open(events)!;
      first.named("snapshot", {
        ...conversation([source]),
        conversation_id: "cnv_1",
        type: "snapshot",
      });
      first.named("participant_status", participant("active", 1));
      await t.time.pass(0);
      expect(t.shown()?.participantStatus?.state).toBe("active");
      first[ending]();
      await t.time.pass(0);
      expect(t.api.open(events)).toBeUndefined();
      expect(t.shown()?.messages).toMatchObject([{ text: "Reconnect this reply" }]);

      await t.time.pass(3_000);
      const second = t.api.open(events)!;
      expect(second).toBeDefined();
      expect(second).not.toBe(first);
      expect(
        t.api.streams.filter((stream) => stream.path === events && !stream.closed)
      ).toHaveLength(1);
      second.named("snapshot", {
        ...conversation([source]),
        conversation_id: "cnv_1",
        type: "snapshot",
      });
      second.named("participant_status", participant("active", 2));
      await t.time.pass(0);
      expect(t.shown()?.participantStatus?.state).toBe("active");
      second.named("participant_status", participant("stopped", 3));
      await t.time.pass(0);
      expect(t.shown()?.participantStatus?.state).toBe("stopped");
      t.client.close();
    }
  );
});
