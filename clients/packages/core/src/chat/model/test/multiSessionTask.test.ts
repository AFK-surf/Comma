import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Runner, TurnScheduler } from "@comma/core-kernel";
import {
  commaConversationEventSchema,
  commaConversationPreviewSchema,
  type CommaTaskRun,
} from "../../../comma/api-schemas";
import { toCodingUsage, usageSchema } from "../../../coding-wire";
import { projectionToChannelState } from "../../view-state";
import { taskActivity, type TaskActivityMessage } from "../taskActivity";
import {
  ConversationChannel,
  toConversationProjection,
  type ConversationChannelState,
} from "../conversationChannel";
import { promiseChatApi, type PromiseChatApi } from "../../../testing/promise-chat-api";
import type { CommaConversation, CommaConversationEvent } from "../../api";
import type { ChatWorkerSession, ConversationProjection } from "@comma/chat-contract";

async function flushMicrotasks() {
  for (let i = 0; i < 20; i++) await Promise.resolve();
}

describe("multi-session Task PR 3 R1 regressions", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });
  it("Item 1: projectionToChannelState preserves workerSessions and array reference", () => {
    const twoWorkers: ChatWorkerSession[] = [
      {
        participantId: "prt_lead",
        slot: "lead",
        label: "Lead",
        model: "claude-opus-5",
        isPrimary: true,
        subscribed: true,
        state: "active",
        status: "Working",
        updatedAt: 1_720_000_001,
      },
      {
        participantId: "prt_rev",
        slot: "reviewer",
        label: "Reviewer",
        model: "gpt-6.2-sol",
        isPrimary: false,
        subscribed: true,
        state: "waiting",
        status: "Waiting for lead",
        updatedAt: 1_720_000_002,
      },
    ];

    const projection = {
      groupId: "grp_1",
      conversationId: "cnv_1",
      status: "ready",
      connection: "live",
      messages: [],
      serverMessages: [],
      pending: [],
      hasMoreHistory: false,
      loadingHistory: false,
      reply: {
        state: "idle",
        pending: false,
        failed: false,
        resuming: false,
      },
      workerSessions: twoWorkers,
      draft: "",
      draftAttachments: [],
      questionAttachments: {},
    } as unknown as ConversationProjection;

    const restored = projectionToChannelState(projection);
    expect(restored.workerSessions).toBe(twoWorkers);
    expect(restored.workerSessions).toHaveLength(2);
    expect(restored.workerSessions?.[1]?.state).toBe("waiting");
  });

  it("Preview schema accepts task_preview_worker_sessions wire payload (state=stopped, status='')", () => {
    const parsed = commaConversationPreviewSchema.parse({
      activity_status: "idle",
      freshness: { state: "fresh", refreshed_at: 1_720_000_000 },
      id: "cnv_task_1",
      group_id: "grp_1",
      kind: "agent_task",
      status: "active",
      title: "Multi-session preview",
      updated_at: 1_720_000_000,
      bound_worker: { participant_id: "prt_lead", name: "Lead" },
      worker_sessions: [
        {
          participant_id: "prt_lead",
          slot: "lead",
          label: "Lead",
          model: "claude-opus-5",
          is_primary: true,
          subscribed: false,
          state: "stopped",
          status: "",
        },
        {
          participant_id: "prt_rev",
          slot: "reviewer",
          label: "Reviewer",
          model: "gpt-6.2-sol",
          is_primary: false,
          subscribed: false,
          state: "stopped",
          status: "",
        },
      ],
    });
    expect(parsed.worker_sessions).toHaveLength(2);
    expect(parsed.worker_sessions?.[0]?.state).toBe("stopped");
    expect(parsed.worker_sessions?.[1]?.status).toBe("");
  });

  it("ConversationChannel + chatView projection: 2-worker snapshot, 1->2 upgrade, issueDetail mutation, and duplicate run dedup", async () => {
    let pushEvent: ((event: CommaConversationEvent) => void) | undefined;
    let streamCount = 0;

    const taskConversation: CommaConversation = {
      group_id: "grp_1",
      id: "cnv_task_live",
      kind: "agent_task",
      title: "Live Multi-Session Task",
      status: "active",
      messages: [],
    };

    const api = promiseChatApi({
      pollConversation: vi.fn(async () => ({
        conversation: taskConversation,
        etag: "etag_1",
      })),
      getConversation: vi.fn(async () => taskConversation),
      listConversationMessages: vi.fn(async () => ({ data: [], has_more: false })),
      streamConversationListEvents: vi.fn(
        (
          _g: string,
          opts: {
            onParticipantStatuses?: (e: CommaConversationEvent) => void;
            onOpen?: () => void;
            signal?: AbortSignal;
          }
        ) => {
          streamCount += 1;
          pushEvent = opts.onParticipantStatuses;
          opts.onOpen?.();
          return new Promise<void>((resolve) => {
            if (opts.signal?.aborted) {
              resolve();
              return;
            }
            opts.signal?.addEventListener("abort", () => resolve(), { once: true });
          });
        }
      ),
    } as unknown as PromiseChatApi);

    const runner = new Runner(undefined, new TurnScheduler());
    const channel = new ConversationChannel({
      api,
      workspaceId: "wsp_1",
      groupId: "grp_1",
      conversationId: "cnv_task_live",
      initialKind: "agent_task",
      env: {
        runner,
        jitterMs: () => 0,
        now: () => 1_720_000_000_000,
        createClientRequestId: () => "req_1",
        transcodeAttachment: undefined,
        visibility: undefined,
      },
    });

    const states: ConversationChannelState[] = [];
    const unsubscribe = channel.subscribe(() => {
      states.push(channel.getSnapshot());
    });

    try {
      channel.start();
      await flushMicrotasks();

      const runPayload = {
        place: { kind: "sandbox" as const },
        model: { kind: "catalog" as const, name: "claude-opus-5" },
        facts: {
          usage: {
            modelCalls: 4,
            inputTokens: 400,
            cachedTokens: 50,
            outputTokens: 100,
            model: "claude-opus-5",
          },
        },
      };

      // 1) Initial 1-worker snapshot
      pushEvent?.({
        type: "task_participant_statuses",
        group_id: "grp_1",
        conversation_id: "cnv_task_live",
        bound_worker: { participant_id: "prt_lead", name: "Lead" },
        participants: [
          {
            conversation_id: "cnv_task_live",
            participant_id: "prt_lead",
            actor_role: "worker",
            state: "active",
            status: "Working",
            updated_at: 1_720_000_010,
          },
        ],
        worker_sessions: [
          {
            participant_id: "prt_lead",
            slot: "lead",
            label: "Lead",
            model: "claude-opus-5",
            is_primary: true,
            subscribed: true,
            state: "active",
            status: "Working",
            updated_at: 1_720_000_010,
          },
        ],
        run: runPayload,
      } as CommaConversationEvent);
      await flushMicrotasks();

      const afterSingle = channel.getSnapshot();
      expect(afterSingle.workerSessions).toHaveLength(1);
      const proj1 = toConversationProjection(afterSingle, {
        groupId: "grp_1",
        workspaceId: "wsp_1",
      });
      expect(projectionToChannelState(proj1).workerSessions).toBe(
        afterSingle.workerSessions
      );

      // 2) Duplicate SSE event with identical run -> zero extra state emission & stable taskRun ref
      const countBeforeDup = states.length;
      const runBeforeDup = afterSingle.taskRun;
      pushEvent?.({
        type: "task_participant_statuses",
        group_id: "grp_1",
        conversation_id: "cnv_task_live",
        bound_worker: { participant_id: "prt_lead", name: "Lead" },
        participants: [
          {
            conversation_id: "cnv_task_live",
            participant_id: "prt_lead",
            actor_role: "worker",
            state: "active",
            status: "Working",
            updated_at: 1_720_000_010,
          },
        ],
        worker_sessions: [
          {
            participant_id: "prt_lead",
            slot: "lead",
            label: "Lead",
            model: "claude-opus-5",
            is_primary: true,
            subscribed: true,
            state: "active",
            status: "Working",
            updated_at: 1_720_000_010,
          },
        ],
        run: {
          place: { kind: "sandbox" },
          model: { kind: "catalog", name: "claude-opus-5" },
          facts: {
            usage: {
              modelCalls: 4,
              inputTokens: 400,
              cachedTokens: 50,
              outputTokens: 100,
              model: "claude-opus-5",
            },
          },
        },
      } as CommaConversationEvent);
      await flushMicrotasks();
      expect(states.length).toBe(countBeforeDup);
      expect(channel.getSnapshot().taskRun).toBe(runBeforeDup);

      // 3) Upgrade 1-worker -> 2-worker with issue_detail
      pushEvent?.({
        type: "task_participant_statuses",
        group_id: "grp_1",
        conversation_id: "cnv_task_live",
        bound_worker: { participant_id: "prt_lead", name: "Lead" },
        participants: [
          {
            conversation_id: "cnv_task_live",
            participant_id: "prt_lead",
            actor_role: "worker",
            state: "error",
            status: "Rate limited",
            updated_at: 1_720_000_020,
            issue: "rate_limit",
            issue_detail: { source: "anthropic", reset_at: 1_720_001_000 },
          },
        ],
        worker_sessions: [
          {
            participant_id: "prt_lead",
            slot: "lead",
            label: "Lead",
            model: "claude-opus-5",
            is_primary: true,
            subscribed: true,
            state: "error",
            status: "Rate limited",
            updated_at: 1_720_000_020,
            issue: "rate_limit",
            issue_detail: { source: "anthropic", reset_at: 1_720_001_000 },
          },
          {
            participant_id: "prt_rev",
            slot: "reviewer",
            label: "Reviewer",
            model: "gpt-6.2-sol",
            is_primary: false,
            subscribed: true,
            state: "waiting",
            status: "Waiting",
            updated_at: 1_720_000_020,
          },
        ],
        run: runPayload,
      } as CommaConversationEvent);
      await flushMicrotasks();

      const afterUpgrade = channel.getSnapshot();
      expect(afterUpgrade.workerSessions).toHaveLength(2);
      const proj2 = toConversationProjection(afterUpgrade, {
        groupId: "grp_1",
        workspaceId: "wsp_1",
      });
      const restored2 = projectionToChannelState(proj2);
      expect(restored2.workerSessions).toBe(afterUpgrade.workerSessions);
      expect(restored2.workerSessions?.[1]?.slot).toBe("reviewer");

      // 4) Same updated_at, nested issue_detail changes -> new references emitted
      const prevSessionsRef = afterUpgrade.workerSessions;
      const prevStatusesRef = afterUpgrade.participantStatuses;
      pushEvent?.({
        type: "task_participant_statuses",
        group_id: "grp_1",
        conversation_id: "cnv_task_live",
        bound_worker: { participant_id: "prt_lead", name: "Lead" },
        participants: [
          {
            conversation_id: "cnv_task_live",
            participant_id: "prt_lead",
            actor_role: "worker",
            state: "error",
            status: "Rate limited",
            updated_at: 1_720_000_020,
            issue: "rate_limit",
            issue_detail: {
              source: "anthropic",
              reset_at: 1_720_002_000,
              credits: true,
            },
          },
        ],
        worker_sessions: [
          {
            participant_id: "prt_lead",
            slot: "lead",
            label: "Lead",
            model: "claude-opus-5",
            is_primary: true,
            subscribed: true,
            state: "error",
            status: "Rate limited",
            updated_at: 1_720_000_020,
            issue: "rate_limit",
            issue_detail: {
              source: "anthropic",
              reset_at: 1_720_002_000,
              credits: true,
            },
          },
          {
            participant_id: "prt_rev",
            slot: "reviewer",
            label: "Reviewer",
            model: "gpt-6.2-sol",
            is_primary: false,
            subscribed: true,
            state: "waiting",
            status: "Waiting",
            updated_at: 1_720_000_020,
          },
        ],
        run: runPayload,
      } as CommaConversationEvent);
      await flushMicrotasks();

      const afterDetailChange = channel.getSnapshot();
      expect(afterDetailChange.workerSessions).not.toBe(prevSessionsRef);
      expect(afterDetailChange.participantStatuses).not.toBe(prevStatusesRef);
      expect(afterDetailChange.workerSessions?.[0]?.issueDetail?.credits).toBe(true);
      expect(afterDetailChange.workerSessions?.[0]?.issueDetail?.resetAt).toBe(
        1_720_002_000
      );
      expect(streamCount).toBeGreaterThanOrEqual(1);
    } finally {
      unsubscribe();
      channel.stop();
    }
  });

  it("Items 2 & 5: parses map models, nullable by_slot usage, partial flag, and strips internal session fields", () => {
    const rawUsage = {
      modelCalls: 15,
      inputTokens: 1500,
      cachedTokens: 200,
      outputTokens: 300,
      model: "claude-opus-5",
      models: {
        "claude-opus-5": {
          modelCalls: 10,
          inputTokens: 1000,
          cachedTokens: 200,
          outputTokens: 200,
        },
        "gpt-6.2-sol": {
          modelCalls: 5,
          inputTokens: 500,
          cachedTokens: 0,
          outputTokens: 100,
        },
      },
      partial: true,
      sessions: { sess_sentinel_live_991: { modelCalls: 10 } },
      retired_sessions: { sess_sentinel_retired_992: { modelCalls: 4 } },
      by_slot: {
        lead: {
          slot: "lead",
          session: "sess_sentinel_live_991",
          is_primary: true,
          usage: {
            modelCalls: 10,
            inputTokens: 1000,
            cachedTokens: 200,
            outputTokens: 200,
            model: "claude-opus-5",
          },
        },
        reviewer: {
          slot: "reviewer",
          session: "sess_sentinel_live_991",
          is_primary: false,
          usage: {
            modelCalls: 5,
            inputTokens: 500,
            cachedTokens: 0,
            outputTokens: 100,
            model: "gpt-6.2-sol",
          },
        },
        auditor: {
          slot: "auditor",
          session: "sess_sentinel_retired_992",
          is_primary: false,
          unreadable: true,
          usage: null,
        },
      },
    };

    const parsedEvent = commaConversationEventSchema.parse({
      type: "task_participant_statuses",
      group_id: "grp_1",
      conversation_id: "cnv_1",
      participants: [],
      run: {
        place: { kind: "sandbox" },
        facts: {
          usage: rawUsage,
          changes: { files: 3, additions: 42, deletions: 7 },
          pull_request: null,
        },
      },
    });

    if (parsedEvent.type !== "task_participant_statuses") {
      throw new Error("unexpected event type");
    }
    const run = parsedEvent.run as CommaTaskRun | undefined;
    if (!run?.facts) {
      throw new Error("expected task run facts");
    }
    expect(run.facts.changes).toEqual({
      files: 3,
      additions: 42,
      deletions: 7,
    });
    expect(run.facts.pull_request).toBeNull();

    const usage = toCodingUsage(run.facts.usage!);
    expect(usage).not.toBeNull();
    expect(usage!.modelCalls).toBe(15);
    expect(usage!.partial).toBe(true);
    expect(usage!.models).toEqual(["claude-opus-5", "gpt-6.2-sol"]);
    expect(usage!.bySlot?.lead?.modelCalls).toBe(10);
    expect(usage!.bySlot?.reviewer?.modelCalls).toBe(5);
    expect(usage!.bySlot?.auditor?.unreadable).toBe(true);
    expect(usage!.bySlot?.auditor?.usage).toBeNull();

    const serialized = JSON.stringify(usage);
    expect(serialized).not.toContain("sess_sentinel_live_991");
    expect(serialized).not.toContain("sess_sentinel_retired_992");
    expect(serialized).not.toContain("retired_sessions");

    const parsedWireUsage = usageSchema.parse(rawUsage);
    const historyUsage = toCodingUsage(parsedWireUsage);
    expect(historyUsage!.modelCalls).toBe(15);
    expect(historyUsage!.partial).toBe(true);
    expect(JSON.stringify(historyUsage)).not.toContain("sess_sentinel_live_991");
  });

  it("Item 7: taskActivity matches milestones to the same participantId when sessions interleave", () => {
    const messages: TaskActivityMessage[] = [
      {
        messageId: "msg_brief",
        source: "server",
        role: "assistant",
        actorType: "agent",
        actorId: "agt_router",
        participantId: "prt_router",
        brief: true,
        text: "Build and review feature",
        createdAt: 1_720_000_000,
      },
      {
        messageId: "msg_lead_ms",
        source: "server",
        role: "assistant",
        actorType: "agent",
        actorId: "agt_worker",
        participantId: "prt_lead",
        text: "",
        milestones: { titles: ["Implemented API"], standalone: true },
        createdAt: 1_720_000_001,
      },
      {
        messageId: "msg_rev_reply",
        source: "server",
        role: "assistant",
        actorType: "agent",
        actorId: "agt_worker",
        participantId: "prt_reviewer",
        text: "Found one edge case in auth.",
        createdAt: 1_720_000_002,
      },
      {
        messageId: "msg_lead_reply",
        source: "server",
        role: "assistant",
        actorType: "agent",
        actorId: "agt_worker",
        participantId: "prt_lead",
        text: "Fixed the edge case and verified tests.",
        createdAt: 1_720_000_003,
      },
    ];

    const activity = taskActivity(messages);
    expect(activity?.groups[0]?.entries).toEqual([
      {
        title: "Implemented API",
        at: 1_720_000_001,
        messageId: "msg_lead_reply",
      },
    ]);
  });
});
