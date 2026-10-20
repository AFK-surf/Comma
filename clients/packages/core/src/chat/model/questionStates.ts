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
    for (const message of transcript) {
      const question = questionOf(message);
      if (question) states.set(question.messageId, question.state);
    }
    let output: ChatMessage[] | undefined;
    if (states.size > 0) {
      server.forEach((message, index) => {
        const question = questionOf(message);
        const state = question && states.get(question.messageId);
        if (!question || !state) return;
        const next = withState(message, question, state, derived);
        if (next !== message) (output ??= server.slice())[index] = next;
      });
    }
    lastServer = { server, transcript, output: output ?? server };
    return lastServer.output;
  }

  function inTranscript(messages: ChatMessage[]): ChatMessage[] {
    if (messages === lastInput) return lastOutput;
    lastInput = messages;
    if (!messages.some(hasQuestion)) {
      lastOutput = messages;
      return messages;
    }

    let output: ChatMessage[] | undefined;
    let nearestPerson: ChatMessage | undefined;
    let laterQuestion = false;
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const message = messages[index]!;
      const question = questionOf(message);
      if (question) {
        const state = stateFor(question, nearestPerson, laterQuestion);
        const next = withState(message, question, state, derived);
        if (next !== message) {
          output ??= messages.slice();
          output[index] = next;
        }
        laterQuestion = true;
        nearestPerson = undefined;
      } else if (message.role === "user") {
        nearestPerson = message;
        laterQuestion = false;
      }
    }

    lastOutput = output ?? messages;
    return lastOutput;
  }

  return { inTranscript, inServerMessages };
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
