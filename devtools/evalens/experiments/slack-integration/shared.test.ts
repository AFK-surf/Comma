import { describe, expect, test } from "bun:test";

import {
  assertHumanSlackDriver,
  assertDistinctSlackApps,
  assertNoSlackInfrastructureErrors,
  collectDirectMessages,
  extractSlackTrajectoryEvidence,
  renderSlackTrigger,
} from "./shared";
import {
  createSlackEvaluationTools,
  type SlackWebClient,
} from "@evalens/adapters/slack";
import {
  SlackProviderActionDatasetItem,
  type SlackProviderExternalAssertion,
} from "./dataset";
import { evaluateExternalAssertion } from "./provider-action-evaluation";
import type { SlackProviderActionResult } from "./shared";

describe("Slack integration experiment helpers", () => {
  test("validates a secret-free provider action fixture", () => {
    expect(() =>
      SlackProviderActionDatasetItem.parse(providerDatasetFixture())
    ).not.toThrow();
  });

  test("rejects missing or coerced assertion fields at dataset load time", () => {
    const item = providerDatasetFixture();

    expect(() =>
      SlackProviderActionDatasetItem.parse({
        ...item,
        expected: {
          ...item.expected,
          externalAssertions: [{ kind: "pin_state", target: "thread_root" }],
        },
      })
    ).toThrow();

    expect(() =>
      SlackProviderActionDatasetItem.parse({
        ...item,
        expected: {
          ...item.expected,
          externalAssertions: [
            { kind: "pin_state", target: "thread_root", present: "true" },
          ],
        },
      })
    ).toThrow();
  });

  test("resolves only setup permalink references", () => {
    expect(
      renderSlackTrigger("read {{source.permalink}}", {
        source: {
          type: "message",
          channelId: "C_EVAL",
          ts: "100.1",
          text: "fixture",
          permalink: "https://example.slack.com/archives/C_EVAL/p1001",
        },
      })
    ).toBe("read https://example.slack.com/archives/C_EVAL/p1001");

    expect(() => renderSlackTrigger("read {{missing.permalink}}", {})).toThrow(
      "unavailable permalink"
    );
  });

  test("rejects a driver token issued by the Salix Slack app", () => {
    expect(() => assertDistinctSlackApps("B_SALIX", "B_SALIX")).toThrow(
      "different Slack app"
    );
    expect(() => assertDistinctSlackApps("B_DRIVER", "B_SALIX")).not.toThrow();
  });

  test("requires the primary Slack driver to be a human user", () => {
    expect(() => assertHumanSlackDriver({ userId: "U_DRIVER" })).not.toThrow();
    expect(() =>
      assertHumanSlackDriver({ userId: "U_BOT", botId: "B_DRIVER" })
    ).toThrow("human user");
  });

  test("extracts Slack operations and provider errors from the Agent trajectory", () => {
    const evidence = extractSlackTrajectoryEvidence(
      {
        id: "agent:main",
        steps: [
          {
            type: "user",
            content: "do it",
            timestamp: new Date(0),
          },
          {
            type: "tool_call",
            id: "call-1",
            name: "call_im_provider_api",
            arguments: { operation: "slack.add_reaction", name: "eyes" },
            timestamp: new Date(1),
          },
          {
            type: "tool_result",
            toolCallId: "call-1",
            name: "call_im_provider_api",
            output: { error: "missing_scope" },
            timestamp: new Date(2),
          },
          {
            type: "assistant",
            content: "I could not add it.",
            timestamp: new Date(3),
          },
          {
            type: "tool_call",
            id: "read-1",
            name: "fs.read_file",
            arguments: { path: "/slack/attachments/source.txt" },
            timestamp: new Date(3),
          },
          {
            type: "tool_result",
            toolCallId: "read-1",
            name: "fs.read_file",
            output: "attachment content",
            timestamp: new Date(3),
          },
          {
            type: "tool_call",
            id: "help-1",
            name: "help",
            arguments: { tool: "im_api.slack.post_message" },
            timestamp: new Date(4),
          },
          {
            type: "tool_result",
            toolCallId: "help-1",
            name: "help",
            output: { manual: "not an operation" },
            timestamp: new Date(5),
          },
        ],
      },
      "do it"
    );

    expect(evidence.inputObserved).toBe(true);
    expect(evidence.operations).toEqual([
      {
        name: "slack.add_reaction",
        arguments: { operation: "slack.add_reaction", name: "eyes" },
        output: { error: "missing_scope" },
        succeeded: false,
      },
    ]);
    expect(evidence.providerErrors).toHaveLength(1);
    expect(evidence.attachmentReads).toEqual(["/slack/attachments/source.txt"]);
    expect(evidence.replyAttempted).toBe(true);
  });

  test("normalizes a generic call envelope into provider arguments", () => {
    const evidence = extractSlackTrajectoryEvidence({
      id: "agent:main",
      steps: [
        {
          type: "tool_call",
          id: "call-1",
          name: "call",
          arguments: {
            tool: "im_api.slack.post_message",
            params: {
              channel: "C_EVAL",
              thread_ts: "1.0",
              text: "done",
            },
          },
          timestamp: new Date(0),
        },
        {
          type: "tool_result",
          toolCallId: "call-1",
          name: "call",
          output: { channel: "C_EVAL", ts: "2.0" },
          timestamp: new Date(1),
        },
      ],
    });

    expect(evidence.operations).toEqual([
      {
        name: "slack.post_message",
        arguments: {
          channel: "C_EVAL",
          thread_ts: "1.0",
          text: "done",
        },
        output: { channel: "C_EVAL", ts: "2.0" },
        succeeded: true,
        createdResource: {
          type: "message",
          channelId: "C_EVAL",
          ts: "2.0",
          threadTs: "1.0",
        },
      },
    ]);
  });

  test("rejects malformed Slack operation arguments in the trajectory", () => {
    expect(() =>
      extractSlackTrajectoryEvidence({
        id: "agent:main",
        steps: [
          {
            type: "tool_call",
            id: "call-1",
            name: "call_im_provider_api",
            arguments: "not-json",
            timestamp: new Date(0),
          },
        ],
      })
    ).toThrow("Slack operation arguments are malformed");
  });

  test("matches Slack-autolinked input against the posted permalink", () => {
    const evidence = extractSlackTrajectoryEvidence(
      {
        id: "agent:main",
        steps: [
          {
            type: "user",
            content:
              "Slack app_mention:\n<@U_AGENT> read <https://example.slack.com/archives/C_EVAL/p1001> &amp; summarize",
            timestamp: new Date(0),
          },
        ],
      },
      "<@U_AGENT> read https://example.slack.com/archives/C_EVAL/p1001 & summarize"
    );

    expect(evidence.inputObserved).toBe(true);
  });

  test("does not classify words in successful Slack response content as errors", () => {
    const evidence = extractSlackTrajectoryEvidence({
      id: "agent:main",
      steps: [
        {
          type: "tool_call",
          id: "read-1",
          name: "call_im_provider_api",
          arguments: { operation: "slack.get_channel_history", channel: "C_EVAL" },
          timestamp: new Date(0),
        },
        {
          type: "tool_result",
          toolCallId: "read-1",
          name: "call_im_provider_api",
          output: JSON.stringify({
            messages: [
              {
                ts: "1.0",
                text: "The previous deployment failed; use the new plan.",
              },
            ],
          }),
          timestamp: new Date(1),
        },
      ],
    });

    expect(evidence.providerErrors).toEqual([]);
    expect(evidence.operations[0]?.succeeded).toBe(true);
  });

  test("classifies a structured tool failure even when its output is neutral", () => {
    const evidence = extractSlackTrajectoryEvidence({
      id: "agent:main",
      steps: [
        {
          type: "tool_call",
          id: "read-1",
          name: "call_im_provider_api",
          arguments: { operation: "slack.get_channel_history", channel: "C_EVAL" },
          timestamp: new Date(0),
        },
        {
          type: "tool_result",
          toolCallId: "read-1",
          name: "call_im_provider_api",
          output: { requestId: "req-1" },
          status: "error",
          errorClass: "transport_error",
          timestamp: new Date(1),
        },
      ],
    });

    expect(evidence.providerErrors).toEqual(["transport_error"]);
    expect(evidence.operations[0]?.succeeded).toBe(false);
  });

  test("rejects malformed structured Slack operation results", () => {
    expect(() =>
      extractSlackTrajectoryEvidence({
        id: "agent:main",
        steps: [
          {
            type: "tool_call",
            id: "read-1",
            name: "call_im_provider_api",
            arguments: {
              operation: "slack.get_channel_history",
              channel: "C_EVAL",
            },
            timestamp: new Date(0),
          },
          {
            type: "tool_result",
            toolCallId: "read-1",
            name: "call_im_provider_api",
            output: [],
            timestamp: new Date(1),
          },
        ],
      })
    ).toThrow("Slack operation result is malformed");
  });

  test("observes only a verified driver DM through its returned DM channel", async () => {
    const observedChannels: string[] = [];
    const slack = createSlackEvaluationTools(
      {
        token: "xoxp-driver",
        workspaceId: "T_EVAL",
        allowedChannelIds: ["C_EVAL"],
        expectedUserId: "U_DRIVER",
        pollMs: 100,
      },
      {
        auth: {
          test: async () => ({ ok: true, team_id: "T_EVAL", user_id: "U_DRIVER" }),
        },
        chat: {
          postMessage: async ({ channel }) => ({ ok: true, channel, ts: "1.0" }),
        },
        conversations: {
          replies: async () => ({ ok: true, messages: [] }),
          history: async (input) => {
            observedChannels.push(String(input.channel));
            return {
              ok: true,
              messages: [
                {
                  ts: "2.0",
                  user: "U_AGENT",
                  text: "private result",
                },
              ],
            };
          },
        },
      } satisfies SlackWebClient
    );
    const operation = {
      name: "slack.send_dm",
      arguments: { user_id: "U_DRIVER", text: "private result" },
      output: JSON.stringify({ channel: "D_DRIVER", ts: "2.0" }),
      succeeded: true,
    };

    const messages = await collectDirectMessages(slack, [operation], "U_DRIVER");
    expect(observedChannels).toEqual(["D_DRIVER"]);
    expect(messages.map((message) => message.text)).toEqual(["private result"]);

    expect(
      await collectDirectMessages(
        slack,
        [{ ...operation, arguments: { user_id: "U_OTHER" } }],
        "U_DRIVER"
      )
    ).toEqual([]);
    expect(observedChannels).toEqual(["D_DRIVER"]);
  });

  test("classifies Slack credential and scope failures as run errors", () => {
    expect(() =>
      assertNoSlackInfrastructureErrors(["Slack API error: missing_scope"])
    ).toThrow("infrastructure error");
    expect(() =>
      assertNoSlackInfrastructureErrors(["Slack API error: invalid_auth"])
    ).toThrow("infrastructure error");
    expect(() =>
      assertNoSlackInfrastructureErrors(["Slack API error: cant_delete_message"])
    ).not.toThrow();
  });

  test("matches natural-language file assertions independent of case and whitespace", () => {
    const result = providerResult({
      threadFiles: [
        {
          id: "F1",
          name: "release-handoff.md",
          content: "Known risk:\nCache   warmup can add ten minutes.",
        },
      ],
    });

    expect(
      evaluateExternalAssertion(
        {
          kind: "thread_file_matches",
          filename: "release-handoff.md",
          contains: ["cache warmup"],
        },
        result
      )
    ).toBe(true);
  });

  test("requires an attempted provider failure before scoring acknowledgement", () => {
    const result = providerResult({
      threadReplies: [
        {
          ts: "2.0",
          text: "I could not remove it.",
          userId: "U_AGENT",
          threadTs: "1.0",
          files: [],
          reactions: [],
        },
      ],
      operations: [],
    });
    const assertion = {
      kind: "provider_failure_acknowledged",
      operation: "remove_reaction",
    } as const;

    expect(evaluateExternalAssertion(assertion, result)).toBe(false);
    result.operations.push({
      name: "slack.remove_reaction",
      arguments: {},
      output: { error: "no_reaction" },
      succeeded: false,
    });
    expect(evaluateExternalAssertion(assertion, result)).toBe(true);
  });

  test("does not treat an unobserved target as an absent reaction", () => {
    expect(
      evaluateExternalAssertion(
        {
          kind: "reaction_state",
          target: "missing_message",
          name: "eyes",
          present: false,
        },
        providerResult()
      )
    ).toBe(false);
  });

  test("binds thread, permalink, and attachment reads to their setup targets", () => {
    const result = providerResult({
      setupResources: {
        thread_a: {
          type: "message",
          channelId: "C_EVAL",
          ts: "1.0",
          text: "A",
        },
        message_a: {
          type: "message",
          channelId: "C_EVAL",
          ts: "2.0",
          text: "A",
        },
        file_a: {
          type: "file",
          channelId: "C_EVAL",
          fileId: "F_A",
          filename: "a.txt",
        },
      },
      operations: [
        {
          name: "slack.get_thread_replies",
          arguments: { channel: "C_EVAL", ts: "9.0" },
          succeeded: true,
          targetResource: { type: "message", channelId: "C_EVAL", ts: "9.0" },
        },
        {
          name: "slack.get_channel_history",
          arguments: { channel: "C_EVAL", oldest: "9.0", latest: "9.0" },
          succeeded: true,
          targetResource: { type: "message", channelId: "C_EVAL", ts: "9.0" },
        },
        {
          name: "slack.fetch_file",
          arguments: { file_id: "F_B" },
          succeeded: true,
          targetResource: { type: "file", fileId: "F_B" },
        },
      ],
    });

    expect(
      evaluateExternalAssertion(
        { kind: "thread_read_observed", target: "thread_a" },
        result
      )
    ).toBe(false);
    expect(
      evaluateExternalAssertion(
        { kind: "permalink_read_observed", target: "message_a" },
        result
      )
    ).toBe(false);
    expect(
      evaluateExternalAssertion(
        { kind: "attachment_fetch_observed", target: "file_a" },
        result
      )
    ).toBe(false);

    result.operations[0]!.targetResource = {
      type: "message",
      channelId: "C_EVAL",
      ts: "1.0",
    };
    result.operations[1]!.targetResource = {
      type: "message",
      channelId: "C_EVAL",
      ts: "2.0",
    };
    result.operations[2]!.targetResource = { type: "file", fileId: "F_A" };
    expect(
      evaluateExternalAssertion(
        { kind: "thread_read_observed", target: "thread_a" },
        result
      )
    ).toBe(true);
    expect(
      evaluateExternalAssertion(
        { kind: "permalink_read_observed", target: "message_a" },
        result
      )
    ).toBe(true);
    expect(
      evaluateExternalAssertion(
        { kind: "attachment_fetch_observed", target: "file_a" },
        result
      )
    ).toBe(true);
  });

  test("does not count an empty successful history response as reading the target", () => {
    const evidence = extractSlackTrajectoryEvidence({
      id: "agent:main",
      steps: [
        {
          type: "tool_call",
          id: "read-1",
          name: "call_im_provider_api",
          arguments: {
            operation: "slack.get_channel_history",
            channel: "C_EVAL",
            oldest: "2.0",
            latest: "2.0",
          },
          timestamp: new Date(0),
        },
        {
          type: "tool_result",
          toolCallId: "read-1",
          name: "call_im_provider_api",
          output: { messages: [] },
          timestamp: new Date(1),
        },
      ],
    });

    expect(evidence.operations[0]).toMatchObject({
      name: "slack.get_channel_history",
      succeeded: true,
    });
    expect(evidence.operations[0]?.targetResource).toBeUndefined();

    const result = providerResult({
      setupResources: {
        message_a: {
          type: "message",
          channelId: "C_EVAL",
          ts: "2.0",
          text: "target",
          permalink: "https://example.slack.com/archives/C_EVAL/p20",
        },
      },
      operations: evidence.operations,
    });
    expect(
      evaluateExternalAssertion(
        { kind: "permalink_read_observed", target: "message_a" },
        result
      )
    ).toBe(false);
  });

  test("scores Agent-created reaction and pin assertions from final provider state", () => {
    const created = {
      name: "slack.post_message",
      arguments: { channel: "C_EVAL", text: "status" },
      output: { channel: "C_EVAL", ts: "2.0" },
      succeeded: true,
      createdResource: {
        type: "message" as const,
        channelId: "C_EVAL",
        ts: "2.0",
      },
    };
    const result = providerResult({
      operations: [
        created,
        {
          name: "slack.add_reaction",
          arguments: { channel: "C_EVAL", ts: "2.0", name: "eyes" },
          succeeded: true,
          targetResource: { type: "message", channelId: "C_EVAL", ts: "2.0" },
        },
        {
          name: "slack.remove_reaction",
          arguments: { channel: "C_EVAL", ts: "2.0", name: "eyes" },
          succeeded: true,
          targetResource: { type: "message", channelId: "C_EVAL", ts: "2.0" },
        },
        {
          name: "slack.pin_message",
          arguments: { channel: "C_EVAL", ts: "2.0" },
          succeeded: true,
          targetResource: { type: "message", channelId: "C_EVAL", ts: "2.0" },
        },
        {
          name: "slack.unpin_message",
          arguments: { channel: "C_EVAL", ts: "2.0" },
          succeeded: true,
          targetResource: { type: "message", channelId: "C_EVAL", ts: "2.0" },
        },
      ],
      createdMessages: [
        {
          channelId: "C_EVAL",
          message: {
            ts: "2.0",
            text: "status",
            files: [],
            reactions: [],
          },
        },
      ],
      pinnedMessageTimestamps: [],
    });

    expect(
      evaluateExternalAssertion(
        { kind: "created_message_reaction_state", text: "status", name: "eyes" },
        result
      )
    ).toBe(false);
    expect(
      evaluateExternalAssertion(
        { kind: "created_message_pin_state", text: "status" },
        result
      )
    ).toBe(false);

    result.createdMessages[0]!.message.reactions.push({
      name: "eyes",
      userIds: ["U_AGENT"],
    });
    result.pinnedMessageTimestamps.push("2.0");
    expect(
      evaluateExternalAssertion(
        { kind: "created_message_reaction_state", text: "status", name: "eyes" },
        result
      )
    ).toBe(true);
    expect(
      evaluateExternalAssertion(
        { kind: "created_message_pin_state", text: "status" },
        result
      )
    ).toBe(true);
  });

  test("does not attribute another actor's reaction to the Agent", () => {
    const result = providerResult({
      operations: [
        {
          name: "slack.post_message",
          arguments: { channel: "C_EVAL", text: "status" },
          output: { channel: "C_EVAL", ts: "2.0" },
          succeeded: true,
          createdResource: {
            type: "message",
            channelId: "C_EVAL",
            ts: "2.0",
          },
        },
        {
          name: "slack.add_reaction",
          arguments: { channel: "C_EVAL", ts: "2.0", name: "eyes" },
          succeeded: true,
          targetResource: { type: "message", channelId: "C_EVAL", ts: "2.0" },
        },
      ],
      createdMessages: [
        {
          channelId: "C_EVAL",
          message: {
            ts: "2.0",
            text: "status",
            files: [],
            reactions: [{ name: "eyes", userIds: ["U_OTHER"] }],
          },
        },
      ],
    });

    expect(
      evaluateExternalAssertion(
        { kind: "created_message_reaction_state", text: "status", name: "eyes" },
        result
      )
    ).toBe(false);
  });

  test("requires chained message operations to target the created message", () => {
    const result = providerResult({
      operations: [
        {
          name: "slack.post_message",
          arguments: { channel: "C_EVAL", text: "draft" },
          output: { channel: "C_EVAL", ts: "2.0" },
          succeeded: true,
          createdResource: {
            type: "message",
            channelId: "C_EVAL",
            ts: "2.0",
          },
        },
        {
          name: "slack.update_message",
          arguments: { channel: "C_EVAL", ts: "3.0", text: "final" },
          output: { ok: true },
          succeeded: true,
          targetResource: {
            type: "message",
            channelId: "C_EVAL",
            ts: "3.0",
          },
        },
      ],
    });
    const assertion = {
      kind: "message_created_then_updated",
      initialText: "draft",
      finalText: "final",
    } as const;

    expect(evaluateExternalAssertion(assertion, result)).toBe(false);
    result.operations[1]!.targetResource = {
      type: "message",
      channelId: "C_EVAL",
      ts: "2.0",
    };
    expect(evaluateExternalAssertion(assertion, result)).toBe(true);
  });

  test("requires Canvas edits to target the created Canvas", () => {
    const result = providerResult({
      operations: [
        {
          name: "slack.create_canvas",
          arguments: { title: "Release", content: "Risk" },
          output: { canvas_id: "CANVAS-1" },
          succeeded: true,
          createdResource: { type: "canvas", canvasId: "CANVAS-1" },
        },
        {
          name: "slack.edit_canvas",
          arguments: { canvas_id: "CANVAS-2", content: "Mitigation" },
          output: { ok: true },
          succeeded: true,
          targetResource: { type: "canvas", canvasId: "CANVAS-2" },
        },
      ],
    });
    const assertion: SlackProviderExternalAssertion = {
      kind: "canvas_created_then_edited",
      title: "Release",
      contains: ["Risk", "Mitigation"],
    };

    expect(evaluateExternalAssertion(assertion, result)).toBe(false);
    result.operations[1]!.targetResource = {
      type: "canvas",
      canvasId: "CANVAS-1",
    };
    expect(evaluateExternalAssertion(assertion, result)).toBe(true);
  });
});

function providerResult(
  overrides: Partial<SlackProviderActionResult> = {}
): SlackProviderActionResult {
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
    ...overrides,
  };
}

function providerDatasetFixture() {
  return {
    id: "provider-action-schema-fixture",
    input: {
      slackSetup: [],
      slackTrigger: { text: "Pin the message" },
    },
    expected: {
      externalAssertions: [
        { kind: "pin_state" as const, target: "thread_root", present: true },
      ],
      semanticCriteria: ["The Agent acknowledges the result"],
      forbiddenOutcomes: [{ kind: "secret_disclosure" as const }],
    },
  };
}
