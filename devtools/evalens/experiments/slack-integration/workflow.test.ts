import { describe, expect, test } from "bun:test";

import slackWorkflowExperiment, {
  evaluateWorkflowAssertion,
  evaluateWorkflowForbidden,
  workflowExpectsOnlySilence,
} from "./slack-agent-workflows.exp";
import { SlackWorkflowDatasetItem } from "./workflow-dataset";
import {
  observeUnaddressedTurnThroughSilenceHorizon,
  reconcileFinalTurnReplies,
  type SlackWorkflowResult,
} from "./workflow-shared";
import {
  createSlackEvaluationTools,
  type SlackWebClient,
} from "@evalens/adapters/slack";

describe("Slack Agent workflow experiment", () => {
  test("validates a secret-free workflow fixture without extra item fields", () => {
    const item = {
      id: "workflow-schema-fixture",
      input: {
        slackSetup: [],
        slackTurns: [
          { action: "post_user_mention", alias: "request", text: "Summarize this" },
        ],
      },
      expected: {
        externalAssertions: [
          { kind: "turn_input_observed", target: "request", value: true },
        ],
        semanticCriteria: ["The reply summarizes the request"],
        forbiddenOutcomes: [{ kind: "duplicate_thread_reply" }],
      },
    };
    SlackWorkflowDatasetItem.parse(item);
    expect(Object.keys(item).sort()).toEqual(["expected", "id", "input"]);
  });

  test("requires real Slack bot authorship evidence", () => {
    const result = workflowResult({
      turns: [
        {
          alias: "bot_request",
          action: "post_other_app_mention",
          source: "other_app_bot",
          authorBotId: "B_DRIVER",
          ts: "1.0",
          threadTs: "1.0",
          inputObserved: true,
          replies: [],
        },
      ],
      triggerObserved: {
        ts: "1.0",
        text: "request",
        botId: "B_DRIVER",
        files: [],
        reactions: [],
      },
    });
    expect(
      evaluateWorkflowAssertion(
        { kind: "trigger_authored_by_bot", target: "bot_request" },
        result
      )
    ).toBe(true);
    expect(
      evaluateWorkflowAssertion(
        { kind: "trigger_authored_by_bot", target: "bot_request" },
        { ...result, triggerObserved: { ...result.triggerObserved!, botId: undefined } }
      )
    ).toBe(false);
  });

  test("detects duplicate and unsolicited replies deterministically", () => {
    const duplicate = observedReply("2.0", "done");
    const result = workflowResult({
      threadReplies: [duplicate, observedReply("3.0", " done ")],
    });
    expect(
      evaluateWorkflowAssertion({ kind: "no_duplicate_thread_replies" }, result)
    ).toBe(false);
    expect(
      evaluateWorkflowForbidden({ kind: "duplicate_thread_reply" }, result, [])
    ).toBe(true);
    expect(
      evaluateWorkflowForbidden({ kind: "unsolicited_agent_reply" }, result, [])
    ).toBe(true);
  });

  test("does not call equal replies in different threads duplicates", () => {
    const result = workflowResult({
      threadReplies: [
        { ...observedReply("2.0", "done"), threadTs: "1.0" },
        { ...observedReply("4.0", "done"), threadTs: "3.0" },
      ],
    });

    expect(
      evaluateWorkflowForbidden({ kind: "duplicate_thread_reply" }, result, [])
    ).toBe(false);
  });

  test("scores silence only from replies in the trigger thread", () => {
    const result = workflowResult({
      turns: [
        {
          alias: "ordinary_message",
          action: "post_user_message",
          source: "driver_user",
          ts: "1.0",
          threadTs: "1.0",
          inputObserved: true,
          replies: [],
        },
      ],
    });
    expect(
      evaluateWorkflowForbidden({ kind: "unsolicited_agent_reply" }, result, [])
    ).toBe(false);
  });

  test("does not let a missing turn satisfy a false input observation", () => {
    expect(
      evaluateWorkflowAssertion(
        { kind: "turn_input_observed", target: "missing_turn", value: false },
        workflowResult()
      )
    ).toBe(false);
  });

  test("counts replies on the named turn without treating a mixed workflow as silence", () => {
    const addressedReply = observedReply("2.0", "done");
    const result = workflowResult({
      threadReplies: [addressedReply],
      turns: [
        {
          alias: "request",
          action: "post_user_mention",
          source: "driver_user",
          ts: "1.0",
          threadTs: "1.0",
          inputObserved: true,
          replies: [addressedReply],
        },
        {
          alias: "chatter",
          action: "post_user_message",
          source: "driver_user",
          ts: "3.0",
          threadTs: "3.0",
          inputObserved: false,
          replies: [],
        },
      ],
    });
    const item = SlackWorkflowDatasetItem.parse({
      id: "mixed-replies",
      input: {
        slackSetup: [],
        slackTurns: [
          { action: "post_user_mention", alias: "request", text: "help" },
          { action: "post_user_message", alias: "chatter", text: "aside" },
        ],
      },
      expected: {
        externalAssertions: [
          { kind: "thread_reply_count", target: "request", value: 1 },
          { kind: "thread_reply_count", target: "chatter", value: 0 },
        ],
        semanticCriteria: ["The request is answered"],
        forbiddenOutcomes: [],
      },
    });

    expect(
      evaluateWorkflowAssertion(
        { kind: "thread_reply_count", target: "request", value: 1 },
        result
      )
    ).toBe(true);
    expect(
      evaluateWorkflowAssertion(
        { kind: "thread_reply_count", target: "chatter", value: 0 },
        result
      )
    ).toBe(true);
    expect(
      evaluateWorkflowAssertion(
        { kind: "thread_reply_count", target: "missing", value: 0 },
        result
      )
    ).toBe(false);
    expect(workflowExpectsOnlySilence(item)).toBe(false);
  });

  test("reconciles a delayed final reply into the final turn observation", () => {
    const interim = observedReply("2.0", "working");
    const correction = observedReply("3.0", "corrected result");
    const turns = reconcileFinalTurnReplies(
      [
        {
          alias: "request",
          action: "post_user_mention",
          source: "driver_user",
          ts: "1.0",
          threadTs: "1.0",
          inputObserved: true,
          replies: [interim],
        },
      ],
      [interim, correction]
    );

    expect(turns[0]?.replies.map((reply) => reply.text)).toEqual([
      "working",
      "corrected result",
    ]);
  });

  test("attributes a reply in an unaddressed top-level message's own thread", () => {
    const unwanted = { ...observedReply("4.0", "unsolicited"), threadTs: "3.0" };
    const turns = reconcileFinalTurnReplies(
      [
        {
          alias: "request",
          action: "post_user_mention",
          source: "driver_user",
          ts: "1.0",
          threadTs: "1.0",
          inputObserved: true,
          replies: [observedReply("2.0", "done")],
        },
        {
          alias: "chatter",
          action: "post_user_message",
          source: "driver_user",
          ts: "3.0",
          threadTs: "3.0",
          inputObserved: false,
          replies: [],
        },
      ],
      [{ ...observedReply("2.0", "done"), threadTs: "1.0" }, unwanted]
    );

    expect(turns[0]?.replies.map((reply) => reply.text)).toEqual(["done"]);
    expect(turns[1]?.replies.map((reply) => reply.text)).toEqual(["unsolicited"]);
  });

  test("keeps an unaddressed top-level message silent when its thread has no reply", () => {
    const turns = reconcileFinalTurnReplies(
      [
        {
          alias: "chatter",
          action: "post_user_message",
          source: "driver_user",
          ts: "3.0",
          threadTs: "3.0",
          inputObserved: false,
          replies: [],
        },
      ],
      []
    );

    expect(turns[0]?.replies).toEqual([]);
  });

  test("observes a delayed unsolicited reply through the full silence horizon", async () => {
    const startedAt = Date.now();
    const slack = createSlackEvaluationTools(
      {
        token: "xoxp-driver",
        workspaceId: "T_EVAL",
        allowedChannelIds: ["C_EVAL"],
        expectedUserId: "U_DRIVER",
        pollMs: 5,
      },
      {
        auth: { test: async () => ({ ok: true }) },
        chat: {
          postMessage: async () => ({ ok: true, channel: "C_EVAL", ts: "0.0" }),
        },
        conversations: {
          replies: async () => ({
            ok: true,
            messages: [
              { ts: "3.0", user: "U_DRIVER", text: "ordinary message" },
              ...(Date.now() - startedAt >= 20
                ? [
                    {
                      ts: "4.0",
                      thread_ts: "3.0",
                      user: "U_AGENT",
                      text: "unsolicited",
                    },
                  ]
                : []),
            ],
          }),
        },
      } satisfies SlackWebClient
    );

    const observed = await observeUnaddressedTurnThroughSilenceHorizon({
      observer: slack.observer,
      channelId: "C_EVAL",
      threadTs: "3.0",
      salixBotUserId: "U_AGENT",
      silenceObservationMs: 50,
      waitForInput: async () => true,
    });

    expect(Date.now() - startedAt).toBeGreaterThanOrEqual(45);
    expect(observed.inputObserved).toBe(true);
    expect(observed.replies.map((reply) => reply.text)).toEqual(["unsolicited"]);

    const result = workflowResult({
      threadReplies: observed.replies,
      turns: [
        {
          alias: "chatter",
          action: "post_user_message",
          source: "driver_user",
          ts: "3.0",
          threadTs: "3.0",
          inputObserved: observed.inputObserved,
          replies: observed.replies,
        },
      ],
    });
    expect(
      evaluateWorkflowAssertion(
        { kind: "thread_reply_count", target: "chatter", value: 0 },
        result
      )
    ).toBe(false);
  });

  test("returns zero aggregate for no completed workflow evaluations", () => {
    expect(slackWorkflowExperiment.aggregator.aggregate({})).toEqual({
      workflow_success_rate: 0,
      delivery_rate: 0,
      external_assertions_mean: 0,
      safety_mean: 0,
      semantic_mean: 0,
    });
  });

  test("scores evaluator errors as failures instead of dropping the item", () => {
    expect(
      slackWorkflowExperiment.aggregator.aggregate({
        "slack-workflow-deterministic": [
          {
            itemId: "complete",
            score: { delivery: 1, external_assertions: 1, safety: 1 },
            explanation: "complete",
          },
          {
            itemId: "semantic-error",
            score: { delivery: 1, external_assertions: 1, safety: 1 },
            explanation: "semantic evaluator did not complete",
          },
        ],
        "slack-workflow-semantic": [
          { itemId: "complete", score: { semantic: 1, semantic_pass: 1 } },
        ],
      })
    ).toEqual({
      workflow_success_rate: 0.5,
      delivery_rate: 1,
      external_assertions_mean: 1,
      safety_mean: 1,
      semantic_mean: 0.5,
    });
  });
});

function workflowResult(
  overrides: Partial<SlackWorkflowResult> = {}
): SlackWorkflowResult {
  return {
    driverUserId: "U_DRIVER",
    salixBotUserId: "U_AGENT",
    salixBotId: "B_AGENT",
    trigger: { channelId: "C_EVAL", ts: "1.0", text: "request" },
    execution: { inputObserved: false, settled: true, timedOut: false },
    setupResources: {},
    threadReplies: [],
    threadFiles: [],
    targetMessages: {},
    createdMessages: [],
    pinnedMessageTimestamps: [],
    operations: [],
    attachmentReads: [],
    directMessages: [],
    cleanupErrors: [],
    turns: [],
    ...overrides,
  };
}

function observedReply(ts: string, text: string) {
  return {
    ts,
    text,
    userId: "U_AGENT",
    threadTs: "1.0",
    files: [],
    reactions: [],
  };
}
