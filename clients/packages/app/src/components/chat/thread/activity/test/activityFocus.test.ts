import { describe, expect, it } from "vitest";
import type { ChatMessage, ChatParticipantStatus } from "@comma/core/chat";
import {
  focusFeedIds,
  focusTurnKey,
  resolveActivityFocus,
  selectActivityFocusTarget,
  type ActivityFocusTaskRef,
} from "../activityFocus";

const router: ChatParticipantStatus = {
  conversationId: "home",
  participantId: "router",
  state: "active",
  status: "is thinking...",
  updatedAt: 1,
};
const created: ActivityFocusTaskRef[] = [
  {
    conversationId: "t_old",
    statusBucket: "in_progress",
    title: "Old",
    requestTurnKey: "turn_1",
  },
  {
    conversationId: "t_done",
    statusBucket: "done",
    title: "Done",
    requestTurnKey: "turn_2",
  },
  {
    conversationId: "t_a",
    statusBucket: "in_progress",
    title: "A",
    requestTurnKey: "turn_2",
  },
  {
    conversationId: "t_b",
    statusBucket: "in_progress",
    title: "B",
    requestTurnKey: "turn_2",
  },
];

describe("selectActivityFocusTarget", () => {
  it("follows the Tasks whose input the Router answers, known or not", () => {
    expect(
      selectActivityFocusTarget({
        createdTasks: created,
        currentTurnKey: "turn_2",
        participantStatus: {
          ...router,
          workingConversationIds: ["t_a", "t_elsewhere"],
        },
      })
    ).toEqual({
      mode: "following",
      tasks: [created[2], { conversationId: "t_elsewhere" }],
    });
  });

  it("waits only on running Tasks that the current turn delegated", () => {
    const waiting = { ...router, waiting: true };
    expect(
      selectActivityFocusTarget({
        createdTasks: created,
        currentTurnKey: "turn_2",
        participantStatus: waiting,
      })?.tasks.map((task) => task.conversationId)
    ).toEqual(["t_a", "t_b"]);
    expect(
      selectActivityFocusTarget({
        createdTasks: created,
        currentTurnKey: "turn_3",
        participantStatus: waiting,
      })
    ).toEqual({ mode: "waiting", tasks: [] });
  });

  it("leaves an idle Router's slot to its newest running Tasks, never over an error", () => {
    for (const participantStatus of [
      undefined,
      { ...router, state: "stopped" as const, status: "" },
      { ...router, loopWake: true },
    ]) {
      expect(
        selectActivityFocusTarget({
          createdTasks: created,
          currentTurnKey: "turn_2",
          participantStatus,
        })
      ).toEqual({ mode: "working", tasks: [created[2], created[3]] });
    }
    expect(
      selectActivityFocusTarget({
        createdTasks: created,
        currentTurnKey: "turn_2",
        participantStatus: { ...router, state: "error", status: "error" },
      })
    ).toBeUndefined();
    // A Router that thinks about this chat says so itself.
    expect(
      selectActivityFocusTarget({
        createdTasks: created,
        currentTurnKey: "turn_2",
        participantStatus: router,
      })
    ).toBeUndefined();
  });

  it("follows at most two Task feeds", () => {
    expect(
      focusFeedIds({
        mode: "following",
        tasks: ["t1", "t2", "t3", "t4", "t5"].map((conversationId) => ({
          conversationId,
        })),
      })
    ).toEqual(["t1", "t2"]);
  });
});

const worker = (active: boolean) => ({
  active,
  avatarId: "actor",
  name: "Codex Worker",
  participantId: "ptp",
});

const message = (
  messageId: string,
  role: ChatMessage["role"],
  messageType?: string
): ChatMessage =>
  ({ messageId, role, ...(messageType ? { messageType } : {}) }) as ChatMessage;

describe("focusTurnKey", () => {
  it("is the person's last message to the Router, a Quick Chat included", () => {
    expect(focusTurnKey([message("m1", "user"), message("m2", "assistant")])).toBe(
      "m1"
    );
    // The server delivers a Quick Chat to the Router: it answers m2 now.
    expect(
      focusTurnKey([message("m1", "user"), message("m2", "user", "quick_chat")])
    ).toBe("m2");
    expect(focusTurnKey([message("m2", "assistant")])).toBeUndefined();
  });
});

describe("resolveActivityFocus", () => {
  it("names unknown Tasks from resolved titles", () => {
    expect(
      resolveActivityFocus(
        { mode: "following", tasks: [{ conversationId: "t_elsewhere" }] },
        {
          groupId: "group",
          titles: new Map([
            ["t_elsewhere", { title: "Elsewhere", statusBucket: "in_progress" }],
          ]),
          workers: new Map([["t_elsewhere", worker(false)]]),
        }
      )?.tasks[0]
    ).toMatchObject({
      statusBucket: "in_progress",
      title: "Elsewhere",
      worker: worker(false),
    });
  });

  it("shows idle-Router Tasks only while their Worker works", () => {
    const target = { mode: "working" as const, tasks: [created[2]!, created[3]!] };
    expect(
      resolveActivityFocus(target, {
        groupId: "group",
        titles: new Map(),
        workers: new Map([
          ["t_a", worker(false)],
          ["t_b", worker(true)],
        ]),
      })?.tasks.map((task) => task.conversationId)
    ).toEqual(["t_b"]);
    expect(
      resolveActivityFocus(target, {
        groupId: "group",
        titles: new Map(),
        workers: new Map([["t_a", worker(false)]]),
      })
    ).toBeUndefined();
  });
});
