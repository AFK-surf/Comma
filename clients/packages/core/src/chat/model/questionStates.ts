import type {
  ChatMessage,
  ChatQuestionAnswerPart,
  ChatQuestionPart,
  ChatQuestionState,
} from "@comma/chat-contract";
import { sameQuestionState } from "./inlineElementContract";

const OPEN: ChatQuestionState = { status: "open" };

/**
 * Where each question card stands, read from the transcript (`messages` in order, this device's sends last). The
 * first message from the person after a question decides it: its `question-answer` for that question answers or
 * skips it, and any other message is a reply written in the chat. A later question before any message from the
 * person replaces it. While this device still sends the deciding message the card says `sending`, or `failed` when
 * an answer from the card did not go.
 *
 * `inTranscript` writes the states into the transcript. `inServerMessages` writes the same states into the server's
 * messages alone, which leave out this device's sends, so a reader of either list sees one state per card.
 *
 * A message whose card did not move keeps its identity, so its row does not draw again; a message both lists share
 * gets the same new message in both.
 */
export function createQuestionStates() {
  let lastInput: ChatMessage[] | undefined;
  let lastOutput: ChatMessage[] = [];
  let lastServer:
    | { server: ChatMessage[]; transcript: ChatMessage[]; output: ChatMessage[] }
    | undefined;
  const derived: Derived = new WeakMap();

  function inServerMessages(
    server: ChatMessage[],
    transcript: ChatMessage[]
  ): ChatMessage[] {
    if (lastServer?.server === server && lastServer.transcript === transcript)
      return lastServer.output;
    const states = new Map<string, ChatQuestionState>();
    const independentQuestionIds = new Set<string>();
    for (const message of transcript) {
      const question = questionOf(message);
      if (question) {
        states.set(question.messageId, question.state);
        if (question.independent) independentQuestionIds.add(question.messageId);
      }
    }
    for (const message of server) {
      const question = questionOf(message);
      if (question?.independent) independentQuestionIds.add(question.messageId);
    }
    const output = finalizeVisibleMessages(
      server,
      independentQuestionIds,
      (message) => {
        const question = questionOf(message);
        const state = question && states.get(question.messageId);
        if (!question || !state) return message;
        return withState(message, question, state, derived);
      }
    );
    lastServer = { server, transcript, output };
    return lastServer.output;
  }

  function inTranscript(messages: ChatMessage[]): ChatMessage[] {
    if (messages === lastInput) return lastOutput;
    lastInput = messages;
    if (
      !messages.some(hasQuestion) &&
      !messages.some((message) => isSilentQuestionAnswerMessage(message))
    ) {
      lastOutput = messages;
      return messages;
    }

    const explicitAnswers = new Map<string, ChatMessage>();
    const directReplies = new Map<string, ChatMessage>();
    const independentQuestionIds = new Set<string>();
    for (const message of messages) {
      const question = questionOf(message);
      if (question?.independent) independentQuestionIds.add(question.messageId);
      if (message.role !== "user") continue;
      const answer = anyAnswerOf(message);
      if (answer) {
        explicitAnswers.set(answer.questionMessageId, message);
      } else if (message.replyToMessageId) {
        directReplies.set(message.replyToMessageId, message);
      }
    }

    let updated: ChatMessage[] | undefined;
    let nearestPerson: ChatMessage | undefined;
    let laterQuestion = false;
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const message = messages[index]!;
      const question = questionOf(message);
      if (question) {
        if (question.independent) {
          // An externally bound independent card (such as a still.fail station
          // card) is decided only by an explicit question-answer targeting its
          // messageId, and stays transparent to the ordinary conversation scan
          // so it neither marks earlier Router questions replaced nor clears
          // nearestPerson for them.
          const decider = explicitAnswers.get(question.messageId);
          const state = stateFor(question, decider, false);
          const next = withState(message, question, state, derived);
          if (next !== message) {
            updated ??= messages.slice();
            updated[index] = next;
          }
        } else {
          const decider =
            explicitAnswers.get(question.messageId) ??
            directReplies.get(question.messageId) ??
            nearestPerson;
          const state = stateFor(question, decider, laterQuestion);
          const next = withState(message, question, state, derived);
          if (next !== message) {
            updated ??= messages.slice();
            updated[index] = next;
          }
          laterQuestion = true;
          nearestPerson = undefined;
        }
      } else if (message.role === "user") {
        // An explicit question-answer or targeted reply addresses one specific
        // message and must not close an unrelated card standing between them.
        if (!anyAnswerOf(message) && !message.replyToMessageId) {
          nearestPerson = message;
          laterQuestion = false;
        }
      } else if (message.role === "assistant" && !isBackgroundStationMessage(message)) {
        // An intervening non-station assistant message (such as a newer
        // proactive alert) claims any later un-targeted free-text reply so it
        // cannot jump backward and mark an earlier unrelated card as replied.
        nearestPerson = undefined;
      }
    }

    const withStates = updated ?? messages;
    lastOutput = omitSilentQuestionAnswers(withStates, independentQuestionIds);
    return lastOutput;
  }

  return { inTranscript, inServerMessages };
}

/**
 * Whether a user message only folds an independent or externally resolved
 * question card (so its state is already shown in-place on the target card and
 * rendering a standalone bubble or cross-thread reply line at the bottom of the
 * chat would mislead the reader).
 */
export function isSilentQuestionAnswerMessage(
  message: ChatMessage,
  independentQuestionIds?: ReadonlySet<string>
): boolean {
  if (message.role !== "user" || message.delivery === "failed") return false;
  const answer = anyAnswerOf(message);
  if (!answer) return false;
  if (message.clientRequestId?.startsWith("sf-card-sync:")) return true;
  if ((message.attachments?.length ?? 0) > 0 || (message.refs?.length ?? 0) > 0) {
    return false;
  }
  if (independentQuestionIds?.has(answer.questionMessageId)) return true;
  return (
    message.text.trim() === "" &&
    (message.parts ?? []).every((part) => part.kind === "question-answer")
  );
}

function isBackgroundStationMessage(message: ChatMessage): boolean {
  return message.clientRequestId?.startsWith("station-task:") === true;
}

function omitSilentQuestionAnswers(
  messages: ChatMessage[],
  independentQuestionIds: ReadonlySet<string>
): ChatMessage[] {
  let filtered: ChatMessage[] | undefined;
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index]!;
    if (isSilentQuestionAnswerMessage(message, independentQuestionIds)) {
      filtered ??= messages.slice(0, index);
    } else if (filtered) {
      filtered.push(message);
    }
  }
  return filtered ?? messages;
}

function finalizeVisibleMessages(
  messages: ChatMessage[],
  independentQuestionIds: ReadonlySet<string>,
  transform: (message: ChatMessage) => ChatMessage
): ChatMessage[] {
  let output: ChatMessage[] | undefined;
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index]!;
    if (isSilentQuestionAnswerMessage(message, independentQuestionIds)) {
      output ??= messages.slice(0, index);
      continue;
    }
    const next = transform(message);
    if (output) {
      output.push(next);
    } else if (next !== message) {
      output = messages.slice(0, index);
      output.push(next);
    }
  }
  return output ?? messages;
}

type Derived = WeakMap<ChatMessage, { state: ChatQuestionState; message: ChatMessage }>;

function hasQuestion(message: ChatMessage) {
  return message.parts?.some((part) => part.kind === "question") === true;
}

function questionOf(message: ChatMessage): ChatQuestionPart | undefined {
  return message.parts?.find(
    (part): part is ChatQuestionPart => part.kind === "question"
  );
}

function anyAnswerOf(message: ChatMessage): ChatQuestionAnswerPart | undefined {
  return message.parts?.find(
    (part): part is ChatQuestionAnswerPart => part.kind === "question-answer"
  );
}

function answerOf(
  message: ChatMessage,
  questionMessageId: string
): ChatQuestionAnswerPart | undefined {
  return message.parts?.find(
    (part): part is ChatQuestionAnswerPart =>
      part.kind === "question-answer" && part.questionMessageId === questionMessageId
  );
}

function stateFor(
  question: ChatQuestionPart,
  person: ChatMessage | undefined,
  laterQuestion: boolean
): ChatQuestionState {
  if (!person) return laterQuestion ? { status: "replaced" } : OPEN;
  const answer = answerOf(person, question.messageId);
  if (!answer) return { status: "replied" };
  const given = {
    ...(answer.choiceIds.length > 0 ? { choiceIds: answer.choiceIds } : {}),
    ...(answer.other !== undefined ? { other: answer.other } : {}),
  };
  if (person.delivery === "failed") {
    return {
      status: "failed",
      ...given,
      ...(person.error ? { error: person.error } : {}),
    };
  }
  if (person.delivery === "sending") return { status: "sending", ...given };
  return answer.skipped ? { status: "skipped" } : { status: "answered", ...given };
}

function withState(
  message: ChatMessage,
  question: ChatQuestionPart,
  state: ChatQuestionState,
  derived: Derived
): ChatMessage {
  if (sameQuestionState(question.state, state)) return message;
  const known = derived.get(message);
  if (known && sameQuestionState(known.state, state)) return known.message;
  const next: ChatMessage = {
    ...message,
    parts: message.parts!.map((part) =>
      part === question ? { ...question, state } : part
    ),
  };
  derived.set(message, { state, message: next });
  return next;
}
