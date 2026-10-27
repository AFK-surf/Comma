import type {
  ChatCommandReceipt,
  ChatLeasedAttachInput,
  ChatLeasedClientRequestInput,
  ChatLeasedSetTaskRunInput,
  ChatLeasedSetTaskStatusInput,
  ChatLeasedTarget,
} from "@comma/chat-contract";
import { Effect } from "effect";
import type { QuestionAnswer } from "../model/conversationChannel";
import type { ChatEntries } from "./entries/ChatEntries";
import type { ChatPublisher } from "./entries/ChatPublisher";

/**
 * Leased commands on the conversation itself rather than its draft, so their
 * receipts carry no draft epoch.
 */
export class ConversationCommands {
  readonly #entries: ChatEntries;
  readonly #publisher: ChatPublisher;

  constructor(entries: ChatEntries) {
    this.#entries = entries;
    this.#publisher = entries.publisher;
  }

  retry(input: ChatLeasedClientRequestInput): Effect.Effect<ChatCommandReceipt, Error> {
    return Effect.suspend(() => {
      const entry = this.#entries.required(input);
      return entry.channel.retry(input.clientRequestId).pipe(
        Effect.map(() => {
          entry.boundary.assertCurrent();
          return this.#publisher.receipt();
        })
      );
    });
  }

  /**
   * Answers a question card. A card answer is not the composer's send: it neither reserves nor consumes the draft,
   * so it takes no draft lease.
   */
  answerQuestion(
    input: ChatLeasedTarget & QuestionAnswer
  ): Effect.Effect<ChatCommandReceipt, Error> {
    return Effect.suspend(() => {
      const entry = this.#entries.required(input);
      return entry.channel
        .answerQuestion({
          questionMessageId: input.questionMessageId,
          choiceIds: input.choiceIds,
          ...(input.other !== undefined ? { other: input.other } : {}),
          skipped: input.skipped,
        })
        .pipe(
          Effect.map(() => {
            entry.boundary.assertCurrent();
            return this.#publisher.receipt();
          })
        );
    });
  }

  attachQuestion(
    input: ChatLeasedTarget & {
      questionMessageId: string;
      files: Pick<ChatLeasedAttachInput, "bytes" | "name" | "size">[];
    }
  ): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    entry.channel.attachFiles(
      input.files.map((file) => ({
        data: new Blob([file.bytes]),
        name: file.name,
        size: file.size,
      })),
      input.questionMessageId
    );
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  removeQuestionAttachment(
    input: ChatLeasedTarget & { questionMessageId: string; attachmentId: string }
  ): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    entry.channel.removeAttachment(input.attachmentId, input.questionMessageId);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  retryQuestionAttachment(
    input: ChatLeasedTarget & { questionMessageId: string; attachmentId: string }
  ): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    entry.channel.retryAttachment(input.attachmentId, input.questionMessageId);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  discard(input: ChatLeasedClientRequestInput): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    entry.channel.discard(input.clientRequestId);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  acceptTaskReview(
    input: ChatLeasedTarget & { reviewVersion: number }
  ): Effect.Effect<ChatCommandReceipt, Error> {
    return Effect.suspend(() => {
      const entry = this.#entries.required(input);
      return entry.channel.acceptTaskReview(input.reviewVersion).pipe(
        Effect.map(() => {
          entry.boundary.assertCurrent();
          return this.#publisher.receipt();
        })
      );
    });
  }

  setTaskStatus(
    input: ChatLeasedSetTaskStatusInput
  ): Effect.Effect<ChatCommandReceipt, Error> {
    return Effect.suspend(() => {
      const entry = this.#entries.required(input);
      return entry.channel.setTaskStatus(input.status, input.expectedUpdatedAt).pipe(
        Effect.map(() => {
          entry.boundary.assertCurrent();
          return this.#publisher.receipt();
        })
      );
    });
  }

  setTaskRun(
    input: ChatLeasedSetTaskRunInput
  ): Effect.Effect<ChatCommandReceipt, Error> {
    return Effect.suspend(() => {
      const entry = this.#entries.required(input);
      return entry.channel.setTaskRun(input.run).pipe(
        Effect.map(() => {
          entry.boundary.assertCurrent();
          return this.#publisher.receipt();
        })
      );
    });
  }

  refresh(input: ChatLeasedTarget): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    entry.channel.refresh();
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  /** Reads the page of history before the oldest message the transcript holds. */
  older(input: ChatLeasedTarget): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    entry.channel.loadOlder();
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  /** Reads a Task's history before the transcript held, for its Activity alone. */
  readTaskActivity(input: ChatLeasedTarget): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    entry.channel.readActivityHistory();
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }
}
