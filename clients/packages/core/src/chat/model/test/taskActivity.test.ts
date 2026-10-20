// A Task's Activity as the core reads it from the transcript: milestones grouped under the person's requests and a
// Loop Task's runs, each opening the result its Agent showed next; no transcript shows a milestone-only message.
import { describe, expect, it } from "vitest";
import type { SalixMessage } from "../../api";
import {
  idleConversationChannelState,
  normalizeServerMessages,
  toConversationProjection,
} from "../conversationChannel";
import {
  taskActivity,
  transcriptMessages,
  withActivityHistory,
  withLoopRuns,
} from "../taskActivity";

const milestone = (title: string) => ({ type: "milestone", title });
const text = (words: string) => ({ type: "text", text: words });

const message = (
  seq: number,
  content: unknown[],
  extra: Record<string, unknown> = {}
): SalixMessage =>
  ({
    message_id: `msg_${seq}`,
    seq,
    kind: "message",
    actor_type: "agent",
    agent_id: "agt_worker",
    content,
    created_at: 1_720_000_000 + seq,
    ...extra,
  }) as SalixMessage;

const brief = (seq: number) =>
  message(seq, [text("Prepare the Q3 review invites.")], {
    agent_id: "agt_router",
    role_label: "delegator",
    metadata: { message_type: "task_command" },
  });
const person = (seq: number, words: string) =>
  message(seq, [text(words)], { actor_type: "user", agent_id: undefined });
// A Router's answer in a Task replies to the message it answers.
const router = (seq: number, words: string) =>
  message(seq, [text(words)], {
    agent_id: "agt_router",
    role_label: "delegator",
    reply_to_message_id: "msg_1",
  });
const wake = (seq: number) =>
  message(seq, [text("Run the hourly check.")], {
    actor_type: "system",
    agent_id: undefined,
    agent_input: {
      role: "user",
      content: "Run the hourly check.",
      trusted_origin: { provider: "loop", loop_id: "lop_1" },
    },
  });

const read = (wire: SalixMessage[]) =>
  normalizeServerMessages(wire, [], "agent_task", "cnv_task");

describe("Task Activity", () => {
  it("shows no milestone-only message in a transcript, and keeps one that also says something", () => {
    const messages = read([
      brief(1),
      message(2, [milestone("Wrote the agenda")]),
      message(3, [milestone("Wrote Alice's invite"), text("Here are the drafts.")]),
    ]);

    expect(transcriptMessages(messages).map((shown) => shown.messageId)).toEqual([
      "msg_1",
      "msg_3",
    ]);
    expect(messages[2]?.text).toBe("Here are the drafts.");
  });

  it("groups milestones under each request and opens the result shown after them", () => {
    const activity = taskActivity(
      read([
        brief(1),
        message(2, [milestone("Wrote the agenda"), milestone("Wrote Alice's invite")]),
        router(3, "Tracking it."),
        message(4, [text("Agenda and Alice's invite are ready.")]),
        person(5, "Also write one for Dave.\nHe owns security."),
        message(6, [milestone("Wrote Dave's invite")]),
        person(7, "What is the status?"),
      ])
    );

    expect(activity?.groups).toEqual([
      {
        request: { messageId: "msg_1", kind: "brief", text: "", at: 1_720_000_001 },
        entries: [
          // The Router's message is not the Worker's result; the Worker's next one is.
          { title: "Wrote the agenda", at: 1_720_000_002, messageId: "msg_4" },
          { title: "Wrote Alice's invite", at: 1_720_000_002, messageId: "msg_4" },
        ],
      },
      {
        request: {
          messageId: "msg_5",
          kind: "follow_up",
          text: "Also write one for Dave.",
          at: 1_720_000_005,
        },
        // No result shown before the next request: it opens where it happened.
        entries: [
          { title: "Wrote Dave's invite", at: 1_720_000_006, messageId: "msg_5" },
        ],
      },
      // A request the Task recorded nothing for is left out.
    ]);
  });

  it("starts a group at a request the Router hands in, not at its answers or notes", () => {
    const activity = taskActivity(
      read([
        brief(1),
        message(2, [milestone("Wrote the agenda"), text("The agenda is ready.")]),
        person(3, "Also write one for Dave."),
        // The Router hands the person's message on, replying to it.
        message(4, [text("Write Dave's invite.")], {
          agent_id: "agt_router",
          role_label: "delegator",
          reply_to_message_id: "msg_3",
        }),
        message(5, [milestone("Wrote Dave's invite"), text("Dave's invite is ready.")]),
        // A note for people only.
        message(6, [text("All invites are ready.")], {
          agent_id: "agt_router",
          role_label: "delegator",
          delivery_filter: { participant_ids: [] },
        }),
        // A request made in Home, handed into this Task: the server marks it.
        message(
          7,
          [text("The person now asks: rewrite the invites for a smaller room.")],
          {
            agent_id: "agt_router",
            role_label: "delegator",
            metadata: { task_request: true },
          }
        ),
        message(8, [milestone("Rewrote the invites"), text("Rewritten.")]),
        // A Router's own follow-up, such as on a timer, replies to nothing and hands in nothing.
        message(9, [text("Checking on the room size.")], {
          agent_id: "agt_router",
          role_label: "delegator",
        }),
        message(10, [milestone("Booked the smaller room")]),
      ])
    );

    expect(
      activity?.groups.map((group) => [group.request?.text, group.entries.length])
    ).toEqual([
      ["", 1],
      ["Also write one for Dave.", 1],
      ["The person now asks: rewrite the invites for a smaller room.", 2],
    ]);
  });

  it("groups a Loop Task's milestones by run, and leaves out a run that recorded none", () => {
    const wire = [
      brief(1),
      message(2, [milestone("Set up the hourly check")]),
      message(3, [text("The check runs every hour.")]),
      wake(4),
      message(5, [milestone("Filed 2 new issues")]),
      message(6, [text("2 new issues today.")]),
      wake(7),
      message(8, [text("Nothing new.")]),
      wake(9),
    ];
    const runs = withLoopRuns([], wire);
    const messages = read(wire);

    // No transcript shows a wake.
    expect(transcriptMessages(messages).map((shown) => shown.messageId)).toEqual([
      "msg_1",
      "msg_3",
      "msg_6",
      "msg_8",
    ]);
    expect(taskActivity(messages, runs)?.groups).toEqual([
      {
        request: { messageId: "msg_1", kind: "brief", text: "", at: 1_720_000_001 },
        entries: [
          { title: "Set up the hourly check", at: 1_720_000_002, messageId: "msg_3" },
        ],
      },
      {
        request: { kind: "run", text: "", at: 1_720_000_004 },
        entries: [
          { title: "Filed 2 new issues", at: 1_720_000_005, messageId: "msg_6" },
        ],
      },
    ]);
    // A page that proves no new run keeps the list.
    expect(withLoopRuns(runs, [wake(7), message(10, [text("Later.")])])).toBe(runs);
  });

  it("projects the Activity beside a transcript without milestone-only messages", () => {
    const serverMessages = read([
      brief(1),
      message(2, [milestone("Wrote the agenda")]),
    ]);
    const projection = toConversationProjection(
      {
        ...idleConversationChannelState,
        conversation: {
          group_id: "grp_1",
          id: "cnv_task",
          kind: "agent_task",
          messages: [],
          status: "active",
          title: "Q3 review",
        },
        messages: serverMessages,
        serverMessages,
      },
      { groupId: "grp_1", workspaceId: "wsp_1" }
    );

    expect(projection.messages.map((shown) => shown.messageId)).toEqual(["msg_1"]);
    expect(projection.serverMessages.map((shown) => shown.messageId)).toEqual([
      "msg_1",
    ]);
    expect(projection.taskActivity?.groups[0]?.entries).toEqual([
      { title: "Wrote the agenda", at: 1_720_000_002, messageId: "msg_1" },
    ]);
  });

  it("reads the history read for the Activity before the transcript, once per message", () => {
    const history = read([
      brief(1),
      message(2, [milestone("Wrote the agenda")]),
      message(3, [text("")]),
    ]);
    // The transcript holds message 3 too; it is read from the transcript.
    const transcript = read([
      message(3, [text("The agenda is ready.")]),
      person(4, "Now the invites."),
      message(5, [milestone("Wrote Alice's invite")]),
    ]);
    const messages = withActivityHistory(history, transcript);

    expect(messages.map((shown) => shown.messageId)).toEqual([
      "msg_1",
      "msg_2",
      "msg_3",
      "msg_4",
      "msg_5",
    ]);
    expect(messages[2]).toBe(transcript[0]);
    expect(withActivityHistory(history, transcript)).toBe(messages);
    expect(withActivityHistory(undefined, transcript)).toBe(transcript);
    expect(
      taskActivity(messages)?.groups.map((group) => [
        group.request?.kind,
        group.entries.map((entry) => entry.messageId),
      ])
    ).toEqual([
      ["brief", ["msg_3"]],
      ["follow_up", ["msg_4"]],
    ]);
  });

  it("has no Activity while the Task has no milestone, and reads none from a person", () => {
    const messages = read([brief(1), person(2, "Thanks"), message(3, [text("Done.")])]);
    expect(taskActivity(messages)).toBeUndefined();
    const forged = read([
      message(1, [milestone("Not mine")], { actor_type: "user", agent_id: undefined }),
    ]);
    expect(forged[0]?.milestones).toBeUndefined();
  });
});
