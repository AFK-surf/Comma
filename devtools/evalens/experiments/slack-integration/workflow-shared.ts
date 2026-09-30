import { type Salix, SalixAdapter } from "@evalens/adapters/salix";
import {
  createSlackEvaluationTools,
  type SlackEvaluationTools,
  type SlackObservedMessage,
  type SlackPostedMessage,
} from "@evalens/adapters/slack";
import type { EvalensLogger, Trajectory } from "@evalens/core";
import { z } from "zod";

import type { SlackProviderActionDatasetItem } from "./dataset";
import {
  assertDistinctSlackApps,
  assertHumanSlackDriver,
  assertNoSlackInfrastructureErrors,
  cleanupSlackResources,
  collectAgentCreatedMessages,
  collectDirectMessages,
  collectSetupTargetMessages,
  collectThreadFiles,
  emptySetupState,
  executeSlackSetup,
  extractSlackTrajectoryEvidence,
  renderSlackTrigger,
  runSlackProviderActionItem,
  type SlackJsonObject,
  type SlackProviderActionResult,
  waitForAgentInput,
} from "./shared";
import type { SlackWorkflowDatasetItem, SlackWorkflowTurn } from "./workflow-dataset";

const ChannelSnapshotSchema = z
  .object({
    topic: z.object({ value: z.string() }).loose().optional(),
    purpose: z.object({ value: z.string() }).loose().optional(),
  })
  .loose();
const PinnedMessageSchema = z
  .object({ message: z.object({ ts: z.string().min(1) }).loose() })
  .loose();

export type SlackWorkflowTurnResult = {
  alias: string;
  action: SlackWorkflowTurn["action"] | "post_user_mention";
  source: "driver_user" | "other_app_bot";
  ts: string;
  threadTs: string;
  authorBotId?: string;
  inputObserved: boolean;
  replies: SlackObservedMessage[];
};

export type SlackWorkflowResult = SlackProviderActionResult & {
  turns: SlackWorkflowTurnResult[];
  triggerObserved?: SlackObservedMessage;
};

export async function runSlackWorkflowItem(input: {
  item: SlackWorkflowDatasetItem;
  salix: SalixAdapter;
  slack: SlackEvaluationTools;
  otherAppDriver?: SlackEvaluationTools;
  prepared: Salix.PreparedRun;
  channelId: string;
  agentTimeoutMs: number;
  slackSettleMs: number;
  silenceObservationMs: number;
  slackConnectFixture: Readonly<Salix.AppIntegrationConfig>;
  logger: EvalensLogger;
}): Promise<{
  result: SlackWorkflowResult;
  trajectory: Trajectory;
  artifacts: Bun.Archive;
}> {
  if ("slackTrigger" in input.item.input) {
    const providerAction = await runSlackProviderActionItem({
      ...input,
      item: input.item as SlackProviderActionDatasetItem,
    });
    return {
      ...providerAction,
      result: {
        ...providerAction.result,
        turns: [
          {
            alias: "request",
            action: "post_user_mention",
            source: "driver_user",
            ts: providerAction.result.trigger.ts,
            threadTs: providerAction.result.trigger.ts,
            inputObserved: providerAction.result.execution.inputObserved,
            replies: providerAction.result.threadReplies,
          },
        ],
      },
    };
  }

  return runSequenceItem(input);
}

async function runSequenceItem(input: {
  item: SlackWorkflowDatasetItem;
  salix: SalixAdapter;
  slack: SlackEvaluationTools;
  otherAppDriver?: SlackEvaluationTools;
  prepared: Salix.PreparedRun;
  channelId: string;
  agentTimeoutMs: number;
  slackSettleMs: number;
  silenceObservationMs: number;
  slackConnectFixture: Readonly<Salix.AppIntegrationConfig>;
  logger: EvalensLogger;
}) {
  if (!("slackTurns" in input.item.input)) {
    throw new Error("Slack workflow sequence is missing slackTurns");
  }
  input.slack.driver.assertAllowedChannel(input.channelId);
  const needsOtherAppDriver = input.item.input.slackTurns.some(
    (turn) => turn.action === "post_other_app_mention"
  );
  const otherAppDriver = input.otherAppDriver;
  if (needsOtherAppDriver && !otherAppDriver) {
    throw new Error(
      "slack.otherAppDriver adapter config is required for other-App-authored workflow turns"
    );
  }
  otherAppDriver?.driver.assertAllowedChannel(input.channelId);
  const driverUserIdentity = await input.slack.driver.preflight();
  assertHumanSlackDriver(driverUserIdentity);
  const otherAppBotIdentity = needsOtherAppDriver
    ? await otherAppDriver?.driver.preflight()
    : undefined;
  const routerAgentId = input.prepared.routerAgentId;
  if (!routerAgentId) throw new Error("Slack workflow missing routerAgentId");
  const routerSessionId = input.prepared.routerSessionId;
  if (!routerSessionId) throw new Error("Slack workflow missing routerSessionId");
  const materializationReceipt = await input.salix.integrations.materializeFixture({
    run: input.prepared,
    inboundAgentId: routerAgentId,
    integration: input.slackConnectFixture,
  });
  if (materializationReceipt.materializationKind !== "im_connect") {
    throw new Error("Slack integration did not materialize an IM connect");
  }
  const slackConnect = materializationReceipt.imConnect;
  if (
    slackConnect.workspaceId !== driverUserIdentity.workspaceId ||
    (otherAppBotIdentity &&
      slackConnect.workspaceId !== otherAppBotIdentity.workspaceId)
  ) {
    throw new Error(
      "Slack driver user, other App bot, and Salix bot must share a workspace"
    );
  }
  assertDistinctSlackApps(driverUserIdentity.botId, slackConnect.botId);
  if (otherAppBotIdentity) {
    assertDistinctSlackApps(otherAppBotIdentity.botId, slackConnect.botId);
  }
  if (needsOtherAppDriver && !otherAppBotIdentity?.botId) {
    throw new Error("otherAppDriver must authenticate as a Slack bot");
  }
  const otherAppBotId = otherAppBotIdentity?.botId;

  const {
    expectedUserId: _expectedUserId,
    otherAppDriver: _otherAppDriver,
    ...sharedSlackConfig
  } = input.slack.config;
  const salixBotClient = createSlackEvaluationTools({
    ...sharedSlackConfig,
    token: input.slackConnectFixture.credentials.botToken,
  });
  await salixBotClient.observer.assertChannelMember(input.channelId);
  const setup = emptySetupState();
  const cleanupErrors: string[] = [];
  const turns: SlackWorkflowTurnResult[] = [];
  let beforeChannel: SlackJsonObject | undefined;
  let root: SlackPostedMessage | undefined;
  const postedTurns: Array<{
    adapter: SlackEvaluationTools;
    channelId: string;
    ts: string;
  }> = [];
  let operations = [] as SlackWorkflowResult["operations"];
  let threadReplies: SlackObservedMessage[] = [];
  let latestSettled: Awaited<ReturnType<SalixAdapter["sessions"]["waitForSettled"]>> = {
    settled: true,
    elapsedMs: 0,
  };
  let completed:
    | { result: SlackWorkflowResult; trajectory: Trajectory; traceJson: string }
    | undefined;

  try {
    beforeChannel = await input.slack.observer.channelInfo(input.channelId);
    await executeSlackSetup(
      input.slack,
      input.channelId,
      input.item.input.slackSetup,
      setup
    );

    for (const turn of input.item.input.slackTurns) {
      const targetTurn =
        turn.action === "post_user_thread_reply"
          ? turns.find((candidate) => candidate.alias === turn.target)
          : undefined;
      if (turn.action === "post_user_thread_reply" && !targetTurn) {
        throw new Error(
          `Slack workflow turn ${turn.alias} targets an unavailable turn: ${turn.target}`
        );
      }
      const baseline = await input.salix.sessions.collectAgentSession({
        agentId: routerAgentId,
        sessionId: routerSessionId,
      });
      const existingReplyIds = new Set(
        targetTurn
          ? (
              await input.slack.observer.readThread({
                channelId: input.channelId,
                threadTs: targetTurn.threadTs,
              })
            )
              .filter((message) => message.userId === slackConnect.botUserId)
              .map((message) => message.ts)
          : []
      );
      const prompt = `${renderSlackTrigger(turn.text, setup.resources)} send by codex`;
      const posted = await postTurn({
        turn,
        prompt,
        threadTs: targetTurn?.threadTs,
        channelId: input.channelId,
        salixBotUserId: slackConnect.botUserId,
        slack: input.slack,
        otherAppDriver,
      });
      const postedBy =
        turn.action === "post_other_app_mention" ? otherAppDriver : input.slack;
      if (!postedBy) {
        throw new Error("Slack workflow other-App driver is unavailable");
      }
      postedTurns.push({
        adapter: postedBy,
        channelId: posted.channelId,
        ts: posted.ts,
      });
      root ??= posted;
      const threadTs = targetTurn?.threadTs ?? posted.ts;
      const addressed = turn.action !== "post_user_message";
      let inputObserved: boolean;
      let replies: SlackObservedMessage[];
      if (addressed) {
        inputObserved = await waitForAgentInput({
          salix: input.salix,
          agentId: routerAgentId,
          sessionId: routerSessionId,
          afterMessageCount: baseline.messages.length,
          expectedText: prompt,
          timeoutMs: input.agentTimeoutMs,
        });
        replies = inputObserved
          ? await waitForNewReplies({
              slack: input.slack,
              channelId: input.channelId,
              threadTs,
              salixBotUserId: slackConnect.botUserId,
              existingReplyIds,
              timeoutMs: input.agentTimeoutMs,
              settleMs: input.slackSettleMs,
            })
          : [];
      } else {
        ({ inputObserved, replies } = await observeUnaddressedTurnThroughSilenceHorizon(
          {
            observer: input.slack.observer,
            channelId: input.channelId,
            threadTs,
            salixBotUserId: slackConnect.botUserId,
            silenceObservationMs: input.silenceObservationMs,
            waitForInput: () =>
              waitForAgentInput({
                salix: input.salix,
                agentId: routerAgentId,
                sessionId: routerSessionId,
                afterMessageCount: baseline.messages.length,
                expectedText: prompt,
                timeoutMs: input.silenceObservationMs,
              }),
          }
        ));
      }
      if (addressed && inputObserved && replies.length > 0) {
        latestSettled = await input.salix.sessions.waitForSettled({
          agentId: routerAgentId,
          sessionId: routerSessionId,
          timeoutMs: input.agentTimeoutMs,
        });
      } else if (addressed) {
        latestSettled = { settled: false, elapsedMs: 0 };
      }
      if (turn.action === "post_other_app_mention" && !otherAppBotId) {
        throw new Error("otherAppDriver must authenticate as a Slack bot");
      }
      turns.push({
        alias: turn.alias,
        action: turn.action,
        source:
          turn.action === "post_other_app_mention" ? "other_app_bot" : "driver_user",
        ts: posted.ts,
        threadTs,
        ...(turn.action === "post_other_app_mention"
          ? { authorBotId: otherAppBotId }
          : {}),
        inputObserved,
        replies,
      });
      if (addressed && replies.length === 0) break;
    }

    const { trace, trajectory } = await input.salix.sessions.collectSessionTrace({
      agentId: routerAgentId,
      sessionId: routerSessionId,
      traceLimit: 500,
    });
    const evidence = extractSlackTrajectoryEvidence(
      trajectory,
      renderSlackTrigger(input.item.input.slackTurns[0]!.text, setup.resources)
    );
    assertNoSlackInfrastructureErrors(evidence.providerErrors);
    operations = evidence.operations;
    const trigger = root;
    if (!trigger) throw new Error("Slack workflow does not have a root message");
    const observedThreads = await Promise.all(
      [...new Set(turns.map((turn) => turn.threadTs))].map(async (threadTs) => ({
        threadTs,
        messages: await input.slack.observer.readThread({
          channelId: input.channelId,
          threadTs,
        }),
      }))
    );
    threadReplies = observedThreads.flatMap(({ threadTs, messages }) =>
      messages
        .filter(
          (message) =>
            message.ts !== threadTs && message.userId === slackConnect.botUserId
        )
        .map((message) => ({
          ...message,
          threadTs: message.threadTs ?? threadTs,
        }))
    );
    const finalTurns = reconcileFinalTurnReplies(turns, threadReplies);
    const triggerObserved = observedThreads
      .find((thread) => thread.threadTs === trigger.ts)
      ?.messages.find((message) => message.ts === trigger.ts);
    const channel = ChannelSnapshotSchema.parse(
      await input.slack.observer.channelInfo(input.channelId)
    );
    const pins = await input.slack.observer.listPins(input.channelId);
    const result: SlackWorkflowResult = {
      driverUserId: driverUserIdentity.userId,
      salixBotUserId: slackConnect.botUserId,
      salixBotId: slackConnect.botId,
      trigger: {
        channelId: trigger.channelId,
        ts: trigger.ts,
        text: trigger.text,
      },
      execution: {
        inputObserved: finalTurns.some((turn) => turn.inputObserved),
        settled: latestSettled.settled,
        timedOut: finalTurns.some(
          (turn) =>
            turn.action !== "post_user_message" &&
            (!turn.inputObserved || turn.replies.length === 0)
        ),
        ...(latestSettled.status ? { status: latestSettled.status } : {}),
      },
      setupResources: setup.resources,
      threadReplies,
      threadFiles: await collectThreadFiles(input.slack, threadReplies),
      targetMessages: await collectSetupTargetMessages(input.slack, setup.resources),
      createdMessages: await collectAgentCreatedMessages(input.slack, operations),
      ...(channel.topic ? { channelTopic: channel.topic.value } : {}),
      ...(channel.purpose ? { channelPurpose: channel.purpose.value } : {}),
      pinnedMessageTimestamps: pins.flatMap((pin) => {
        const parsed = PinnedMessageSchema.safeParse(pin);
        return parsed.success ? [parsed.data.message.ts] : [];
      }),
      operations,
      attachmentReads: evidence.attachmentReads,
      directMessages: await collectDirectMessages(
        input.slack,
        operations,
        driverUserIdentity.userId
      ),
      cleanupErrors,
      turns: finalTurns,
      ...(triggerObserved ? { triggerObserved } : {}),
    };
    completed = {
      result,
      trajectory,
      traceJson: JSON.stringify(trace, null, 2),
    };
  } finally {
    const errors = await cleanupSlackResources({
      slack: input.slack,
      salixBotClient,
      channelId: input.channelId,
      setup,
      operations,
      threadReplies,
      beforeChannel,
    });
    for (const posted of postedTurns.reverse()) {
      const error = await posted.adapter.fixtureCleaner.cleanup(() =>
        posted.adapter.fixtureCleaner.deleteMessage(posted.channelId, posted.ts)
      );
      if (error) {
        errors.push(
          `Slack cleanup failed (delete workflow message ${posted.ts}): ${error}`
        );
      }
    }
    cleanupErrors.push(...errors);
    for (const error of errors) input.logger.error(error);
  }

  if (!completed) throw new Error("Slack workflow completed without an observation");
  return {
    result: completed.result,
    trajectory: completed.trajectory,
    artifacts: new Bun.Archive({
      "slack-workflow-observation.json": JSON.stringify(completed.result, null, 2),
      "salix-trace.json": completed.traceJson,
    }),
  };
}

export function reconcileFinalTurnReplies(
  turns: SlackWorkflowTurnResult[],
  finalReplies: SlackObservedMessage[]
): SlackWorkflowTurnResult[] {
  const capturedOwners = new Map(
    turns.flatMap((turn) =>
      turn.replies.map((reply) => [reply.ts, turn.alias] as const)
    )
  );
  const repliesByTurn = new Map<string, SlackObservedMessage[]>();
  for (const reply of finalReplies) {
    const owner =
      capturedOwners.get(reply.ts) ??
      [...turns]
        .reverse()
        .find(
          (turn) =>
            turn.threadTs === (reply.threadTs ?? turn.threadTs) && turn.ts <= reply.ts
        )?.alias;
    if (!owner) continue;
    repliesByTurn.set(owner, [...(repliesByTurn.get(owner) ?? []), reply]);
  }
  return turns.map((turn) => ({
    ...turn,
    replies: repliesByTurn.get(turn.alias) ?? [],
  }));
}

export async function observeUnaddressedTurnThroughSilenceHorizon(input: {
  observer: SlackEvaluationTools["observer"];
  channelId: string;
  threadTs: string;
  salixBotUserId: string;
  silenceObservationMs: number;
  waitForInput: () => Promise<boolean>;
}): Promise<{ inputObserved: boolean; replies: SlackObservedMessage[] }> {
  const [delivery, inputObserved] = await Promise.all([
    input.observer.waitForBotReplies({
      channelId: input.channelId,
      threadTs: input.threadTs,
      botUserId: input.salixBotUserId,
      timeoutMs: input.silenceObservationMs,
      settleMs: input.silenceObservationMs,
    }),
    input.waitForInput(),
  ]);
  return { inputObserved, replies: delivery.messages };
}

async function postTurn(input: {
  turn: SlackWorkflowTurn;
  prompt: string;
  threadTs?: string;
  channelId: string;
  salixBotUserId: string;
  slack: SlackEvaluationTools;
  otherAppDriver?: SlackEvaluationTools;
}): Promise<SlackPostedMessage> {
  if (input.turn.action === "post_user_mention") {
    return input.slack.driver.postMention({
      channelId: input.channelId,
      botUserId: input.salixBotUserId,
      text: input.prompt,
    });
  }
  if (input.turn.action === "post_other_app_mention") {
    if (!input.otherAppDriver) {
      throw new Error("Slack workflow other-App driver is unavailable");
    }
    return input.otherAppDriver.driver.postMention({
      channelId: input.channelId,
      botUserId: input.salixBotUserId,
      text: input.prompt,
    });
  }
  if (input.turn.action === "post_user_message") {
    return input.slack.driver.postMessage({
      channelId: input.channelId,
      text: input.prompt,
    });
  }
  const threadTs = input.threadTs;
  if (!threadTs) throw new Error("Slack workflow does not have a target thread");
  return input.slack.driver.postThreadMessage({
    channelId: input.channelId,
    threadTs,
    text: input.prompt,
  });
}

async function waitForNewReplies(input: {
  slack: SlackEvaluationTools;
  channelId: string;
  threadTs: string;
  salixBotUserId: string;
  existingReplyIds: ReadonlySet<string>;
  timeoutMs: number;
  settleMs: number;
}): Promise<SlackObservedMessage[]> {
  const startedAt = Date.now();
  let lastReplyChangeAt: number | undefined;
  let replySignature = "";
  let replies: SlackObservedMessage[] = [];
  while (Date.now() - startedAt < input.timeoutMs) {
    replies = (await input.slack.observer.readThread(input)).filter(
      (message) =>
        message.userId === input.salixBotUserId &&
        !input.existingReplyIds.has(message.ts)
    );
    if (replies.length > 0) {
      const nextSignature = replies.map((reply) => reply.ts).join("\n");
      if (nextSignature !== replySignature) {
        replySignature = nextSignature;
        lastReplyChangeAt = Date.now();
      }
      if (
        lastReplyChangeAt !== undefined &&
        Date.now() - lastReplyChangeAt >= input.settleMs
      ) {
        return replies;
      }
    }
    await Bun.sleep(input.slack.config.pollMs);
  }
  return replies;
}
