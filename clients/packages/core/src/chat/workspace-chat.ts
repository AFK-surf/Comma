// The account's chat with Comma (`workspaceChat`): its default workspace's Group chat, or with `workspace` that
// workspace's. The core resolves it once signed in and every client opens it from here. While the server still makes
// the workspace, the core waits as long as it says (1–10 s) and asks again; a chat it found before is shown at once
// (`kept`) and confirmed or replaced by the server's answer.
//
// Bound: one resolution at a time for each topic while it is shown, one request per wait while the workspace is made,
// nothing after an answer that settles it. A chat not found waits for `workspaceChat.retry`.
import type { ChatWorkspaceResolution } from "@comma/chat-contract";
import { topicKey, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import type { WorkspaceChat, WorkspaceChatValue } from "../contract.ts";
import { type Ctx, Live } from "../ctx.ts";

/** Where the default chat found before is kept on the device (the account's meta). */
const KEPT = "workspaceChat";
const MAX_WAIT_S = 10;

const LOADING: WorkspaceChatValue = { status: "loading", chat: null, kept: false };

export class WorkspaceChats {
  readonly #ctx: Ctx;
  readonly #live: Live;
  readonly #resolve: (
    workspaceId?: string
  ) => Effect.Effect<ChatWorkspaceResolution, Error>;
  readonly #values = new Map<string, WorkspaceChatValue>();
  /** Topics whose resolution is under way. */
  readonly #running = new Map<string, symbol>();
  #accountKey: string | null = null;

  constructor(
    ctx: Ctx,
    resolve: (workspaceId?: string) => Effect.Effect<ChatWorkspaceResolution, Error>
  ) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    this.#resolve = resolve;
    ctx.kernel.source("workspaceChat", {
      start: (topic) => this.#start(topic),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#running.delete(topicKey(topic));
      },
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key !== this.#accountKey) {
        // Another account (or none): nothing of the one before is shown, and what is shown is resolved again.
        this.#accountKey = key;
        this.#values.clear();
        for (const topic of this.#shown()) {
          this.#live.stop(topic);
          ctx.kernel.store.invalidate(topic);
          this.#start(topic);
        }
        return;
      }
      // The same account opened (its session confirmed): what waited for it is resolved now.
      for (const topic of this.#shown())
        if (!this.#running.has(topicKey(topic)) && !this.#values.has(topicKey(topic)))
          this.#start(topic);
    });
  }

  /** Resolves again a chat not found (failed, hidden, refused: `workspaceChat.retry`); one under way goes on. */
  retry(workspace: string | undefined): void {
    for (const topic of this.#shown()) {
      if (String(topic.workspace ?? "") !== (workspace ?? "")) continue;
      // A resolution under way, or one that found the chat, is the answer already.
      if (this.#running.has(topicKey(topic))) continue;
      if (this.#values.get(topicKey(topic))?.status === "ready") continue;
      this.#live.stop(topic);
      this.#start(topic);
    }
  }

  #shown(): Topic[] {
    return this.#ctx.kernel.store
      .liveTopics()
      .filter((topic) => topic.topic === "workspaceChat");
  }

  #value(topic: Topic): WorkspaceChatValue {
    const value = this.#values.get(topicKey(topic));
    if (value) return value;
    const kept = topic.workspace ? null : this.#kept();
    return kept ? { status: "ready", chat: kept, kept: true } : LOADING;
  }

  #kept(): WorkspaceChat | null {
    return this.#ctx.session.current()?.meta<WorkspaceChat>(KEPT) ?? null;
  }

  #set(topic: Topic, value: WorkspaceChatValue): void {
    this.#values.set(topicKey(topic), value);
    this.#ctx.kernel.store.invalidate(topic);
  }

  #start(topic: Topic): void {
    const ctx = this.#ctx;
    const key = topicKey(topic);
    const workspace = String(topic.workspace ?? "") || undefined;
    const run = Symbol(key);
    this.#running.set(key, run);
    this.#live.run(
      topic,
      Effect.gen({ self: this }, function* () {
        for (;;) {
          // With no one signed in it waits: a session that comes starts it again.
          const account = yield* ctx.session.account().pipe(Effect.option);
          if (Option.isNone(account)) return;
          const answer = yield* Effect.result(this.#resolve(workspace));
          if (account.value.closed) return;
          if (Result.isFailure(answer)) {
            // Offline, or the server failed: a chat found before stays shown, and a retry asks again.
            const shown = this.#value(topic);
            this.#set(topic, {
              status: "error",
              chat: shown.chat,
              kept: shown.chat !== null,
            });
            return;
          }
          const resolution = answer.success;
          if (resolution.status === "provisioning") {
            const waitS = Math.min(
              Math.max(resolution.retryAfterSeconds, 1),
              MAX_WAIT_S
            );
            this.#set(topic, {
              status: "provisioning",
              chat: null,
              kept: false,
              provisioning: {
                workspaceId: resolution.workspaceId,
                groupId: resolution.groupId,
                retryAfterSeconds: waitS,
              },
            });
            yield* Effect.sleep(waitS * 1000);
            continue;
          }
          if (resolution.status !== "ready") {
            this.#set(topic, { status: resolution.status, chat: null, kept: false });
            return;
          }
          const chat: WorkspaceChat = {
            workspaceId: resolution.workspaceId,
            groupId: resolution.groupId,
            conversationId: resolution.conversationId,
            ...(resolution.createdAt === undefined
              ? {}
              : { createdAt: resolution.createdAt }),
            ...(resolution.updatedAt === undefined
              ? {}
              : { updatedAt: resolution.updatedAt }),
          };
          if (!workspace) account.value.setMeta(KEPT, chat);
          this.#set(topic, { status: "ready", chat, kept: false });
          return;
        }
      }).pipe(
        // A resolution the session's change cut short: the change starts the next.
        Effect.catchDefect(() => Effect.void),
        Effect.ensuring(
          Effect.sync(() => {
            if (this.#running.get(key) === run) this.#running.delete(key);
          })
        )
      )
    );
  }
}
