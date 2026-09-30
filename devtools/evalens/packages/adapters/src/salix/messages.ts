import { z } from "zod";
import type { Salix } from "./types";
import { NormalizedSessionMessageSchema } from "./protocol";

export type RouterConversationBaseline = {
  messageCount: number;
  messageIds: Set<string>;
};

const salixMessageArraySchema = z.array(NormalizedSessionMessageSchema);
export const SalixMessageBundleSchema = z.union([
  salixMessageArraySchema,
  z
    .looseObject({ messages: salixMessageArraySchema })
    .transform(({ messages }) => messages),
  z
    .looseObject({
      messages: z.looseObject({ messages: salixMessageArraySchema }),
    })
    .transform(({ messages }) => messages.messages),
  z
    .looseObject({
      session: z.looseObject({ messages: salixMessageArraySchema }),
    })
    .transform(({ session }) => session.messages),
]);

export function latestAssistantReply(
  bundle: unknown,
  afterMessageId?: number
): Salix.AssistantReply | undefined {
  const messages = SalixMessageBundleSchema.parse(bundle);
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message?.role !== "assistant") {
      continue;
    }
    const content = message.content;
    if (!content) {
      continue;
    }
    const messageId = message.sequence;
    if (
      afterMessageId !== undefined &&
      messageId !== undefined &&
      messageId <= afterMessageId
    ) {
      continue;
    }
    return { content, messageId, message };
  }
  return undefined;
}

export function latestRouterConversationReply(
  messages: Salix.SessionMessage[],
  baseline: RouterConversationBaseline,
  agentId?: string
): Salix.AssistantReply | undefined {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (!message) {
      continue;
    }
    if (!isAgentConversationMessage(message, agentId)) {
      continue;
    }
    const id = message.id;
    if (id ? baseline.messageIds.has(id) : index < baseline.messageCount) {
      continue;
    }

    const content = message.content;
    if (!content) {
      continue;
    }
    return { content, messageId: message.sequence, message };
  }

  return undefined;
}

export function routerConversationBaseline(
  messages: Salix.SessionMessage[]
): RouterConversationBaseline {
  return {
    messageCount: messages.length,
    messageIds: new Set(
      messages
        .map((message) => message.id)
        .filter((id): id is string => id !== undefined)
    ),
  };
}

export function routerConversationBaselineAfterMessage(
  messages: Salix.SessionMessage[],
  messageId: string
): RouterConversationBaseline | undefined {
  const index = messages.findIndex((message) => message.id === messageId);
  if (index < 0) {
    return undefined;
  }
  return routerConversationBaseline(messages.slice(0, index + 1));
}

export function maxMessageId(messages: Salix.SessionMessage[]): number | undefined {
  const ids = messages
    .map((message) => message.sequence)
    .filter((id): id is number => id !== undefined);
  return ids.length > 0 ? Math.max(...ids) : undefined;
}

function isAgentConversationMessage(
  message: Salix.SessionMessage,
  agentId?: string
): boolean {
  const actorType = message.role;
  const messageAgentId = message.agentId;

  if (agentId && messageAgentId && messageAgentId !== agentId) {
    return false;
  }
  if (actorType) {
    return actorType === "assistant";
  }
  return Boolean(messageAgentId && (!agentId || messageAgentId === agentId));
}
