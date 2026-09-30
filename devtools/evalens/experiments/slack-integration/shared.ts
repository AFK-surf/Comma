import { type Salix, SalixAdapter } from "@evalens/adapters/salix";
import {
  createSlackEvaluationTools,
  type SlackEvaluationTools,
  type SlackObservedMessage,
  type SlackSetupResource,
} from "@evalens/adapters/slack";
import type { EvalensLogger, Trajectory } from "@evalens/core";
import { z, type JSONType } from "zod";

import type { SlackProviderActionDatasetItem, SlackSetupAction } from "./dataset";

export type SlackJsonObject = Record<string, JSONType>;
type JsonObject = SlackJsonObject;

const JsonObjectSchema = z.record(z.string(), z.json());
const OperationArgumentsSchema = z.union([
  JsonObjectSchema,
  z.string().transform((value, context) => {
    try {
      return JsonObjectSchema.parse(JSON.parse(value));
    } catch (error) {
      context.addIssue({
        code: "custom",
        message: `Slack operation arguments are malformed: ${error instanceof Error ? error.message : String(error)}`,
      });
      return z.NEVER;
    }
  }),
]);
const ProviderResultSchema = z
  .object({ error: z.json().optional(), ok: z.boolean().optional() })
  .loose();
const ProviderOutputSchema = z
  .union([
    JsonObjectSchema,
    z.string().transform((value, context) => {
      try {
        return JsonObjectSchema.parse(JSON.parse(value));
      } catch (error) {
        context.addIssue({
          code: "custom",
          message: `Slack operation result is malformed: ${error instanceof Error ? error.message : String(error)}`,
        });
        return z.NEVER;
      }
    }),
  ])
  .transform((object) => {
    for (const key of ["result", "output", "data"] as const) {
      const nested = JsonObjectSchema.safeParse(object[key]);
      if (nested.success) return nested.data;
    }
    return object;
  });
const ProviderMessageRefSchema = ProviderOutputSchema.transform((output, context) => {
  const channelId = output.channel ?? output.channel_id;
  const ts = output.ts ?? output.message_ts;
  if (typeof channelId !== "string" || !channelId || typeof ts !== "string" || !ts) {
    context.addIssue({
      code: "custom",
      message: "Slack message operation result is missing channel or timestamp",
    });
    return z.NEVER;
  }
  return { channelId, ts };
});
const ProviderCanvasIdSchema = ProviderOutputSchema.transform((output, context) => {
  if (typeof output.canvas_id !== "string" || !output.canvas_id) {
    context.addIssue({
      code: "custom",
      message: "Slack Canvas operation result is missing canvas_id",
    });
    return z.NEVER;
  }
  return output.canvas_id;
});
const ProviderMessagesSchema = ProviderOutputSchema.transform((output, context) => {
  const parsed = z
    .array(z.object({ ts: z.string().min(1) }).loose())
    .safeParse(output.messages);
  if (!parsed.success) {
    context.addIssue({
      code: "custom",
      message: `Slack messages result is malformed: ${z.prettifyError(parsed.error)}`,
    });
    return z.NEVER;
  }
  return parsed.data;
});
const ChannelSnapshotSchema = z
  .object({
    topic: z.object({ value: z.string() }).loose().optional(),
    purpose: z.object({ value: z.string() }).loose().optional(),
  })
  .loose();
const PinnedMessageSchema = z
  .object({ message: z.object({ ts: z.string().min(1) }).loose() })
  .loose();

export type SlackOperationEvidence = {
  name: string;
  arguments: JsonObject;
  output?: JSONType;
  succeeded: boolean;
  createdResource?:
    | { type: "message"; channelId: string; ts: string; threadTs?: string }
    | { type: "canvas"; canvasId: string };
  targetResource?:
    | { type: "message"; channelId: string; ts: string }
    | { type: "file"; fileId: string }
    | { type: "canvas"; canvasId: string };
};

export type SlackTrajectoryEvidence = {
  inputObserved: boolean;
  assistantMessages: string[];
  attachmentReads: string[];
  operations: SlackOperationEvidence[];
  providerErrors: string[];
  replyAttempted: boolean;
};

export type SlackProviderActionResult = {
  driverUserId: string;
  salixBotUserId: string;
  salixBotId: string;
  trigger: { channelId: string; ts: string; text: string };
  execution: {
    inputObserved: boolean;
    settled: boolean;
    timedOut: boolean;
    status?: string;
  };
  setupResources: Record<string, SlackSetupResource>;
  threadReplies: SlackObservedMessage[];
  threadFiles: Array<{
    id: string;
    name?: string;
    mimetype?: string;
    content: string;
  }>;
  targetMessages: Record<string, SlackObservedMessage | null>;
  createdMessages: Array<{ channelId: string; message: SlackObservedMessage }>;
  channelTopic?: string;
  channelPurpose?: string;
  pinnedMessageTimestamps: string[];
  operations: SlackOperationEvidence[];
  attachmentReads: string[];
  directMessages: SlackObservedMessage[];
  cleanupErrors: string[];
};

export async function runSlackProviderActionItem(input: {
  item: SlackProviderActionDatasetItem;
  salix: SalixAdapter;
  slack: SlackEvaluationTools;
  prepared: Salix.PreparedRun;
  channelId: string;
  agentTimeoutMs: number;
  slackSettleMs: number;
  slackConnectFixture: Readonly<Salix.AppIntegrationConfig>;
  logger: EvalensLogger;
}): Promise<{
  result: SlackProviderActionResult;
  trajectory: Trajectory;
  artifacts: Bun.Archive;
}> {
  input.slack.driver.assertAllowedChannel(input.channelId);
  const driverUserIdentity = await input.slack.driver.preflight();
  assertHumanSlackDriver(driverUserIdentity);
  const routerAgentId = input.prepared.routerAgentId;
  if (!routerAgentId) throw new Error("routerAgentId is required");
  const routerSessionId = input.prepared.routerSessionId;
  if (!routerSessionId) throw new Error("routerSessionId is required");
  const materializationReceipt = await input.salix.integrations.materializeFixture({
    run: input.prepared,
    inboundAgentId: routerAgentId,
    integration: input.slackConnectFixture,
  });
  if (materializationReceipt.materializationKind !== "im_connect") {
    throw new Error("Slack integration did not materialize an IM connect");
  }
  const slackConnect = materializationReceipt.imConnect;
  if (slackConnect.workspaceId !== driverUserIdentity.workspaceId) {
    throw new Error(
      `Slack workspace mismatch between driver user and Salix bot: ${driverUserIdentity.workspaceId} != ${slackConnect.workspaceId}`
    );
  }
  assertDistinctSlackApps(driverUserIdentity.botId, slackConnect.botId);
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
  let beforeChannel: JsonObject | undefined;
  let trigger: { channelId: string; ts: string; text: string } | undefined;
  let operations: SlackOperationEvidence[] = [];
  let threadReplies: SlackObservedMessage[] = [];
  let completed:
    | { result: SlackProviderActionResult; trajectory: Trajectory; traceJson: string }
    | undefined;

  try {
    beforeChannel = await input.slack.observer.channelInfo(input.channelId);
    await executeSlackSetup(
      input.slack,
      input.channelId,
      input.item.input.slackSetup,
      setup
    );
    const baseline = await input.salix.sessions.collectAgentSession({
      agentId: routerAgentId,
      sessionId: routerSessionId,
    });
    const prompt = `${renderSlackTrigger(
      input.item.input.slackTrigger.text,
      setup.resources
    )} send by codex`;
    trigger = await input.slack.driver.postMention({
      channelId: input.channelId,
      botUserId: slackConnect.botUserId,
      text: prompt,
    });
    const startedAt = Date.now();
    const inputObserved = await waitForAgentInput({
      salix: input.salix,
      agentId: routerAgentId,
      sessionId: routerSessionId,
      afterMessageCount: baseline.messages.length,
      expectedText: prompt,
      timeoutMs: input.agentTimeoutMs,
    });
    let elapsed = Date.now() - startedAt;
    const delivery = inputObserved
      ? await input.slack.observer.waitForBotReplies({
          channelId: input.channelId,
          threadTs: trigger.ts,
          botUserId: slackConnect.botUserId,
          timeoutMs: Math.max(1, input.agentTimeoutMs - elapsed),
          settleMs: input.slackSettleMs,
        })
      : {
          messages: [],
          timedOut: true,
          elapsedMs: elapsed,
        };
    elapsed = Date.now() - startedAt;
    const settled = inputObserved
      ? await input.salix.sessions.waitForSettled({
          agentId: routerAgentId,
          sessionId: routerSessionId,
          timeoutMs: Math.max(1, input.agentTimeoutMs - elapsed),
        })
      : { settled: false, elapsedMs: elapsed };

    const { trace, trajectory } = await input.salix.sessions.collectSessionTrace({
      agentId: routerAgentId,
      sessionId: routerSessionId,
      traceLimit: 500,
    });
    const evidence = extractSlackTrajectoryEvidence(trajectory, prompt);
    assertNoSlackInfrastructureErrors(evidence.providerErrors);
    operations = evidence.operations;
    const thread = await input.slack.observer.readThread({
      channelId: input.channelId,
      threadTs: trigger.ts,
    });
    threadReplies = thread.filter(
      (message) =>
        message.ts !== trigger?.ts && message.userId === slackConnect.botUserId
    );
    if (threadReplies.length === 0) threadReplies = delivery.messages;
    const threadFiles = await collectThreadFiles(input.slack, threadReplies);
    const targetMessages = await collectSetupTargetMessages(
      input.slack,
      setup.resources
    );
    const createdMessages = await collectAgentCreatedMessages(input.slack, operations);
    const channel = await input.slack.observer.channelInfo(input.channelId);
    const pins = await input.slack.observer.listPins(input.channelId);
    const channelSnapshot = ChannelSnapshotSchema.parse(channel);
    const directMessages = await collectDirectMessages(
      input.slack,
      operations,
      driverUserIdentity.userId
    );

    const result: SlackProviderActionResult = {
      driverUserId: driverUserIdentity.userId,
      salixBotUserId: slackConnect.botUserId,
      salixBotId: slackConnect.botId,
      trigger: {
        channelId: trigger.channelId,
        ts: trigger.ts,
        text: trigger.text,
      },
      execution: {
        inputObserved,
        settled: settled.settled,
        timedOut: !inputObserved || delivery.timedOut,
        ...(settled.status ? { status: settled.status } : {}),
      },
      setupResources: setup.resources,
      threadReplies,
      threadFiles,
      targetMessages,
      createdMessages,
      ...(channelSnapshot.topic ? { channelTopic: channelSnapshot.topic.value } : {}),
      ...(channelSnapshot.purpose
        ? { channelPurpose: channelSnapshot.purpose.value }
        : {}),
      pinnedMessageTimestamps: pins.flatMap((pin) => {
        const parsed = PinnedMessageSchema.safeParse(pin);
        return parsed.success ? [parsed.data.message.ts] : [];
      }),
      operations,
      attachmentReads: evidence.attachmentReads,
      directMessages,
      cleanupErrors,
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
      trigger,
    });
    cleanupErrors.push(...errors);
    for (const error of errors) input.logger.error(error);
  }

  if (!completed) throw new Error("Slack item completed without an observation");
  return {
    result: completed.result,
    trajectory: completed.trajectory,
    artifacts: new Bun.Archive({
      "slack-observation.json": JSON.stringify(completed.result, null, 2),
      "salix-trace.json": completed.traceJson,
    }),
  };
}

export function assertDistinctSlackApps(
  inputActorBotId: string | undefined,
  salixBotId: string
): void {
  if (inputActorBotId && inputActorBotId === salixBotId) {
    throw new Error(
      "Slack driver token must belong to a different Slack app than the materialized Salix connect"
    );
  }
}

export function assertHumanSlackDriver(identity: {
  userId: string;
  botId?: string;
}): void {
  if (identity.botId) {
    throw new Error(
      `Slack user driver must authenticate as a human user, but ${identity.userId} belongs to bot ${identity.botId}`
    );
  }
}

export type SetupState = {
  resources: Record<string, SlackSetupResource>;
  messages: Array<{ channelId: string; ts: string }>;
  files: string[];
  reactions: Array<{ channelId: string; ts: string; name: string }>;
  pins: Array<{ channelId: string; ts: string }>;
};

export async function executeSlackSetup(
  slack: SlackEvaluationTools,
  channelId: string,
  actions: SlackSetupAction[],
  state: SetupState
): Promise<void> {
  for (const action of actions) {
    await executeSetupAction(slack, channelId, action, state);
  }
}

export function emptySetupState(): SetupState {
  return { resources: {}, messages: [], files: [], reactions: [], pins: [] };
}

async function executeSetupAction(
  slack: SlackEvaluationTools,
  channelId: string,
  action: SlackSetupAction,
  state: SetupState
): Promise<void> {
  if (action.action === "post_message" || action.action === "post_thread_reply") {
    const target =
      action.action === "post_thread_reply"
        ? requireMessageResource(state.resources, action.target)
        : undefined;
    const message = await slack.driver.postMessage({
      channelId,
      text: action.text,
      ...(target ? { threadTs: target.threadTs ?? target.ts } : {}),
    });
    const permalink = await slack.observer.getPermalink({ channelId, ts: message.ts });
    state.resources[action.alias] = {
      type: "message",
      channelId,
      ts: message.ts,
      text: message.text,
      permalink,
      ...(message.threadTs ? { threadTs: message.threadTs } : {}),
    };
    state.messages.push({ channelId, ts: message.ts });
    return;
  }
  if (action.action === "upload_file") {
    const file = await slack.driver.uploadTextFile({
      channelId,
      filename: action.filename,
      content: action.content,
    });
    state.resources[action.alias] = {
      type: "file",
      channelId,
      fileId: file.fileId,
      filename: action.filename,
      ...(file.permalink ? { permalink: file.permalink } : {}),
    };
    state.files.push(file.fileId);
    return;
  }
  const target = requireMessageResource(state.resources, action.target);
  if (action.action === "add_reaction") {
    await slack.driver.addReaction({ channelId, ts: target.ts, name: action.name });
    state.reactions.push({ channelId, ts: target.ts, name: action.name });
    return;
  }
  await slack.driver.pinMessage({ channelId, ts: target.ts });
  state.pins.push({ channelId, ts: target.ts });
}

export function renderSlackTrigger(
  template: string,
  resources: Record<string, SlackSetupResource>
): string {
  return template.replaceAll(
    /\{\{([a-zA-Z0-9_-]+)\.permalink\}\}/gu,
    (_match, alias) => {
      const resource = resources[alias];
      if (!resource?.permalink) {
        throw new Error(`Slack trigger references unavailable permalink: ${alias}`);
      }
      return resource.permalink;
    }
  );
}

export function extractSlackTrajectoryEvidence(
  trajectory: Trajectory,
  triggerText?: string
): SlackTrajectoryEvidence {
  const results = new Map(
    trajectory.steps
      .filter((step) => step.type === "tool_result")
      .map((step) => [step.toolCallId, step] as const)
  );
  const operations: SlackOperationEvidence[] = [];
  const providerErrors: string[] = [];
  const assistantMessages: string[] = [];
  const attachmentReads: string[] = [];
  let inputObserved = false;

  for (const step of trajectory.steps) {
    if (step.type === "user") {
      inputObserved ||= !triggerText || normalizedContains(step.content, triggerText);
    } else if (step.type === "assistant" && step.content) {
      assistantMessages.push(step.content);
    } else if (step.type === "tool_call") {
      const envelope = OperationArgumentsSchema.parse(step.arguments);
      const nestedParams = JsonObjectSchema.safeParse(envelope.params);
      const operationArguments = nestedParams.success ? nestedParams.data : envelope;
      if (step.name === "fs.read_file") {
        const path = operationArguments.path;
        if (typeof path !== "string" || !path.trim()) {
          throw new Error("fs.read_file path is required");
        }
        const result = results.get(step.id);
        if (
          path.startsWith("/slack/attachments/") &&
          result &&
          !providerError(result)
        ) {
          attachmentReads.push(path);
        }
      }
      if (step.name === "help") continue;
      const directName = step.name.match(/(?:^|\.)(slack\.[a-z0-9_]+)$/iu)?.[1];
      const declaredName = [envelope.operation, envelope.api, envelope.tool].find(
        (value): value is string =>
          typeof value === "string" &&
          (value.startsWith("slack.") || value.startsWith("im_api.slack."))
      );
      const name = directName
        ? directName.toLowerCase()
        : declaredName?.replace(/^im_api\./u, "");
      if (!name) continue;
      const result = results.get(step.id);
      const error = result ? providerError(result) : "missing tool result";
      if (error) providerErrors.push(error);
      const succeeded = Boolean(result) && !error;
      let createdResource: SlackOperationEvidence["createdResource"];
      let targetResource: SlackOperationEvidence["targetResource"];
      if (succeeded && (name === "slack.post_message" || name === "slack.send_dm")) {
        const message = ProviderMessageRefSchema.parse(result?.output);
        createdResource = {
          type: "message",
          ...message,
          ...(typeof operationArguments.thread_ts === "string"
            ? { threadTs: operationArguments.thread_ts }
            : {}),
        };
      } else if (succeeded && name === "slack.create_canvas") {
        createdResource = {
          type: "canvas",
          canvasId: ProviderCanvasIdSchema.parse(result?.output),
        };
      }
      if (succeeded && name === "slack.get_thread_replies") {
        const channelId = operationArguments.channel;
        const ts = operationArguments.ts;
        const messages = ProviderMessagesSchema.parse(result?.output);
        if (
          typeof channelId === "string" &&
          typeof ts === "string" &&
          messages.some((message) => message.ts === ts)
        ) {
          targetResource = { type: "message", channelId, ts };
        }
      } else if (succeeded && name === "slack.get_channel_history") {
        const channelId = operationArguments.channel;
        const oldest = operationArguments.oldest;
        const latest = operationArguments.latest;
        const messages = ProviderMessagesSchema.parse(result?.output);
        if (
          typeof channelId === "string" &&
          typeof oldest === "string" &&
          oldest === latest &&
          messages.some((message) => message.ts === oldest)
        ) {
          targetResource = { type: "message", channelId, ts: oldest };
        }
      } else if (
        name === "slack.fetch_file" &&
        typeof operationArguments.file_id === "string"
      ) {
        targetResource = { type: "file", fileId: operationArguments.file_id };
      } else if (
        [
          "slack.update_message",
          "slack.delete_message",
          "slack.add_reaction",
          "slack.remove_reaction",
          "slack.pin_message",
          "slack.unpin_message",
        ].includes(name)
      ) {
        const channelId = operationArguments.channel_id ?? operationArguments.channel;
        const ts =
          operationArguments.message_ts ??
          operationArguments.timestamp ??
          operationArguments.ts;
        if (typeof channelId === "string" && typeof ts === "string") {
          targetResource = { type: "message", channelId, ts };
        }
      } else if (
        [
          "slack.edit_canvas",
          "slack.set_canvas_access",
          "slack.delete_canvas",
        ].includes(name) &&
        typeof operationArguments.canvas_id === "string"
      ) {
        targetResource = {
          type: "canvas",
          canvasId: operationArguments.canvas_id,
        };
      }
      operations.push({
        name,
        arguments: operationArguments,
        ...(result ? { output: result.output } : {}),
        succeeded,
        ...(createdResource ? { createdResource } : {}),
        ...(targetResource ? { targetResource } : {}),
      });
    }
  }
  return {
    inputObserved,
    assistantMessages,
    attachmentReads,
    operations,
    providerErrors,
    replyAttempted:
      assistantMessages.length > 0 ||
      operations.some((op) => op.name === "slack.post_message"),
  };
}

export function assertNoSlackInfrastructureErrors(errors: string[]): void {
  const error = errors.find((candidate) =>
    /\b(?:invalid_auth|token_revoked|token_expired|account_inactive|not_authed|missing_scope)\b/iu.test(
      candidate
    )
  );
  if (error) throw new Error(`Slack provider infrastructure error: ${error}`);
}

export async function waitForAgentInput(input: {
  salix: SalixAdapter;
  agentId: string;
  sessionId: string;
  afterMessageCount: number;
  expectedText?: string;
  timeoutMs: number;
}): Promise<boolean> {
  const deadline = Date.now() + input.timeoutMs;
  const expectedText = input.expectedText;
  while (Date.now() < deadline) {
    const session = await input.salix.sessions.collectAgentSession(input);
    const added = session.messages.slice(input.afterMessageCount);
    if (!expectedText && added.length > 0) return true;
    if (expectedText) {
      for (const message of added) {
        if (
          message.role === "user" &&
          typeof message.content === "string" &&
          normalizedContains(message.content, expectedText)
        )
          return true;
      }
    }
    await Bun.sleep(Math.min(1_000, Math.max(1, deadline - Date.now())));
  }
  return false;
}

export async function collectThreadFiles(
  slack: SlackEvaluationTools,
  replies: SlackObservedMessage[]
) {
  const files = replies.flatMap((reply) => reply.files);
  return Promise.all(
    files.map(async (file) => ({
      id: file.id,
      ...(file.name ? { name: file.name } : {}),
      ...(file.mimetype ? { mimetype: file.mimetype } : {}),
      content: new TextDecoder().decode(await slack.observer.downloadFile(file.id)),
    }))
  );
}

export async function collectSetupTargetMessages(
  slack: SlackEvaluationTools,
  resources: Record<string, SlackSetupResource>
) {
  const entries = await Promise.all(
    Object.entries(resources).map(async ([alias, resource]) => {
      if (resource.type !== "message") return [alias, null] as const;
      const messages = resource.threadTs
        ? await slack.observer.readThread({
            channelId: resource.channelId,
            threadTs: resource.threadTs,
          })
        : await slack.observer.readConversationHistory({
            channelId: resource.channelId,
            oldest: resource.ts,
            latest: resource.ts,
            limit: 1,
          });
      return [
        alias,
        messages.find((message) => message.ts === resource.ts) ?? null,
      ] as const;
    })
  );
  return Object.fromEntries(entries);
}

export async function collectAgentCreatedMessages(
  slack: SlackEvaluationTools,
  operations: SlackOperationEvidence[]
): Promise<Array<{ channelId: string; message: SlackObservedMessage }>> {
  const resources = operations.flatMap((operation) =>
    operation.name === "slack.post_message" &&
    operation.succeeded &&
    operation.createdResource?.type === "message"
      ? [operation.createdResource]
      : []
  );
  const observations = await Promise.all(
    resources.map(async (resource) => {
      const messages = resource.threadTs
        ? await slack.observer.readThread({
            channelId: resource.channelId,
            threadTs: resource.threadTs,
          })
        : await slack.observer.readConversationHistory({
            channelId: resource.channelId,
            oldest: resource.ts,
            latest: resource.ts,
            limit: 1,
          });
      const message = messages.find((candidate) => candidate.ts === resource.ts);
      return message ? [{ channelId: resource.channelId, message }] : [];
    })
  );
  return observations.flat();
}

export async function collectDirectMessages(
  slack: SlackEvaluationTools,
  operations: SlackOperationEvidence[],
  driverUserId: string
): Promise<SlackObservedMessage[]> {
  const refs = operations
    .filter(
      (operation) =>
        operation.name === "slack.send_dm" &&
        operation.succeeded &&
        operation.arguments.user_id === driverUserId
    )
    .flatMap((operation) => providerMessageRef(operation.output));
  const messages = await Promise.all(
    refs.map(async ({ channelId, ts }) => {
      const history = await slack.observer
        .withAllowedChannel(channelId)
        .readConversationHistory({
          channelId,
          oldest: ts,
          latest: ts,
          limit: 1,
        });
      return history.find((message) => message.ts === ts);
    })
  );
  return messages.flatMap((message) => (message ? [message] : []));
}

export async function cleanupSlackResources(input: {
  slack: SlackEvaluationTools;
  salixBotClient: SlackEvaluationTools;
  channelId: string;
  setup: SetupState;
  operations: SlackOperationEvidence[];
  threadReplies: SlackObservedMessage[];
  beforeChannel?: JsonObject;
  trigger?: { channelId: string; ts: string };
}): Promise<string[]> {
  const tasks: Array<{ label: string; run: () => Promise<unknown> }> = [];
  for (const reaction of input.setup.reactions) {
    tasks.push({
      label: `remove setup reaction ${reaction.name}`,
      run: () => input.slack.fixtureCleaner.removeReaction(reaction),
    });
  }
  for (const pin of input.setup.pins) {
    tasks.push({
      label: `remove setup pin ${pin.ts}`,
      run: () => input.slack.fixtureCleaner.unpinMessage(pin.channelId, pin.ts),
    });
  }
  for (const fileId of input.setup.files) {
    tasks.push({
      label: `delete setup file ${fileId}`,
      run: () => input.slack.fixtureCleaner.deleteFile(fileId),
    });
  }
  for (const message of input.setup.messages.reverse()) {
    tasks.push({
      label: `delete setup message ${message.ts}`,
      run: () =>
        input.slack.fixtureCleaner.deleteMessage(message.channelId, message.ts),
    });
  }

  const createdMessageRefs = new Map<string, { channelId: string; ts: string }>();
  const deletedMessageRefs = new Set(
    input.operations
      .filter(
        (operation) => operation.name === "slack.delete_message" && operation.succeeded
      )
      .flatMap((operation) => {
        const { channel, ts } = operation.arguments;
        return typeof channel === "string" && typeof ts === "string"
          ? [`${channel}:${ts}`]
          : [];
      })
  );
  for (const reply of input.threadReplies) {
    for (const file of reply.files) {
      tasks.push({
        label: `delete Agent reply file ${file.id}`,
        run: () => input.salixBotClient.fixtureCleaner.deleteFile(file.id),
      });
    }
    if (reply.files.length === 0) {
      const ref = { channelId: input.channelId, ts: reply.ts };
      createdMessageRefs.set(`${ref.channelId}:${ref.ts}`, ref);
    }
  }
  for (const operation of input.operations) {
    if (
      operation.succeeded &&
      ["slack.post_message", "slack.send_dm"].includes(operation.name)
    ) {
      for (const ref of providerMessageRef(operation.output)) {
        createdMessageRefs.set(`${ref.channelId}:${ref.ts}`, ref);
      }
    }
    if (operation.name === "slack.add_reaction" && operation.succeeded) {
      const { channel, ts, name } = operation.arguments;
      if (
        typeof channel === "string" &&
        typeof ts === "string" &&
        typeof name === "string"
      ) {
        tasks.push({
          label: `remove Agent reaction ${name}`,
          run: () =>
            input.salixBotClient.fixtureCleaner.removeReaction({
              channelId: channel,
              ts,
              name,
            }),
        });
      }
    }
    if (operation.name === "slack.pin_message" && operation.succeeded) {
      const { channel, ts } = operation.arguments;
      if (typeof channel === "string" && typeof ts === "string") {
        tasks.push({
          label: `remove Agent pin ${ts}`,
          run: () => input.salixBotClient.fixtureCleaner.unpinMessage(channel, ts),
        });
      }
    }
  }
  const cleanupBotSlack = createSlackEvaluationTools({
    ...input.salixBotClient.config,
    allowedChannelIds: [
      ...new Set([
        ...input.salixBotClient.config.allowedChannelIds,
        ...[...createdMessageRefs.values()].map((ref) => ref.channelId),
      ]),
    ],
  });
  for (const [key, ref] of createdMessageRefs) {
    if (deletedMessageRefs.has(key)) continue;
    tasks.push({
      label: `delete Agent message ${ref.channelId}:${ref.ts}`,
      run: () => cleanupBotSlack.fixtureCleaner.deleteMessage(ref.channelId, ref.ts),
    });
  }
  const trigger = input.trigger;
  if (trigger) {
    tasks.push({
      label: `delete trigger ${trigger.ts}`,
      run: () =>
        input.slack.fixtureCleaner.deleteMessage(trigger.channelId, trigger.ts),
    });
  }
  const deletedCanvasIds = new Set(
    input.operations
      .filter(
        (operation) => operation.name === "slack.delete_canvas" && operation.succeeded
      )
      .map((operation) => providerCanvasId(operation.output))
  );
  const canvasIds = new Set(
    input.operations
      .filter(
        (operation) => operation.name === "slack.create_canvas" && operation.succeeded
      )
      .map((operation) => providerCanvasId(operation.output))
  );
  for (const canvasId of canvasIds) {
    if (deletedCanvasIds.has(canvasId)) continue;
    tasks.push({
      label: `delete Agent canvas ${canvasId}`,
      run: () =>
        input.salixBotClient.fixtureCleaner.apiCall(
          input.channelId,
          "canvases.delete",
          { canvas_id: canvasId }
        ),
    });
  }
  const beforeChannel = input.beforeChannel
    ? ChannelSnapshotSchema.parse(input.beforeChannel)
    : undefined;
  const topic = beforeChannel?.topic?.value;
  const purpose = beforeChannel?.purpose?.value;
  const topicChanged = input.operations.some(
    (operation) => operation.name === "slack.set_channel_topic" && operation.succeeded
  );
  const purposeChanged = input.operations.some(
    (operation) => operation.name === "slack.set_channel_purpose" && operation.succeeded
  );
  if (topicChanged && topic !== undefined) {
    tasks.push({
      label: "restore channel topic",
      run: () => input.salixBotClient.driver.setChannelTopic(input.channelId, topic),
    });
  }
  if (purposeChanged && purpose !== undefined) {
    tasks.push({
      label: "restore channel purpose",
      run: () =>
        input.salixBotClient.driver.setChannelPurpose(input.channelId, purpose),
    });
  }

  const errors: string[] = [];
  for (const task of tasks) {
    const error = await input.slack.fixtureCleaner.cleanup(task.run);
    if (error) errors.push(`Slack cleanup failed (${task.label}): ${error}`);
  }
  return errors;
}

function requireMessageResource(
  resources: Record<string, SlackSetupResource>,
  alias: string
) {
  const resource = resources[alias];
  if (!resource || resource.type !== "message") {
    throw new Error(`Slack setup target is not a message: ${alias}`);
  }
  return resource;
}

function providerError(
  result: Extract<Trajectory["steps"][number], { type: "tool_result" }>
): string | undefined {
  if (result.errorClass || result.errorMessage) {
    return [result.errorClass, result.errorMessage].filter(Boolean).join(": ");
  }
  if (result.status && /^(?:error|failed|cancelled)$/iu.test(result.status)) {
    return `tool result status: ${result.status}`;
  }
  if (result.output === undefined || result.output === null) {
    return "missing tool result";
  }
  if (typeof result.output === "string") {
    const text = result.output.trim();
    if (!text) return "missing tool result";
    try {
      return structuredProviderError(JSON.parse(text));
    } catch {
      return undefined;
    }
  }
  return structuredProviderError(result.output);
}

function structuredProviderError(output: unknown): string | undefined {
  const parsed = ProviderResultSchema.safeParse(output);
  if (!parsed.success) {
    throw new Error(
      `Slack operation result is malformed: ${z.prettifyError(parsed.error)}`
    );
  }
  const error = parsed.data.error;
  if (error !== undefined && error !== null && error !== false && error !== "") {
    return JSON.stringify(error).slice(0, 1_000);
  }
  if (parsed.data.ok === false) return JSON.stringify(parsed.data).slice(0, 1_000);
  return undefined;
}

function providerMessageRef(output: unknown): Array<{ channelId: string; ts: string }> {
  return [ProviderMessageRefSchema.parse(output)];
}

function providerCanvasId(output: unknown): string {
  return ProviderCanvasIdSchema.parse(output);
}

function normalizedContains(value: string, expected: string): boolean {
  const normalize = (text: string) =>
    text
      .replace(/<@[^>]+>/gu, "")
      .replace(/<((?:https?|mailto):[^>|]+)(?:\|[^>]*)?>/giu, "$1")
      .replace(/&amp;/gu, "&")
      .replace(/&lt;/gu, "<")
      .replace(/&gt;/gu, ">")
      .replace(/\s+/gu, " ")
      .trim();
  const left = normalize(value);
  const right = normalize(expected);
  return left.includes(right) || right.includes(left);
}
