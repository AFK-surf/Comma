import type {
  ChatInlineMessagePart,
  ChatInlineMessagePartKind,
  ChatInlineTask,
  ChatMessagePart,
} from "@comma/chat-contract";
import type { SalixContentBlock } from "../../../api";

type InlineElementPlainTextLabels = {
  task: string;
  unavailableTask: string;
};

type InlineElementContractAdapter<Kind extends ChatInlineMessagePartKind> = {
  decode(
    block: SalixContentBlock
  ): Extract<ChatInlineMessagePart, { kind: Kind }> | undefined;
  equals(
    left: Extract<ChatInlineMessagePart, { kind: Kind }>,
    right: Extract<ChatInlineMessagePart, { kind: Kind }>
  ): boolean;
  toPlainText(
    part: Extract<ChatInlineMessagePart, { kind: Kind }>,
    labels: InlineElementPlainTextLabels
  ): string;
};

type InlineElementContractRegistry = {
  [Kind in ChatInlineMessagePartKind]: InlineElementContractAdapter<Kind>;
};

/**
 * Pure, Main-safe half of the inline-element registry. The mapped type is
 * exhaustive over the chat-contract union, so a new inline kind cannot ship
 * until its wire decoder and plain-text fallback are both registered.
 */
const inlineElementContracts = {
  "dynamic-ui": {
    decode() {
      return undefined;
    },
    equals(left, right) {
      return (
        left.originTaskId === right.originTaskId &&
        left.contentId === right.contentId &&
        left.uiRef === right.uiRef &&
        left.version === right.version &&
        left.summary === right.summary &&
        left.messageId === right.messageId &&
        left.conversationId === right.conversationId &&
        left.attachmentIndex === right.attachmentIndex
      );
    },
    toPlainText(part) {
      return part.summary;
    },
  },
  "inline-task": {
    decode(rawBlock) {
      const block = objectValue(rawBlock);
      if (
        !block ||
        block.type !== "conversation_ref" ||
        block.presentation !== "inline"
      ) {
        return undefined;
      }

      if (block.unavailable === true) {
        return { kind: "inline-task", task: { unavailable: true } };
      }

      const conversationId = stringValue(block.conversation_id);
      if (block.kind !== "agent_task" || !conversationId) {
        return { kind: "inline-task", task: { unavailable: true } };
      }

      return {
        kind: "inline-task",
        task: {
          activityStatus: stringValue(block.activity_status),
          conversationId,
          freshness: freshnessValue(block.freshness),
          status: stringValue(block.status),
          title: stringValue(block.title),
          unavailable: false,
          updatedAt: numberValue(block.updated_at),
        },
      };
    },
    equals(left, right) {
      return (
        left.task.activityStatus === right.task.activityStatus &&
        left.task.conversationId === right.task.conversationId &&
        left.task.freshness === right.task.freshness &&
        left.task.status === right.task.status &&
        left.task.title === right.task.title &&
        left.task.unavailable === right.task.unavailable &&
        left.task.updatedAt === right.task.updatedAt
      );
    },
    toPlainText(part, labels) {
      if (part.task.unavailable) return labels.unavailableTask;
      return part.task.title || labels.task;
    },
  },
} satisfies InlineElementContractRegistry;

/** Decode only server-projected structured blocks; model-authored text never enters here. */
export function decodeInlineMessagePart(
  block: SalixContentBlock
): ChatInlineMessagePart | undefined {
  for (const adapter of Object.values(inlineElementContracts)) {
    const value = adapter.decode(block);
    if (value) return value;
  }
  return undefined;
}

export function inlineMessagePartPlainText(
  part: ChatInlineMessagePart,
  labels: InlineElementPlainTextLabels
) {
  // The exhaustive registry is keyed by this exact discriminant. TypeScript
  // cannot retain that correlation through an indexed union, so erase it only
  // at this closed dispatch boundary rather than weakening adapter definitions.
  const adapter = inlineElementContracts[part.kind] as InlineElementContractAdapter<
    typeof part.kind
  >;
  return adapter.toPlainText(part, labels);
}

export function messagePartsHaveInlineElements(
  parts: readonly ChatMessagePart[] | undefined
): parts is readonly ChatMessagePart[] {
  return parts !== undefined && parts.some((part) => part.kind !== "markdown");
}

/**
 * Value equality over ordered message parts. Used to keep compiled markdown
 * and projected message identities stable when snapshot plumbing (IPC echoes,
 * poll refreshes) re-materializes equal data with fresh object identities.
 */
export function sameMessageParts(
  left: readonly ChatMessagePart[],
  right: readonly ChatMessagePart[]
) {
  if (left === right) {
    return true;
  }
  if (left.length !== right.length) {
    return false;
  }
  return left.every((part, index) => sameMessagePart(part, right[index]!));
}

function sameMessagePart(left: ChatMessagePart, right: ChatMessagePart) {
  if (left === right) {
    return true;
  }
  if (left.kind === "markdown" || right.kind === "markdown") {
    return (
      left.kind === "markdown" && right.kind === "markdown" && left.text === right.text
    );
  }
  if (left.kind !== right.kind) {
    return false;
  }
  const adapter = inlineElementContracts[left.kind] as InlineElementContractAdapter<
    typeof left.kind
  >;
  return adapter.equals(left, right);
}
function objectValue(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function stringValue(value: unknown) {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function numberValue(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function freshnessValue(value: unknown): ChatInlineTask["freshness"] {
  const candidate = typeof value === "string" ? value : objectValue(value)?.state;
  return candidate === "fresh" || candidate === "stale" || candidate === "unknown"
    ? candidate
    : undefined;
}
