import { taskStatusBucket } from "@comma/i18n";
import type {
  ChatDeviceSetupOffer,
  ChatInlineMessagePart,
  ChatInlineMessagePartKind,
  ChatInlineTask,
  ChatMessagePart,
  ChatQuestionAnswerPart,
  ChatQuestionChoice,
  ChatQuestionPart,
  ChatQuestionState,
} from "@comma/chat-contract";
import type { SalixContentBlock } from "../api";

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
  "device-setup-offer": {
    decode(rawBlock) {
      const block = objectValue(rawBlock);
      if (!block || block.type !== "device_setup_offer") return undefined;
      const offer = deviceSetupOfferValue(block);
      return offer ? { kind: "device-setup-offer", offer } : undefined;
    },
    equals(left, right) {
      return (
        left.offer.offerId === right.offer.offerId &&
        left.offer.status === right.offer.status &&
        left.offer.revision === right.offer.revision &&
        left.offer.expiresAt === right.offer.expiresAt &&
        left.offer.name === right.offer.name &&
        left.offer.model === right.offer.model &&
        left.offer.shortId === right.offer.shortId &&
        left.offer.reporterDeviceId === right.offer.reporterDeviceId
      );
    },
    toPlainText(part) {
      return part.offer.name;
    },
  },
  // A question carries the id of the message that asks it, so the block walk decodes it (`questionPartValue`).
  question: {
    decode() {
      return undefined;
    },
    equals(left, right) {
      return (
        left.messageId === right.messageId &&
        left.prompt === right.prompt &&
        left.multiSelect === right.multiSelect &&
        left.allowOther === right.allowOther &&
        left.choices.length === right.choices.length &&
        left.choices.every((choice, index) =>
          sameChoice(choice, right.choices[index]!)
        ) &&
        sameQuestionState(left.state, right.state)
      );
    },
    toPlainText(part) {
      return [
        part.prompt,
        ...part.choices.map((choice, index) => `${index + 1}. ${choice.label}`),
      ].join("\n");
    },
  },
  "question-answer": {
    decode(rawBlock) {
      return questionAnswerPartValue(rawBlock);
    },
    equals(left, right) {
      return (
        left.questionMessageId === right.questionMessageId &&
        left.skipped === right.skipped &&
        left.other === right.other &&
        sameStrings(left.choiceIds, right.choiceIds)
      );
    },
    // The answer's own text block says it in the person's words.
    toPlainText() {
      return "";
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

      const status = stringValue(block.status);
      return {
        kind: "inline-task",
        task: {
          activityStatus: stringValue(block.activity_status),
          conversationId,
          freshness: freshnessValue(block.freshness),
          status,
          ...(status === undefined ? {} : { statusBucket: taskStatusBucket(status) }),
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
const OPEN_QUESTION: ChatQuestionState = { status: "open" };

/**
 * An Agent's `question` block as the message `messageId` asks it: two to six choices with distinct ids. Its state
 * starts open; the transcript pass (`withQuestionStates`) says where it stands.
 */
export function questionPartValue(
  rawBlock: unknown,
  messageId: string
): ChatQuestionPart | undefined {
  const block = objectValue(rawBlock);
  const prompt = stringValue(block?.prompt);
  if (!block || block.type !== "question" || !prompt || !messageId) return undefined;
  const choices = (Array.isArray(block.choices) ? block.choices : []).flatMap(
    (raw): ChatQuestionChoice[] => {
      const choice = objectValue(raw);
      const id = stringValue(choice?.id);
      const label = stringValue(choice?.label);
      if (!choice || !id || !label) return [];
      const description = stringValue(choice.description);
      const reply = stringValue(choice.reply);
      return [
        {
          id,
          label,
          ...(description ? { description } : {}),
          ...(reply ? { reply } : {}),
          ...(choice.recommended === true ? { recommended: true } : {}),
        },
      ];
    }
  );
  if (
    choices.length < 2 ||
    choices.length > 6 ||
    new Set(choices.map((choice) => choice.id)).size !== choices.length
  )
    return undefined;
  return {
    kind: "question",
    messageId,
    prompt,
    choices,
    multiSelect: block.multi_select === true,
    allowOther: block.allow_other !== false,
    state: OPEN_QUESTION,
  };
}

/** A person's `question_answer` block: which question it answers, and how. */
export function questionAnswerPartValue(
  rawBlock: unknown
): ChatQuestionAnswerPart | undefined {
  const block = objectValue(rawBlock);
  const questionMessageId = stringValue(block?.question_message_id);
  if (!block || block.type !== "question_answer" || !questionMessageId)
    return undefined;
  const choiceIds = Array.isArray(block.choice_ids)
    ? block.choice_ids.filter((id): id is string => typeof id === "string")
    : [];
  return {
    kind: "question-answer",
    questionMessageId,
    choiceIds,
    ...(typeof block.other === "string" ? { other: block.other } : {}),
    skipped: block.skipped === true,
  };
}

export function sameQuestionState(left: ChatQuestionState, right: ChatQuestionState) {
  return (
    left === right ||
    (left.status === right.status &&
      left.other === right.other &&
      left.error === right.error &&
      sameStrings(left.choiceIds ?? [], right.choiceIds ?? []))
  );
}

function sameChoice(left: ChatQuestionChoice, right: ChatQuestionChoice) {
  return (
    left.id === right.id &&
    left.label === right.label &&
    left.description === right.description &&
    left.reply === right.reply &&
    left.recommended === right.recommended
  );
}

function sameStrings(left: readonly string[], right: readonly string[]) {
  return (
    left.length === right.length && left.every((value, index) => value === right[index])
  );
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

/**
 * A device setup offer as the server wrote it: in an agent's `device_setup_offer` block, and in the `offer` of the
 * `device_setup_offer.updated` event that says its later state.
 */
export function deviceSetupOfferValue(
  value: unknown
): ChatDeviceSetupOffer | undefined {
  const block = objectValue(value);
  if (!block) return undefined;
  const offerId = stringValue(block.offer_id);
  const name = stringValue(block.name);
  const model = stringValue(block.model);
  const shortId = stringValue(block.short_id)?.toUpperCase();
  const reporterDeviceId = stringValue(block.reporter_device_id);
  const status = stringValue(block.status);
  const expiresAt = numberValue(block.expires_at);
  const revision = numberValue(block.revision);
  if (
    !offerId ||
    !name ||
    !model ||
    !shortId ||
    !/^[0-9A-F]{4}$/.test(shortId) ||
    !reporterDeviceId ||
    !status ||
    expiresAt === undefined ||
    !Number.isSafeInteger(expiresAt) ||
    expiresAt <= 0
  )
    return undefined;
  return {
    expiresAt,
    model,
    name,
    offerId,
    reporterDeviceId,
    ...(revision !== undefined && Number.isSafeInteger(revision) && revision > 0
      ? { revision }
      : {}),
    shortId,
    status,
  };
}

/** Whether `next`, seen after `current`, replaces it: a higher revision does, and one without a revision always. */
export function deviceSetupOfferReplaces(
  current: ChatDeviceSetupOffer,
  next: ChatDeviceSetupOffer
) {
  return (
    current.revision === undefined ||
    next.revision === undefined ||
    next.revision > current.revision
  );
}
