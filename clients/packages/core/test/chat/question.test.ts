// An Agent's question card in a window's view (`chatView`): drawn from its `question` block, answered with one
// message in the person's words, and closed by whatever the person says next.
import { CoreClient } from "@comma/core-kernel/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ChatQuestionPart } from "@comma/chat-contract";
import type { ChatViewValue } from "../../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const files = "/v1/comma/groups/grp_1/files";
const file = (name: string) => ({
  name,
  size: 3,
  bytes: new Uint8Array([1, 2, 3]),
});

const events = `${base}/events`;
const view = {
  topic: "chatView",
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};
const named = {
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};

const asked = {
  message_id: "m1",
  seq: 1,
  kind: "message",
  actor_type: "agent",
  agent_id: "agt_1",
  created_at: 1,
  content: [
    { type: "text", text: "下周三两个会撞了。" },
    {
      type: "question",
      prompt: "这两个会怎么处理？",
      choices: [
        { id: "c1", label: "挪到周四", reply: "把同步会挪到周四。", recommended: true },
        { id: "c2", label: "两个都参加" },
      ],
      multi_select: false,
      allow_other: true,
    },
    {
      type: "text",
      text: "这两个会怎么处理？\n\n1. 挪到周四\n2. 两个都参加",
      fallback_for: "question",
    },
  ],
};

const answer = (seq: number, choiceIds: string[], text: string) => ({
  message_id: `m${seq}`,
  seq,
  kind: "message",
  actor_type: "user",
  created_at: seq,
  client_request_id: "question-answer:m1",
  reply_to_message_id: "m1",
  content: [
    { type: "text", text },
    { type: "question_answer", question_message_id: "m1", choice_ids: choiceIds },
  ],
});

const detail = (messages: unknown[]) => ({
  group_id: "grp_1",
  id: "cnv_1",
  kind: "user_chat",
  title: "Thread",
  status: "open",
  messages,
});
const snapshot = (messages: unknown[]) => ({
  type: "snapshot",
  conversation_id: "cnv_1",
  group_id: "grp_1",
  status: "open",
  messages,
});

function setup() {
  const host = new FakeHost();
  host.api
    .onStream(events)
    .onStream("/v1/comma/groups/grp_1/conversations/events")
    .on("GET", base, detail([asked]));
  const core = startTestCore(host);
  core.observeSession(signedIn());
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  let value: ChatViewValue | undefined;
  client.subscribe(
    view,
    (v) => (value = v as ChatViewValue),
    () => undefined
  );
  const question = () => {
    const [shown, server] = [value!.state!.messages, value!.state!.serverMessages].map(
      (messages) =>
        messages
          .find((m) => m.messageId === "m1")!
          .parts!.find((part): part is ChatQuestionPart => part.kind === "question")!
    );
    // The native clients draw rows from the server's messages: the card says the same there.
    expect(server!.state).toEqual(shown!.state);
    return shown!;
  };
  return {
    host,
    client,
    time: host.time!,
    state: () => value!.state!,
    question,
    stream: () => host.api.open(events)!,
  };
}

describe("an Agent's question card", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("draws the card in place of its plain-text version, and answers it in the person's words", async () => {
    const t = setup();
    await t.time.pass(1_500);
    t.stream().named("snapshot", snapshot([asked]));
    await t.time.pass(100);

    const message = t.state().messages.find((m) => m.messageId === "m1")!;
    expect(message.parts!.map((part) => part.kind)).toEqual(["markdown", "question"]);
    expect(t.question()).toMatchObject({
      prompt: "这两个会怎么处理？",
      multiSelect: false,
      allowOther: true,
      state: { status: "open" },
    });

    t.host.api.on("POST", `${base}/messages`, () =>
      json(200, detail([asked, answer(2, ["c1"], "把同步会挪到周四。")]))
    );
    const release = t.host.api.hold("POST", `${base}/messages`);
    const answering = t.client.call("chatView.answerQuestion", {
      ...named,
      questionMessageId: "m1",
      choiceIds: ["c1"],
    });
    await t.time.pass(100);
    expect(t.question().state).toEqual({ status: "sending", choiceIds: ["c1"] });
    expect(t.host.api.seen("POST", `${base}/messages`)[0]!.body).toMatchObject({
      client_request_id: "question-answer:m1",
      reply_to_message_id: "m1",
      message: {
        content: [
          { type: "text", text: "把同步会挪到周四。" },
          { type: "question_answer", question_message_id: "m1", choice_ids: ["c1"] },
        ],
      },
    });

    release();
    await answering;
    await t.time.pass(100);
    expect(t.question().state).toEqual({ status: "answered", choiceIds: ["c1"] });
  });

  it("closes as answered in the chat as soon as the person writes there instead", async () => {
    const t = setup();
    await t.time.pass(1_500);
    t.stream().named("snapshot", snapshot([asked]));
    await t.time.pass(100);

    t.host.api.hold("POST", `${base}/messages`);
    void t.client.call("chatView.send", { ...named, text: "周四我也不行，改到下周一" });
    await t.time.pass(100);
    expect(t.question().state).toEqual({ status: "replied" });
  });

  it("lets the card's images go when the person writes in the chat instead", async () => {
    const t = setup();
    const path = `/uploads/${"p".repeat(22)}-photo.png`;
    t.host.api.on("POST", files, { name: "photo.png", path, size: 3 });
    await t.time.pass(1_500);
    t.stream().named("snapshot", snapshot([asked]));
    await t.time.pass(100);
    await t.client.call("chatView.attach", {
      ...named,
      questionMessageId: "m1",
      files: [{ name: "photo.png", size: 3, bytes: new Uint8Array([1, 2, 3]) }],
    });
    await t.time.pass(100);
    expect(t.state().questionAttachments?.m1).toHaveLength(1);

    t.host.api.hold("POST", `${base}/messages`);
    void t.client.call("chatView.send", { ...named, text: "周四我也不行，改到下周一" });
    await t.time.pass(100);
    expect(t.question().state).toEqual({ status: "replied" });
    expect(t.state().questionAttachments).toBeUndefined();
  });

  it("shows the answer another device gave first when this device's answer is refused", async () => {
    const t = setup();
    await t.time.pass(1_500);
    t.stream().named("snapshot", snapshot([asked]));
    await t.time.pass(100);

    t.host.api.on("POST", `${base}/messages`, () => json(409, { error: "conflict" }));
    await t.client
      .call("chatView.answerQuestion", {
        ...named,
        questionMessageId: "m1",
        choiceIds: ["c1"],
      })
      .catch(() => undefined);
    await t.time.pass(100);
    expect(t.question().state.status).toBe("failed");

    t.stream().named("snapshot", snapshot([asked, answer(2, ["c2"], "两个都参加")]));
    await t.time.pass(100);
    expect(t.question().state).toEqual({ status: "answered", choiceIds: ["c2"] });
    expect(t.state().pending).toEqual([]);
  });

  it("answers several choices in the person's words without Intl.ListFormat, which Hermes lacks", async () => {
    // The Android and iOS apps run the core in Hermes, whose Intl has no ListFormat. (Intl's members are not
    // enumerable, so a spread copy would take away all of Intl, not ListFormat alone.)
    vi.stubGlobal("Intl", Object.create(Intl, { ListFormat: { value: undefined } }));
    const multi = {
      ...asked,
      content: asked.content.map((block) =>
        block.type === "question" ? { ...block, multi_select: true } : block
      ),
    };
    const t = setup();
    await t.time.pass(1_500);
    t.stream().named("snapshot", snapshot([multi]));
    await t.time.pass(100);

    t.host.api.hold("POST", `${base}/messages`);
    void t.client.call("chatView.answerQuestion", {
      ...named,
      questionMessageId: "m1",
      choiceIds: ["c1", "c2"],
      other: "周四下午更好",
    });
    await t.time.pass(100);
    expect(t.question().state).toEqual({
      status: "sending",
      choiceIds: ["c1", "c2"],
      other: "周四下午更好",
    });
    expect(t.host.api.seen("POST", `${base}/messages`)[0]!.body).toMatchObject({
      message: {
        content: [
          { type: "text", text: "挪到周四, 两个都参加\n\n周四下午更好" },
          {
            type: "question_answer",
            question_message_id: "m1",
            choice_ids: ["c1", "c2"],
            other: "周四下午更好",
          },
        ],
      },
    });
  });

  it("sends an answer that failed again with the images added to the card", async () => {
    const t = setup();
    const path = `/uploads/${"p".repeat(22)}-photo.png`;
    t.host.api.on("POST", files, { name: "photo.png", path, size: 3 });
    await t.time.pass(1_500);
    t.stream().named("snapshot", snapshot([asked]));
    await t.time.pass(100);

    await t.client.call("chatView.attach", {
      ...named,
      questionMessageId: "m1",
      files: [{ name: "photo.png", size: 3, bytes: new Uint8Array([1, 2, 3]) }],
    });
    await t.time.pass(100);
    expect(t.state().questionAttachments?.m1).toMatchObject([
      { name: "photo.png", path, status: "uploaded" },
    ]);

    t.host.api.on("POST", `${base}/messages`, () =>
      json(503, { error: "unavailable" })
    );
    const answerWithImage = () =>
      t.client
        .call("chatView.answerQuestion", {
          ...named,
          questionMessageId: "m1",
          choiceIds: [],
          other: "",
        })
        .catch(() => undefined);
    await answerWithImage();
    await t.time.pass(100);
    expect(t.question().state.status).toBe("failed");
    // The card still holds the image, so its retry sends it.
    expect(t.state().questionAttachments?.m1).toMatchObject([
      { name: "photo.png", path },
    ]);

    t.host.api.on("POST", `${base}/messages`, () =>
      json(200, detail([asked, answer(2, [], `![photo.png](${path})`)]))
    );
    await answerWithImage();
    await t.time.pass(100);
    const sent = t.host.api.seen("POST", `${base}/messages`);
    expect(sent).toHaveLength(2);
    expect(JSON.stringify(sent[1]!.body)).toContain(path);
    expect(t.state().questionAttachments).toBeUndefined();
  });

  it.each(["uploaded", "failed"] as const)(
    "answers picks alone when the person left Other, without its %s image",
    async (status) => {
      const t = setup();
      const path = `/uploads/${"p".repeat(22)}-private.png`;
      t.host.api.on("POST", files, () =>
        status === "uploaded"
          ? json(200, { name: "private.png", path, size: 3 })
          : json(503, { error: "unavailable" })
      );
      await t.time.pass(1_500);
      t.stream().named("snapshot", snapshot([asked]));
      await t.time.pass(100);
      await t.client.call("chatView.attach", {
        ...named,
        questionMessageId: "m1",
        files: [{ name: "private.png", size: 3, bytes: new Uint8Array([1, 2, 3]) }],
      });
      await t.time.pass(100);
      expect(t.state().questionAttachments?.m1?.[0]?.status).toBe(status);

      t.host.api.on("POST", `${base}/messages`, () =>
        json(200, detail([asked, answer(2, ["c2"], "两个都参加")]))
      );
      // Every card leaves `other` out once the person picks a listed choice instead.
      await t.client.call("chatView.answerQuestion", {
        ...named,
        questionMessageId: "m1",
        choiceIds: ["c2"],
      });
      await t.time.pass(100);
      const sent = t.host.api.seen("POST", `${base}/messages`);
      expect(sent).toHaveLength(1);
      expect(JSON.stringify(sent[0]!.body)).not.toContain("private.png");
      expect(t.question().state).toEqual({ status: "answered", choiceIds: ["c2"] });
    }
  );

  it("keeps a card's images apart from the draft through attach, retry, removal and the answer", async () => {
    const t = setup();
    t.host.api.on("POST", files, () => json(503, { error: "unavailable" }));
    await t.time.pass(1_500);
    t.stream().named("snapshot", snapshot([asked]));
    await t.time.pass(100);
    await t.client.call("chatView.attach", { ...named, files: [file("draft.png")] });
    await t.client.call("chatView.attach", {
      ...named,
      questionMessageId: "m1",
      files: [file("card.png")],
    });
    await t.time.pass(100);
    const draft = t.state().draftAttachments[0]!;
    const card = t.state().questionAttachments!.m1![0]!;
    expect(draft.status).toBe("failed");
    expect(card.status).toBe("failed");
    t.host.api.on("POST", files, {
      name: "uploaded.png",
      path: `/uploads/${"p".repeat(22)}-uploaded.png`,
      size: 3,
    });
    await t.client.call("chatView.retryAttachment", {
      ...named,
      questionMessageId: "m1",
      attachmentId: card.id,
    });
    await t.time.pass(100);
    expect(t.state().questionAttachments!.m1![0]!.status).toBe("uploaded");
    expect(t.state().draftAttachments).toEqual([draft]);
    await t.client.call("chatView.removeAttachment", {
      ...named,
      questionMessageId: "m1",
      attachmentId: card.id,
    });
    await t.time.pass(100);
    expect(t.state().questionAttachments).toBeUndefined();
    expect(t.state().draftAttachments).toEqual([draft]);
    await t.client.call("chatView.retryAttachment", {
      ...named,
      attachmentId: draft.id,
    });
    await t.time.pass(100);
    expect(t.state().draftAttachments[0]!.status).toBe("uploaded");
    await t.client.call("chatView.attach", {
      ...named,
      questionMessageId: "m1",
      files: [file("card2.png")],
    });
    await t.time.pass(100);
    const heldDraft = t.state().draftAttachments;
    t.host.api.on("POST", `${base}/messages`, () =>
      json(200, detail([asked, answer(2, [], "image answer")]))
    );
    await t.client.call("chatView.answerQuestion", {
      ...named,
      questionMessageId: "m1",
      choiceIds: [],
      other: "",
    });
    await t.time.pass(100);
    expect(t.question().state.status).toBe("answered");
    expect(t.state().questionAttachments).toBeUndefined();
    expect(t.state().draftAttachments).toEqual(heldDraft);
    await t.client.call("chatView.removeAttachment", {
      ...named,
      attachmentId: draft.id,
    });
    await t.time.pass(100);
    expect(t.state().draftAttachments).toEqual([]);
  });
});
