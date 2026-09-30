import type { CommaLocale } from "@comma/i18n";
import { conversationProjectionSchema } from "@comma/chat-contract";
import { describe, expect, it, vi } from "vitest";
import type {
  CommaApiClient,
  CommaConversation,
  CommaConversationKind,
  CommaConversationEvent,
  CommaConversationListEvent,
  SalixMessage,
} from "../../../../api";
import { CommaApiError } from "../../../../api";
import {
  ConversationChannel,
  normalizeServerMessages,
  toConversationProjection,
  type ConversationChannelOptions,
  type ConversationVisibility,
} from "../conversationChannel";
import { ATTACHED_FILES_HEADER, ATTACHED_ONLY_TEXT } from "../protocol";
import type { AttachmentTranscoder } from "../conversationChannel";

describe("ConversationChannel", () => {
  it("recovers runnable UI only from bound Agent content and keeps version replies", () => {
    const block = {
      type: "dynamic_ui",
      ui_ref: "weather",
      version: 1,
      summary: "Singapore: 27 °C",
      text: "Singapore: 27 °C",
      blob_ref: { kind: "blob", uuid: "a".repeat(32), hash: "b".repeat(64), size: 120 },
    };
    const wire: SalixMessage = {
      actor_type: "agent",
      agent_id: "worker",
      message_id: "card",
      kind: "message",
      content: [block],
      reply_to_message_id: "previous-card",
    };
    const initial = normalizeServerMessages([wire], [], "agent_task", "task");
    expect(initial[0]?.parts).toEqual([
      {
        kind: "dynamic-ui",
        contentId: "a".repeat(32),
        uiRef: "weather",
        summary: block.summary,
        version: 1,
        conversationId: "task",
        messageId: "card",
        attachmentIndex: 0,
        originTaskId: undefined,
      },
    ]);
    expect(initial[0]?.replyToMessageId).toBe("previous-card");
    expect(normalizeServerMessages([wire], initial, "agent_task", "task")).toBe(
      initial
    );
    expect(
      normalizeServerMessages(
        [{ ...wire, content: [{ ...block, blob_ref: {} }] }],
        [],
        "agent_task",
        "task"
      )[0]?.parts
    ).toEqual([{ kind: "markdown", text: block.summary }]);
  });
  it("keeps chat replies visible while delivery events stay out of the transcript", () => {
    const reply: SalixMessage = {
      message_id: "reply",
      actor_type: "agent",
      kind: "message",
      content: [{ type: "text", text: "Your report is ready." }],
    };
    const events: SalixMessage[] = [
      "provider.output",
      "provider.status",
      "message.redelivery",
    ].map((event_type) => ({
      message_id: event_type,
      actor_type: "system",
      kind: "app_event",
      content: [{ type: "text", text: "Internal delivery event" }],
      metadata: { event_type },
    }));
    events.push({
      message_id: "provider-input",
      actor_type: "system",
      kind: "message",
      content: [{ type: "text", text: "Private provider prompt context" }],
      agent_input: { role: "user", content: "Private provider prompt context" },
    });
    expect(normalizeServerMessages([reply, ...events], [], "agent_task")).toEqual(
      normalizeServerMessages([reply], [], "agent_task")
    );
  });

  it("preserves explicit reply targets through refresh without inferring them from message order", () => {
    const wire: SalixMessage = {
      actor_type: "agent",
      agent_id: "worker-a",
      role_label: "worker",
      message_id: "reply",
      kind: "message",
      content: [{ type: "text", text: "Result" }],
      reply_to_message_id: "earlier-worker-message",
      thread_root_message_id: "user-root",
    };
    const initial = normalizeServerMessages([wire], [], "agent_task");
    expect(initial[0]?.replyToMessageId).toBe("earlier-worker-message");
    expect(initial[0]?.threadRootMessageId).toBe("user-root");
    expect(normalizeServerMessages([wire], initial, "agent_task")).toBe(initial);
    const changed = normalizeServerMessages(
      [{ ...wire, reply_to_message_id: "user-message" }],
      initial,
      "agent_task"
    );
    expect(changed[0]?.replyToMessageId).toBe("user-message");
    const withRoot = normalizeServerMessages(
      [{ ...wire, thread_root_message_id: "backfilled-root" }],
      initial,
      "agent_task"
    );
    expect(withRoot[0]?.threadRootMessageId).toBe("backfilled-root");
    expect(withRoot).not.toBe(initial);
    const {
      reply_to_message_id: _target,
      thread_root_message_id: _root,
      ...legacy
    } = wire;
    expect(
      normalizeServerMessages([legacy], [], "agent_task")[0]?.replyToMessageId
    ).toBeUndefined();
  });

  it.each([
    ["no blob", { file_name: "report.pdf" }, undefined],
    [
      "unbound nested file_ref",
      {
        file_name: "report.pdf",
        file_ref: { environment_id: "vfs", path: "/report.pdf" },
        attachment_index: 1,
      },
      undefined,
    ],
    ["incomplete ref", { blob_ref: { uuid: "u", size: 1 } }, undefined],
    ["oversize", { blob_ref: { uuid: "u", hash: "h", size: 10_000_001 } }, undefined],
    ["fractional size", { blob_ref: { uuid: "u", hash: "h", size: 1.5 } }, undefined],
    ["string size", { blob_ref: { uuid: "u", hash: "h", size: "1" } }, undefined],
    [
      "long Unicode name",
      { file_name: "界".repeat(342), blob_ref: { uuid: "u", hash: "h", size: 1 } },
      undefined,
    ],
    [
      "empty file",
      { file_name: "empty.txt", blob_ref: { uuid: "u", hash: "h", size: 0 } },
      "empty.txt",
    ],
    [
      "exact byte limit",
      { file_name: "report.pdf", blob_ref: { uuid: "u", hash: "h", size: 10_000_000 } },
      "report.pdf",
    ],
    [
      "name at UTF-8 limit",
      {
        file_name: "界".repeat(341) + "a",
        blob_ref: { uuid: "u", hash: "h", size: 1 },
      },
      "界".repeat(341) + "a",
    ],
    [
      "name basename",
      {
        file_name: "  folder/report.pdf  ",
        title: "ignored.pdf",
        blob_ref: { uuid: "u", hash: "h", size: 1 },
      },
      "report.pdf",
    ],
    [
      "title fallback",
      {
        file_name: " .. ",
        title: " folder/title.pdf ",
        path: "/ignored.pdf",
        blob_ref: { uuid: "u", hash: "h", size: 1 },
      },
      "title.pdf",
    ],
    [
      "path fallback",
      {
        file_name: " ",
        title: "/",
        path: "/folder/path.pdf",
        blob_ref: { uuid: "u", hash: "h", size: 1 },
      },
      "path.pdf",
    ],
    ["default name", { blob_ref: { uuid: "u", hash: "h", size: 1 } }, "attachment"],
  ] as const)(
    "offers a canonical file download only inside the server contract: %s",
    (_name, block, downloadName) => {
      const [projected] = normalizeServerMessages(
        [
          {
            actor_type: "agent",
            agent_id: "agt1_worker",
            message_id: "msg1_file",
            kind: "message",
            content: [
              { type: "text", text: "Ready" },
              { type: "file", ...block },
            ],
          },
        ],
        [],
        "agent_task"
      );
      const attachment = projected!.attachments![0]!;
      expect(attachment.attachmentIndex).toBe(
        downloadName === undefined ? undefined : 1
      );
      if (downloadName !== undefined) expect(attachment.fileName).toBe(downloadName);
      expect(projected!.text).toBe("Ready");
    }
  );

  it("does not offer a canonical blob download without a sender agent", () => {
    const [projected] = normalizeServerMessages(
      [
        {
          actor_type: "provider_user",
          message_id: "msg_provider_blob",
          kind: "message",
          content: [
            {
              type: "file",
              file_name: "report.pdf",
              blob_ref: { uuid: "u", hash: "h", size: 1 },
            },
          ],
        },
      ],
      [],
      "user_chat"
    );
    expect(projected!.attachments![0]!.attachmentIndex).toBeUndefined();
  });

  it("preserves provider file and native local-file presentation without inventing downloads", () => {
    const [projected] = normalizeServerMessages(
      [
        {
          actor_type: "provider_user",
          message_id: "msg1_provider",
          kind: "message",
          content: [
            { type: "file", path: "/feishu/report.pdf", file_name: "report.pdf" },
            {
              type: "local_file",
              local_file_ref: `lfi1_${"a".repeat(43)}`,
              display_name: "local.pdf",
              media_type: "application/pdf",
              size: 20,
            },
          ],
        },
      ],
      [],
      "user_chat"
    );
    expect(projected!.attachments).toMatchObject([
      { workspacePath: "/feishu/report.pdf", fileName: "report.pdf" },
      { localFileRef: `lfi1_${"a".repeat(43)}`, fileName: "local.pdf" },
    ]);
    expect(
      projected!.attachments!.every((item) => item.attachmentIndex === undefined)
    ).toBe(true);
  });

  it("publishes an accepted review without waiting for a subsequent detail read", async () => {
    const api = createConversationApi();
    const accepted = conversation({
      kind: "agent_task",
      status: "completed",
      updated_at: 2,
    });
    api.client.acceptTaskReview = vi.fn(async () => accepted);
    const channel = createChannel(api, { initialKind: "agent_task" });
    channel.start();
    api.resolvePoll(0, {
      conversation: conversation({
        kind: "agent_task",
        status: "ready_for_review",
        review_version: 1,
        updated_at: 1,
      }),
      notModified: false,
    });
    await flushMicrotasks();
    await channel.acceptTaskReview(1);
    expect(channel.getSnapshot().conversation?.status).toBe("completed");
    expect(api.client.acceptTaskReview).toHaveBeenCalledWith("grp_1", "cnv_1", 1);
    channel.stop();
  });

  it("refreshes a conflicting review and ignores a result from a stopped session", async () => {
    const api = createConversationApi();
    let resolve!: (value: CommaConversation) => void;
    api.client.acceptTaskReview = vi.fn(
      () =>
        new Promise<CommaConversation>((settle) => {
          resolve = settle;
        })
    );
    const channel = createChannel(api, { initialKind: "agent_task" });
    channel.start();
    api.resolvePoll(0, {
      conversation: conversation({
        kind: "agent_task",
        status: "ready_for_review",
        review_version: 1,
      }),
      notModified: false,
    });
    await flushMicrotasks();
    const accepting = channel.acceptTaskReview(1);
    channel.stop();
    resolve(conversation({ kind: "agent_task", status: "completed" }));
    await accepting;
    expect(channel.getSnapshot().conversation?.status).toBe("ready_for_review");
    channel.start();
    api.client.acceptTaskReview = vi.fn(async () => {
      throw new Error("conflict");
    });
    const refresh = vi.spyOn(channel, "refresh");
    await expect(channel.acceptTaskReview(1)).rejects.toThrow("conflict");
    expect(refresh).toHaveBeenCalledOnce();
    channel.stop();
  });

  it("derives the Worker view from canonical Salix authorship", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { initialKind: "agent_task" });

    channel.start();
    api.resolvePoll(0, {
      conversation: conversation({ kind: "agent_task" }, [
        message("msg_worker", "assistant", "Done", undefined, {
          agent_id: "agt1_worker_1",
          role_label: "worker",
        }),
      ]),
      etag: '"worker-snapshot"',
      notModified: false,
    });
    await flushMicrotasks();

    expect(channel.getSnapshot().serverMessages[0]).toMatchObject({
      actorId: "agt1_worker_1",
      actorRole: "worker",
    });
    channel.stop();
  });

  it("withholds the append callback for the history baseline, then reports only new canonical messages", () => {
    const appended: string[][] = [];
    const api = createConversationApi();
    const channel = createChannel(api, {
      onCanonicalMessagesAppended: ({ messages }) => {
        appended.push(messages.map((entry) => entry.messageId));
      },
    });

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_history", "user", "Hi"),
          message("msg_reply", "assistant", "Hello"),
        ],
      },
      "snapshot"
    );

    // The first snapshot is the conversation's history, not an arrival.
    expect(appended).toEqual([]);

    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_history", "user", "Hi"),
          message("msg_reply", "assistant", "Hello"),
          message("msg_router", "assistant", "Router replied"),
        ],
      },
      "snapshot"
    );

    expect(appended).toEqual([["msg_router"]]);

    // Replaying the same canonical set is not a second arrival.
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_history", "user", "Hi"),
          message("msg_reply", "assistant", "Hello"),
          message("msg_router", "assistant", "Router replied"),
        ],
      },
      "snapshot"
    );

    expect(appended).toEqual([["msg_router"]]);
    channel.stop();
  });

  it("omits an empty legacy reply scope before publishing native Chat state", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api, { initialKind: "agent_task" });

    channel.start();
    api.resolvePoll(0, {
      conversation: conversation({ kind: "agent_task", status: "completed" }, [
        message("msg_user", "user", "Do the work"),
        message("msg_reply", "assistant", "Done"),
      ]),
      etag: '"task-completed"',
      notModified: false,
    });
    await flushMicrotasks();

    expect("replyToMessageIds" in channel.getSnapshot().messages[1]!).toBe(false);
    expect(
      "replyToMessageIds" in
        toConversationProjection(channel.getSnapshot(), {
          groupId: "grp_1",
          workspaceId: "wsp_1",
        }).messages[1]!
    ).toBe(false);
    channel.stop();
    vi.useRealTimers();
  });

  it("keeps both Task participants through projection and fences stopped streams", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { initialKind: "agent_task" });
    channel.start();
    api.resolvePoll(0, {
      conversation: conversation({ kind: "agent_task", status: "active" }),
      etag: '"v1"',
      notModified: false,
    });
    await flushMicrotasks();
    const options = vi.mocked(api.client.streamConversationListEvents).mock
      .calls[0]![1];
    expect(options.conversationId).toBe("cnv_1");
    const status = {
      type: "task_participant_statuses" as const,
      group_id: "grp_1",
      conversation_id: "cnv_1",
      participants: [
        {
          conversation_id: "cnv_1",
          participant_id: "ptc_router",
          actor_id: "actor_router",
          actor_role: "router" as const,
          name: "Router",
          state: "active" as const,
          status: "is thinking...",
          updated_at: 1,
        },
        {
          conversation_id: "cnv_1",
          participant_id: "ptc_worker",
          actor_id: "actor_worker",
          actor_role: "worker" as const,
          name: "Worker",
          state: "active" as const,
          status: "is working...",
          updated_at: 1,
        },
      ],
    };
    options.onParticipantStatuses?.(status);
    expect(channel.getSnapshot().participantStatuses).toHaveLength(2);
    expect(
      toConversationProjection(channel.getSnapshot(), {
        groupId: "grp_1",
        workspaceId: "wsp_1",
      }).participantStatuses
    ).toMatchObject([
      { name: "Router", actorId: "actor_router", actorRole: "router" },
      { name: "Worker", actorId: "actor_worker", actorRole: "worker" },
    ]);
    options.onParticipantStatuses?.({
      ...status,
      conversation_id: "other",
      participants: [],
    });
    expect(channel.getSnapshot().participantStatuses).toHaveLength(2);
    options.onParticipantStatuses?.({
      ...status,
      participants: status.participants.slice(1),
    });
    expect(channel.getSnapshot().participantStatuses).toMatchObject([
      { name: "Worker" },
    ]);
    api.taskStreams[0]!.resolve();
    await flushMicrotasks();
    options.onParticipantStatuses?.(status);
    expect(channel.getSnapshot().participantStatuses).toMatchObject([
      { name: "Worker" },
    ]);
    channel.stop();
    options.onParticipantStatuses?.(status);
    expect(channel.getSnapshot().participantStatuses).toBeUndefined();
  });

  it.each(["eof", "network"])(
    "retains Task status across %s until a replacement or auth loss",
    async (ending) => {
      vi.useFakeTimers();
      const api = createConversationApi();
      const channel = createChannel(api, { initialKind: "agent_task" });
      try {
        channel.start();
        api.resolvePoll(0, {
          conversation: conversation({ kind: "agent_task", status: "active" }),
          notModified: false,
        });
        await flushMicrotasks();
        const options = () =>
          vi.mocked(api.client.streamConversationListEvents).mock.calls.at(-1)![1];
        const snapshot = {
          type: "task_participant_statuses" as const,
          group_id: "grp_1",
          conversation_id: "cnv_1",
          participants: [
            {
              conversation_id: "cnv_1",
              participant_id: "worker",
              name: "Worker",
              state: "active" as const,
              status: "is thinking...",
              updated_at: 1,
            },
          ],
        };
        const first = options();
        first.onParticipantStatuses?.(snapshot);
        const original = channel.getSnapshot().participantStatuses;
        if (ending === "eof") api.taskStreams[0]!.resolve();
        else api.taskStreams[0]!.reject(new TypeError("Failed to fetch"));
        await flushMicrotasks();
        expect(channel.getSnapshot().participantStatuses).toBe(original);
        await vi.advanceTimersByTimeAsync(5_000);
        expect(api.taskStreams).toHaveLength(2);
        expect(channel.getSnapshot().participantStatuses).toBe(original);
        first.onParticipantStatuses?.({ ...snapshot, participants: [] });
        expect(channel.getSnapshot().participantStatuses).toBe(original);
        options().onParticipantStatuses?.({ ...snapshot, participants: [] });
        expect(channel.getSnapshot().participantStatuses).toEqual([]);
        options().onParticipantStatuses?.(snapshot);
        api.taskStreams[1]!.reject(new CommaApiError(401, "unauthorized"));
        await flushMicrotasks();
        expect(channel.getSnapshot().participantStatuses).toBeUndefined();
        options().onParticipantStatuses?.(snapshot);
        expect(channel.getSnapshot().participantStatuses).toBeUndefined();
      } finally {
        channel.stop();
        vi.useRealTimers();
      }
    }
  );

  it("publishes loaded task detail and live connection as one snapshot", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { initialKind: "agent_task" });
    const snapshots: ReturnType<typeof channel.getSnapshot>[] = [];
    channel.subscribe(() => snapshots.push(channel.getSnapshot()));
    channel.start();
    snapshots.length = 0;
    api.resolvePoll(0, {
      conversation: conversation({ kind: "agent_task", status: "ready_for_review" }),
      etag: '"review-1"',
      notModified: false,
    });
    await flushMicrotasks();
    expect(snapshots).toHaveLength(1);
    expect(snapshots[0]).toMatchObject({ status: "ready", connection: "live" });
    expect(api.taskStreams).toHaveLength(1);
  });

  it("refreshes agent task detail from Group SSE versions", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { initialKind: "agent_task" });

    channel.start();
    expect(api.polls).toHaveLength(1);
    expect(api.polls[0]?.etag).toBeUndefined();

    api.resolvePoll(0, {
      conversation: conversation({ kind: "agent_task", status: "running" }),
      etag: '"task-version-1"',
      notModified: false,
    });
    await flushMicrotasks();

    expect(api.taskStreams).toHaveLength(1);
    api.emitTaskInvalidation(0, "owner-a.1");
    await flushMicrotasks();

    expect(api.polls).toHaveLength(2);
    expect(api.polls[1]?.etag).toBe('"task-version-1"');

    api.resolvePoll(1, {
      conversation: conversation({ kind: "agent_task", status: "completed" }),
      etag: '"task-version-2"',
      notModified: false,
    });
    await flushMicrotasks();

    expect(api.polls).toHaveLength(2);
    expect(channel.getSnapshot().conversation?.status).toBe("completed");
    expect(api.taskStreams).toHaveLength(2);
  });

  it("drains one explicit task refresh requested while the initial read is in flight", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { initialKind: "agent_task" });

    channel.start();
    expect(api.polls).toHaveLength(1);

    channel.refresh();
    channel.refresh();
    expect(api.polls).toHaveLength(1);

    api.resolvePoll(0, {
      conversation: conversation({
        kind: "agent_task",
        status: "ready_for_review",
      }),
      etag: '"task-ready-before-explicit-refresh"',
      notModified: false,
    });
    await flushMicrotasks();

    expect(api.polls).toHaveLength(2);

    api.resolvePoll(1, {
      conversation: conversation({ kind: "agent_task", status: "completed" }),
      etag: '"task-completed-after-explicit-refresh"',
      notModified: false,
    });
    await flushMicrotasks();

    expect(channel.getSnapshot().conversation?.status).toBe("completed");
    expect(api.polls).toHaveLength(2);
  });

  it("loads a delayed task follow-up reply after its SSE invalidation", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, {
      initialKind: "agent_task",
      requestIds: ["req_follow_up"],
    });

    channel.start();
    api.resolvePoll(0, {
      conversation: conversation({ kind: "agent_task", status: "completed" }),
      etag: '"task-terminal-1"',
      notModified: false,
    });
    await flushMicrotasks();
    expect(api.taskStreams).toHaveLength(1);

    const send = channel.send("continue");
    api.resolveSend(
      0,
      conversation({ kind: "agent_task", status: "completed" }, [
        message("msg_follow_up", "user", "continue", "req_follow_up"),
      ])
    );
    await send;
    await flushMicrotasks();
    expect(api.polls).toHaveLength(2);

    api.resolvePoll(1, {
      conversation: conversation({ kind: "agent_task", status: "completed" }, [
        message("msg_follow_up", "user", "continue", "req_follow_up"),
      ]),
      etag: '"task-terminal-2"',
      notModified: false,
    });
    await flushMicrotasks();
    expect(api.taskStreams).toHaveLength(2);

    api.emitTaskInvalidation(1, "owner-follow-up.2");
    await flushMicrotasks();
    expect(api.polls).toHaveLength(3);

    api.resolvePoll(2, {
      conversation: conversation({ kind: "agent_task", status: "completed" }, [
        message("msg_follow_up", "user", "continue", "req_follow_up"),
        message("msg_reply", "assistant", "continued"),
      ]),
      etag: '"task-terminal-3"',
      notModified: false,
    });
    await flushMicrotasks();

    expect(channel.getSnapshot().pending).toEqual([]);
    expect(channel.getSnapshot().messages.at(-1)).toMatchObject({
      messageId: "msg_reply",
      role: "assistant",
      text: "continued",
    });
  });

  it("reconciles an immediate task send after the initial read is superseded", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, {
      initialKind: "agent_task",
      requestIds: ["req_before_detail"],
    });

    channel.start();
    expect(api.polls).toHaveLength(1);
    expect(channel.getSnapshot().conversation).toBeUndefined();

    const send = channel.send("continue immediately");
    api.resolveSend(
      0,
      conversation({ kind: "agent_task", status: "completed" }, [
        message(
          "msg_before_detail",
          "user",
          "continue immediately",
          "req_before_detail"
        ),
      ])
    );
    await send;

    // The initial detail request began before the append and can return 304;
    // the explicit send supersedes it with a fresh exact read.
    api.resolvePoll(0, {
      etag: '"task-initial"',
      notModified: true,
    });
    await flushMicrotasks();

    expect(api.polls).toHaveLength(2);

    api.resolvePoll(1, {
      conversation: conversation({ kind: "agent_task", status: "completed" }, [
        message(
          "msg_before_detail",
          "user",
          "continue immediately",
          "req_before_detail"
        ),
        message("msg_after_detail", "assistant", "continued after loading"),
      ]),
      etag: '"task-terminal-1"',
      notModified: false,
    });
    await flushMicrotasks();

    expect(channel.getSnapshot().messages.at(-1)).toMatchObject({
      messageId: "msg_after_detail",
      role: "assistant",
      text: "continued after loading",
    });
  });

  it("settles a terminal task follow-up when sendMessage already includes its reply", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, {
      initialKind: "agent_task",
      requestIds: ["req_immediate_reply"],
    });

    channel.start();
    api.resolvePoll(0, {
      conversation: conversation({ kind: "agent_task", status: "completed" }),
      etag: '"task-terminal-1"',
      notModified: false,
    });
    await flushMicrotasks();

    const send = channel.send("continue");
    api.resolveSend(
      0,
      conversation({ kind: "agent_task", status: "completed" }, [
        message("msg_follow_up", "user", "continue", "req_immediate_reply"),
        message("msg_immediate_reply", "assistant", "already continued"),
      ])
    );
    await send;

    expect(channel.getSnapshot().messages.at(-1)).toMatchObject({
      messageId: "msg_immediate_reply",
      role: "assistant",
      text: "already continued",
    });
    channel.stop();
  });

  it("reopens the Chat stream after an opaque invalidation without a resume cursor", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    expect(api.streams).toHaveLength(1);

    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");
    api.emit(0, { type: "conversation_invalidated" }, "conversation_invalidated");
    await flushMicrotasks();

    expect(api.streams).toHaveLength(2);
    vi.useRealTimers();
  });

  it("reuses message and array references when an equivalent snapshot repeats", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [message("msg_1", "assistant", "stable answer")],
      },
      "snapshot"
    );
    const firstMessages = channel.getSnapshot().messages;
    const firstMessage = firstMessages[0];

    api.emit(
      0,
      {
        type: "snapshot",
        messages: [message("msg_1", "assistant", "stable answer")],
      },
      "snapshot"
    );

    expect(channel.getSnapshot().messages).toBe(firstMessages);
    expect(channel.getSnapshot().messages[0]).toBe(firstMessage);
  });

  it("keeps every non-draft field identity on setDraft and emits once per change", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [message("msg_1", "assistant", "stable answer")],
      },
      "snapshot"
    );
    const before = channel.getSnapshot();
    const emitted = vi.fn();
    channel.subscribe(emitted);

    channel.setDraft("typing a draft");
    const after = channel.getSnapshot();
    expect(emitted).toHaveBeenCalledTimes(1);
    expect(after.draft).toBe("typing a draft");
    // A keystroke must not rebuild derived conversation state: memoized
    // subscribers bail on these identities to skip the transcript re-render.
    expect(after.messages).toBe(before.messages);
    expect(after.serverMessages).toBe(before.serverMessages);
    expect(after.pending).toBe(before.pending);
    expect(after.conversation).toBe(before.conversation);

    // Re-setting the same draft is a no-op and must not emit at all.
    channel.setDraft("typing a draft");
    expect(emitted).toHaveBeenCalledTimes(1);
  });

  it("derives ref cards and attachment views from additive content blocks", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_1", "assistant", "created the task\nfallback text", undefined, {
            content: [
              { type: "text", text: "created the task" },
              {
                type: "conversation_ref",
                conversation_id: "cnv_task",
                kind: "agent_task",
                title: "部署报告",
              },
              {
                type: "file",
                file_name: "report.pdf",
                mime_type: "application/pdf",
                size: 123,
                title: "report.pdf",
              },
              {
                type: "image",
                file_name: "diagram.png",
                mime_type: "image/png",
                size: 456,
              },
              { type: "widget", text: "fallback text" },
            ],
          }),
        ],
      },
      "snapshot"
    );

    expect(channel.getSnapshot().messages[0]).toMatchObject({
      attachments: [
        {
          blockType: "file",
          fileName: "report.pdf",
          mimeType: "application/pdf",
          size: 123,
          title: "report.pdf",
        },
        {
          blockType: "image",
          fileName: "diagram.png",
          mimeType: "image/png",
          size: 456,
          title: undefined,
        },
      ],
      refs: [{ conversationId: "cnv_task", kind: "agent_task", title: "部署报告" }],
      parts: [{ kind: "markdown", text: "created the task\nfallback text" }],
    });
  });

  it("projects a canonical local JPG as an image with its opaque preview ref", () => {
    const api = createConversationApi();
    const channel = createChannel(api);
    const localFileRef = `lfi1_${"i".repeat(43)}`;

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_local_image", "user", "", undefined, {
            content: [
              {
                type: "local_file",
                display_name: "promise.jpg",
                local_file_ref: localFileRef,
                media_type: "image/jpeg",
                size: 456,
              },
            ],
          }),
        ],
      },
      "snapshot"
    );

    expect(channel.getSnapshot().messages[0]?.attachments).toEqual([
      {
        blockType: "image",
        fileName: "promise.jpg",
        localFileRef,
        mimeType: "image/jpeg",
        size: 456,
        title: undefined,
      },
    ]);
  });

  it("projects canonical local GIF and WebP files as images", () => {
    const api = createConversationApi();
    const channel = createChannel(api);
    const gifRef = `lfi1_${"g".repeat(43)}`;
    const webpRef = `lfi1_${"w".repeat(43)}`;

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_local_gif", "user", "", undefined, {
            content: [
              {
                type: "local_file",
                display_name: "motion.gif",
                local_file_ref: gifRef,
                media_type: "image/gif",
                size: 120,
              },
            ],
          }),
          message("msg_local_webp", "user", "", undefined, {
            content: [
              {
                type: "local_file",
                display_name: "photo.webp",
                local_file_ref: webpRef,
                media_type: "image/webp",
                size: 240,
              },
            ],
          }),
        ],
      },
      "snapshot"
    );

    expect(channel.getSnapshot().messages[0]?.attachments).toEqual([
      {
        blockType: "image",
        fileName: "motion.gif",
        localFileRef: gifRef,
        mimeType: "image/gif",
        size: 120,
        title: undefined,
      },
    ]);
    expect(channel.getSnapshot().messages[1]?.attachments).toEqual([
      {
        blockType: "image",
        fileName: "photo.webp",
        localFileRef: webpRef,
        mimeType: "image/webp",
        size: 240,
        title: undefined,
      },
    ]);
  });

  it("keeps legacy multi-text rich messages on the canonical content fallback", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_legacy_rich", "assistant", "a\nb", undefined, {
            content: [
              { type: "text", text: "a" },
              { type: "text", text: "b" },
              {
                type: "conversation_ref",
                conversation_id: "cnv_task",
                kind: "agent_task",
                title: "Legacy Task",
              },
            ],
          }),
        ],
      },
      "snapshot"
    );

    expect(channel.getSnapshot().messages[0]).toMatchObject({
      parts: [{ kind: "markdown", text: "a\nb" }],
      refs: [
        {
          conversationId: "cnv_task",
          kind: "agent_task",
          title: "Legacy Task",
        },
      ],
    });
  });

  it("preserves inline Task references in their ordered message positions", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_inline", "assistant", "created a task", undefined, {
            content: [
              { type: "text", text: "Created " },
              {
                type: "conversation_ref",
                conversation_id: "cnv_task_public",
                kind: "agent_task",
                presentation: "inline",
                status: "running",
                title: "Deploy report",
              },
              { type: "text", text: " and kept " },
              { type: "widget", text: "its fallback " },
              {
                type: "conversation_ref",
                conversation_id: "cnv_chat_public",
                kind: "user_chat",
                title: "Related chat",
              },
              { type: "text", text: "." },
            ],
          }),
        ],
      },
      "snapshot"
    );

    expect(channel.getSnapshot().messages[0]).toMatchObject({
      parts: [
        { kind: "markdown", text: "Created " },
        {
          kind: "inline-task",
          task: {
            conversationId: "cnv_task_public",
            status: "running",
            title: "Deploy report",
            unavailable: false,
          },
        },
        { kind: "markdown", text: " and kept " },
        { kind: "markdown", text: "its fallback " },
        { kind: "markdown", text: "." },
      ],
      refs: [
        {
          conversationId: "cnv_chat_public",
          kind: "user_chat",
          title: "Related chat",
        },
      ],
    });
  });

  it("projects a user message's comma:task mention link as an inline Task part", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message(
            "msg_user_mention",
            "user",
            "Check [Fix login](comma:task/cnv1_menu) today"
          ),
          message(
            "msg_assistant_plain",
            "assistant",
            "Mentioning [Fix login](comma:task/cnv1_menu) as text"
          ),
        ],
      },
      "snapshot"
    );

    const [userMessage, assistantMessage] = channel.getSnapshot().messages;
    expect(userMessage?.parts).toEqual([
      { kind: "markdown", text: "Check " },
      {
        kind: "inline-task",
        task: {
          conversationId: "cnv1_menu",
          title: "Fix login",
          unavailable: false,
        },
      },
      { kind: "markdown", text: " today" },
    ]);
    // Assistant Task references arrive only as structured conversation_ref
    // blocks; assistant-authored text must never be parsed into chips.
    expect(assistantMessage?.parts).toEqual([
      {
        kind: "markdown",
        text: "Mentioning [Fix login](comma:task/cnv1_menu) as text",
      },
    ]);
  });

  it("preserves a whitespace-only text block between inline Tasks", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_inline_spacing", "assistant", "First Second", undefined, {
            content: [
              {
                type: "conversation_ref",
                conversation_id: "cnv_task_first",
                kind: "agent_task",
                presentation: "inline",
                title: "First",
              },
              { type: "text", text: " " },
              {
                type: "conversation_ref",
                conversation_id: "cnv_task_second",
                kind: "agent_task",
                presentation: "inline",
                title: "Second",
              },
            ],
          }),
        ],
      },
      "snapshot"
    );

    expect(channel.getSnapshot().messages[0]?.parts).toEqual([
      {
        kind: "inline-task",
        task: {
          activityStatus: undefined,
          conversationId: "cnv_task_first",
          freshness: undefined,
          status: undefined,
          title: "First",
          unavailable: false,
          updatedAt: undefined,
        },
      },
      { kind: "markdown", text: " " },
      {
        kind: "inline-task",
        task: {
          activityStatus: undefined,
          conversationId: "cnv_task_second",
          freshness: undefined,
          status: undefined,
          title: "Second",
          unavailable: false,
          updatedAt: undefined,
        },
      },
    ]);
  });

  it("keeps unavailable inline Tasks ordered without retaining identity fields", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message(
            "msg_inline_unavailable",
            "assistant",
            "Task unavailable",
            undefined,
            {
              content: [
                { type: "text", text: "Open " },
                {
                  type: "conversation_ref",
                  presentation: "inline",
                  unavailable: true,
                },
                { type: "text", text: " later." },
              ],
            }
          ),
        ],
      },
      "snapshot"
    );

    expect(channel.getSnapshot().messages[0]?.parts).toEqual([
      { kind: "markdown", text: "Open " },
      { kind: "inline-task", task: { unavailable: true } },
      { kind: "markdown", text: " later." },
    ]);
    expect(channel.getSnapshot().messages[0]?.refs).toEqual([]);
  });

  it("consumes malformed inline references as unavailable instead of legacy cards", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_inline_malformed", "assistant", "Malformed task", undefined, {
            content: [
              { type: "text", text: "Open " },
              {
                type: "conversation_ref",
                conversation_id: "cnv_untrusted",
                kind: "user_chat",
                presentation: "inline",
                title: "Untrusted title",
              },
              { type: "text", text: "." },
            ],
          }),
        ],
      },
      "snapshot"
    );

    expect(channel.getSnapshot().messages[0]?.parts).toEqual([
      { kind: "markdown", text: "Open " },
      { kind: "inline-task", task: { unavailable: true } },
      { kind: "markdown", text: "." },
    ]);
    expect(channel.getSnapshot().messages[0]?.refs).toEqual([]);
    expect(JSON.stringify(channel.getSnapshot().messages[0]?.parts)).not.toContain(
      "Untrusted title"
    );
    expect(JSON.stringify(channel.getSnapshot().messages[0]?.parts)).not.toContain(
      "cnv_untrusted"
    );
  });

  it("keeps block-derived message references stable until canonical content changes", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_1", "assistant", "answer", undefined, {
            content: [
              { type: "conversation_ref", conversation_id: "cnv_task", title: "A" },
            ],
          }),
        ],
      },
      "snapshot"
    );
    const first = channel.getSnapshot().messages[0];

    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_1", "assistant", "answer", undefined, {
            content: [
              { type: "conversation_ref", conversation_id: "cnv_task", title: "A" },
            ],
          }),
        ],
      },
      "snapshot"
    );
    expect(channel.getSnapshot().messages[0]).toBe(first);

    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_1", "assistant", "answer", undefined, {
            content: [
              { type: "conversation_ref", conversation_id: "cnv_task", title: "B" },
            ],
          }),
        ],
      },
      "snapshot"
    );

    expect(channel.getSnapshot().messages[0]).not.toBe(first);
    expect(channel.getSnapshot().messages[0]?.refs[0]?.title).toBe("B");
  });

  it("reconciles optimistic sends by client_request_id and retries with the same id", async () => {
    const api = createConversationApi();
    let clientDeviceId = "device-a";
    const channel = createChannel(api, {
      requestIds: ["req_1", "req_2", "req_3"],
      getClientDeviceId: () => clientDeviceId,
    });

    const firstSend = channel.send("hello");
    expect(channel.getSnapshot().pending).toMatchObject([
      { clientRequestId: "req_1", text: "hello", status: "sending" },
    ]);
    expect(channel.getSnapshot().messages.at(-1)).toMatchObject({
      clientRequestId: "req_1",
      role: "user",
      text: "hello",
      delivery: "sending",
    });

    api.resolveSend(
      0,
      conversation({ status: "waiting" }, [message("msg_1", "user", "hello", "req_1")])
    );
    await firstSend;

    expect(channel.getSnapshot().pending).toEqual([]);
    expect(channel.getSnapshot().messages).toMatchObject([
      { messageId: "msg_1", clientRequestId: "req_1", role: "user", text: "hello" },
    ]);

    const retrySend = channel.send("again");
    api.rejectSend(1, new Error("offline"));
    await expect(retrySend).rejects.toThrow("offline");
    expect(channel.getSnapshot().pending).toMatchObject([
      { clientRequestId: "req_2", text: "again", status: "failed" },
    ]);

    clientDeviceId = "device-b";
    const retry = channel.retry("req_2");
    expect(api.sendCalls.at(-1)).toMatchObject({
      clientDeviceId: "device-a",
      text: "again",
      clientRequestId: "req_2",
    });
    api.resolveSend(
      2,
      conversation({ status: "waiting" }, [message("msg_2", "user", "again", "req_2")])
    );
    await retry;
    expect(channel.getSnapshot().pending).toEqual([]);

    const discardSend = channel.send("discard me");
    expect(api.sendCalls.at(-1)).toMatchObject({ clientDeviceId: "device-b" });
    api.rejectSend(3, new Error("offline"));
    await expect(discardSend).rejects.toThrow("offline");
    const failedId = channel.getSnapshot().pending[0]?.clientRequestId;
    expect(failedId).toBeTruthy();
    channel.discard(failedId ?? "");
    expect(channel.getSnapshot().pending).toEqual([]);
  });

  it("localizes billing send failures without exposing server error codes", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, {
      requestIds: ["req_billing", "req_internal"],
    });

    const billingSend = channel.send("hello");
    api.rejectSend(
      0,
      new CommaApiError(402, "billing_unavailable", {
        error: "billing_unavailable",
        reason: "insufficient_credits",
      })
    );
    await expect(billingSend).rejects.toThrow("billing_unavailable");

    expect(channel.getSnapshot().pending).toMatchObject([
      {
        clientRequestId: "req_billing",
        error: "You’re out of credits. Add credits or switch plans to continue.",
        failureAction: "billing",
        status: "failed",
      },
    ]);
    expect(JSON.stringify(channel.getSnapshot().messages)).not.toContain(
      "billing_unavailable"
    );
    expect(JSON.stringify(channel.getSnapshot().messages)).not.toContain(
      "insufficient_credits"
    );

    const internalSend = channel.send("again");
    api.rejectSend(
      1,
      new CommaApiError(500, "private_internal_detail", {
        error: "private_internal_detail",
      })
    );
    await expect(internalSend).rejects.toThrow("private_internal_detail");

    expect(channel.getSnapshot().pending.at(-1)).toMatchObject({
      clientRequestId: "req_internal",
      error: undefined,
      status: "failed",
    });
    expect(JSON.stringify(channel.getSnapshot().messages)).not.toContain(
      "private_internal_detail"
    );

    const zhApi = createConversationApi();
    const zhChannel = createChannel(zhApi, {
      locale: "zh-CN",
      requestIds: ["req_billing_zh"],
    });
    const zhSend = zhChannel.send("你好");
    zhApi.rejectSend(
      0,
      new CommaApiError(402, "billing_unavailable", {
        error: "billing_unavailable",
        reason: "insufficient_credits",
      })
    );
    await expect(zhSend).rejects.toThrow("billing_unavailable");
    expect(zhChannel.getSnapshot().pending).toMatchObject([
      {
        error: "额度不足，请充值或升级套餐后重试。",
        status: "failed",
      },
    ]);
  });

  it("reconciles optimistic sends when Salix echoes the request id as message_id only", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { requestIds: ["req_real_shape"] });

    const send = channel.send("hello real salix");

    api.resolveSend(
      0,
      conversation({ status: "waiting" }, [
        message("req_real_shape", "user", "hello real salix"),
      ])
    );
    await send;

    expect(channel.getSnapshot().pending).toEqual([]);
    expect(channel.getSnapshot().messages).toMatchObject([
      {
        delivery: "sent",
        messageId: "req_real_shape",
        role: "user",
        text: "hello real salix",
      },
    ]);
  });

  it("sends skill mention locations and retries with the same skills", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { requestIds: ["req_skill"] });
    const skills = [{ location: "/.runtime/skills/code-review/SKILL.md" }];

    const send = channel.send("please /code-review", { skills });
    expect(api.sendCalls[0]).toMatchObject({
      clientRequestId: "req_skill",
      skills,
      text: "please /code-review",
    });

    api.rejectSend(0, new Error("offline"));
    await expect(send).rejects.toThrow("offline");

    const retry = channel.retry("req_skill");
    expect(api.sendCalls[1]).toMatchObject({
      clientRequestId: "req_skill",
      skills,
      text: "please /code-review",
    });
    api.resolveSend(
      1,
      conversation({ status: "waiting" }, [
        message("msg_skill", "user", "please /code-review", "req_skill"),
      ])
    );
    await retry;
    expect(channel.getSnapshot().pending).toEqual([]);
  });

  it("admits a mixed local/image selection identically in either order", () => {
    const localFile = {
      localFileRef: `lfi1_${"q".repeat(43)}`,
      mediaType: "text/plain",
      name: "notes.txt",
      size: 5,
    };
    const images = Array.from({ length: 8 }, (_, index) => ({
      name: `photo-${index}.png`,
      size: 3,
      data: new Blob(["img"]),
    }));

    // Local ref first, then a full slate of eight images.
    const localFirst = createChannel(createConversationApi());
    localFirst.attachLocalFiles([localFile]);
    localFirst.attachFiles(images);
    const localFirstFailures = localFirst
      .getSnapshot()
      .draftAttachments.filter((attachment) => attachment.status === "failed");
    expect(localFirst.getSnapshot().draftAttachments).toHaveLength(9);
    expect(localFirstFailures).toEqual([]);

    // The reversed order must admit the exact same selection.
    const imagesFirst = createChannel(createConversationApi());
    imagesFirst.attachFiles(images);
    expect(() => imagesFirst.attachLocalFiles([{ ...localFile }])).not.toThrow();
    const imagesFirstFailures = imagesFirst
      .getSnapshot()
      .draftAttachments.filter((attachment) => attachment.status === "failed");
    expect(imagesFirst.getSnapshot().draftAttachments).toHaveLength(9);
    expect(imagesFirstFailures).toEqual([]);

    // The upload budget itself still binds: a ninth image fails in both.
    imagesFirst.attachFiles([
      { name: "photo-9.png", size: 3, data: new Blob(["img"]) },
    ]);
    expect(
      imagesFirst
        .getSnapshot()
        .draftAttachments.filter((attachment) => attachment.status === "failed")
    ).toHaveLength(1);
  });

  it("uploads draft attachments before sending and reuses uploaded files on message retry", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, {
      requestIds: ["att_1", "req_upload"],
    });

    channel.attachFiles([{ name: "report.txt", size: 5, data: new Blob(["hello"]) }]);
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { id: "att_1", name: "report.txt", status: "uploading" },
    ]);
    expect(api.uploadCalls[0]?.name).toBe("report.txt");

    api.resolveUpload(0, {
      path: "/uploads/1-report.txt",
      name: "report.txt",
      size: 5,
    });
    await flushMicrotasks();
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { path: "/uploads/1-report.txt", status: "uploaded" },
    ]);

    const send = channel.send("");
    expect(api.sendCalls[0]).toMatchObject({
      clientRequestId: "req_upload",
      text: `${ATTACHED_ONLY_TEXT}\n\n${ATTACHED_FILES_HEADER}\n- report.txt (workspace file: /uploads/1-report.txt)`,
    });
    expect(channel.getSnapshot().draftAttachments).toEqual([]);

    api.rejectSend(0, new Error("offline"));
    await expect(send).rejects.toThrow("offline");
    expect(api.uploadCalls).toHaveLength(1);

    const retry = channel.retry("req_upload");
    expect(api.uploadCalls).toHaveLength(1);
    expect(api.sendCalls[1]?.text).toContain("/uploads/1-report.txt");
    api.resolveSend(
      1,
      conversation({ status: "waiting" }, [
        message("msg_upload", "user", api.sendCalls[1]?.text ?? "", "req_upload"),
      ])
    );
    await retry;
  });

  it("previews only bounded workspace-image responses and revokes their URLs", async () => {
    const api = createConversationApi();
    const channel = createChannel(api);
    const workspacePath = `/uploads/${"A".repeat(22)}-preview.png`;
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:web-workspace-preview");
    const revokeObjectURL = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {});

    const operation = channel.previewLocalFile(workspacePath);
    expect(api.fetchCalls).toMatchObject([{ path: workspacePath }]);
    api.resolveFetch(
      0,
      new Blob([Uint8Array.from([137, 80, 78, 71])], { type: "image/png" })
    );
    const preview = await operation;

    expect(preview?.url).toBe("blob:web-workspace-preview");
    preview?.release();
    preview?.release();
    expect(revokeObjectURL).toHaveBeenCalledOnce();

    await expect(
      channel.previewLocalFile("/uploads/../../private.png")
    ).resolves.toBeUndefined();
    expect(api.fetchCalls).toHaveLength(1);

    const mismatched = channel.previewLocalFile(
      `/uploads/${"B".repeat(22)}-mismatched.png`
    );
    api.resolveFetch(1, new Blob(["jpeg"], { type: "image/jpeg" }));
    await expect(mismatched).resolves.toBeUndefined();
    expect(createObjectURL).toHaveBeenCalledOnce();

    createObjectURL.mockRestore();
    revokeObjectURL.mockRestore();
  });

  it("resolves an Agent image from the canonical blob reference in the Message", async () => {
    const api = createConversationApi();
    const channel = createChannel(api);
    const blobRef = {
      hash: "b".repeat(64),
      kind: "blob" as const,
      size: 4,
      uuid: "a".repeat(32),
    };
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:agent-image-preview");
    const revokeObjectURL = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {});

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_agent_image", "assistant", "", undefined, {
            agent_id: "agt1_image_author",
            content: [
              {
                blob_ref: blobRef,
                file_name: "capture.png",
                file_ref: {
                  environment_id: "vfs",
                  path: "/artifacts/capture.png",
                },
                mime_type: "image/png",
                size: 4,
                type: "image",
              },
            ],
          }),
        ],
      },
      "snapshot"
    );

    const attachment = channel.getSnapshot().serverMessages[0]?.attachments[0];
    expect(attachment).toMatchObject({
      agentId: "agt1_image_author",
      blobRef,
      fileName: "capture.png",
      mimeType: "image/png",
      workspacePath: "/artifacts/capture.png",
    });

    const operation = channel.previewLocalFile({
      agentId: attachment!.agentId!,
      blobRef: attachment!.blobRef!,
      fileName: attachment!.fileName!,
      kind: "agent-blob",
      mediaType: "image/png",
    });
    expect(api.agentBlobFetchCalls).toMatchObject([
      { agentId: "agt1_image_author", ref: blobRef },
    ]);
    api.resolveAgentBlobFetch(
      0,
      new Blob([Uint8Array.of(137, 80, 78, 71)], {
        type: "application/octet-stream",
      })
    );

    const preview = await operation;
    expect(preview?.url).toBe("blob:agent-image-preview");
    expect(createObjectURL.mock.calls[0]?.[0]).toMatchObject({
      size: 4,
      type: "image/png",
    });
    preview?.release();
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:agent-image-preview");

    channel.stop();
    createObjectURL.mockRestore();
    revokeObjectURL.mockRestore();
  });

  it("sends local refs without uploading bytes and preserves them across retry", async () => {
    const api = createConversationApi();
    const onLocalFilesCommitted = vi.fn(async () => undefined);
    const channel = createChannel(api, {
      onLocalFilesCommitted,
      requestIds: ["req_local"],
    });
    const localFile = {
      localFileRef: `lfi1_${"b".repeat(43)}`,
      mediaType: "text/plain",
      name: "notes.txt",
      size: 5,
    };

    channel.attachLocalFiles([localFile]);
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { name: "notes.txt", size: 5, status: "uploaded" },
    ]);
    expect(api.uploadCalls).toHaveLength(0);

    const send = channel.send("");
    expect(api.sendCalls[0]).toMatchObject({
      clientRequestId: "req_local",
      localFiles: [
        {
          displayName: "notes.txt",
          localFileRef: localFile.localFileRef,
          mediaType: "text/plain",
          size: 5,
        },
      ],
      text: "",
    });
    expect(channel.getSnapshot().draftAttachments).toEqual([]);

    api.rejectSend(0, new Error("offline"));
    await expect(send).rejects.toThrow("offline");
    expect(onLocalFilesCommitted).not.toHaveBeenCalled();
    const retry = channel.retry("req_local");
    expect(api.sendCalls[1]).toMatchObject({
      clientRequestId: "req_local",
      localFiles: api.sendCalls[0]?.localFiles,
    });
    api.resolveSend(
      1,
      conversation({ status: "waiting" }, [
        message("msg_local", "user", "", "req_local", {
          content: [
            {
              type: "local_file",
              local_file_ref: localFile.localFileRef,
              display_name: "notes.txt",
              media_type: "text/plain",
              size: 5,
            },
          ],
        }),
      ])
    );
    await retry;
    expect(onLocalFilesCommitted).toHaveBeenCalledOnce();
    expect(onLocalFilesCommitted).toHaveBeenCalledWith(
      api.sendCalls[0]?.localFiles,
      1_000
    );
    expect(channel.getSnapshot().messages[0]?.attachments).toMatchObject([
      { fileName: "notes.txt", mimeType: "text/plain", size: 5 },
    ]);
  });

  it("reconciles committed local refs after a lost send response", async () => {
    const api = createConversationApi();
    const onLocalFilesCommitted = vi.fn(async () => undefined);
    const channel = createChannel(api, {
      initialKind: "agent_task",
      onLocalFilesCommitted,
      requestIds: ["req_lost_local"],
    });
    const localFile = {
      localFileRef: `lfi1_${"c".repeat(43)}`,
      mediaType: "text/plain",
      name: "lost.txt",
      size: 7,
    };

    channel.start();
    channel.attachLocalFiles([localFile]);
    const send = channel.send("");
    api.rejectSend(0, new Error("response lost"));
    await expect(send).rejects.toThrow("response lost");
    expect(onLocalFilesCommitted).not.toHaveBeenCalled();

    api.resolvePoll(0, {
      conversation: conversation({ kind: "agent_task", status: "ready_for_review" }, [
        message("msg_lost_local", "user", "", "req_lost_local", {
          content: [
            {
              type: "local_file",
              local_file_ref: localFile.localFileRef,
              display_name: "lost.txt",
              media_type: "text/plain",
              size: 7,
            },
          ],
          created_at: 12_345,
        }),
      ]),
      etag: '"lost-local-committed"',
      notModified: false,
    });
    await flushMicrotasks();

    expect(onLocalFilesCommitted).toHaveBeenCalledOnce();
    expect(onLocalFilesCommitted).toHaveBeenCalledWith(
      [
        {
          displayName: "lost.txt",
          localFileRef: localFile.localFileRef,
          mediaType: "text/plain",
          size: 7,
        },
      ],
      12_345_000
    );
    expect(channel.getSnapshot().pending).toEqual([]);
    channel.stop();
  });

  it("reconciles canonical local refs on a fresh runtime after restart", async () => {
    const api = createConversationApi();
    const onLocalFilesCommitted = vi.fn(async () => undefined);
    const channel = createChannel(api, {
      initialKind: "agent_task",
      onLocalFilesCommitted,
    });
    const localFileRef = `lfi1_${"d".repeat(43)}`;

    channel.start();
    api.resolvePoll(0, {
      conversation: conversation({ kind: "agent_task", status: "ready_for_review" }, [
        message("msg_restart_local", "user", "", "req_restart_local", {
          content: [
            {
              type: "local_file",
              local_file_ref: localFileRef,
              display_name: "restart.txt",
              media_type: "text/plain",
              size: 9,
            },
          ],
          created_at: 22_222,
        }),
      ]),
      etag: '"restart-local"',
      notModified: false,
    });
    await flushMicrotasks();

    expect(onLocalFilesCommitted).toHaveBeenCalledOnce();
    expect(onLocalFilesCommitted).toHaveBeenCalledWith(
      [
        {
          displayName: "restart.txt",
          localFileRef,
          mediaType: "text/plain",
          size: 9,
        },
      ],
      22_222_000
    );
    channel.stop();
  });

  it("blocks sends while attachments are failed and retries attachment uploads", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, {
      requestIds: ["att_1", "req_after_upload"],
    });

    channel.attachFiles([{ name: "fail.txt", size: 5, data: new Blob(["hello"]) }]);
    api.rejectUpload(0, new CommaApiError(413, "file_too_large"));
    await flushMicrotasks();
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { error: "The file exceeds the 10 MB limit", status: "failed" },
    ]);

    await expect(channel.send("send anyway")).resolves.toBeUndefined();
    expect(api.sendCalls).toHaveLength(0);

    channel.retryAttachment("att_1");
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { status: "uploading" },
    ]);
    expect(api.uploadCalls).toHaveLength(2);
    api.resolveUpload(1, {
      path: "/uploads/2-fail.txt",
      name: "fail.txt",
      size: 5,
    });
    await flushMicrotasks();

    const send = channel.send("now send");
    expect(api.sendCalls[0]?.text).toContain("/uploads/2-fail.txt");
    api.resolveSend(
      0,
      conversation({ status: "waiting" }, [
        message("msg_upload", "user", api.sendCalls[0]?.text ?? "", "req_after_upload"),
      ])
    );
    await send;
  });

  it("fails local attachment validation without calling the API and aborts removed uploads", () => {
    const api = createConversationApi();
    const channel = createChannel(api, {
      requestIds: ["bad_ext", "too_large", "good"],
    });

    channel.attachFiles([
      { name: "script.exe", size: 1, data: new Blob(["x"]) },
      {
        name: "huge.txt",
        size: 10_000_001,
        data: new Blob(["x"]),
      },
      { name: "notes.txt", size: 1, data: new Blob(["x"]) },
    ]);

    expect(api.uploadCalls).toHaveLength(1);
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { error: "This file type is not supported", status: "failed" },
      { error: "The file exceeds the 10 MB limit", status: "failed" },
      { name: "notes.txt", status: "uploading" },
    ]);

    channel.removeAttachment("good");
    expect(api.uploadCalls[0]?.signal?.aborted).toBe(true);
    expect(channel.getSnapshot().draftAttachments.map((item) => item.id)).toEqual([
      "bad_ext",
      "too_large",
    ]);
  });

  it("localizes attachment validation with the channel's explicit locale", () => {
    const api = createConversationApi();
    const channel = createChannel(api, {
      locale: "zh-CN",
      requestIds: ["bad_ext"],
    });

    channel.attachFiles([{ name: "script.exe", size: 1, data: new Blob(["x"]) }]);

    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { error: "不支持此文件类型", status: "failed" },
    ]);
    expect(api.uploadCalls).toHaveLength(0);
  });

  it("rejects camera formats the runtime cannot read unless a transcoder is installed", () => {
    const api = createConversationApi();
    const channel = createChannel(api, { requestIds: ["heic"] });

    channel.attachFiles([{ name: "IMG_0001.HEIC", size: 3, data: new Blob(["x"]) }]);

    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { error: "This file type is not supported", status: "failed" },
    ]);
    expect(api.uploadCalls).toHaveLength(0);
  });

  it("transcodes a HEIC attachment to JPEG before uploading it", async () => {
    const api = createConversationApi();
    const transcodeAttachment = vi.fn<AttachmentTranscoder>(async (file) => ({
      data: new Blob(["jpeg-bytes"], { type: "image/jpeg" }),
      name: file.name.replace(/\.heic$/i, ".jpg"),
      size: 10,
    }));
    const channel = createChannel(api, {
      requestIds: ["heic"],
      transcodeAttachment,
    });

    channel.attachFiles([{ name: "IMG_0001.HEIC", size: 3, data: new Blob(["x"]) }]);
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { id: "heic", isImage: true, name: "IMG_0001.HEIC", status: "uploading" },
    ]);
    expect(transcodeAttachment).toHaveBeenCalledOnce();
    await flushMicrotasks();

    expect(api.uploadCalls).toHaveLength(1);
    expect(api.uploadCalls[0]?.name).toBe("IMG_0001.jpg");
    api.resolveUpload(0, {
      path: "/uploads/1-IMG_0001.jpg",
      name: "IMG_0001.jpg",
      size: 10,
    });
    await flushMicrotasks();
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      {
        isImage: true,
        name: "IMG_0001.jpg",
        path: "/uploads/1-IMG_0001.jpg",
        status: "uploaded",
      },
    ]);
  });

  it("fails the attachment without uploading when the transcoder cannot decode it", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, {
      requestIds: ["heic"],
      transcodeAttachment: async () => {
        throw new Error("sips: unable to decode");
      },
    });

    channel.attachFiles([{ name: "broken.heif", size: 3, data: new Blob(["x"]) }]);
    await flushMicrotasks();

    expect(api.uploadCalls).toHaveLength(0);
    expect(channel.getSnapshot().draftAttachments).toMatchObject([
      { error: "Upload failed", status: "failed" },
    ]);
  });

  it("derives awaiting reply from user-tail snapshots but cancelled and failed clear it", async () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        status: "completed",
        messages: [message("msg_1", "user", "question")],
      },
      "snapshot"
    );

    expect(channel.getSnapshot()).toMatchObject({
      awaitingReply: true,
      awaitingTimedOut: false,
    });

    api.emit(
      0,
      {
        type: "snapshot",
        status: "cancelled",
        messages: [message("msg_1", "user", "question")],
      },
      "snapshot"
    );

    expect(channel.getSnapshot()).toMatchObject({
      awaitingReply: false,
      awaitingTimedOut: false,
    });

    api.emit(
      0,
      {
        type: "snapshot",
        status: "failed",
        messages: [message("msg_1", "user", "question")],
      },
      "snapshot"
    );

    expect(channel.getSnapshot()).toMatchObject({
      awaitingReply: false,
      awaitingTimedOut: false,
    });
  });

  it("does not present an idle Router with a user-tail transcript as still thinking", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        activity_status: "thinking",
        messages: [message("msg_1", "user", "create a task")],
      } as CommaConversationEvent,
      "snapshot"
    );
    expect(channel.getSnapshot().awaitingReply).toBe(true);

    api.emit(
      0,
      {
        type: "snapshot",
        activity_status: "idle",
        messages: [message("msg_1", "user", "create a task")],
      } as CommaConversationEvent,
      "snapshot"
    );
    expect(channel.getSnapshot()).toMatchObject({
      awaitingReply: false,
      awaitingTimedOut: false,
    });
  });

  it("projects the exact participant display status independently of local awaiting state", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        activity_status: "idle",
        messages: [message("msg_1", "user", "create a task")],
      } as CommaConversationEvent,
      "snapshot"
    );
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_1", "user", "create a task"),
          message("msg_progress", "assistant", "I will check that"),
        ],
        participant_status: {
          conversation_id: "cnv_1",
          participant_id: "ptp_1",
          state: "active",
          status: "is executing a tool...",
          working_provider: "wechat",
          updated_at: 1_780_000_000_123,
        },
      } as CommaConversationEvent,
      "snapshot"
    );

    expect(channel.getSnapshot()).toMatchObject({
      participantStatus: {
        conversationId: "cnv_1",
        participantId: "ptp_1",
        state: "active",
        status: "is executing a tool...",
        workingProvider: "wechat",
        updatedAt: 1_780_000_000_123,
      },
    });
    expect(
      conversationProjectionSchema.parse(
        toConversationProjection(channel.getSnapshot(), {
          groupId: "grp_1",
          workspaceId: "wsp_1",
        })
      ).participantStatus
    ).toEqual({
      conversationId: "cnv_1",
      participantId: "ptp_1",
      state: "active",
      status: "is executing a tool...",
      workingProvider: "wechat",
      updatedAt: 1_780_000_000_123,
    });

    // A reply or an unrelated owner in a malformed snapshot cannot stop the
    // actual Participant's continued work.
    api.emit(
      0,
      {
        type: "snapshot",
        participant_status: {
          conversation_id: "cnv_other",
          participant_id: "ptp_other",
          state: "stopped",
          status: "",
          updated_at: 1_780_000_000_456,
        },
      },
      "snapshot"
    );
    expect(channel.getSnapshot().participantStatus?.state).toBe("active");

    api.emit(
      0,
      {
        type: "participant_status",
        conversation_id: "cnv_1",
        participant_id: "ptp_1",
        state: "stopped",
        status: "",
        updated_at: 1_780_000_000_456,
      } as CommaConversationEvent,
      "participant_status"
    );

    expect(channel.getSnapshot()).toMatchObject({
      participantStatus: {
        participantId: "ptp_1",
        state: "stopped",
        status: "",
        updatedAt: 1_780_000_000_456,
      },
    });
  });

  it("keeps a Loop wake classified across an unavailable reconnect read until a new chat turn", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api);
    channel.start();

    api.emit(
      0,
      {
        type: "snapshot",
        messages: [
          message("msg_1", "user", "Earlier request"),
          message("msg_2", "assistant", "Earlier reply"),
        ],
        participant_status: {
          conversation_id: "cnv_1",
          participant_id: "ptp_1",
          state: "active",
          status: "is thinking...",
          updated_at: 1,
          loop_wake: true,
        },
      } as CommaConversationEvent,
      "snapshot"
    );
    expect(channel.getSnapshot().participantStatus?.loopWake).toBe(true);
    expect(
      conversationProjectionSchema.parse(
        toConversationProjection(channel.getSnapshot(), {
          groupId: "grp_1",
          workspaceId: "wsp_1",
        })
      ).participantStatus?.loopWake
    ).toBe(true);

    // The Participant read may be unavailable on reconnect. Keep the Loop
    // origin with the uncertain active status so the renderer still hides it.
    api.resolveStream(0);
    await flushMicrotasks();
    await vi.advanceTimersByTimeAsync(3_000);
    expect(api.streams).toHaveLength(2);
    api.emit(
      1,
      {
        type: "snapshot",
        messages: [
          message("msg_1", "user", "Earlier request"),
          message("msg_2", "assistant", "Earlier reply"),
        ],
      } as CommaConversationEvent,
      "snapshot"
    );
    expect(channel.getSnapshot().participantStatus?.state).toBe("active");
    expect(channel.getSnapshot().participantStatus?.loopWake).toBe(true);

    api.emit(
      1,
      {
        type: "participant_status",
        conversation_id: "cnv_1",
        participant_id: "ptp_1",
        state: "active",
        status: "is thinking...",
        updated_at: 2,
      } as CommaConversationEvent,
      "participant_status"
    );
    expect(channel.getSnapshot().participantStatus?.loopWake).toBeUndefined();
    channel.stop();
    vi.useRealTimers();
  });

  it("clears Participant-owned realtime state when its owner becomes unavailable", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");
    api.emit(
      0,
      {
        type: "participant_status",
        conversation_id: "cnv_1",
        participant_id: "ptp_1",
        state: "active",
        status: "is executing a tool...",
        updated_at: 1_780_000_000_123,
      } as CommaConversationEvent,
      "participant_status"
    );
    api.emit(0, activityEvent(), "activity");

    expect(channel.getSnapshot()).toMatchObject({
      participantStatus: { state: "active" },
      activity: { status: "running" },
    });

    api.emit(
      0,
      {
        type: "participant_status_cleared",
        conversation_id: "cnv_1",
        participant_id: "ptp_1",
        reason: "owner_unavailable",
      } as CommaConversationEvent,
      "participant_status_cleared"
    );

    expect(channel.getSnapshot()).toMatchObject({
      participantStatus: undefined,
      activity: undefined,
    });
  });

  // The durable model-connection error describes the transcript position the
  // next send advances, so it must not outlive that send: held on screen it
  // reads as though the just-sent message failed before it was even delivered.
  it("retires a terminal Participant error when the next message is sent", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { requestIds: ["req_after_failure"] });

    channel.start();
    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");
    api.emit(
      0,
      {
        type: "participant_status",
        conversation_id: "cnv_1",
        participant_id: "ptp_1",
        issue: "model_connection_failed",
        state: "error",
        status: "error: the model could not be reached",
        updated_at: 1_780_000_000_123,
      } as CommaConversationEvent,
      "participant_status"
    );

    expect(channel.getSnapshot()).toMatchObject({
      participantStatus: { issue: "model_connection_failed", state: "error" },
    });

    const send = channel.send("人呢");
    expect(channel.getSnapshot().participantStatus).toBeUndefined();

    api.resolveSend(
      0,
      conversation({ activity_status: "idle", status: "waiting" }, [
        message("msg_after_failure", "user", "人呢", "req_after_failure"),
      ])
    );
    await send;
  });

  it("keeps local send feedback through stale idle snapshots and hands it over to the exact draft", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { requestIds: ["req_local_idle"] });

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        activity_status: "idle",
        messages: [],
      } as CommaConversationEvent,
      "snapshot"
    );

    const observedAwaitingStates: boolean[] = [];
    channel.subscribe(() => {
      observedAwaitingStates.push(channel.getSnapshot().awaitingReply);
    });

    const send = channel.send("keep the activity surface continuous");
    api.resolveSend(
      0,
      conversation({ activity_status: "idle", status: "waiting" }, [
        message(
          "msg_local_idle_user",
          "user",
          "keep the activity surface continuous",
          "req_local_idle"
        ),
      ])
    );
    await send;

    expect(channel.getSnapshot()).toMatchObject({
      awaitingReply: true,
      awaitingTurnKey: "req_local_idle",
      locallyAwaitingReply: true,
      pending: [],
    });
    expect(
      toConversationProjection(channel.getSnapshot(), {
        groupId: "grp_1",
        workspaceId: "wsp_1",
      })
    ).toMatchObject({
      awaitingReply: true,
      awaitingTurnKey: "req_local_idle",
      locallyAwaitingReply: true,
    });
    expect(observedAwaitingStates.every(Boolean)).toBe(true);

    api.emit(
      0,
      draftEvent("message_draft_started", {
        draft_id: "draft_local_idle",
        source_message_ids: ["msg_local_idle_user"],
        text: "Streaming",
      }),
      "message_draft_started"
    );
    expect(channel.getSnapshot()).toMatchObject({
      assistantDraft: {
        draftId: "draft_local_idle",
        text: "Streaming",
      },
      locallyAwaitingReply: false,
    });

    api.emit(
      0,
      {
        type: "snapshot",
        activity_status: "idle",
        messages: [
          message(
            "msg_local_idle_user",
            "user",
            "keep the activity surface continuous",
            "req_local_idle"
          ),
          message("msg_local_idle_reply", "assistant", "Streaming complete"),
        ],
        status: "waiting",
      } as CommaConversationEvent,
      "snapshot"
    );

    expect(channel.getSnapshot()).toMatchObject({
      assistantDraft: undefined,
      awaitingReply: false,
      awaitingTimedOut: false,
      locallyAwaitingReply: false,
    });
  });

  it.each(["stopped", "error"] as const)(
    "keeps immediate local feedback when an old %s Participant snapshot replays",
    async (state) => {
      const api = createConversationApi();
      const channel = createChannel(api);
      channel.start();
      api.emit(0, { type: "snapshot", messages: [] }, "snapshot");
      const status = {
        type: "participant_status",
        conversation_id: "cnv_1",
        participant_id: "ptp_1",
        state,
        status: state === "error" ? "previous turn failed" : "",
        updated_at: 10,
      } as CommaConversationEvent;
      api.emit(0, status, "participant_status");

      const send = channel.send("new question");
      expect(channel.getSnapshot()).toMatchObject({
        locallyAwaitingReply: true,
        awaitingTurnKey: "req_1",
        participantStatus: undefined,
      });
      api.emit(0, status, "participant_status");
      expect(channel.getSnapshot().locallyAwaitingReply).toBe(true);
      api.resolveSend(
        0,
        conversation({ activity_status: "idle" }, [
          message("msg_current", "user", "new question", "req_1"),
        ])
      );
      await send;
      expect(channel.getSnapshot().locallyAwaitingReply).toBe(true);
      channel.stop();
    }
  );

  it.each(["running", "idle", "failed"] as const)(
    "hands local feedback over only to exact-source %s Activity, including a cold-start terminal",
    async (status) => {
      const api = createConversationApi();
      const channel = createChannel(api);
      channel.start();
      api.emit(0, { type: "snapshot", messages: [] }, "snapshot");
      const send = channel.send("new question");
      api.resolveSend(
        0,
        conversation({ activity_status: "idle" }, [
          message("msg_current", "user", "new question", "req_1"),
        ])
      );
      await send;

      api.emit(0, activityEvent({ source_message_ids: ["msg_other"] }), "activity");
      expect(channel.getSnapshot().locallyAwaitingReply).toBe(true);
      api.emit(
        0,
        activityEvent({
          source_message_ids: ["msg_current"],
          status,
          phase: status === "idle" ? "idle" : "thinking",
          action: undefined,
          summary: undefined,
          summary_class: status === "idle" ? "none" : "generic",
          tool_name: undefined,
        }),
        "activity"
      );
      expect(channel.getSnapshot().locallyAwaitingReply).toBe(false);

      api.emit(
        0,
        {
          type: "participant_status",
          conversation_id: "cnv_1",
          participant_id: "ptp_1",
          state: "stopped",
          status: "",
          updated_at: 10,
        } as CommaConversationEvent,
        "participant_status"
      );
      expect(channel.getSnapshot().locallyAwaitingReply).toBe(false);
      channel.stop();
    }
  );

  it("expires local feedback after acknowledgement even when the stream remains silent", async () => {
    vi.useFakeTimers();
    try {
      const api = createConversationApi();
      const channel = createChannel(api, { now: () => Date.now() });
      const send = channel.send("new question");
      api.resolveSend(
        0,
        conversation({ activity_status: "idle" }, [
          message("msg_current", "user", "new question", "req_1"),
        ])
      );
      await send;
      expect(channel.getSnapshot()).toMatchObject({
        locallyAwaitingReply: true,
        pending: [],
      });

      await vi.advanceTimersByTimeAsync(150_000);
      expect(channel.getSnapshot()).toMatchObject({
        awaitingTimedOut: true,
        locallyAwaitingReply: false,
        pending: [],
      });
      expect(api.polls).toHaveLength(0);
      expect(api.streams).toHaveLength(0);
      channel.stop();
    } finally {
      vi.useRealTimers();
    }
  });

  it("gives a retried send a fresh deadline and ignores the retired timer", async () => {
    vi.useFakeTimers();
    try {
      const api = createConversationApi();
      const channel = createChannel(api, { now: () => Date.now() });
      const first = channel.send("try again");
      const firstFailure = expect(first).rejects.toThrow("offline");
      await vi.advanceTimersByTimeAsync(100_000);
      api.rejectSend(0, new Error("offline"));
      await firstFailure;

      const retry = channel.retry("req_1");
      await vi.advanceTimersByTimeAsync(100_000);
      expect(channel.getSnapshot()).toMatchObject({
        locallyAwaitingReply: true,
        awaitingTimedOut: false,
        pending: [{ clientRequestId: "req_1", status: "sending" }],
      });
      api.resolveSend(
        1,
        conversation({ activity_status: "idle" }, [
          message("msg_retried", "user", "try again", "req_1"),
        ])
      );
      await retry;
      await vi.advanceTimersByTimeAsync(50_000);
      expect(channel.getSnapshot()).toMatchObject({
        locallyAwaitingReply: false,
        awaitingTimedOut: true,
        pending: [],
      });
      channel.stop();
    } finally {
      vi.useRealTimers();
    }
  });

  it("hands local feedback to the exact draft and keeps its pixels through cancellation", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { requestIds: ["req_local_cancel"] });

    channel.start();
    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");

    const send = channel.send("cancel this exact reply");
    api.resolveSend(
      0,
      conversation({ activity_status: "idle", status: "waiting" }, [
        message(
          "msg_local_cancel_user",
          "user",
          "cancel this exact reply",
          "req_local_cancel"
        ),
      ])
    );
    await send;

    api.emit(
      0,
      draftEvent("message_draft_started", {
        draft_id: "draft_local_cancel",
        source_message_ids: ["msg_local_cancel_user"],
        text: "Partial",
      }),
      "message_draft_started"
    );
    expect(channel.getSnapshot().locallyAwaitingReply).toBe(false);

    api.emit(
      0,
      draftEvent("message_draft_cancelled", {
        draft_id: "draft_local_cancel",
        response_key: responseKey(["msg_local_cancel_user"]),
        source_message_ids: ["msg_unrelated_user"],
        text: "",
      }),
      "message_draft_cancelled"
    );
    expect(channel.getSnapshot()).toMatchObject({
      assistantDraft: { draftId: "draft_local_cancel" },
      locallyAwaitingReply: false,
    });

    api.emit(
      0,
      draftEvent("message_draft_cancelled", {
        draft_id: "draft_local_cancel",
        source_message_ids: ["msg_local_cancel_user"],
        text: "",
      }),
      "message_draft_cancelled"
    );

    expect(channel.getSnapshot()).toMatchObject({
      assistantDraft: { draftId: "draft_local_cancel", text: "Partial" },
      awaitingReply: false,
      awaitingTimedOut: false,
    });
  });

  it("settles a locally accepted send on an exact failed activity terminal", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { requestIds: ["req_local_failure"] });

    channel.start();
    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");

    const send = channel.send("fail this reply");
    api.resolveSend(
      0,
      conversation({ activity_status: "idle", status: "waiting" }, [
        message(
          "msg_local_failure_user",
          "user",
          "fail this reply",
          "req_local_failure"
        ),
      ])
    );
    await send;
    expect(channel.getSnapshot().awaitingReply).toBe(true);

    api.emit(
      0,
      activityEvent({
        action: undefined,
        phase: "thinking",
        source_message_ids: ["msg_local_failure_user"],
        status: "failed",
        summary: undefined,
        summary_class: "generic",
        tool_name: undefined,
      }),
      "activity"
    );

    expect(channel.getSnapshot()).toMatchObject({
      activity: { status: "failed" },
      awaitingReply: false,
      awaitingTimedOut: false,
    });
  });

  it("turns a send with no acknowledgement into a retryable failure", () => {
    let now = 10_000;
    const api = createConversationApi();
    const channel = createChannel(api, { now: () => now });

    void channel.send("hello");
    expect(channel.getSnapshot()).toMatchObject({
      awaitingReply: true,
      pending: [{ clientRequestId: "req_1", status: "sending" }],
    });

    now += 151_000;
    channel.refreshDerivedState();

    expect(channel.getSnapshot()).toMatchObject({
      awaitingReply: false,
      pending: [{ clientRequestId: "req_1", status: "failed" }],
    });
  });

  it("marks long awaiting replies as timed out after 150 seconds", async () => {
    let now = 10_000;
    const api = createConversationApi();
    const channel = createChannel(api, { now: () => now });

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        status: "waiting",
        messages: [message("msg_1", "user", "question")],
      },
      "snapshot"
    );

    expect(channel.getSnapshot()).toMatchObject({
      awaitingReply: true,
      awaitingTimedOut: false,
    });

    now += 151_000;
    channel.refreshDerivedState();

    expect(channel.getSnapshot()).toMatchObject({
      awaitingReply: true,
      awaitingTimedOut: true,
    });
  });

  it("keeps the previous non-empty snapshot when a later snapshot suspiciously clears messages", async () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [message("msg_1", "assistant", "saved answer")],
      },
      "snapshot"
    );
    const firstMessages = channel.getSnapshot().messages;

    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");

    expect(channel.getSnapshot().messages).toBe(firstMessages);
    expect(channel.getSnapshot()).toMatchObject({
      syncWarning: "suspect-empty",
    });
  });

  it("merges a non-empty tail snapshot into the complete canonical history", () => {
    const api = createConversationApi();
    const channel = createChannel(api);
    const first = message("msg_1", "user", "first");
    const second = message("msg_2", "assistant", "second");
    const third = message("msg_3", "assistant", "third");

    channel.start();
    api.emit(0, { type: "snapshot", messages: [first, second] }, "snapshot");
    api.emit(0, { type: "snapshot", messages: [second, third] }, "snapshot");

    expect(channel.getSnapshot().serverMessages.map((item) => item.messageId)).toEqual([
      "msg_1",
      "msg_2",
      "msg_3",
    ]);
    expect(channel.getSnapshot().messages.map((item) => item.text)).toEqual([
      "first",
      "second",
      "third",
    ]);
  });

  it.each(["failed", "cancelled"])(
    "keeps append-only task history when a %s snapshot is unexpectedly empty",
    async (status) => {
      const api = createConversationApi();
      const channel = createChannel(api, { initialKind: "agent_task" });

      channel.start();
      api.resolvePoll(0, {
        conversation: conversation({ kind: "agent_task", status }, [
          message("msg_terminal_history", "assistant", "saved terminal history"),
        ]),
        etag: '"terminal-history-1"',
        notModified: false,
      });
      await flushMicrotasks();
      const firstMessages = channel.getSnapshot().messages;

      channel.refresh();
      await flushMicrotasks();
      expect(api.polls).toHaveLength(2);
      api.resolvePoll(1, {
        conversation: conversation({ kind: "agent_task", status }, []),
        etag: '"terminal-history-2"',
        notModified: false,
      });
      await flushMicrotasks();

      expect(channel.getSnapshot().messages).toBe(firstMessages);
      expect(channel.getSnapshot()).toMatchObject({
        syncWarning: "suspect-empty",
      });
    }
  );

  it("stores conversation activity frames, ignores other conversations, and clears on idle or TTL", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");
    api.emit(
      0,
      activityEvent({
        conversation_id: "other-conversation",
        summary: "This should not render",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toBeUndefined();

    api.emit(
      0,
      activityEvent({
        action: "Running tests",
        conversation_id: "cnv_1",
        producer_epoch: "epoch-a",
        summary: "Checking the workspace",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toMatchObject({
      action: "Running tests",
      conversationId: "cnv_1",
      producerEpoch: "epoch-a",
      status: "running",
      summary: "Checking the workspace",
    });

    await vi.advanceTimersByTimeAsync(149_000);
    expect(channel.getSnapshot().activity?.summary).toBe("Checking the workspace");

    await vi.advanceTimersByTimeAsync(1_000);
    expect(channel.getSnapshot().activity).toBeUndefined();

    api.emit(
      0,
      activityEvent({
        conversation_id: "cnv_1",
        status: "running",
        summary: "One more thing",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity?.summary).toBe("One more thing");

    api.emit(
      0,
      activityEvent({
        action: undefined,
        conversation_id: "cnv_1",
        phase: "idle",
        status: "idle",
        summary: undefined,
        summary_class: "none",
        tool_name: undefined,
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toBeUndefined();
    vi.useRealTimers();
  });

  it("gates Activity v2 on snapshot and rejects stale, duplicate, and stale idle frames", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      activityEvent({ sequence: 42, summary: "Before snapshot" }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toBeUndefined();

    api.emit(
      0,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    api.emit(
      0,
      activityEvent({ sequence: 42, summary: "Latest public summary" }),
      "activity"
    );
    const latest = channel.getSnapshot().activity;
    expect(latest).toMatchObject({
      ownerTurnKey: "msg_user",
      sequence: 42,
      summary: "Latest public summary",
    });

    api.emit(
      0,
      activityEvent({ sequence: 42, summary: "Conflicting duplicate" }),
      "activity"
    );
    api.emit(
      0,
      activityEvent({ sequence: 41, summary: "Delayed old summary" }),
      "activity"
    );
    api.emit(
      0,
      activityEvent({
        action: undefined,
        phase: "idle",
        sequence: 41,
        status: "idle",
        summary: undefined,
        summary_class: "none",
        tool_name: undefined,
      }),
      "activity"
    );

    expect(channel.getSnapshot().activity).toBe(latest);
  });

  it("rejects missing or invalid summary authority before advancing the producer cursor", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    api.emit(
      0,
      activityEvent({
        sequence: 50,
        summary: "Missing authority",
        summary_class: undefined,
      }),
      "activity"
    );
    api.emit(
      0,
      activityEvent({
        sequence: 51,
        summary: "Private authority is not public wire data",
        summary_class: "private" as never,
      }),
      "activity"
    );
    api.emit(
      0,
      activityEvent({
        sequence: 52,
        summary: "Unknown authority must fail closed",
        summary_class: "future" as never,
      }),
      "activity"
    );
    for (const contradictory of [
      { phase: "thinking", summary_class: "none" },
      { phase: "execution", summary_class: "generic" },
      { phase: "messaging", summary_class: "public" },
      { phase: "thinking", status: "failed", summary_class: "public" },
      { phase: "thinking", summary: " ", summary_class: "public" },
      { goal: "x".repeat(513), phase: "thinking", summary_class: "public" },
    ]) {
      api.emit(
        0,
        activityEvent({
          ...contradictory,
          sequence: 52,
        } as never),
        "activity"
      );
    }
    expect(channel.getSnapshot().activity).toBeUndefined();

    api.emit(
      0,
      activityEvent({
        sequence: 50,
        summary: "Authorized public summary",
        summary_class: "public",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toMatchObject({
      sequence: 50,
      summary: "Authorized public summary",
      summaryClass: "public",
    });
  });

  it("canonicalizes generic product copy and strips non-public payload", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    api.emit(
      0,
      activityEvent({
        action: "PRIVATE_GENERIC_ACTION",
        phase: "thinking",
        sequence: 60,
        summary: "PRIVATE_GENERIC_SUMMARY",
        summary_class: "generic",
        tool_name: "private.tool",
      }),
      "activity"
    );

    expect(channel.getSnapshot().activity).toMatchObject({
      action: "Thinking",
      phase: "thinking",
      summary: "Thinking",
      summaryClass: "generic",
    });
    expect(channel.getSnapshot().activity?.toolName).toBeUndefined();

    api.emit(
      0,
      activityEvent({
        action: "PRIVATE_NONE_ACTION",
        phase: "idle",
        sequence: 61,
        status: "idle",
        summary: "PRIVATE_NONE_SUMMARY",
        summary_class: "none",
        tool_name: "private.tool",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toBeUndefined();
  });

  it("bounds public Activity prose by Unicode code points before its cursor", () => {
    const api = createConversationApi();
    const channel = createChannel(api);
    const emojiBoundary = "😀".repeat(512);
    const combiningMarkBoundary = "e\u0301".repeat(256);

    channel.start();
    api.emit(
      0,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    api.emit(0, activityEvent({ sequence: 70, summary: emojiBoundary }), "activity");
    expect(channel.getSnapshot().activity?.summary).toBe(emojiBoundary);

    api.emit(
      0,
      activityEvent({ sequence: 71, summary: combiningMarkBoundary }),
      "activity"
    );
    expect(channel.getSnapshot().activity?.summary).toBe(combiningMarkBoundary);

    api.emit(0, activityEvent({ sequence: 74, summary: "😀".repeat(513) }), "activity");
    api.emit(
      0,
      activityEvent({ sequence: 73, summary: "e\u0301".repeat(257) }),
      "activity"
    );
    api.emit(0, activityEvent({ sequence: 72, summary: "Still accepted" }), "activity");
    expect(channel.getSnapshot().activity).toMatchObject({
      sequence: 72,
      summary: "Still accepted",
    });
  });

  it("authorizes an Activity producer epoch cutover only through a new SSE incarnation", async () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    api.emit(
      0,
      activityEvent({ producer_epoch: "epoch-a", sequence: 100 }),
      "activity"
    );
    const epochA = channel.getSnapshot().activity;

    api.emit(
      0,
      activityEvent({ producer_epoch: "epoch-b", sequence: 1, status: "failed" }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toBe(epochA);
    await flushMicrotasks();
    expect(api.streams).toHaveLength(2);

    api.emit(
      1,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    api.emit(
      1,
      activityEvent({
        producer_epoch: "epoch-b",
        sequence: 1,
        status: "failed",
        summary: "New producer failed",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toMatchObject({
      producerEpoch: "epoch-b",
      sequence: 1,
      status: "failed",
      summary: "New producer failed",
    });
    api.emit(
      1,
      activityEvent({
        producer_epoch: "epoch-a",
        sequence: 101,
        summary: "Delayed retired producer",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity?.summary).toBe("New producer failed");
  });

  it("keeps the Activity producer watermark across a reconnect", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    api.emit(
      0,
      activityEvent({ producer_epoch: "epoch-a", sequence: 100 }),
      "activity"
    );
    expect(channel.getSnapshot().activity?.sequence).toBe(100);

    api.resolveStream(0);
    await vi.advanceTimersByTimeAsync(30_000);
    const streamIndex = api.streams.length - 1;
    expect(streamIndex).toBeGreaterThan(0);
    api.emit(
      streamIndex,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );

    // A stale replay of the same epoch must not re-establish a lower
    // baseline just because it is the first frame after the reconnect.
    api.emit(
      streamIndex,
      activityEvent({
        producer_epoch: "epoch-a",
        sequence: 40,
        summary: "Stale replay",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity?.summary).not.toBe("Stale replay");

    // The same producer continuing past the watermark still applies.
    api.emit(
      streamIndex,
      activityEvent({
        producer_epoch: "epoch-a",
        sequence: 101,
        summary: "Fresh frame",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toMatchObject({
      sequence: 101,
      summary: "Fresh frame",
    });
  });

  it("re-accepts the watermark frame itself after a reconnect", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    api.emit(
      0,
      activityEvent({
        producer_epoch: "epoch-a",
        sequence: 100,
        summary: "Long-running work",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity?.sequence).toBe(100);

    // The local TTL clears the presentation while the producer still
    // considers this frame current.
    await vi.advanceTimersByTimeAsync(150_000);
    expect(channel.getSnapshot().activity).toBeUndefined();

    api.resolveStream(0);
    await vi.advanceTimersByTimeAsync(30_000);
    const streamIndex = api.streams.length - 1;
    expect(streamIndex).toBeGreaterThan(0);
    api.emit(
      streamIndex,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );

    // The snapshot-gated reconnect replays the still-valid frame at the
    // watermark: it must repaint instead of leaving the surface empty.
    api.emit(
      streamIndex,
      activityEvent({
        producer_epoch: "epoch-a",
        sequence: 100,
        summary: "Long-running work",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toMatchObject({
      sequence: 100,
      summary: "Long-running work",
    });

    // A second equal-sequence frame inside the same incarnation is a plain
    // duplicate and stays rejected.
    api.emit(
      streamIndex,
      activityEvent({
        producer_epoch: "epoch-a",
        sequence: 100,
        summary: "Duplicate frame",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity?.summary).toBe("Long-running work");
  });

  it("does not let a rejected lower frame consume reconnect baseline admission", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    api.emit(
      0,
      activityEvent({
        producer_epoch: "epoch-a",
        sequence: 100,
        summary: "Before reconnect",
      }),
      "activity"
    );

    api.resolveStream(0);
    await vi.advanceTimersByTimeAsync(30_000);
    const streamIndex = api.streams.length - 1;
    api.emit(
      streamIndex,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );

    // Admission is commit-on-accept. This delayed lower callback is a no-op
    // and must not mark the new incarnation as having consumed its baseline.
    api.emit(
      streamIndex,
      activityEvent({
        producer_epoch: "epoch-a",
        sequence: 40,
        summary: "Rejected lower baseline",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity?.summary).toBe("Before reconnect");

    // The still-current equal watermark remains the first admitted frame and
    // must reconcile exactly once in this incarnation.
    api.emit(
      streamIndex,
      activityEvent({
        producer_epoch: "epoch-a",
        sequence: 100,
        summary: "Equal baseline restored",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toMatchObject({
      sequence: 100,
      summary: "Equal baseline restored",
    });
  });

  it("settles an equal failed reconnect baseline only for its current source", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api, { requestIds: ["req_D2"] });
    const d1 = message("msg_D1_user", "user", "Start D1");

    channel.start();
    api.emit(0, { type: "snapshot", messages: [d1] }, "snapshot");
    api.emit(
      0,
      activityEvent({
        action: undefined,
        phase: "thinking",
        producer_epoch: "epoch-a",
        response_key: "rsp-D1",
        sequence: 100,
        source_message_ids: [d1.message_id],
        status: "failed",
        summary: undefined,
        summary_class: "generic",
        tool_name: undefined,
      }),
      "activity"
    );
    expect(channel.getSnapshot().awaitingReply).toBe(false);

    const d2Send = channel.send("Start D2");
    const d2 = message("msg_D2_user", "user", "Start D2", "req_D2");
    api.resolveSend(
      0,
      conversation({ activity_status: "thinking", status: "waiting" }, [d1, d2])
    );
    await d2Send;
    expect(channel.getSnapshot()).toMatchObject({
      activity: undefined,
      awaitingReply: true,
    });

    api.resolveStream(0);
    await vi.advanceTimersByTimeAsync(30_000);
    const streamIndex = api.streams.length - 1;
    api.emit(streamIndex, { type: "snapshot", messages: [d1, d2] }, "snapshot");

    // The first lower callback stays rejected without consuming admission.
    api.emit(
      streamIndex,
      activityEvent({
        action: undefined,
        phase: "thinking",
        producer_epoch: "epoch-a",
        response_key: "rsp-D1",
        sequence: 40,
        source_message_ids: [d1.message_id],
        status: "failed",
        summary: undefined,
        summary_class: "generic",
        tool_name: undefined,
      }),
      "activity"
    );
    expect(channel.getSnapshot()).toMatchObject({
      activity: undefined,
      awaitingReply: true,
    });

    // Replaying D1's accepted equal failure may rehydrate D1's terminal
    // surface, but its exact source binding must not settle current D2.
    api.emit(
      streamIndex,
      activityEvent({
        action: undefined,
        phase: "thinking",
        producer_epoch: "epoch-a",
        response_key: "rsp-D1",
        sequence: 100,
        source_message_ids: [d1.message_id],
        status: "failed",
        summary: undefined,
        summary_class: "generic",
        tool_name: undefined,
      }),
      "activity"
    );
    expect(channel.getSnapshot()).toMatchObject({
      activity: { responseKey: "rsp-D1", sequence: 100, status: "failed" },
      awaitingReply: true,
      awaitingTimedOut: false,
    });
  });

  it("rejects a retired Activity producer epoch after any later reconnect", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    api.emit(
      0,
      activityEvent({ producer_epoch: "epoch-a", sequence: 100 }),
      "activity"
    );

    // Mid-stream epoch change forces the snapshot-first restart...
    api.emit(0, activityEvent({ producer_epoch: "epoch-b", sequence: 5 }), "activity");
    await flushMicrotasks();
    api.emit(
      1,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );
    // ...and the new incarnation turns the cursor over to epoch-b.
    api.emit(1, activityEvent({ producer_epoch: "epoch-b", sequence: 5 }), "activity");
    expect(channel.getSnapshot().activity?.producerEpoch).toBe("epoch-b");

    api.resolveStream(1);
    await vi.advanceTimersByTimeAsync(30_000);
    const streamIndex = api.streams.length - 1;
    expect(streamIndex).toBeGreaterThan(1);
    api.emit(
      streamIndex,
      { type: "snapshot", messages: [message("msg_user", "user", "hello")] },
      "snapshot"
    );

    // The retired epoch cannot come back as a new baseline, not even as the
    // first frame of a fresh incarnation with a high sequence.
    api.emit(
      streamIndex,
      activityEvent({
        producer_epoch: "epoch-a",
        sequence: 200,
        summary: "Retired epoch comeback",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity?.summary).not.toBe("Retired epoch comeback");

    // The live epoch keeps flowing.
    api.emit(
      streamIndex,
      activityEvent({
        producer_epoch: "epoch-b",
        sequence: 6,
        summary: "Live epoch continues",
      }),
      "activity"
    );
    expect(channel.getSnapshot().activity).toMatchObject({
      producerEpoch: "epoch-b",
      sequence: 6,
      summary: "Live epoch continues",
    });
  });

  it("settles a turn on model failure and preserves the failure through terminal idle", () => {
    const api = createConversationApi();
    const channel = createChannel(api, { requestIds: ["req_after_failure"] });

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        status: "waiting",
        messages: [message("msg_user", "user", "hello")],
      },
      "snapshot"
    );
    expect(channel.getSnapshot().awaitingReply).toBe(true);

    api.emit(
      0,
      activityEvent({
        action: "PRIVATE_FAILURE_ACTION",
        phase: "thinking",
        status: "failed",
        summary: "PRIVATE_FAILURE_SUMMARY",
        summary_class: "generic",
        tool_name: "private.tool",
      }),
      "activity"
    );
    expect(channel.getSnapshot()).toMatchObject({
      activity: { status: "failed", summaryClass: "generic" },
      awaitingReply: false,
      awaitingTimedOut: false,
    });
    expect(channel.getSnapshot().activity?.action).toBeUndefined();
    expect(channel.getSnapshot().activity?.summary).toBeUndefined();
    expect(channel.getSnapshot().activity?.toolName).toBeUndefined();

    api.emit(
      0,
      activityEvent({
        action: undefined,
        phase: "idle",
        status: "idle",
        summary: undefined,
        summary_class: "none",
        tool_name: undefined,
      }),
      "activity"
    );
    expect(channel.getSnapshot()).toMatchObject({
      activity: { status: "failed" },
      awaitingReply: false,
    });

    void channel.send("try again");
    expect(channel.getSnapshot().activity).toBeUndefined();
    expect(channel.getSnapshot().awaitingReply).toBe(true);
  });

  it("atomically settles participant activity with the canonical reply after invalidation", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        activity_status: "thinking",
        messages: [message("msg_user", "user", "hello")],
      } as CommaConversationEvent,
      "snapshot"
    );
    api.emit(
      0,
      activityEvent({
        conversation_id: "cnv_1",
        phase: "thinking",
        status: "running",
        summary: "Thinking",
      }),
      "activity"
    );
    api.emit(
      0,
      {
        type: "participant_status",
        conversation_id: "cnv_1",
        participant_id: "ptp_1",
        state: "active",
        status: "is waiting: async tool call still running",
        updated_at: 1,
      },
      "participant_status"
    );
    api.emit(
      0,
      draftEvent("message_draft_started", {
        draft_id: "draft_final",
        source_message_ids: ["msg_user"],
        text: "Final answer",
      }),
      "message_draft_started"
    );

    expect(channel.getSnapshot()).toMatchObject({
      activity: { phase: "thinking", status: "running" },
      assistantDraft: { draftId: "draft_final", text: "Final answer" },
      awaitingReply: true,
    });

    api.emit(
      0,
      {
        type: "conversation_invalidated",
        conversation_id: "cnv_1",
      } as CommaConversationEvent,
      "conversation_invalidated"
    );
    await flushMicrotasks();

    expect(api.streams).toHaveLength(2);
    const replyPublications: Array<string | undefined> = [];
    channel.subscribe(() => {
      const snapshot = channel.getSnapshot();
      if (snapshot.messages.some((item) => item.messageId === "msg_final")) {
        replyPublications.push(snapshot.participantStatus?.state);
      }
    });
    api.emit(
      1,
      {
        type: "snapshot",
        activity_status: "idle",
        messages: [
          message("msg_user", "user", "hello"),
          message("msg_final", "assistant", "Final answer"),
        ],
        participant_status: {
          conversation_id: "cnv_1",
          participant_id: "ptp_1",
          state: "stopped",
          status: "",
          updated_at: 2,
        },
      } as CommaConversationEvent,
      "snapshot"
    );

    expect(channel.getSnapshot()).toMatchObject({
      activity: undefined,
      assistantDraft: undefined,
      awaitingReply: false,
      awaitingTimedOut: false,
      participantStatus: { state: "stopped" },
    });
    expect(replyPublications).toEqual(["stopped"]);
    expect(channel.getSnapshot().messages.at(-1)).toMatchObject({
      messageId: "msg_final",
      role: "assistant",
      text: "Final answer",
    });

    await vi.advanceTimersByTimeAsync(150_000);
    expect(channel.getSnapshot().activity).toBeUndefined();

    const nextSend = channel.send("Next question");
    expect(channel.getSnapshot().locallyAwaitingReply).toBe(true);
    api.resolveSend(
      0,
      conversation({ activity_status: "idle" }, [
        message("msg_user", "user", "hello"),
        message("msg_final", "assistant", "Final answer"),
        message("msg_next", "user", "Next question", "req_1"),
      ])
    );
    await nextSend;
    api.emit(
      1,
      {
        type: "snapshot",
        participant_status: {
          conversation_id: "cnv_1",
          participant_id: "ptp_1",
          state: "active",
          status: "is thinking...",
          updated_at: 3,
        },
      },
      "snapshot"
    );
    expect(channel.getSnapshot()).toMatchObject({
      locallyAwaitingReply: true,
      participantStatus: { state: "active" },
    });
    channel.stop();
    vi.useRealTimers();
  });

  it("publishes one complete reconnect snapshot instead of clearing and replaying the draft", async () => {
    const api = createConversationApi();
    const channel = createChannel(api);
    channel.start();
    const user = message("msg_user", "user", "Continue");
    api.emit(
      0,
      { type: "snapshot", messages: [user], participant_draft: null },
      "snapshot"
    );
    const draft = {
      conversation_id: "cnv_1",
      draft_id: "draft_continuous",
      response_key: "rsp_continuous",
      source_message_ids: ["msg_user"],
      revision: 1,
      text: "Visible prefix",
    };
    api.emit(0, draftEvent("message_draft_started", draft), "message_draft_started");
    api.emit(0, { type: "conversation_invalidated" }, "conversation_invalidated");
    await flushMicrotasks();
    expect(api.streams).toHaveLength(2);
    const observed: Array<string | undefined> = [];
    const unsubscribe = channel.subscribe(() =>
      observed.push(channel.getSnapshot().assistantDraft?.text)
    );
    api.emit(
      1,
      {
        type: "snapshot",
        messages: [user],
        participant_draft: { ...draft, revision: 2, text: "Visible prefix continues" },
      },
      "snapshot"
    );
    expect(observed).toEqual(["Visible prefix continues"]);
    api.emit(
      0,
      { type: "snapshot", messages: [user], participant_draft: null },
      "snapshot"
    );
    expect(channel.getSnapshot().assistantDraft?.text).toBe("Visible prefix continues");
    api.emit(
      1,
      {
        type: "snapshot",
        messages: [user, message("msg_final", "assistant", "Final answer")],
        participant_draft: null,
      },
      "snapshot"
    );
    expect(channel.getSnapshot().assistantDraft).toBeUndefined();
    api.emit(
      1,
      draftEvent("message_draft_started", {
        ...draft,
        draft_id: "draft_next_send",
        text: "Another send in this activation",
      }),
      "message_draft_started"
    );
    expect(channel.getSnapshot().assistantDraft?.text).toBe(
      "Another send in this activation"
    );
    unsubscribe();
    channel.stop();
  });

  it("ignores a foreign Participant draft without losing its canonical snapshot", () => {
    const api = createConversationApi();
    const channel = createChannel(api);
    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [message("msg_user", "user", "My message")],
        participant_draft: {
          conversation_id: "cnv_foreign",
          draft_id: "draft_foreign",
          response_key: "rsp_foreign",
          source_message_ids: ["msg_user"],
          revision: 1,
          text: "Not this conversation",
        },
      },
      "snapshot"
    );
    expect(channel.getSnapshot().messages[0]?.text).toBe("My message");
    expect(channel.getSnapshot().assistantDraft).toBeUndefined();
    channel.stop();
  });

  it("detects stream wait support, requests long-poll windows, and holds drafts on reconnect", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    expect(api.streams[0]?.waitMs).toBeUndefined();

    api.emit(
      0,
      {
        type: "snapshot",
        messages: [],
        stream: { drafts: true, window_ms: 30_000 },
      } as CommaConversationEvent,
      "snapshot"
    );
    api.emit(
      0,
      draftEvent("message_draft_started", { draft_id: "draft_1", text: "Hel" }),
      "message_draft_started"
    );

    expect(assistantDraft(channel)).toEqual({
      conversationId: "cnv_1",
      draftId: "draft_1",
      text: "Hel",
    });

    api.rejectStream(0, new Error("network"));
    await flushMicrotasks();

    expect(assistantDraft(channel)).toEqual({
      conversationId: "cnv_1",
      draftId: "draft_1",
      text: "Hel",
    });
    expect(channel.getSnapshot().connection).toBe("reconnecting");

    await vi.advanceTimersByTimeAsync(1_000);

    expect(api.streams).toHaveLength(2);
    expect(api.streams[1]?.waitMs).toBe(30_000);
    vi.useRealTimers();
  });

  it("fences aborted stream callbacks and waits for each incarnation snapshot", async () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");
    api.emit(
      0,
      draftEvent("message_draft_started", {
        draft_id: "draft_old",
        response_key: "rsp_old",
        source_message_ids: ["msg_old"],
        text: "Old visible text",
      }),
      "message_draft_started"
    );

    api.emit(
      0,
      { type: "conversation_invalidated" } as CommaConversationEvent,
      "conversation_invalidated"
    );
    await flushMicrotasks();
    expect(api.streams).toHaveLength(2);

    api.emit(
      0,
      draftEvent("message_draft_started", {
        response_key: "rsp_late_old_callback",
        source_message_ids: ["msg_late"],
        text: "Must not render",
      }),
      "message_draft_started"
    );
    api.emit(
      1,
      draftEvent("message_draft_started", {
        response_key: "rsp_before_snapshot",
        source_message_ids: ["msg_before_snapshot"],
        text: "Must also not render",
      }),
      "message_draft_started"
    );
    expect(assistantDraft(channel)?.text).toBe("Old visible text");

    api.emit(1, { type: "snapshot", messages: [] }, "snapshot");
    api.emit(
      1,
      draftEvent("message_draft_started", {
        draft_id: "draft_new",
        response_key: "rsp_new",
        source_message_ids: ["msg_new"],
        text: "New visible text",
      }),
      "message_draft_started"
    );
    expect(channel.getSnapshot().assistantDraft).toMatchObject({
      responseKey: "rsp_new",
      text: "New visible text",
    });
  });

  it("projects continuous draft revision deltas across the chat bridge state", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");
    api.emit(
      0,
      draftEvent("message_draft_started", {
        revision: 0,
        text: "Hel",
      }),
      "message_draft_started"
    );
    api.emit(
      0,
      draftEvent("message_draft_delta", {
        delta: "lo",
        revision: 1,
        text: "Hello",
      }),
      "message_draft_delta"
    );

    expect(channel.getSnapshot().assistantDraft).toMatchObject({
      revision: 1,
      text: "Hello",
    });
    expect(
      toConversationProjection(channel.getSnapshot(), {
        groupId: "grp_1",
        workspaceId: "wsp_1",
      }).assistantDraft
    ).toMatchObject({
      revision: 1,
      text: "Hello",
    });
  });

  it("rejects source-less drafts instead of assigning them to the latest turn", async () => {
    const api = createConversationApi();
    const channel = createChannel(api, { requestIds: ["req_D2"] });

    channel.start();
    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");
    api.emit(
      0,
      draftEvent("message_draft_started", {
        draft_id: "draft_D1",
        source_message_ids: [],
        text: "old source-less draft",
      }),
      "message_draft_started"
    );
    expect(channel.getSnapshot().assistantDraft).toBeUndefined();

    void channel.send("Start D2");
    api.emit(
      0,
      draftEvent("message_draft_delta", {
        draft_id: "draft_D1",
        source_message_ids: [],
        text: "late old source-less draft",
      }),
      "message_draft_delta"
    );
    expect(channel.getSnapshot().assistantDraft).toBeUndefined();

    api.emit(
      0,
      draftEvent("message_draft_started", {
        draft_id: "draft_D2",
        source_message_ids: [],
        text: "fresh source-less draft",
      }),
      "message_draft_started"
    );
    expect(channel.getSnapshot().assistantDraft).toBeUndefined();

    api.emit(
      0,
      draftEvent("message_draft_completed", {
        draft_id: "draft_D2",
        source_message_ids: [],
        text: "fresh source-less draft",
      }),
      "message_draft_completed"
    );
    api.emit(
      0,
      {
        type: "message_created",
        conversation_id: "cnv_1",
        message_id: "msg_D2_final",
        role: "assistant",
      } as CommaConversationEvent,
      "message_created"
    );
    await flushMicrotasks();
    expect(api.streams).toHaveLength(2);
    api.emit(
      1,
      {
        type: "snapshot",
        messages: [message("msg_D2_final", "assistant", "D2 final")],
      },
      "snapshot"
    );
    expect(channel.getSnapshot().messages).toContainEqual(
      expect.objectContaining({
        messageId: "msg_D2_final",
        role: "assistant",
      })
    );
  });

  it("tracks cumulative frames, holds completion, cancels immediately, and atomically hands off on snapshots", async () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [],
        stream: { drafts: true, window_ms: 30_000 },
      } as CommaConversationEvent,
      "snapshot"
    );
    api.emit(
      0,
      draftEvent("message_draft_started", { draft_id: "draft_1", text: "Hel" }),
      "message_draft_started"
    );
    api.emit(
      0,
      draftEvent("message_draft_delta", {
        conversation_id: "other-conversation",
        draft_id: "draft_other",
        text: "Wrong draft",
      }),
      "message_draft_delta"
    );
    expect(assistantDraft(channel)?.text).toBe("Hel");

    api.emit(
      0,
      draftEvent("message_draft_delta", { draft_id: "draft_1", text: "Hello" }),
      "message_draft_delta"
    );
    expect(assistantDraft(channel)).toEqual({
      conversationId: "cnv_1",
      draftId: "draft_1",
      text: "Hello",
    });

    api.emit(
      0,
      draftEvent("message_draft_completed", {
        draft_id: "draft_1",
        text: "Hello",
      }),
      "message_draft_completed"
    );
    expect(channel.getSnapshot().assistantDraft).toMatchObject({
      responseKey: "rsp:msg_user",
      status: "completed",
      text: "Hello",
    });

    api.emit(
      0,
      { type: "conversation_invalidated" } as CommaConversationEvent,
      "conversation_invalidated"
    );
    expect(assistantDraft(channel)?.text).toBe("Hello");
    await flushMicrotasks();
    expect(api.streams).toHaveLength(2);

    api.emit(
      1,
      {
        type: "snapshot",
        messages: [
          message("msg_user", "user", "Prompt"),
          message("msg_final", "assistant", "Hello"),
        ],
      },
      "snapshot"
    );
    expect(assistantDraft(channel)).toBeUndefined();

    api.emit(
      1,
      draftEvent("message_draft_delta", {
        draft_id: "draft_late_duplicate",
        text: "Hello again",
      }),
      "message_draft_delta"
    );
    expect(assistantDraft(channel)).toBeUndefined();

    api.emit(
      1,
      draftEvent("message_draft_started", {
        draft_id: "draft_2",
        response_key: "rsp:msg_cancel",
        source_message_ids: ["msg_cancel"],
        text: "Partial",
      }),
      "message_draft_started"
    );
    api.emit(
      1,
      draftEvent("message_draft_cancelled", {
        draft_id: "draft_2",
        response_key: "rsp:msg_cancel",
        source_message_ids: ["msg_cancel"],
        status: "cancelled",
        text: "Partial",
      }),
      "message_draft_cancelled"
    );
    expect(assistantDraft(channel)).toMatchObject({
      conversationId: "cnv_1",
      draftId: "draft_2",
      text: "Partial",
    });
    await flushMicrotasks();
    expect(api.streams).toHaveLength(3);

    api.emit(2, { type: "snapshot", messages: [] }, "snapshot");
    api.emit(
      2,
      draftEvent("message_draft_started", {
        draft_id: "draft_2_replayed",
        response_key: "rsp:msg_cancel",
        source_message_ids: ["msg_cancel"],
        text: "Late replay",
      }),
      "message_draft_started"
    );
    expect(assistantDraft(channel)).toBeUndefined();

    api.emit(
      2,
      draftEvent("message_draft_started", {
        draft_id: "draft_3",
        response_key: "rsp:msg_fresh",
        source_message_ids: ["msg_fresh"],
        text: "Fresh",
      }),
      "message_draft_started"
    );
    expect(assistantDraft(channel)?.text).toBe("Fresh");
  });

  it("reopens a held stream when Salix invalidates the Chat so the canonical snapshot is fetched immediately", async () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.emit(
      0,
      {
        type: "snapshot",
        messages: [],
        stream: { drafts: true, window_ms: 30_000 },
      } as CommaConversationEvent,
      "snapshot"
    );
    api.emit(
      0,
      draftEvent("message_draft_started", {
        draft_id: "draft_commit",
        text: "Done",
      }),
      "message_draft_started"
    );

    api.emit(
      0,
      { type: "conversation_invalidated" } as CommaConversationEvent,
      "conversation_invalidated"
    );
    await flushMicrotasks();

    expect(assistantDraft(channel)?.text).toBe("Done");
    expect(api.streams).toHaveLength(2);

    api.emit(
      1,
      {
        type: "snapshot",
        messages: [
          message("msg_user", "user", "Prompt"),
          message("asst_1", "assistant", "Done"),
        ],
        title: "Titled from snapshot",
      } as CommaConversationEvent,
      "snapshot"
    );

    expect(channel.getSnapshot().conversation?.title).toBe("Titled from snapshot");
    expect(channel.getSnapshot().assistantDraft).toBeUndefined();
    expect(channel.getSnapshot().messages.at(-1)).toMatchObject({
      messageId: "asst_1",
      role: "assistant",
      text: "Done",
    });
  });

  it("backs off network failures, caps the delay, resets after a successful stream, and stops on 401", async () => {
    vi.useFakeTimers();
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    api.rejectStream(0, new Error("network"));
    await flushMicrotasks();
    expect(channel.getSnapshot()).toMatchObject({
      connection: "reconnecting",
      lastBackoffMs: 1_000,
    });

    await vi.advanceTimersByTimeAsync(1_000);
    api.rejectStream(1, new Error("network"));
    await flushMicrotasks();
    expect(channel.getSnapshot().lastBackoffMs).toBe(2_000);

    for (let index = 0; index < 5; index += 1) {
      const lastBackoff = channel.getSnapshot().lastBackoffMs ?? 0;
      await vi.advanceTimersByTimeAsync(lastBackoff);
      api.rejectStream(index + 2, new Error("network"));
      await flushMicrotasks();
    }
    expect(channel.getSnapshot().lastBackoffMs).toBe(15_000);

    await vi.advanceTimersByTimeAsync(15_000);
    api.emit(7, { type: "snapshot", messages: [] }, "snapshot");
    api.resolveStream(7);
    await flushMicrotasks();
    expect(channel.getSnapshot()).toMatchObject({
      connection: "live",
      lastBackoffMs: 0,
    });

    await vi.advanceTimersByTimeAsync(3_000);
    api.rejectStream(8, new CommaApiError(401, "unauthorized"));
    await flushMicrotasks();

    expect(channel.getSnapshot()).toMatchObject({
      status: "error",
      errorKind: "unauthorized",
      connection: "paused",
    });
    await vi.advanceTimersByTimeAsync(15_000);
    expect(api.streams).toHaveLength(9);
    vi.useRealTimers();
  });

  it("marks a healthy open stream live as soon as its first canonical frame arrives", () => {
    const api = createConversationApi();
    const channel = createChannel(api);

    channel.start();
    expect(channel.getSnapshot().connection).toBe("connecting");

    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");

    expect(channel.getSnapshot()).toMatchObject({
      connection: "live",
      lastBackoffMs: 0,
    });
  });

  it("does not emit to listeners after unsubscribe", () => {
    const api = createConversationApi();
    const channel = createChannel(api);
    const listener = vi.fn();

    const unsubscribe = channel.subscribe(listener);
    unsubscribe();
    channel.start();
    api.emit(0, { type: "snapshot", messages: [] }, "snapshot");

    expect(listener).not.toHaveBeenCalled();
  });

  it("pauses while hidden and resumes from the injected visibility seam", async () => {
    const api = createConversationApi();
    const visibility = createVisibility(false);
    const channel = createChannel(api, { visibility });

    channel.start();
    expect(channel.getSnapshot().connection).toBe("paused");
    expect(api.streams).toEqual([]);

    visibility.setVisible(true);
    await flushMicrotasks();

    expect(api.streams).toHaveLength(1);
    expect(channel.getSnapshot().connection).toBe("connecting");
  });
});

function createChannel(
  api: ReturnType<typeof createConversationApi>,
  opts: {
    initialKind?: CommaConversationKind;
    getClientDeviceId?: () => string | undefined;
    locale?: CommaLocale;
    now?: () => number;
    onCanonicalMessagesAppended?: ConversationChannelOptions["onCanonicalMessagesAppended"];
    onLocalFilesCommitted?: ConversationChannelOptions["onLocalFilesCommitted"];
    requestIds?: string[];
    transcodeAttachment?: AttachmentTranscoder;
    visibility?: ConversationVisibility;
  } = {}
) {
  const requestIds = [...(opts.requestIds ?? ["req_1", "req_2", "req_3"])];
  return new ConversationChannel({
    api: api.client,
    ...(opts.getClientDeviceId ? { getClientDeviceId: opts.getClientDeviceId } : {}),
    conversationId: "cnv_1",
    groupId: "grp_1",
    initialKind: opts.initialKind ?? "user_chat",
    ...(opts.locale ? { locale: opts.locale } : {}),
    ...(opts.onLocalFilesCommitted
      ? { onLocalFilesCommitted: opts.onLocalFilesCommitted }
      : {}),
    ...(opts.onCanonicalMessagesAppended
      ? { onCanonicalMessagesAppended: opts.onCanonicalMessagesAppended }
      : {}),
    env: {
      now: opts.now ?? (() => Date.now()),
      setTimeout: globalThis.setTimeout.bind(globalThis),
      clearTimeout: globalThis.clearTimeout.bind(globalThis),
      visibility: opts.visibility,
      createClientRequestId: () => requestIds.shift() ?? `req_${requestIds.length}`,
      jitterMs: () => 0,
      transcodeAttachment: opts.transcodeAttachment,
    },
    workspaceId: "wsp_1",
  });
}

function createConversationApi() {
  type TaskStreamCall = {
    onEvent: (event: CommaConversationListEvent) => void;
    resolve: () => void;
    reject: (error: unknown) => void;
  };
  type StreamCall = {
    onEvent: (event: CommaConversationEvent, eventName: string) => void;
    resolve: () => void;
    reject: (error: unknown) => void;
    waitMs: number | undefined;
  };
  type SendCall = {
    text: string;
    clientDeviceId: string | undefined;
    clientRequestId: string | undefined;
    localFiles: Parameters<CommaApiClient["sendMessage"]>[2]["localFiles"];
    skills: { location: string }[] | undefined;
    resolve: (conversation: CommaConversation) => void;
    reject: (error: unknown) => void;
  };
  type PollCall = {
    etag: string | undefined;
    resolve: (result: Awaited<ReturnType<CommaApiClient["pollConversation"]>>) => void;
    reject: (error: unknown) => void;
  };
  type UploadCall = {
    name: string;
    signal: AbortSignal | undefined;
    resolve: (file: { path: string; name: string; size: number }) => void;
    reject: (error: unknown) => void;
  };
  type FetchCall = {
    path: string;
    signal: AbortSignal | undefined;
    resolve: (file: Blob) => void;
    reject: (error: unknown) => void;
  };
  type AgentBlobFetchCall = {
    agentId: string;
    ref: Parameters<CommaApiClient["fetchAgentBlob"]>[2];
    signal: AbortSignal | undefined;
    resolve: (file: Blob) => void;
    reject: (error: unknown) => void;
  };
  const agentBlobFetchCalls: AgentBlobFetchCall[] = [];
  const fetchCalls: FetchCall[] = [];
  const streams: StreamCall[] = [];
  const taskStreams: TaskStreamCall[] = [];
  const polls: PollCall[] = [];
  const sendCalls: SendCall[] = [];
  const uploadCalls: UploadCall[] = [];

  const client = {
    fetchAgentBlob: vi.fn(
      (
        _groupId,
        agentId: string,
        ref: Parameters<CommaApiClient["fetchAgentBlob"]>[2],
        opts?: Parameters<CommaApiClient["fetchAgentBlob"]>[3]
      ) =>
        new Promise<Blob>((resolve, reject) => {
          agentBlobFetchCalls.push({
            agentId,
            ref,
            signal: opts?.signal,
            resolve,
            reject,
          });
        })
    ),
    fetchGroupFile: vi.fn(
      (
        _workspaceId,
        path: string,
        opts?: Parameters<CommaApiClient["fetchGroupFile"]>[2]
      ) =>
        new Promise<Blob>((resolve, reject) => {
          fetchCalls.push({ path, signal: opts?.signal, resolve, reject });
        })
    ),
    pollConversation: vi.fn(
      (
        _workspaceId,
        _conversationId,
        opts?: Parameters<CommaApiClient["pollConversation"]>[2]
      ) =>
        new Promise<Awaited<ReturnType<CommaApiClient["pollConversation"]>>>(
          (resolve, reject) => {
            polls.push({ etag: opts?.etag, resolve, reject });
          }
        )
    ),
    streamConversationEvents: vi.fn(
      (
        _workspaceId,
        _conversationId,
        opts: Parameters<CommaApiClient["streamConversationEvents"]>[2]
      ) =>
        new Promise<void>((resolve, reject) => {
          opts.signal?.addEventListener(
            "abort",
            () => reject(new DOMException("Aborted", "AbortError")),
            { once: true }
          );
          const streamOpts = opts as typeof opts & { waitMs?: number };
          streams.push({
            onEvent: opts.onEvent,
            resolve,
            reject,
            waitMs: streamOpts.waitMs,
          });
        })
    ),
    streamConversationListEvents: vi.fn(
      (_groupId, opts: Parameters<CommaApiClient["streamConversationListEvents"]>[1]) =>
        new Promise<void>((resolve, reject) => {
          if (opts.signal?.aborted) {
            reject(new DOMException("Aborted", "AbortError"));
            return;
          }
          opts.signal?.addEventListener(
            "abort",
            () => reject(new DOMException("Aborted", "AbortError")),
            { once: true }
          );
          taskStreams.push({ onEvent: opts.onEvent, reject, resolve });
        })
    ),
    sendMessage: vi.fn(
      (
        _workspaceId,
        _conversationId,
        attrs: Parameters<CommaApiClient["sendMessage"]>[2]
      ) =>
        new Promise<CommaConversation>((resolve, reject) => {
          sendCalls.push({
            text: attrs.text,
            clientDeviceId: attrs.clientDeviceId,
            clientRequestId: attrs.clientRequestId,
            localFiles: attrs.localFiles,
            skills: attrs.skills,
            resolve,
            reject,
          });
        })
    ),
    uploadGroupFile: vi.fn(
      (_workspaceId, attrs: Parameters<CommaApiClient["uploadGroupFile"]>[1]) =>
        new Promise((resolve, reject) => {
          uploadCalls.push({
            name: attrs.name,
            signal: attrs.signal,
            resolve,
            reject,
          });
        })
    ),
  } as Partial<CommaApiClient> as CommaApiClient;

  return {
    agentBlobFetchCalls,
    client,
    fetchCalls,
    polls,
    streams,
    taskStreams,
    sendCalls,
    uploadCalls,
    emit(index: number, event: CommaConversationEvent, eventName: string) {
      streams[index]?.onEvent(event, eventName);
    },
    emitTaskInvalidation(index: number, version: string) {
      taskStreams[index]?.onEvent({
        group_id: "grp_1",
        kind: "agent_task",
        type: "conversation_list_invalidated",
        version,
      });
    },
    resolveStream(index: number) {
      streams[index]?.resolve();
    },
    resolvePoll(
      index: number,
      value: Awaited<ReturnType<CommaApiClient["pollConversation"]>>
    ) {
      polls[index]?.resolve(value);
    },
    resolveFetch(index: number, value: Blob) {
      fetchCalls[index]?.resolve(value);
    },
    resolveAgentBlobFetch(index: number, value: Blob) {
      agentBlobFetchCalls[index]?.resolve(value);
    },
    rejectStream(index: number, error: unknown) {
      streams[index]?.reject(error);
    },
    resolveSend(index: number, value: CommaConversation) {
      sendCalls[index]?.resolve(value);
    },
    rejectSend(index: number, error: unknown) {
      sendCalls[index]?.reject(error);
    },
    resolveUpload(index: number, file: { path: string; name: string; size: number }) {
      uploadCalls[index]?.resolve(file);
    },
    rejectUpload(index: number, error: unknown) {
      uploadCalls[index]?.reject(error);
    },
  };
}

function message(
  messageId: string,
  role: string,
  text: string,
  clientRequestId?: string,
  overrides: Partial<SalixMessage> = {}
) {
  return {
    message_id: messageId,
    kind: "message",
    actor_type: role === "assistant" ? "agent" : "user",
    content: [{ type: "text", text }],
    client_request_id: clientRequestId,
    created_at: 1,
    ...overrides,
  };
}

let nextActivitySequence = 1;

function activityEvent(
  attrs: Partial<CommaConversationEvent> & Record<string, unknown> = {}
): CommaConversationEvent {
  return {
    type: "activity",
    conversation_id: "cnv_1",
    phase: "execution",
    status: "running",
    action: "Running a command",
    summary: "Working",
    tool_name: "env.exec",
    display_strength: "strong",
    display_priority: "work",
    display_hold_ms: 5_000,
    producer_epoch: "epoch-a",
    response_key: "rsp-activity",
    sequence: nextActivitySequence++,
    source_message_ids: ["msg_user"],
    summary_class: "public",
    updated_at: 1,
    ...attrs,
  } as CommaConversationEvent;
}

type AssistantDraftSnapshot = {
  conversationId: string;
  draftId: string;
  text: string;
};

function assistantDraft(channel: ConversationChannel) {
  const draft = (
    channel.getSnapshot() as ReturnType<ConversationChannel["getSnapshot"]> & {
      assistantDraft?: AssistantDraftSnapshot;
    }
  ).assistantDraft;
  return draft
    ? {
        conversationId: draft.conversationId,
        draftId: draft.draftId,
        text: draft.text,
      }
    : undefined;
}

function draftEvent(
  type: string,
  attrs: Record<string, unknown> = {}
): CommaConversationEvent {
  const sourceMessageIds = Object.hasOwn(attrs, "source_message_ids")
    ? (attrs.source_message_ids as string[])
    : ["msg_user"];
  return {
    type,
    conversation_id: "cnv_1",
    draft_id: "draft_1",
    response_key: responseKey(sourceMessageIds),
    source_message_ids: sourceMessageIds,
    status: type.replace("message_draft_", ""),
    text: "",
    ...attrs,
  } as CommaConversationEvent;
}

function responseKey(sourceMessageIds: readonly string[]) {
  return `rsp:${sourceMessageIds.join("|")}`;
}

function conversation(
  attrs: Partial<CommaConversation> = {},
  messages = attrs.messages ?? []
): CommaConversation {
  return {
    group_id: "grp_1",
    id: "cnv_1",
    kind: "user_chat",
    title: "Thread",
    status: "completed",
    ...attrs,
    messages,
  };
}

function createVisibility(initialVisible: boolean) {
  let visible = initialVisible;
  const listeners = new Set<() => void>();
  return {
    isVisible: () => visible,
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    setVisible(next: boolean) {
      visible = next;
      for (const listener of listeners) {
        listener();
      }
    },
  } satisfies ConversationVisibility & { setVisible(next: boolean): void };
}

async function flushMicrotasks() {
  await Promise.resolve();
  await Promise.resolve();
}
