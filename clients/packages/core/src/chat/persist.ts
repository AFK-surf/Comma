// Conversations kept on the device, per account (its database's `doc` "chat:<group>/<conversation>"): what each one
// showed last (its conversation, its last 500 messages, the draft) and its unsent messages. A conversation opens from
// it at once, offline too, then reads the server again; a message being sent when the device stopped is sent again
// with the same request id (the server keeps one). While the account is signed in, each group with kept conversations
// has its change feed open (`?changes=1`): a kept conversation no window shows is read again when the server says it
// changed, so the next time it opens it is already current.
//
// Bounds: at most 64 conversations kept (the least recently shown goes), 500 messages each; a change is written once
// it has rested 1 s. One feed per group with kept conversations, reconnected after 1, 2, 4, 8 then 15 s; one read per
// changed conversation at a time (the scheduler's key, background priority), with its validator (a 304 costs nothing).
// A feed's resync reads again only the group's kept conversations, at most 64.
import { CoreError, Priority } from "@comma/core-kernel";
import { Effect, Result, type Fiber } from "effect";
import { z } from "zod";
import type { ChatTarget } from "@comma/chat-contract";
import type { Account } from "../account.ts";
import { route } from "../api.ts";
import {
  commaConversationSchema,
  type CommaConversation,
} from "../comma/api-schemas.ts";
import { API_LANE, type Ctx } from "../ctx.ts";
import { readEvents } from "../sse.ts";
import type { ChatConversationStore } from "./coordinator/hostContract.ts";
import { after, cancel, type ChatEnv, type TimerHandle } from "./env.ts";
import { SeqCoverage } from "./model/seqCoverage.ts";
import {
  idleConversationChannelState,
  messageSeqs,
  normalizeServerMessages,
  type ChatMessage,
  type ConversationChannelState,
  type PendingSend,
} from "./model/conversationChannel.ts";

const MAX_KEPT = 64;
const MAX_MESSAGES = 500;
const WRITE_MS = 1_000;
const RETRY_MS = [1_000, 2_000, 4_000, 8_000, 15_000];
const KEPT_META = "chatKept";

/** A conversation as the device keeps it. */
type Kept = {
  conversation: CommaConversation | undefined;
  serverMessages: ChatMessage[];
  /** The seq ranges of the kept messages that were read whole (`ConversationChannelState.history`). */
  ranges?: [number, number][];
  draft: string;
  pending: PendingSend[];
  /** The validator of the last read, for a background read to cost a 304 when nothing changed. */
  etag?: string;
};

/**
 * The newest messages to keep, and the ranges read among them: a range that reaches before the oldest kept message
 * starts at that message, and one wholly before it goes.
 */
function keptHistory(
  messages: ChatMessage[],
  ranges: readonly (readonly [number, number])[] | undefined
): Pick<Kept, "serverMessages" | "ranges"> {
  const serverMessages = messages.slice(-MAX_MESSAGES);
  const first = serverMessages[0]?.seq;
  if (!ranges?.length || first === undefined) return { serverMessages };
  return {
    serverMessages,
    ranges: SeqCoverage.of(ranges)
      .clip(first, Number.MAX_SAFE_INTEGER)
      .ranges.map(([from, to]): [number, number] => [from, to]),
  };
}

/** The kept conversations, most recently shown first. */
type KeptIndex = ChatTarget[];

const docName = (t: { groupId: string; conversationId: string }) =>
  `chat:${t.groupId}/${t.conversationId}`;
const sameTarget = (a: ChatTarget, b: { groupId: string; conversationId: string }) =>
  a.groupId === b.groupId && a.conversationId === b.conversationId;

/** What the group change feed says (`?changes=1`). */
const changeEventSchema = z.discriminatedUnion("type", [
  z
    .object({
      type: z.literal("conversation_changes_resync_required"),
      group_id: z.string().min(1),
      version: z.string().min(1).max(128),
    })
    .strip(),
  z
    .object({
      type: z.literal("conversation_changed"),
      group_id: z.string().min(1),
      conversation_id: z.string().min(1),
      kind: z.string(),
      change: z.enum(["upsert", "delete", "message"]),
      seq: z.number().int().optional(),
      version: z.string().min(1).max(128),
    })
    .strip(),
]);

export class ChatStore implements ChatConversationStore {
  readonly #ctx: Ctx;
  readonly #env: ChatEnv;
  /** Whether a window shows the conversation now (the coordinator retains it): its channel keeps it current. */
  readonly #shown: (target: ChatTarget) => boolean;
  readonly #dirty = new Map<
    string,
    { target: ChatTarget; state: ConversationChannelState }
  >();
  #timer: TimerHandle | undefined;
  /** Each open group feed (one per group with kept conversations), to stop when its group has none left. */
  readonly #feeds = new Map<string, { fiber?: Fiber.Fiber<unknown, unknown> }>();
  /** The unsent sends last written for each kept conversation: a change of them is written at once. */
  readonly #writtenPending = new Map<string, string>();
  #account: Account | null = null;

  constructor(ctx: Ctx, env: ChatEnv, shown: (target: ChatTarget) => boolean) {
    this.#ctx = ctx;
    this.#env = env;
    this.#shown = shown;
    ctx.session.onChange(() => {
      const account = ctx.session.current();
      if (account === this.#account) return;
      // The account before is already gone from this device (the session deletes an account it lets go, before
      // telling anyone): what it had not written goes with it.
      if (this.#timer !== undefined) {
        cancel(this.#env, this.#timer);
        this.#timer = undefined;
      }
      this.#dirty.clear();
      this.#account = account;
      this.#writtenPending.clear();
      for (const feed of this.#feeds.values())
        if (feed.fiber) ctx.runner.interrupt(feed.fiber);
      this.#feeds.clear();
      if (account)
        for (const group of this.#groups(account)) this.#follow(account, group);
    });
  }

  seed(
    target: ChatTarget
  ): { state: ConversationChannelState; resend: string[] } | undefined {
    const account = this.#ctx.session.current();
    const kept = account?.doc<Kept>(docName(target))?.value;
    if (!account || !kept) return undefined;
    this.#remember(account, target);
    return {
      state: {
        ...idleConversationChannelState,
        conversation: kept.conversation,
        serverMessages: kept.serverMessages,
        messages: kept.serverMessages,
        ...(kept.ranges?.length
          ? { history: { hasOlder: true, loadingOlder: false, ranges: kept.ranges } }
          : {}),
        draft: kept.draft,
        pending: kept.pending,
        status: kept.conversation || kept.serverMessages.length > 0 ? "ready" : "idle",
        syncWarning: "stale",
      },
      resend: kept.pending
        .filter((pending) => pending.status === "sending")
        .map((pending) => pending.clientRequestId),
    };
  }

  changed(target: ChatTarget, state: ConversationChannelState): void {
    // A conversation the server refused (gone, forbidden) is not kept.
    if (state.errorKind && state.errorKind !== "network") return;
    this.#dirty.set(docName(target), { target, state });
    // An unsent send is written at once: a device that stops right after sends it again (same request id), and a
    // send that ended is not sent again.
    if (
      pendingKey(state.pending) !== (this.#writtenPending.get(docName(target)) ?? "[]")
    ) {
      this.flush();
      return;
    }
    if (this.#timer !== undefined) return;
    this.#timer = after(this.#env, WRITE_MS, () => {
      this.#timer = undefined;
      this.flush();
    });
  }

  /**
   * Writes every change not yet written: at once for an unsent send, and when the core is closed in order
   * (`Core.close`). A core that is stopped without it (its process or tab ends) loses at most the last second of
   * draft edits; an unsent send is already written.
   */
  flush(): void {
    if (this.#timer !== undefined) {
      cancel(this.#env, this.#timer);
      this.#timer = undefined;
    }
    const account = this.#account;
    const dirty = [...this.#dirty.values()];
    this.#dirty.clear();
    if (!account || account.closed) return;
    for (const { target, state } of dirty) {
      const pending = state.pending;
      this.#writtenPending.set(docName(target), pendingKey(pending));
      if (
        !state.conversation &&
        state.serverMessages.length === 0 &&
        !state.draft &&
        !pending.length
      ) {
        // Nothing left to keep: what was kept goes, so no send ended here comes back.
        if (account.doc(docName(target))) this.#forget(account, target);
        continue;
      }
      const was = account.doc<Kept>(docName(target))?.value;
      this.#keep(account, target, {
        conversation: state.conversation
          ? withoutMessages(state.conversation)
          : was?.conversation,
        ...keptHistory(state.serverMessages, state.history?.ranges),
        draft: state.draft,
        pending,
        ...(was?.etag ? { etag: was.etag } : {}),
      });
    }
  }

  #keep(account: Account, target: ChatTarget, kept: Kept): void {
    account.putDoc(docName(target), kept, this.#ctx.now());
    this.#remember(account, target);
  }

  /** `target` is the most recently shown; past 64, the least recently shown is let go. */
  #remember(account: Account, target: ChatTarget): void {
    const index = account.meta<KeptIndex>(KEPT_META) ?? [];
    const next = [
      {
        workspaceId: target.workspaceId,
        groupId: target.groupId,
        conversationId: target.conversationId,
      },
      ...index.filter((item) => !sameTarget(item, target)),
    ];
    const gone = next.splice(MAX_KEPT);
    for (const item of gone) account.deleteDoc(docName(item));
    account.setMeta(KEPT_META, next);
    for (const item of gone) this.#unfollowIfNone(account, item.groupId);
    if (!this.#feeds.has(target.groupId)) this.#follow(account, target.groupId);
  }

  #forget(account: Account, target: { groupId: string; conversationId: string }): void {
    account.deleteDoc(docName(target));
    this.#writtenPending.delete(docName(target));
    const index = account.meta<KeptIndex>(KEPT_META) ?? [];
    account.setMeta(
      KEPT_META,
      index.filter((item) => !sameTarget(item, target))
    );
    this.#unfollowIfNone(account, target.groupId);
  }

  /** A group with no kept conversation left has no feed. */
  #unfollowIfNone(account: Account, group: string): void {
    if (this.#groups(account).includes(group)) return;
    const feed = this.#feeds.get(group);
    this.#feeds.delete(group);
    if (feed?.fiber) this.#ctx.runner.interrupt(feed.fiber);
  }

  /** The group is gone or no longer the account's (403/404): nothing of it is kept, and its feed ends. */
  #forgetGroup(account: Account, group: string): void {
    // The feed calling this ends by itself: it is no longer the group's, so forgetting does not interrupt it.
    this.#feeds.delete(group);
    for (const kept of account.meta<KeptIndex>(KEPT_META) ?? [])
      if (kept.groupId === group) this.#forget(account, kept);
  }

  #groups(account: Account): string[] {
    return [
      ...new Set(
        (account.meta<KeptIndex>(KEPT_META) ?? []).map((item) => item.groupId)
      ),
    ];
  }

  /** The group's change feed while the account is signed in: each change reads a kept conversation again. */
  #follow(account: Account, group: string): void {
    if (this.#feeds.has(group)) return;
    const ctx = this.#ctx;
    const once = Effect.scoped(
      Effect.gen({ self: this }, function* () {
        const body = yield* ctx.api.stream(
          account,
          `${route`/v1/comma/groups/${group}/conversations/events`}?changes=1`
        );
        backoff = 0;
        yield* readEvents(body, (value) =>
          Effect.gen({ self: this }, function* () {
            const event = changeEventSchema.safeParse(value);
            if (!event.success)
              return yield* Effect.fail(
                new CoreError("bad_response", "an event outside the feed")
              );
            if (event.data.group_id !== group)
              return yield* Effect.fail(
                new CoreError("bad_response", "an event of another group")
              );
            if (event.data.type === "conversation_changes_resync_required") {
              // What changed while no feed was open is unknown: the kept ones of this group are read again.
              for (const kept of account.meta<KeptIndex>(KEPT_META) ?? [])
                if (kept.groupId === group) this.#refresh(account, kept);
              return;
            }
            const change = event.data;
            const kept = (account.meta<KeptIndex>(KEPT_META) ?? []).find((item) =>
              sameTarget(item, {
                groupId: group,
                conversationId: change.conversation_id,
              })
            );
            if (!kept) return;
            if (change.change === "delete") this.#forget(account, kept);
            else this.#refresh(account, kept);
          })
        );
      })
    );
    let backoff = 0;
    const feed: { fiber?: Fiber.Fiber<unknown, unknown> } = {};
    this.#feeds.set(group, feed);
    feed.fiber = ctx.runner.fork(
      Effect.gen({ self: this }, function* () {
        for (;;) {
          const ended = yield* Effect.result(once);
          if (
            account.closed ||
            this.#account !== account ||
            this.#feeds.get(group) !== feed
          )
            return;
          if (
            Result.isFailure(ended) &&
            (ended.failure.status === 403 || ended.failure.status === 404)
          ) {
            this.#forgetGroup(account, group);
            return;
          }
          yield* Effect.sleep(RETRY_MS[Math.min(backoff, RETRY_MS.length - 1)]!);
          backoff++;
        }
      })
    );
  }

  /** Reads a kept conversation no window shows again, in the background; one shown keeps itself current. */
  #refresh(account: Account, target: ChatTarget): void {
    if (this.#shown(target)) return;
    const ctx = this.#ctx;
    const path = route`/v1/comma/groups/${target.groupId}/conversations/${target.conversationId}`;
    const read = Effect.gen({ self: this }, function* () {
      const was = account.doc<Kept>(docName(target))?.value;
      if (!was) return;
      const answer = yield* Effect.result(
        ctx.api.get(
          account,
          `${path}?message_limit=${MAX_MESSAGES}`,
          commaConversationSchema,
          was.etag
        )
      );
      if (account.closed || this.#shown(target)) return;
      if (Result.isFailure(answer)) {
        // Gone or no longer this account's: not kept. Anything else is tried at the next change.
        if (answer.failure.status === 404 || answer.failure.status === 403)
          this.#forget(account, target);
        return;
      }
      if (answer.success.notModified) return;
      const conversation = answer.success.value;
      const serverMessages = normalizeServerMessages(
        conversation.messages ?? [],
        was.serverMessages,
        conversation.kind,
        target.conversationId
      );
      account.putDoc(
        docName(target),
        {
          ...was,
          conversation: withoutMessages(conversation),
          ...keptHistory(
            serverMessages,
            SeqCoverage.of(was.ranges ?? [])
              .addRuns(messageSeqs(conversation.messages ?? []))
              .ranges.map(([first, last]): [number, number] => [first, last])
          ),
          ...(answer.success.etag ? { etag: answer.success.etag } : {}),
        } satisfies Kept,
        ctx.now()
      );
    });
    ctx.runner.fork(
      ctx.scheduler.ask(
        API_LANE,
        `${account.dbName}:${docName(target)}`,
        Priority.background,
        read
      )
    );
  }
}

function withoutMessages(conversation: CommaConversation): CommaConversation {
  return { ...conversation, messages: [] };
}

/** The unsent sends' identity and state: what changing writes the conversation at once. */
function pendingKey(pending: readonly PendingSend[]): string {
  return JSON.stringify(pending.map((item) => [item.clientRequestId, item.status]));
}
