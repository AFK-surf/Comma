import type { ChatViewValue } from "@comma/core/contract";
import {
  idleConversationChannelState,
  type ChatMessage,
  type ConversationChannelState,
  type DraftAttachment,
} from "@comma/core/chat";
import { getNativeBridge } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { describe, expect, it, vi } from "vitest";
import { testProductLease } from "../../../../test/productInboxProjectionHarness";
import { CoreConversationChannel } from "../CoreConversationChannel";

const session = {
  sessionId: testProductLease.sessionId,
  audience: testProductLease.audience,
};

const message = (messageId: string, text: string): ChatMessage => ({
  attachments: [],
  delivery: "sent",
  messageId,
  parts: [{ kind: "markdown", text }],
  refs: [],
  role: "assistant",
  source: "server",
  text,
});

/**
 * The core's view of the conversation, as a test sets it (`show`), and the answers to the window's calls (`answer`,
 * by call name; a promise holds the answer back).
 */
function scriptView(answer: (name: string, params: unknown) => unknown = () => null) {
  let value: ChatViewValue | undefined;
  const views = { shown: 0 };
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "chatView" ? value : undefined),
    calls: (name, params) => answer(name, params) ?? { revision: value?.revision ?? 0 },
    onSubscribe: () => (views.shown += 1),
    onUnsubscribe: () => (views.shown -= 1),
  });
  return {
    core,
    /** How many views of the conversation the window holds now. */
    views,
    show(
      state: Partial<ConversationChannelState> | null,
      { revision = 1, draftEpoch = 0, sessionId = session.sessionId } = {}
    ) {
      value = {
        session: { ...session, sessionId },
        revision,
        draftEpoch,
        lease: { leaseId: "lease_1", subscriberId: "win_main:grp_1/cnv_1" },
        state: state && { ...idleConversationChannelState, status: "ready", ...state },
      };
      core.changed("chatView");
    },
  };
}

function open(
  core: ReturnType<typeof createScriptedCore>,
  initialState?: ConversationChannelState
) {
  const channel = new CoreConversationChannel({
    bridge: getNativeBridge(),
    client: core.client,
    conversationId: "cnv_1",
    groupId: "grp_1",
    ...(initialState ? { initialState } : {}),
    locale: "en",
    session: testProductLease,
    workspaceId: "wsp_1",
  });
  channel.start();
  return channel;
}

/** A file whose bytes read at once (a promise already settled), so a test waits on no I/O. */
const file = (name: string, text = "abc") => {
  const bytes = new TextEncoder().encode(text);
  return {
    data: { arrayBuffer: () => Promise.resolve(bytes.buffer) } as Blob,
    name,
    size: bytes.length,
  };
};

/** Lets every continuation already due run: the scripted core answers in microtasks, and nothing here waits on time. */
async function flush(rounds = 50) {
  for (let round = 0; round < rounds; round += 1) await Promise.resolve();
}

describe("a window's channel on a conversation", () => {
  it("shows the core's view for its own session only, and lets the view go when it stops", async () => {
    installNativeBridgeMock({ self: { role: "main-window", windowId: "win_main" } });
    const view = scriptView();
    const channel = open(view.core);
    view.show({ messages: [message("m1", "Hi")] });
    await flush();
    expect(channel.getSnapshot().messages.map((m) => m.text)).toEqual(["Hi"]);

    view.show(
      { messages: [message("m2", "Another account's")] },
      { sessionId: "other" }
    );
    await flush();
    expect(channel.getSnapshot().messages.map((m) => m.text)).toEqual(["Hi"]);

    expect(view.views.shown).toBe(1);
    channel.stop();
    await flush();
    expect(view.views.shown).toBe(0);
  });

  it("keeps an edit typed here until the core's draft is as new, so a late echo cannot restore deleted text", async () => {
    installNativeBridgeMock({ self: { role: "main-window", windowId: "win_main" } });
    const answers: ((receipt: unknown) => void)[] = [];
    const view = scriptView((name) =>
      name === "chatView.setDraft"
        ? new Promise((resolve) => answers.push(resolve))
        : null
    );
    const channel = open(view.core);
    view.show({ draft: "" }, { draftEpoch: 0 });
    await flush();

    channel.setDraft("Hello");
    channel.setDraft("");
    expect(channel.getSnapshot().draft).toBe("");
    // The core's echo of the first edit arrives before its answers.
    view.show({ draft: "Hello" }, { draftEpoch: 1 });
    await flush();
    expect(channel.getSnapshot().draft).toBe("");

    answers[0]!({ revision: 2, draftEpoch: 1 });
    answers[1]!({ revision: 3, draftEpoch: 2 });
    await flush();
    expect(channel.getSnapshot().draft).toBe("");
    view.show({ draft: "" }, { draftEpoch: 2, revision: 3 });
    await flush();
    expect(channel.getSnapshot().draft).toBe("");

    // Another window's edit, newer than any here, shows.
    view.show({ draft: "From another window" }, { draftEpoch: 3, revision: 4 });
    await flush();
    expect(channel.getSnapshot().draft).toBe("From another window");
  });

  it("paints a carried transcript until the core's is ready, keeping it beneath an error", async () => {
    installNativeBridgeMock({ self: { role: "main-window", windowId: "win_main" } });
    const carried = message("m-carried", "Carried history");
    const seed = {
      ...idleConversationChannelState,
      messages: [carried],
      serverMessages: [carried],
      status: "ready" as const,
      syncWarning: "stale" as const,
    };
    const view = scriptView();
    const channel = open(view.core, seed);
    expect(channel.getSnapshot().messages).toEqual([carried]);

    view.show({ status: "loading" });
    await flush();
    expect(channel.getSnapshot()).toMatchObject({
      messages: [carried],
      status: "ready",
      syncWarning: "stale",
    });

    view.show({ status: "error", errorKind: "network" }, { revision: 2 });
    await flush();
    expect(channel.getSnapshot()).toMatchObject({
      errorKind: "network",
      messages: [carried],
      status: "error",
    });

    view.show({ messages: [], serverMessages: [], status: "ready" }, { revision: 3 });
    await flush();
    expect(channel.getSnapshot().messages).toEqual([]);
  });

  it("shows a file it reads as uploading until the core shows it, and sends after it", async () => {
    installNativeBridgeMock({
      platform: "web",
      self: { role: "main-window", windowId: "win_main" },
    });
    const view = scriptView((name) =>
      name === "chatView.attach" ? { revision: 2 } : null
    );
    const channel = open(view.core);
    view.show({});
    await flush();

    channel.attachFiles([file("notes.txt")]);
    channel.send("See attached");
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { name: "notes.txt", status: "uploading" },
    ]);
    await flush();
    // The file went first: the send waited for it.
    expect(view.core.sent.map(([name]) => name)).toEqual([
      "chatView.attach",
      "chatView.send",
    ]);
    expect(view.core.sentTo("chatView.attach")).toMatchObject([
      { files: [{ name: "notes.txt", size: 3, bytes: new Uint8Array([97, 98, 99]) }] },
    ]);
    // Answered, but the core has not shown it yet: the row stays.
    expect(channel.getSnapshot().draftAttachments).toHaveLength(1);

    const shown: DraftAttachment = {
      error: undefined,
      id: "att_1",
      isImage: false,
      name: "notes.txt",
      path: undefined,
      size: 3,
      status: "uploading",
    };
    view.show({ draftAttachments: [shown] }, { revision: 2 });
    await flush();
    expect(channel.getSnapshot().draftAttachments).toEqual([shown]);
  });

  it("shows a file it could not hand over as failed, retries it and removes it here", async () => {
    installNativeBridgeMock({
      platform: "web",
      self: { role: "main-window", windowId: "win_main" },
    });
    let refuse = true;
    const view = scriptView((name) => {
      if (name !== "chatView.attach") return null;
      if (refuse) throw new Error("The draft is full.");
      return { revision: 2 };
    });
    const channel = open(view.core);
    view.show({});
    await flush();

    channel.attachFiles([file("notes.txt")]);
    await flush();
    const [failed] = channel.getSnapshot().draftAttachments;
    expect(failed).toMatchObject({ status: "failed", error: "The draft is full." });

    refuse = false;
    channel.retryAttachment(failed!.id);
    await flush();
    expect(view.core.sentTo("chatView.attach")).toHaveLength(2);
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { name: "notes.txt", status: "uploading" },
    ]);

    refuse = true;
    channel.attachFiles([file("other.txt")]);
    await flush();
    const other = channel
      .getSnapshot()
      .draftAttachments.find((row) => row.name === "other.txt")!;
    channel.removeAttachment(other.id);
    expect(channel.getSnapshot().draftAttachments.map((row) => row.name)).toEqual([
      "notes.txt",
    ]);
    expect(view.core.sentTo("chatView.removeAttachment")).toEqual([]);
  });

  it("sends again a message the core lost as it started again, once the new core shows the view", async () => {
    installNativeBridgeMock({ self: { role: "main-window", windowId: "win_main" } });
    let lost = true;
    const view = scriptView((name) =>
      name === "chatView.send" && lost
        ? new Promise(() => undefined)
        : name === "chatView.send"
          ? { revision: 2 }
          : null
    );
    const channel = open(view.core);
    view.show({});
    await flush();

    let sent = false;
    void Promise.resolve(channel.send("Still there?")).then(() => (sent = true));
    await flush();
    expect(view.core.sentTo("chatView.send")).toHaveLength(1);
    // The core goes (another tab ran it) before it answered: the new one forgot this window.
    lost = false;
    view.core.client.resume();
    await flush();
    expect(view.core.sentTo("chatView.send")).toHaveLength(2);
    await flush();
    expect(sent).toBe(true);
  });

  it("hands Electron's Main files from disk with the view's lease and room, and sends only once Main attached them", async () => {
    let attached!: () => void;
    const pickAttachments = vi.fn(
      () =>
        new Promise((resolve) => {
          attached = () =>
            resolve({
              cancelled: false,
              errors: [],
              intakeId: "intake_1",
              revision: 2,
            });
        })
    );
    installNativeBridgeMock({
      chat: { pickAttachments } as never,
      platform: "electron",
      self: { role: "main-window", windowId: "win_main" },
    });
    const view = scriptView();
    const channel = open(view.core);
    view.show({});
    await flush();

    const dropped = new File(["abc"], "report.pdf");
    channel.attachFiles([{ data: dropped, name: "report.pdf", size: 3 }]);
    channel.send("Here it is");
    await flush();
    expect(pickAttachments).toHaveBeenCalledWith(
      expect.objectContaining({
        conversationId: "cnv_1",
        files: [dropped],
        groupId: "grp_1",
        leaseId: "lease_1",
        maxFiles: 50,
        maxUploadFiles: 8,
        subscriberId: "win_main:grp_1/cnv_1",
        surfaceId: "win_main",
        workspaceId: "wsp_1",
      })
    );
    expect(view.core.sentTo("chatView.send")).toEqual([]);

    attached();
    await flush();
    expect(view.core.sentTo("chatView.send")).toMatchObject([{ text: "Here it is" }]);
  });
});
