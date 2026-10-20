// Main's part of chat now that the conversations are the client core's: what only Main can do, through its own core
// client. Files AirDrop received go to the intake the core opens for a window's draft (`chat.intake.receive`), and
// files dropped on a window drive an intake (`chat.intake.claim`); each attaches what Main registered. The file picker
// registers under the intake the core opened for it (pick.ts); a notification's reply sends; Main hears the notices
// the core words for new messages and committed local files (marked bound); it tells the core the connector's device
// ids and its language.
import type {
  ChatCommandReceipt,
  ChatLeasedAttachInput,
  ChatLeasedAttachLocalFilesInput,
  ChatLeasedTarget,
  ChatTarget,
} from "@comma/chat-contract";
import type {
  ChatAppendedValue,
  ChatCommittedFilesValue,
  ChatIntakeRoom,
  Calls,
} from "@comma/core/contract";
import type { CoreClient } from "@comma/core-kernel/client";

/** How one attachment intake ended (`chat.intake.settle`). */
export type ChatAttachmentIntakeOutcome = {
  cancelled: boolean;
  errorCount: number;
  errors?: readonly unknown[];
};

/**
 * One intake a picker or AirDrop holds. `assertCurrent` is the synchronous fence each file registration checks: it
 * fails once `refresh` (asked of the core right before) found the intake no longer the draft's.
 */
export interface MainChatIntake {
  readonly intakeId: string;
  /** Asks the core whether the intake is still its draft's. */
  refresh(): Promise<void>;
  assertCurrent(): void;
  markDialogClosed(): void;
  settle(outcome: ChatAttachmentIntakeOutcome): Promise<void>;
  releaseIfUnused(): void;
}

export type MainChatTarget = ChatLeasedTarget & { surfaceId: string };

/** An intake the core opened for files the computer received: settling it lets the draft's send go on. */
export type MainChatReceivedIntake = Pick<
  MainChatIntake,
  "intakeId" | "assertCurrent" | "settle"
> & {
  /** Asks the core whether the intake is still its draft's: the room the draft has then. */
  refresh(): Promise<ChatIntakeRoom>;
  /** Attaches files Main registered to the intake's draft. */
  attach(items: Calls["chat.intake.attach"]["params"]["items"]): Promise<void>;
};

export type MainChatReceived =
  | { refused: "no_chat"; title?: undefined }
  | { refused: "directory"; title: string }
  | {
      refused?: undefined;
      title: string;
      workspaceId: string;
      intake: MainChatReceivedIntake;
    };

export class MainChat {
  readonly #client: () => CoreClient | undefined;
  /** What Main last told the core, told again to a core that started again (it remembers nothing). */
  #devices: Record<string, string> | undefined;
  #locale: string | undefined;
  #rejoinOf: CoreClient | undefined;

  constructor(client: () => CoreClient | undefined) {
    this.#client = client;
  }

  /** Re-sends the device ids and locale each time the core Main talks to started again. */
  #followRejoin(): void {
    const client = this.#client();
    if (!client || client === this.#rejoinOf) return;
    this.#rejoinOf = client;
    client.onRejoin(() => {
      if (this.#devices) this.#tell("chat.clientDevices", { devices: this.#devices });
      if (this.#locale !== undefined)
        this.#tell("chat.locale", { locale: this.#locale });
    });
  }

  #tell(name: string, params: unknown): void {
    void this.#call(name, params).catch(() => undefined);
  }

  #call<R>(name: string, params: unknown): Promise<R> {
    const client = this.#client();
    if (!client) return Promise.reject(new Error("The Comma core is not running."));
    return client.call(name, params) as Promise<R>;
  }

  /** A reply sent with no view of the conversation (a notification banner's). */
  async sendDetached(target: ChatTarget, text: string): Promise<void> {
    await this.#call("chat.sendDetached", { ...target, text });
  }

  /**
   * Files the computer received for window `surfaceId`: the intake the core opened on the draft of the conversation
   * the window shows, or why the core refused them.
   */
  async receive(
    surfaceId: string,
    files: readonly { name: string; isDirectory: boolean }[]
  ): Promise<MainChatReceived> {
    const answer = await this.#call<Calls["chat.intake.receive"]["result"]>(
      "chat.intake.receive",
      { surfaceId, files }
    );
    if ("refused" in answer) return answer;
    const fence = this.#fence(answer.intakeId);
    return {
      title: answer.title,
      workspaceId: answer.workspaceId,
      intake: {
        intakeId: answer.intakeId,
        refresh: fence.refresh,
        assertCurrent: fence.assertCurrent,
        attach: async (items) => {
          await this.#call("chat.intake.attach", { intakeId: answer.intakeId, items });
        },
        settle: async (outcome) => {
          await this.#call("chat.intake.settle", {
            intakeId: answer.intakeId,
            outcome,
          }).catch(() => undefined);
          // The session may have ended: the intake is gone then, which changes nothing.
          await this.#call("chat.intake.release", { intakeId: answer.intakeId }).catch(
            () => undefined
          );
        },
      },
    };
  }

  retain(target: ChatLeasedTarget): Promise<ChatCommandReceipt> {
    return this.#call("chat.retain", target);
  }

  async release(target: ChatLeasedTarget): Promise<void> {
    await this.#call("chat.release", target).catch(() => undefined);
  }

  attach(input: ChatLeasedAttachInput): Promise<ChatCommandReceipt> {
    return this.#call("chat.attach", input);
  }

  attachLocalFiles(
    input: ChatLeasedAttachLocalFilesInput
  ): Promise<ChatCommandReceipt> {
    return this.#call("chat.attachLocalFiles", input);
  }

  /** Opens an intake for `target`'s draft: the draft's send waits until it settles. */
  async claim(target: MainChatTarget): Promise<MainChatIntake> {
    const { intakeId } = await this.#call<{ intakeId: string }>(
      "chat.intake.claim",
      target
    );
    const fence = this.intake(intakeId);
    let active = true;
    return {
      ...fence,
      assertCurrent: () => {
        if (!active)
          throw new Error("The Chat attachment intake claim is no longer active.");
        fence.assertCurrent();
      },
      settle: async (outcome) => {
        await this.#call("chat.intake.settle", { intakeId, outcome }).catch(
          () => undefined
        );
      },
      releaseIfUnused: () => {
        if (!active) return;
        active = false;
        void this.#call("chat.intake.release", { intakeId }).catch(() => undefined);
      },
    };
  }

  /**
   * An intake the core holds, as Main registers files under it: the one Main claimed, or the one the core opened
   * for its own file pick (the core settles that one). `assertCurrent` fails once `refresh` found it gone.
   */
  intake(
    intakeId: string
  ): Pick<
    MainChatIntake,
    "intakeId" | "refresh" | "assertCurrent" | "markDialogClosed"
  > {
    const fence = this.#fence(intakeId);
    return {
      intakeId,
      refresh: async () => {
        await fence.refresh();
      },
      assertCurrent: fence.assertCurrent,
      markDialogClosed: () => {
        void this.#call("chat.intake.dialogClosed", { intakeId }).catch(
          () => undefined
        );
      },
    };
  }

  /** Intake `intakeId` as the core last said: `refresh` asks it (the draft's room), `assertCurrent` reads the answer. */
  #fence(intakeId: string) {
    let current = true;
    return {
      refresh: async (): Promise<ChatIntakeRoom> => {
        try {
          return await this.#call<ChatIntakeRoom>("chat.intake.check", { intakeId });
        } catch (error) {
          current = false;
          throw error;
        }
      },
      assertCurrent: () => {
        if (!current)
          throw new Error("The Chat attachment intake claim is no longer active.");
      },
    };
  }

  /** The connector's device id per workspace, sent with each message. */
  setClientDevices(devices: Record<string, string>): void {
    this.#devices = devices;
    this.#followRejoin();
    this.#tell("chat.clientDevices", { devices });
  }

  /** The language Main words chat's messages in. */
  setLocale(locale: string): void {
    this.#locale = locale;
    this.#followRejoin();
    this.#tell("chat.locale", { locale });
  }

  /**
   * Follows what Main must act on: each conversation's newly appended canonical messages (`onAppended`, once each)
   * and each send's committed local files (`onCommitted`). Returns a stop.
   */
  follow(handlers: {
    onAppended?: (appended: ChatAppendedValue) => void;
    onCommitted?: (committed: ChatCommittedFilesValue) => void;
  }): () => void {
    const client = this.#client();
    if (!client) return () => undefined;
    // What the core kept before Main followed is old news; a core that started again counts from 0.
    let lastAppended: number | null = null;
    let lastCommitted: number | null = null;
    const stops = [
      handlers.onAppended
        ? client.subscribe(
            { topic: "chatAppended" },
            (value) => {
              const appended = (value as { appended: ChatAppendedValue[] }).appended;
              const newest = appended.at(-1)?.seq ?? 0;
              if (lastAppended === null || newest < lastAppended) {
                lastAppended = newest;
                return;
              }
              for (const item of appended)
                if (item.seq > lastAppended) handlers.onAppended!(item);
              lastAppended = newest;
            },
            () => undefined
          )
        : () => undefined,
      handlers.onCommitted
        ? client.subscribe(
            { topic: "chatCommittedFiles" },
            (value) => {
              const committed = (value as { committed: ChatCommittedFilesValue[] })
                .committed;
              const newest = committed.at(-1)?.seq ?? 0;
              // Committed files are marked bound even if Main joined late: marking is idempotent.
              for (const item of committed)
                if (lastCommitted === null || item.seq > lastCommitted)
                  handlers.onCommitted!(item);
              lastCommitted = newest;
            },
            () => undefined
          )
        : () => undefined,
    ];
    return () => {
      for (const stop of stops) stop();
    };
  }
}
