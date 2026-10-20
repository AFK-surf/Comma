// A window's view of a conversation (`chatView`): subscribing retains the conversation for that window, and the
// `chatView.*` calls act on it. The core holds the window's lease, so a window keeps nothing of its own but what it
// shows while a call is under way (an edit it typed, a file it is reading).
//
// A window's calls apply in the order it made them (`#inTurn`): an edit made before a send is that message's, one made
// after it is the next draft's. Each call takes its turn on arrival and gives it up once its coordinator step ran;
// what that step started (a send's transmission, a pick's dialog) goes on outside the turn.
import {
  chatRetainInputSchema,
  type ChatCommandReceipt,
  type ChatPickAttachmentsResult,
  type ChatRetainInput,
  type ConversationProjection,
} from "@comma/chat-contract";
import {
  CoreError,
  type Call,
  type ClientId,
  type Topic,
  type Value,
} from "@comma/core-kernel";
import { Deferred, Effect, Exit, Fiber } from "effect";
import { z } from "zod";
import type { ChatSessionIdentity, ChatViewValue } from "../contract.ts";
import type { Ctx } from "../ctx.ts";
import { asCoreError, parse } from "./calls.ts";
import type { ChatCoordinator } from "./coordinator/ChatCoordinator.ts";
import type { ChatEnv } from "./env.ts";
import type { ConversationChannelState } from "./model/conversationChannel.ts";
import { pickQuota } from "./model/attachmentQuota.ts";
import { attachTextsToMessage, MAX_ATTACHMENTS_PER_MESSAGE } from "./model/protocol.ts";
import { projectionToChannelState } from "./view-state.ts";

/** A failed pick's row (coordinator/intake/intakeOutcomes.ts). */
const INTAKE_FAILURE_PREFIX = "chat-intake-failure:";

/** What the views need of the core's chat. */
export interface ChatViewHost {
  readonly ctx: Ctx;
  readonly env: ChatEnv;
  coordinator(): ChatCoordinator;
  identity(): ChatSessionIdentity;
  /** Refuses a client acting for another window. */
  own(client: ClientId, input: { surfaceId: string; subscriberId: string }): void;
  /** What every chat call waits for (the account's data open) and checks (the session it names); its params left. */
  admit(name: string, params: unknown): Effect.Effect<unknown, CoreError>;
  /** A pick through Electron's file dialog, for a leased draft. */
  pick(
    input: ChatRetainInput & {
      surfaceId: string;
      maxFiles: number;
      maxTotalSize: number;
      maxUploadFiles: number;
    }
  ): Effect.Effect<ChatPickAttachmentsResult, Error>;
}

const targetSchema = z.object({
  workspace: z.string().min(1),
  group: z.string().min(1),
  conversation: z.string().min(1),
  surface: z.string().min(1),
});

const sendSchema = targetSchema.extend({
  text: z.string(),
  consumeDraft: z.literal(false).optional(),
  clientRequestId: z.string().min(8).max(128).optional(),
  replyToMessageId: z.string().min(1).optional(),
  skills: z
    .array(z.object({ location: z.string().min(1) }))
    .max(50)
    .optional(),
  attachedTexts: z
    .array(z.object({ source: z.string().min(1).optional(), text: z.string().min(1) }))
    .max(50)
    .optional(),
  files: z
    .array(
      z.object({
        name: z.string().min(1).max(1024),
        size: z.number().int().nonnegative(),
        bytes: z.instanceof(Uint8Array),
      })
    )
    .min(1)
    .max(MAX_ATTACHMENTS_PER_MESSAGE)
    .optional(),
});

type Target = z.output<typeof targetSchema>;

/** One view: the lease the core holds for its window, and what it showed last. */
type View = {
  lease: ChatRetainInput;
  surfaceId: string;
  /** Retained under the account open now. */
  retained: boolean;
  shown?: { projection: ConversationProjection; state: ConversationChannelState };
};

/** Whether two projections differ in their draft alone (each other field the same object or value). */
function sameButDraft(a: ConversationProjection, b: ConversationProjection): boolean {
  if (a === b) return true;
  const keys = Object.keys(b) as (keyof ConversationProjection)[];
  return (
    keys.length === Object.keys(a).length &&
    keys.every((key) => key === "draft" || a[key] === b[key])
  );
}

/** The subscriber a window's view is, as windows have always named theirs: `surface:group/conversation`. */
function subscriberOf(target: Target): string {
  return `${target.surface}:${target.group}/${target.conversation}`;
}

function targetOf(topic: Topic): Target {
  return {
    workspace: String(topic.workspace),
    group: String(topic.group),
    conversation: String(topic.conversation),
    surface: String(topic.surface),
  };
}

/** A view's lease as the calls that name the window take it. */
const leased = (view: View) => ({ ...view.lease, surfaceId: view.surfaceId });

/** A call's step: what it does at its turn, now or as an effect that starts then. */
type Step<A> = () => A | Effect.Effect<A, Error>;

export class ChatViews {
  readonly #host: ChatViewHost;
  /** The views windows show, by subscriber. */
  readonly #views = new Map<string, View>();
  /** Each client's last call to take its turn: the next one waits for it. */
  readonly #turns = new Map<ClientId, Deferred.Deferred<void>>();

  constructor(host: ChatViewHost) {
    this.#host = host;
    host.ctx.kernel.source("chatView", {
      // Each step shows: an optimistic message before its server's answer.
      coalesce: false,
      // The window let go of it: the coordinator keeps the conversation warm for its own release delay.
      evictAfterMs: 0,
      start: (topic) => {
        const target = targetOf(topic);
        const view: View = {
          lease: chatRetainInputSchema.parse({
            workspaceId: target.workspace,
            groupId: target.group,
            conversationId: target.conversation,
            leaseId: host.env.uuid(),
            subscriberId: subscriberOf(target),
          }),
          surfaceId: target.surface,
          retained: false,
        };
        this.#views.set(view.lease.subscriberId, view);
        this.#retain(view);
      },
      stop: (topic) => {
        const subscriberId = subscriberOf(targetOf(topic));
        const view = this.#views.get(subscriberId);
        if (!view) return;
        this.#views.delete(subscriberId);
        try {
          host.coordinator().release(view.lease);
        } catch {
          // Never retained (signed out), or let go with the account it was of.
        }
      },
      compute: (topic): Value => ({ ok: this.#value(targetOf(topic)) }),
    });
  }

  /**
   * Retains each view not retained yet, once the account is open: one shown while it was opening, or every view after
   * the account changed (`forgetRetained`: the coordinator holds nothing of the last).
   */
  retainAll(): void {
    for (const view of this.#views.values()) this.#retain(view);
  }

  /** The account changed: no view is retained under the new one yet. */
  forgetRetained(): void {
    for (const view of this.#views.values()) view.retained = false;
  }

  #retain(view: View): void {
    if (view.retained || this.#host.ctx.session.current() === null) return;
    try {
      this.#host.coordinator().retain(view.lease);
      view.retained = true;
    } catch {
      // Not retained: the session's next change tries again.
    }
  }

  #value(target: Target): ChatViewValue {
    const host = this.#host;
    const coordinator = host.coordinator();
    const snapshot = coordinator.state();
    const subscriberId = subscriberOf(target);
    const view = this.#views.get(subscriberId);
    const session = host.ctx.session.withheld()
      ? undefined
      : snapshot.sessions.find(
          (s) => s.key === `${target.group}/${target.conversation}`
        );
    if (!session || !view)
      return {
        session: host.identity(),
        revision: snapshot.revision,
        draftEpoch: null,
        lease: null,
        state: null,
      };
    const projection =
      session.surfaceProjections?.find((p) => p.subscriberId === subscriberId)?.state ??
      session.state;
    return {
      session: host.identity(),
      revision: snapshot.revision,
      draftEpoch: session.draftEpoch ?? null,
      lease: { leaseId: view.lease.leaseId, subscriberId },
      state: this.#stateOf(view, projection),
    };
  }

  /**
   * `projection` as the view shows it. A keystroke changes only the draft of the projection the coordinator keeps:
   * the rest of the last state is kept, rather than made again for each key.
   */
  #stateOf(view: View, projection: ConversationProjection): ConversationChannelState {
    const last = view.shown;
    const state =
      last && sameButDraft(last.projection, projection)
        ? last.state.draft === projection.draft
          ? last.state
          : { ...last.state, draft: projection.draft }
        : projectionToChannelState(projection);
    view.shown = { projection, state };
    return state;
  }

  /** The view `params` name, as the calling window's: refused for another window's, or one nobody shows. */
  #view(client: ClientId, params: unknown): View {
    const target = parse(targetSchema, params);
    const subscriberId = subscriberOf(target);
    this.#host.own(client, { surfaceId: target.surface, subscriberId });
    const view = this.#views.get(subscriberId);
    if (!view)
      throw new CoreError(
        "not_retained",
        "This window does not show that conversation."
      );
    return view;
  }

  /**
   * `step` at the client's turn: once its earlier view calls ran theirs and the call is admitted. The turn is taken
   * as the call arrives (the kernel runs a call at once, up to its first wait) and given up once `step` ran; an effect
   * `step` returns runs on outside the turn, as the core's work.
   */
  #inTurn<A>(
    name: string,
    client: ClientId,
    params: unknown,
    step: (rest: unknown) => Step<A>
  ): Effect.Effect<A, CoreError> {
    const turns = this.#turns;
    const host = this.#host;
    return Effect.gen(function* () {
      const mine = yield* Deferred.make<void>();
      const before = turns.get(client);
      turns.set(client, mine);
      const started = yield* Effect.gen(function* () {
        if (before) yield* Deferred.await(before);
        const rest = yield* host.admit(name, params);
        const out = step(rest)();
        return Effect.isEffect(out)
          ? { work: host.ctx.runner.fork(Effect.exit(out)) }
          : { done: out };
      }).pipe(
        Effect.catchDefect((defect) => Effect.fail(asCoreError(defect))),
        Effect.exit,
        Effect.ensuring(
          Effect.andThen(
            Deferred.succeed(mine, undefined),
            Effect.sync(() => {
              if (turns.get(client) === mine) turns.delete(client);
            })
          )
        )
      );
      if (Exit.isFailure(started)) return yield* Effect.failCause(started.cause);
      if ("done" in started.value) return started.value.done;
      return yield* Fiber.join(started.value.work).pipe(
        Effect.flatten,
        Effect.mapError(asCoreError)
      );
    });
  }

  /** `chatView.*`. */
  calls(): Record<string, Call> {
    const c = () => this.#host.coordinator();
    const on = <S extends z.ZodType, A>(
      name: string,
      schema: S,
      run: (
        view: View,
        input: z.output<S>,
        call: { progress(value: unknown): void }
      ) => A | Effect.Effect<A, Error>
    ): [string, Call] => [
      name,
      {
        run: (params, call) =>
          this.#inTurn(name, call.client, params, (rest) => () => {
            const view = this.#view(call.client, rest);
            return run(view, parse(schema, rest), call);
          }),
      },
    ];
    const withDraft = targetSchema.extend({ draft: z.string() });
    const withRequest = targetSchema.extend({ clientRequestId: z.string().min(1) });
    const withAttachment = targetSchema.extend({
      attachmentId: z.string().min(1),
      questionMessageId: z.string().min(1).optional(),
    });
    return Object.fromEntries([
      on("chatView.setDraft", withDraft, (v, i) =>
        c().setDraft({ ...leased(v), draft: i.draft })
      ),
      on("chatView.prefillDraft", withDraft, (v, i) =>
        c().prefillDraft({ ...leased(v), draft: i.draft })
      ),
      on("chatView.send", sendSchema, (v, i, call) => {
        const sendIntentId = this.#host.env.uuid();
        const intent = { ...leased(v), sendIntentId };
        c().beginSendIntent(intent);
        const coordinator = c();
        return coordinator
          .send(
            {
              ...intent,
              text: i.attachedTexts?.length
                ? attachTextsToMessage(i.text, i.attachedTexts)
                : i.text,
              ...(i.consumeDraft === false ? { consumeDraft: false } : {}),
              ...(i.clientRequestId ? { clientRequestId: i.clientRequestId } : {}),
              ...(i.replyToMessageId ? { replyToMessageId: i.replyToMessageId } : {}),
              ...(i.skills ? { skills: i.skills } : {}),
              ...(i.files ? { files: i.files } : {}),
            },
            () => call.progress({ accepted: true })
          )
          .pipe(
            Effect.tapError(() =>
              Effect.sync(() => {
                try {
                  coordinator.cancelSendIntent(intent);
                } catch {
                  // Committed, or the lease is gone: nothing is reserved.
                }
              })
            )
          );
      }),
      on("chatView.retry", withRequest, (v, i) =>
        c().retry({ ...v.lease, clientRequestId: i.clientRequestId })
      ),
      on("chatView.discard", withRequest, (v, i) =>
        c().discard({ ...v.lease, clientRequestId: i.clientRequestId })
      ),
      on("chatView.refresh", targetSchema, (v) => c().refresh(v.lease)),
      on("chatView.older", targetSchema, (v) => c().older(v.lease)),
      on("chatView.readTaskActivity", targetSchema, (v) =>
        c().readTaskActivity(v.lease)
      ),
      on("chatView.clearPresentation", targetSchema, (v) =>
        c().clearPresentation(v.lease)
      ),
      on(
        "chatView.acceptTaskReview",
        targetSchema.extend({ reviewVersion: z.number().int().nonnegative() }),
        (v, i) => c().acceptTaskReview({ ...v.lease, reviewVersion: i.reviewVersion })
      ),
      on(
        "chatView.setTaskStatus",
        targetSchema.extend({
          status: z.enum(["completed", "cancelled"]),
          expectedUpdatedAt: z.number().int().positive(),
        }),
        (v, i) =>
          c().setTaskStatus({
            ...v.lease,
            status: i.status,
            expectedUpdatedAt: i.expectedUpdatedAt,
          })
      ),
      on(
        "chatView.attach",
        targetSchema.extend({
          questionMessageId: z.string().min(1).optional(),
          files: z
            .array(
              z.object({
                name: z.string().min(1).max(1024),
                size: z.number().int().nonnegative(),
                bytes: z.instanceof(Uint8Array),
              })
            )
            .min(1)
            .max(MAX_ATTACHMENTS_PER_MESSAGE),
        }),
        (v, i) => {
          // A question card's images: its other answer takes them, apart from the draft.
          if (i.questionMessageId)
            return c().attachQuestion({
              ...v.lease,
              questionMessageId: i.questionMessageId,
              files: i.files,
            });
          let receipt: ChatCommandReceipt = { revision: c().state().revision };
          for (const file of i.files) receipt = c().attach({ ...leased(v), ...file });
          return receipt;
        }
      ),
      on("chatView.removeAttachment", withAttachment, (v, i) =>
        i.questionMessageId
          ? c().removeQuestionAttachment({
              ...v.lease,
              questionMessageId: i.questionMessageId,
              attachmentId: i.attachmentId,
            })
          : c().removeAttachment({ ...leased(v), attachmentId: i.attachmentId })
      ),
      on("chatView.retryAttachment", withAttachment, (v, i) => {
        if (i.questionMessageId)
          return c().retryQuestionAttachment({
            ...v.lease,
            questionMessageId: i.questionMessageId,
            attachmentId: i.attachmentId,
          });
        const retry = () =>
          c().retryAttachment({ ...leased(v), attachmentId: i.attachmentId });
        // A failed pick's row: another pick takes its place (whatever it picks, the failure is resolved).
        if (!i.attachmentId.startsWith(INTAKE_FAILURE_PREFIX)) return retry();
        const picking = this.#pick(v);
        if (!picking)
          throw new Error(
            "No attachment slot is available for a replacement selection."
          );
        return picking.pipe(Effect.andThen(Effect.sync(retry)));
      }),
      on(
        "chatView.answerQuestion",
        targetSchema.extend({
          questionMessageId: z.string().min(1),
          choiceIds: z.array(z.string().min(1)).max(6),
          other: z.string().max(8000).optional(),
          skipped: z.boolean().optional(),
        }),
        (v, i) =>
          c().answerQuestion({
            ...v.lease,
            questionMessageId: i.questionMessageId,
            choiceIds: i.choiceIds,
            ...(i.other !== undefined ? { other: i.other } : {}),
            skipped: i.skipped === true,
          })
      ),
      on("chatView.pickAttachments", targetSchema, (v) => {
        const picking = this.#pick(v);
        return picking ? Effect.as(picking, true) : false;
      }),
    ]);
  }

  /** A pick for `view`'s draft within its room; undefined when it has none. */
  #pick(view: View): Effect.Effect<ChatPickAttachmentsResult, Error> | undefined {
    const target: Target = {
      workspace: view.lease.workspaceId,
      group: view.lease.groupId,
      conversation: view.lease.conversationId,
      surface: view.surfaceId,
    };
    const quota = pickQuota(this.#value(target).state?.draftAttachments ?? []);
    if (!quota) return undefined;
    return this.#host.pick({ ...view.lease, surfaceId: view.surfaceId, ...quota });
  }
}
