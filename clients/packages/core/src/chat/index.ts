// Chat in the client core: each conversation a UI shows, its messages, sends, drafts and attachments. The engine is
// the coordinator (coordinator/) and its conversation channels (model/), run here on the core's Clock (clock.ts) and
// the account's API (http.ts); a window subscribes to its view of a conversation (`chatView`, views.ts) and makes the
// `chatView.*` calls.
// Electron's Main uses its own core client for what only it can do. It shows the notices the core words for messages
// the Router sends (`chatAppended`: which messages, the banner's title, body and reply placeholder) and sends a
// banner's reply. It hands the core files the computer received (AirDrop): the core picks the window's conversation,
// opens an intake on its draft, says what room the draft has, and attaches what Main registered
// (`chat.intake.receive`, `chat.intake.attach`). A window's file pick (`chatView.pickAttachments`) is the core's: it
// opens the intake, asks Main's file dialog (`DesktopPorts.pickAttachments`), which registers the local files it keeps
// under that intake, and attaches what it gave.
//
// Bounds: the coordinator's (at most 32 conversations retained, one let go 30 s after its last view; one stream per
// retained conversation, reconnected after 250 ms while a reply is awaited, else 3 s, failures backing off 1 s doubling
// to 15 s). A client's leases end when it disconnects.
import {
  chatLeasedAttachInputSchema,
  chatLeasedAttachLocalFilesInputSchema,
  chatLeasedPickAttachmentsInputSchema,
  chatLeasedTargetSchema,
  chatGroupImagePreviewSchema,
  chatLocalFileSchema,
  chatReadGroupImageInputSchema,
  chatReleaseInputSchema,
  chatRetainInputSchema,
  chatTargetSchema,
  chatWorkspaceSkillsInputSchema,
  type ChatCommandReceipt,
  type ChatPickAttachmentsResult,
  type ChatReadGroupImageInput,
  type ChatRuntimeSnapshot,
  type ChatTarget,
} from "@comma/chat-contract";
import {
  baseLocale,
  messages as i18n,
  supportedLocales,
  type CommaLocale,
} from "@comma/i18n";
import {
  CoreError,
  type Call,
  type CallContext,
  type ClientId,
  type Topic,
  type Value,
} from "@comma/core-kernel";
import { Duration, Effect, Fiber } from "effect";

/** The longest the core waits for a workspace being made before it asks again. */
const MAX_PROVISIONING_WAIT_SECONDS = 10;
import { z } from "zod";
import type { ChatSessionIdentity } from "../contract.ts";
import { readFile } from "../files.ts";
import type { Ctx } from "../ctx.ts";
import type { CommaConversation, CommaLocalFileRef } from "./api.ts";
import { coreChatEnv } from "./clock.ts";
import {
  ChatCoordinator,
  type ChatAttachmentIntakeClaim,
  type ChatAttachmentIntakeOutcome,
} from "./coordinator/ChatCoordinator.ts";
import { StaleChatSessionError } from "./coordinator/entries/sessionBoundary.ts";
import { imageMediaTypeOfName } from "./coordinator/workspace/GroupImagePreviews.ts";
import type { ChatEnv } from "./env.ts";
import { createChatApi } from "./http.ts";
import { messageContextInputSchema, readMessageContext } from "./message-context.ts";
import { prepareInputSchema, readPreparedConversation } from "./prepare.ts";
import { ChatStore } from "./persist.ts";
import { asCoreError, parse } from "./calls.ts";
import { route } from "../api.ts";
import { pickQuota } from "./model/attachmentQuota.ts";
import { validateAttachment } from "./model/conversationChannel.ts";
import {
  composeMessageWithAttachments,
  MAX_ATTACHMENTS_PER_MESSAGE,
} from "./model/protocol.ts";
import {
  ChatViews,
  type ConversationHolder,
  type HostedConversations,
} from "./views.ts";
import { WorkspaceChats } from "./workspace-chat.ts";
import type { AttachmentUploadInput, ChatMessage } from "./runtime.ts";

/** At most this many appended messages and committed files are kept for Main to read. */
const RING = 50;

/** One system notification for a message the Router sent, as the core words it (`chatAppended`). */
export type ChatNotice = {
  messageId: string;
  title: string;
  body: string;
  replyPlaceholder: string;
};

/** The notices for the messages one conversation gained (`chatAppended`). */
export type ChatAppended = {
  seq: number;
  target: ChatTarget;
  notices: ChatNotice[];
};

/**
 * What a notice or an AirDrop offer calls `conversation`: Comma for Home chat, whose stored server title is not a name
 * for the person; a Task keeps its own title, the product's name when it has none.
 */
function conversationName(
  conversation: Pick<CommaConversation, "kind" | "title"> | undefined,
  locale: CommaLocale,
  productName: string
): string {
  return conversation?.kind === "user_chat"
    ? i18n.electron_notification_router_title({}, { locale })
    : (conversation?.title ?? "").trim() || productName;
}

/**
 * The notices for `messages`, new in `conversation`: one for each message the core marks as the Router speaking with
 * words to show (`ChatMessage.notice`; files alone give no banner), titled by the conversation's name.
 */
function noticesFor(
  conversation: Pick<CommaConversation, "kind" | "title">,
  messages: readonly ChatMessage[],
  locale: CommaLocale,
  productName: string
): ChatNotice[] {
  const title = conversationName(conversation, locale, productName);
  const replyPlaceholder = i18n.electron_notification_reply_placeholder({}, { locale });
  return messages.flatMap((message) =>
    message.notice?.preview
      ? [
          {
            messageId: message.messageId,
            title,
            body: message.notice.preview,
            replyPlaceholder,
          },
        ]
      : []
  );
}

/** An intake's room: what its draft takes more (`pickQuota`), none once it is full. */
function roomOf(
  attachments: Parameters<typeof pickQuota>[0]
): NonNullable<ReturnType<typeof pickQuota>> {
  return pickQuota(attachments) ?? { maxFiles: 0, maxTotalSize: 0, maxUploadFiles: 0 };
}

/**
 * Files the computer received for a window (`chat.intake.receive`): the window, the conversation it showed then, and
 * the lease the core holds on that conversation until the intake ends (a window that changes conversation does not
 * let it go); `retained` unless `hosted` holds it, which keeps its drafts without one.
 */
type Received = {
  surfaceId: string;
  shown: { subscriberId: string; leaseId: string; workspaceId: string };
  lease: z.output<typeof chatRetainInputSchema>;
  retained: boolean;
};

const receivedItemSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("upload"),
    name: z.string().min(1),
    size: z.number().int().nonnegative(),
    bytes: z.instanceof(Uint8Array),
  }),
  z.object({ kind: z.literal("local_file"), file: chatLocalFileSchema }),
]);

/** Local files a send committed, for Main to mark bound (`chatCommittedFiles`). */
export type ChatCommittedFiles = {
  seq: number;
  files: CommaLocalFileRef[];
  committedAtMs: number | null;
};

const intakeOutcomeSchema = z.object({
  cancelled: z.boolean(),
  errorCount: z.number().int().nonnegative(),
  errors: z.array(z.unknown()).optional(),
});

/** A call's params without the session it names (`session`), and that session. */
function splitSession(p: unknown): { session: unknown; rest: unknown } {
  if (typeof p !== "object" || p === null || !("session" in p))
    return { session: undefined, rest: p };
  const { session, ...rest } = p as { session: unknown };
  return { session, rest };
}

/** Whether a window's session (`asked`) is the one the core works for now. */
function sameSession(asked: unknown, current: ChatSessionIdentity): boolean {
  if (!current || typeof asked !== "object" || asked === null) return false;
  const { sessionId, audience } = asked as { sessionId?: unknown; audience?: unknown };
  return sessionId === current.sessionId && audience === current.audience;
}

/** The owner of an intake the core opened for a pick: Main's own client (one bound to no window) acts on it. */
const DESKTOP = Symbol("desktop");

/** A window's pick: no sources (a window never names a file on this computer). */
const pickInputSchema = chatLeasedPickAttachmentsInputSchema
  .omit({ sources: true })
  .strict();

/** How long a call waits for the core to know the window's sign-in. */
const ACCOUNT_WAIT_MS = 10_000;

export class Chat {
  readonly #ctx: Ctx;
  /** Conversations the coordinator does not hold (a Task a station hosts): their views are shown and acted on there. */
  hosted: HostedConversations | undefined;

  /**
   * What the coordinator answers a call with, as the call's effect: its error as the core's. Work it starts runs in
   * the core's scope, not the call's: a window that goes away does not stop a send under way.
   */
  #call<A>(run: () => A | Effect.Effect<A, Error>): Effect.Effect<A, CoreError> {
    return Effect.suspend(() => {
      const out = run();
      if (!Effect.isEffect(out)) return Effect.succeed(out);
      const work = this.#ctx.runner.fork(Effect.exit(out));
      return Fiber.join(work).pipe(Effect.flatten);
    }).pipe(
      Effect.mapError(asCoreError),
      // A coordinator check that throws (a stale session, a lease that is not held) refuses the call.
      Effect.catchDefect((defect) => Effect.fail(asCoreError(defect)))
    );
  }
  readonly #env: ChatEnv;
  #coordinator: ChatCoordinator;
  /** The windows' views (`chatView`). */
  readonly #views: ChatViews;
  /** The account's chat with Comma (`workspaceChat`). */
  readonly #workspaceChats: WorkspaceChats;
  readonly #store: ChatStore;
  #locale: CommaLocale = baseLocale;
  readonly #deviceIds = new Map<string, string>();
  /** Each client's retained subscribers (by subscriber id), let go when it disconnects. */
  readonly #leases = new Map<
    ClientId,
    Map<string, z.output<typeof chatRetainInputSchema>>
  >();
  /**
   * Open attachment intakes by id, and who may act on each: the client that opened it, or (`DESKTOP`) Main, for an
   * intake the core opened for its own file pick.
   */
  readonly #intakes = new Map<
    string,
    {
      client: ClientId | typeof DESKTOP;
      claim: ChatAttachmentIntakeClaim;
      /** The draft it is for. */
      target: ChatTarget;
      received?: Received;
    }
  >();
  #appended: ChatAppended[] = [];
  #committed: ChatCommittedFiles[] = [];
  #seq = 0;
  #accountKey: string | null = null;

  /** The language messages the core words are in (`chat.locale`). */
  get locale(): CommaLocale {
    return this.#locale;
  }

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#env = coreChatEnv(ctx);
    // Kept on the device: a conversation a window shows keeps itself current through its channel.
    this.#store = new ChatStore(ctx, this.#env, (target) =>
      this.#coordinator
        .state()
        .sessions.some(
          (session) =>
            session.groupId === target.groupId &&
            session.conversationId === target.conversationId &&
            session.refs > 0
        )
    );
    this.#coordinator = this.#create();
    // A window shows every step of a conversation (its own message sending before the server's answer): no change waits.
    // Each value names the session it is of: a window shows only one of its own session.
    ctx.kernel.source("chat", {
      coalesce: false,
      start: () => {},
      stop: () => {},
      compute: (topic): Value => ({
        ok: { session: this.#identity(), snapshot: this.#state(topic) },
      }),
    });
    ctx.kernel.source("chatAppended", {
      start: () => {},
      stop: () => {},
      compute: (): Value => ({ ok: { appended: this.#appended } }),
    });
    ctx.kernel.source("chatCommittedFiles", {
      start: () => {},
      stop: () => {},
      compute: (): Value => ({ ok: { committed: this.#committed } }),
    });
    this.#views = new ChatViews({
      ctx,
      env: this.#env,
      coordinator: () => this.#coordinator,
      identity: () => this.#identity(),
      own: (client, input) => this.#own(client, input),
      admit: (name, p) => this.#admit(name, p),
      hosted: () => this.hosted,
      pick: (input) => this.#pick(input),
    });
    ctx.kernel.calls(this.#views.calls());
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) {
        // Shown again, withheld (a sign-out under way or undecided), or the account opened: views shown while it was
        // opening are retained now.
        this.#views.retainAll();
        this.#invalidate();
        return;
      }
      this.#accountKey = key;
      // Nothing of one account's chats is kept for another: its conversations, leases and intakes end.
      for (const { claim } of this.#intakes.values()) claim.releaseIfUnused();
      this.#intakes.clear();
      this.#leases.clear();
      this.#coordinator.reset();
      this.#appended = [];
      this.#committed = [];
      // The views windows still show are the new account's to keep current.
      this.#views.forgetRetained();
      this.#views.retainAll();
      this.#invalidate();
    });
    // After the session's own change above: a resolution starts on the coordinator of the new session.
    this.#workspaceChats = new WorkspaceChats(ctx, (workspaceId) =>
      this.#coordinator.resolveWorkspaceChat(workspaceId)
    );
    this.#calls();
  }

  /** The window a client is (Electron's Main vouches for it): it may act only on its own surface and subscribers. */
  readonly #surfaces = new Map<ClientId, string>();

  bind(client: ClientId, surface: string): void {
    this.#surfaces.set(client, surface);
  }

  /** Refuses a call that names another window's surface or subscriber than its caller's. */
  #own(client: ClientId, input: unknown): void {
    const surface = this.#surfaces.get(client);
    if (surface === undefined || typeof input !== "object" || input === null) return;
    const { surfaceId, subscriberId } = input as {
      surfaceId?: unknown;
      subscriberId?: unknown;
    };
    if (
      (surfaceId !== undefined && surfaceId !== surface) ||
      (subscriberId !== undefined &&
        (typeof subscriberId !== "string" || !subscriberId.startsWith(`${surface}:`)))
    )
      throw new CoreError("forbidden", "a window acts only as itself");
  }

  /** The core is closed in order: the device's last draft edits are written now (see ChatStore.flush). */
  close(): void {
    this.#store.flush();
  }

  /** A UI left: its leases and the intakes it opened end. */
  disconnect(client: ClientId): void {
    const leases = this.#leases.get(client);
    this.#leases.delete(client);
    this.#surfaces.delete(client);
    for (const lease of leases?.values() ?? []) {
      try {
        this.#coordinator.release(lease);
      } catch {
        // A lease of a conversation the coordinator already let go.
      }
    }
    for (const [id, intake] of this.#intakes)
      if (intake.client === client) this.#end(id);
  }

  /** An intake ends: the draft's send no longer waits for it, and a received one lets its conversation go. */
  #end(intakeId: string): void {
    const intake = this.#intakes.get(intakeId);
    if (!intake) return;
    this.#intakes.delete(intakeId);
    intake.claim.releaseIfUnused();
    if (intake.received?.retained)
      try {
        this.#coordinator.release(intake.received.lease);
      } catch {
        // A conversation the coordinator already let go.
      }
  }

  /**
   * Fails when intake `intakeId` no longer takes files for its draft: it ended, another draft took its place, or (files
   * received) its window shows another conversation now.
   */
  #assertCurrent(intake: {
    claim: ChatAttachmentIntakeClaim;
    received?: Received;
  }): void {
    const received = intake.received;
    if (received) {
      const now = this.#shownBy(received.surfaceId);
      if (
        !now ||
        now.subscriberId !== received.shown.subscriberId ||
        now.leaseId !== received.shown.leaseId ||
        now.workspaceId !== received.shown.workspaceId
      )
        throw new Error("The destination chat changed while files were received.");
    }
    intake.claim.assertCurrent();
  }

  /** Who holds `conversation`'s draft and takes what a window does to it: `hosted` for its own, else the coordinator. */
  #holder(conversation: string): ConversationHolder {
    return this.hosted?.owns(conversation) ? this.hosted : this.#coordinator;
  }

  /** The one conversation window `surfaceId` shows, whoever holds it; undefined when it shows none or several. */
  #shownBy(surfaceId: string) {
    return (
      this.#coordinator.incomingAttachmentTarget(surfaceId) ??
      this.#views.hostedShownBy(surfaceId)
    );
  }

  /** What intake `intake`'s draft takes more now. */
  #room(intake: { target: ChatTarget }): NonNullable<ReturnType<typeof pickQuota>> {
    const { workspaceId, groupId, conversationId } = intake.target;
    if (this.hosted?.owns(conversationId))
      return (
        this.hosted.room({
          workspace: workspaceId,
          group: groupId,
          conversation: conversationId,
        }) ?? { maxFiles: 0, maxTotalSize: 0, maxUploadFiles: 0 }
      );
    const session = this.#coordinator
      .state()
      .sessions.find(
        (s) =>
          s.workspaceId === workspaceId &&
          s.groupId === groupId &&
          s.conversationId === conversationId
      );
    return roomOf(session?.state?.draftAttachments ?? []);
  }

  /**
   * Files the computer received, for window `surfaceId`'s draft: refused when the window shows no single conversation
   * or a file is a folder (nothing can attach it); otherwise an intake opens on that conversation's draft, held while
   * the window changes conversation; the draft is not sent before the intake settles.
   */
  #receive(
    client: ClientId,
    input: { surfaceId: string; files: { isDirectory: boolean }[] }
  ):
    | { refused: "no_chat" }
    | { refused: "directory"; title: string }
    | { intakeId: string; title: string; workspaceId: string } {
    const shown = this.#shownBy(input.surfaceId);
    if (!shown) return { refused: "no_chat" };
    const title = conversationName(
      shown.conversation,
      this.#locale,
      this.#ctx.host.desktop?.app.productName ?? "Comma"
    );
    if (input.files.some((file) => file.isDirectory))
      return { refused: "directory", title };
    const lease = {
      workspaceId: shown.workspaceId,
      groupId: shown.groupId,
      conversationId: shown.conversationId,
      subscriberId: `received:${this.#env.uuid()}`,
      leaseId: this.#env.uuid(),
    };
    const holder = this.#holder(shown.conversationId);
    const retained = holder === this.#coordinator;
    if (retained) this.#coordinator.retain(lease);
    let claim: ChatAttachmentIntakeClaim;
    try {
      claim = holder.claimAttachmentIntake({
        ...lease,
        surfaceId: input.surfaceId,
      });
    } catch (error) {
      if (retained) this.#coordinator.release(lease);
      throw error;
    }
    this.#intakes.set(claim.intakeId, {
      client,
      claim,
      target: lease,
      received: {
        surfaceId: input.surfaceId,
        shown: {
          subscriberId: shown.subscriberId,
          leaseId: shown.leaseId,
          workspaceId: shown.workspaceId,
        },
        lease,
        retained,
      },
    });
    return {
      intakeId: claim.intakeId,
      title,
      workspaceId: shown.workspaceId,
    };
  }

  /** Attaches files Main registered for received intake `intakeId` to its draft, while it is still that draft's. */
  #attachReceived(
    intakeId: string,
    items: z.output<typeof receivedItemSchema>[]
  ): ChatCommandReceipt {
    const intake = this.#intakes.get(intakeId)!;
    const received = intake.received!;
    this.#assertCurrent(intake);
    const target = { ...received.lease, surfaceId: received.surfaceId };
    return this.#attachItems(target, items) ?? { revision: this.#revision(target) };
  }

  /** Attaches what a pick or AirDrop gave to `target`'s draft: the last receipt, none when it gave nothing. */
  #attachItems(
    target: ChatTarget & { leaseId: string; subscriberId: string; surfaceId: string },
    items: readonly (
      | { kind: "upload"; name: string; size: number; bytes: Uint8Array<ArrayBuffer> }
      | { kind: "local_file"; file: z.output<typeof chatLocalFileSchema> }
    )[]
  ): ChatCommandReceipt | undefined {
    const holder = this.#holder(target.conversationId);
    let receipt: ChatCommandReceipt | undefined;
    for (const item of items)
      receipt =
        item.kind === "upload"
          ? holder.attach({
              ...target,
              bytes: item.bytes,
              name: item.name,
              size: item.size,
            })
          : holder.attachLocalFiles({ ...target, files: [item.file] });
    return receipt;
  }

  /** The revision the views of `target` are at, as a receipt names it. */
  #revision(target: ChatTarget): number {
    return this.hosted?.owns(target.conversationId)
      ? this.hosted.revision()
      : this.#coordinator.state().revision;
  }

  #create(): ChatCoordinator {
    const ctx = this.#ctx;
    const env = this.#env;
    const options = {
      env,
      store: this.#store,
      createSessionBoundApi: () => {
        const account = ctx.session.current();
        if (!account) throw new StaleChatSessionError();
        const isCurrent = () => !account.closed && ctx.session.current() === account;
        return {
          api: createChatApi(ctx, account, env),
          session: account.lease,
          isCurrent,
          assertCurrent: () => {
            if (!isCurrent()) throw new StaleChatSessionError();
          },
        };
      },
      getClientDeviceId: (workspaceId) => this.#deviceIds.get(workspaceId),
      onCanonicalMessagesAppended: ({ conversation, messages, target }) => {
        const notices = noticesFor(
          conversation,
          messages,
          this.#locale,
          ctx.host.desktop?.app.productName ?? "Comma"
        );
        if (notices.length === 0) return;
        const { workspaceId, groupId, conversationId } = target;
        this.#appended = [
          ...this.#appended,
          {
            seq: ++this.#seq,
            target: { workspaceId, groupId, conversationId },
            notices,
          },
        ].slice(-RING);
        ctx.kernel.store.invalidate({ topic: "chatAppended" });
      },
      onLocalFilesCommitted: (files, committedAtMs) => {
        this.#committed = [
          ...this.#committed,
          { seq: ++this.#seq, files: [...files], committedAtMs: committedAtMs ?? null },
        ].slice(-RING);
        ctx.kernel.store.invalidate({ topic: "chatCommittedFiles" });
      },
      onStateChanged: () => {
        ctx.kernel.store.invalidateAll(
          (topic) => topic.topic === "chat" || topic.topic === "chatView"
        );
      },
      ...(ctx.host.renderImagePreview
        ? {
            renderGroupImagePreview: (input: {
              bytes: Uint8Array;
              mediaType: string;
            }) => ctx.runner.run(ctx.host.renderImagePreview!(input)),
          }
        : {}),
      ...(ctx.host.transcodeImage
        ? {
            transcodeAttachment: (file: AttachmentUploadInput) =>
              Effect.promise(() => file.data.arrayBuffer()).pipe(
                Effect.flatMap((bytes) =>
                  ctx.host.transcodeImage!({
                    bytes: new Uint8Array(bytes),
                    name: file.name,
                    mediaType: file.data.type,
                  })
                ),
                Effect.map((out) => ({
                  data: new Blob([out.bytes as Uint8Array<ArrayBuffer>], {
                    type: out.mediaType,
                  }),
                  name: out.name,
                  size: out.bytes.length,
                }))
              ),
          }
        : {}),
    } as ConstructorParameters<typeof ChatCoordinator>[0];
    // Read when a conversation opens: the language can change (`chat.locale`).
    Object.defineProperty(options, "locale", {
      enumerable: true,
      get: () => this.#locale,
    });
    const coordinator = new ChatCoordinator(options);
    // A keystroke publishes the drafts alone: the views show it.
    coordinator.subscribeDrafts(() =>
      ctx.kernel.store.invalidateAll((topic) => topic.topic === "chatView")
    );
    return coordinator;
  }

  #invalidate(): void {
    this.#ctx.kernel.store.invalidateAll((topic) => topic.topic.startsWith("chat"));
  }

  /** The runtime snapshot as one surface sees it: only its own presentation fences. */
  #state(topic: Topic): ChatRuntimeSnapshot {
    const state = this.#coordinator.state();
    if (this.#ctx.session.withheld())
      return {
        protocolVersion: state.protocolVersion,
        revision: state.revision,
        sessions: [],
      };
    const surface = typeof topic.surface === "string" ? topic.surface : "";
    return {
      ...state,
      sessions: state.sessions.map((session) =>
        session.surfaceProjections
          ? {
              ...session,
              surfaceProjections: session.surfaceProjections.filter((p) =>
                p.subscriberId.startsWith(`${surface}:`)
              ),
            }
          : session
      ),
    };
  }

  #calls(): void {
    const c = () => this.#coordinator;
    const sync = <S extends z.ZodType, A>(
      schema: S,
      run: (input: z.output<S>) => A
    ) => ({
      run: (p: unknown, call: { client: ClientId }) =>
        this.#call(() => {
          const input = parse(schema, p);
          this.#own(call.client, input);
          return run(input);
        }),
    });
    this.#register({
      "chat.retain": {
        run: (p, call) =>
          this.#call(() => {
            const input = parse(chatRetainInputSchema, p);
            this.#own(call.client, input);
            const receipt = c().retain(input);
            let leases = this.#leases.get(call.client);
            if (!leases) this.#leases.set(call.client, (leases = new Map()));
            leases.set(input.subscriberId, input);
            return receipt;
          }),
      },
      "chat.release": {
        run: (p, call) =>
          this.#call(() => {
            const input = parse(chatReleaseInputSchema, p);
            this.#own(call.client, input);
            const leases = this.#leases.get(call.client);
            if (leases?.get(input.subscriberId)?.leaseId === input.leaseId)
              leases.delete(input.subscriberId);
            return c().release(input);
          }),
      },
      "chat.attach": sync(chatLeasedAttachInputSchema, (i) =>
        this.#holder(i.conversationId).attach(i)
      ),
      "chat.attachLocalFiles": sync(chatLeasedAttachLocalFilesInputSchema, (i) =>
        this.#holder(i.conversationId).attachLocalFiles(i)
      ),
      "chat.resolveWorkspaceChat": sync(
        z.object({
          workspaceId: z.string().min(1).optional(),
          afterProvisioning: z.number().nonnegative().optional(),
        }),
        (i) =>
          i.afterProvisioning === undefined
            ? c().resolveWorkspaceChat(i.workspaceId)
            : Effect.sleep(
                Duration.seconds(
                  Math.min(
                    Math.max(i.afterProvisioning, 1),
                    MAX_PROVISIONING_WAIT_SECONDS
                  )
                )
              ).pipe(Effect.andThen(() => c().resolveWorkspaceChat(i.workspaceId)))
      ),
      "chat.listSkills": sync(chatWorkspaceSkillsInputSchema, (i) => c().listSkills(i)),
      "workspaceChat.retry": sync(
        z.object({ workspace: z.string().min(1).optional() }),
        (i) => {
          this.#workspaceChats.retry(i.workspace);
          return null;
        }
      ),
      /** A conversation's last messages read ahead of its opening (a window that stops asking cancels). */
      "chat.prepare": {
        cancellable: true,
        run: (p) =>
          Effect.suspend(() =>
            readPreparedConversation(this.#ctx, parse(prepareInputSchema, p))
          ).pipe(Effect.catchDefect((defect) => Effect.fail(asCoreError(defect)))),
      },
      /** The messages around one message, for a reply that quotes one the transcript has not loaded. */
      "chat.messageContext": {
        cancellable: true,
        run: (p) =>
          Effect.suspend(() => {
            const input = parse(messageContextInputSchema, p);
            // A Task a station hosts is read back on its station.
            return this.hosted?.owns(input.conversationId)
              ? this.hosted.messageContext(
                  input.groupId,
                  input.conversationId,
                  input.messageId
                )
              : readMessageContext(this.#ctx, input);
          }).pipe(Effect.catchDefect((defect) => Effect.fail(asCoreError(defect)))),
      },
      "chat.readGroupImage": sync(chatReadGroupImageInputSchema, (i) =>
        i.source === "attachment" ? this.#readMessageImage(i) : c().readGroupImage(i)
      ),
      /** A reply sent without a view (Main's notification banner). */
      "chat.sendDetached": sync(
        chatTargetSchema.extend({ text: z.string().min(1) }),
        (i) =>
          c().sendDetachedMessage(
            {
              workspaceId: i.workspaceId,
              groupId: i.groupId,
              conversationId: i.conversationId,
            },
            i.text
          )
      ),
      /**
       * A file for a cloud Task, checked as a composer attachment is and put in the workspace's Router chat: the
       * workspace file its first message names (`chat.startTask`).
       */
      "chat.uploadTaskFile": sync(
        z.object({
          workspaceId: z.string().min(1),
          name: z.string().min(1).max(1024),
          bytes: z.instanceof(Uint8Array),
        }),
        (i) => {
          const file = {
            data: new Blob([i.bytes]),
            name: i.name,
            size: i.bytes.byteLength,
          };
          // The window holds the count to its Task's message; each file is checked as the composer's are.
          const invalid = validateAttachment(file, 0, this.#locale, false);
          if (invalid) return Effect.fail(CoreError.invalid(invalid));
          return c()
            .resolveWorkspaceChat(i.workspaceId)
            .pipe(
              Effect.flatMap((chat) =>
                chat.status === "ready"
                  ? c().uploadDetachedFile(chat.groupId, file)
                  : Effect.fail(
                      CoreError.invalid(`the workspace chat is ${chat.status}`)
                    )
              ),
              Effect.map(({ name, path, size }) => ({ name, path, size }))
            );
        }
      ),
      /**
       * A Task in Comma's cloud with `model`, its first message `text` and the files `uploads` names, listed as the
       * composer lists them (`POST /v1/comma/workspaces/:ws/tasks`): the server makes it and shares the files into it
       * (`SalixIM.ModelMentionTask.start_from_window/5`), and answers the Task, which the window opens at once. Made
       * once under `key`: made again with it (a call that failed), it is the same Task. A refusal fails `refused`
       * with why, in the server's words.
       */
      "chat.startTask": sync(
        z
          .object({
            workspaceId: z.string().min(1),
            key: z.string().min(8).max(128),
            model: z.object({ id: z.string().min(1), name: z.string().min(1) }),
            text: z.string().trim(),
            uploads: z
              .array(z.object({ name: z.string().min(1), path: z.string().min(1) }))
              .max(MAX_ATTACHMENTS_PER_MESSAGE)
              .optional(),
          })
          .refine((i) => i.text !== "" || (i.uploads?.length ?? 0) > 0, {
            message: "text is required",
          }),
        (i) => {
          const ctx = this.#ctx;
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                route`/v1/comma/workspaces/${i.workspaceId}/tasks`,
                z.object({ task_id: z.string(), group_id: z.string() }),
                {
                  client_request_id: i.key,
                  text: composeMessageWithAttachments(i.text, i.uploads ?? []),
                  model: { id: i.model.id },
                }
              )
            ),
            Effect.map((made) => ({
              groupId: made.group_id,
              conversationId: made.task_id,
            })),
            Effect.mapError((failure) => refusedWithWhy(failure))
          );
        }
      ),
      /** The language messages the core words are in (the UI's, or Electron's Main's). */
      "chat.locale": sync(z.object({ locale: z.string() }), ({ locale }) => {
        if ((supportedLocales as readonly string[]).includes(locale))
          this.#locale = locale as CommaLocale;
        return null;
      }),
      /** This device's id in each workspace (Electron's connector), sent with each message. */
      "chat.clientDevices": sync(
        z.object({ devices: z.record(z.string(), z.string()) }),
        (i) => {
          this.#deviceIds.clear();
          for (const [workspace, device] of Object.entries(i.devices))
            this.#deviceIds.set(workspace, device);
          return null;
        }
      ),
      /** Files the computer received (AirDrop) for a window's draft: an intake on it, or why there is none. */
      "chat.intake.receive": {
        run: (p, call) =>
          this.#call(() => {
            const input = parse(
              z.object({
                surfaceId: z.string().min(1),
                files: z
                  .array(z.object({ isDirectory: z.boolean() }).loose())
                  .max(1_000),
              }),
              p
            );
            this.#own(call.client, input);
            return this.#receive(call.client, input);
          }),
      },
      "chat.intake.attach": this.#intakeCall(
        (intake, p, id) => {
          const { items } = parse(
            z.object({ items: z.array(receivedItemSchema).max(50) }).loose(),
            p
          );
          return this.#attachReceived(id, items);
        },
        { received: true }
      ),
      /** Opens an attachment intake for a picker or a received file: the draft's send waits for it. */
      "chat.intake.claim": {
        run: (p, call) =>
          this.#call(() => {
            const input = parse(
              chatLeasedTargetSchema.extend({ surfaceId: z.string().min(1) }),
              p
            );
            this.#own(call.client, input);
            const claim = this.#holder(input.conversationId).claimAttachmentIntake(
              input
            );
            this.#intakes.set(claim.intakeId, {
              client: call.client,
              claim,
              target: input,
            });
            return { intakeId: claim.intakeId };
          }),
      },
      "chat.intake.check": this.#intakeCall((intake) => {
        this.#assertCurrent(intake);
        return this.#room(intake);
      }),
      "chat.intake.dialogClosed": this.#intakeCall((intake) => {
        intake.claim.markDialogClosed();
        return null;
      }),
      "chat.intake.settle": this.#intakeCall((intake, p) => {
        intake.claim.settle(
          parse(z.object({ outcome: intakeOutcomeSchema }), p)
            .outcome as ChatAttachmentIntakeOutcome
        );
        return null;
      }),
      "chat.intake.release": this.#intakeCall((_intake, _p, id) => {
        this.#end(id);
        return null;
      }),
    });
  }

  /**
   * Each call runs once the account's data is open: a window can ask as soon as it knows it is signed in, while the
   * core is still opening the account (the web's database takes a moment).
   */
  #register(calls: Record<string, Call>): void {
    this.#ctx.kernel.calls(
      Object.fromEntries(
        Object.entries(calls).map(([name, call]) => [
          name,
          {
            ...call,
            run: (p: unknown, at: CallContext) =>
              Effect.flatMap(this.#admit(name, p), (rest) => call.run(rest, at)),
          },
        ])
      )
    );
  }

  /**
   * What a call waits for and checks before it acts; its params without the session they name. Signed in, the
   * account's data open: at once. Not known yet (the window knew of its sign-in before the core heard of it, or the
   * account is still opening): until it is, at most a few seconds. Signed out: at once.
   */
  #admit(name: string, p: unknown): Effect.Effect<unknown, CoreError> {
    const session = this.#ctx.session;
    const signedIn = Effect.callback<void>((resume) => {
      const check = () => {
        const phase = session.value().phase;
        if (session.current() !== null || phase === "signed_out") resume(Effect.void);
      };
      const stop = session.onChange(check);
      check();
      return Effect.sync(stop);
    });
    const ready = Effect.ignore(
      signedIn.pipe(Effect.timeout(ACCOUNT_WAIT_MS), Effect.andThen(session.account()))
    );
    return Effect.andThen(
      ready,
      Effect.suspend(() => {
        // A window names the session it acts for: one the core is no longer on is refused, so a stale window never
        // acts for the account that took its place. Letting go of its own lease is not acting: a release is taken
        // from a window of an earlier session (or its stream would stay open).
        const { session: asked, rest } = splitSession(p);
        if (
          asked !== undefined &&
          name !== "chat.release" &&
          !sameSession(asked, this.#identity())
        )
          return Effect.fail(
            new CoreError(
              "session_changed",
              "The chat session lease is missing or stale."
            )
          );
        return Effect.succeed(rest);
      })
    );
  }

  /** The session the core works for now, as windows compare theirs with it; null while none is shown. */
  #identity(): ChatSessionIdentity {
    const value = this.#ctx.session.value();
    if (value.phase !== "signed_in" || this.#ctx.session.withheld()) return null;
    return { sessionId: value.sessionId, audience: value.audience };
  }

  /** One pick for a window's draft, through Main's file dialog (`chat.pickAttachments`). */
  #pick(
    input: z.output<typeof pickInputSchema>
  ): Effect.Effect<ChatPickAttachmentsResult, Error> {
    const desktop = this.#ctx.host.desktop;
    if (!desktop)
      throw new CoreError("unsupported", "Picking files needs the desktop app.");
    const account = this.#ctx.session.current();
    if (!account) throw new StaleChatSessionError();
    const { maxFiles, maxTotalSize, maxUploadFiles, ...target } = input;
    const claim = this.#holder(target.conversationId).claimAttachmentIntake(target);
    const { intakeId } = claim;
    this.#intakes.set(intakeId, { client: DESKTOP, claim, target });
    // A pick that fails or is given up before it reported settles as failed: a send waiting on it rejects rather
    // than going without the files.
    let outcome: ChatAttachmentIntakeOutcome = { cancelled: false, errorCount: 1 };
    return desktop
      .pickAttachments({
        intakeId,
        surfaceId: target.surfaceId,
        workspaceId: target.workspaceId,
        lease: { ...account.lease },
        maxFiles,
        maxTotalSize,
        maxUploadFiles,
      })
      .pipe(
        Effect.map((picked): ChatPickAttachmentsResult => {
          const receipt = this.#attachItems(
            target,
            picked.items.map((item) =>
              item.kind === "upload"
                ? { ...item, bytes: new Uint8Array(item.bytes) }
                : item
            )
          ) ?? { revision: this.#revision(target) };
          outcome = {
            cancelled: picked.cancelled,
            errorCount: picked.errors.length,
            errors: picked.errors,
          };
          return {
            cancelled: picked.cancelled,
            errors: picked.errors,
            intakeId,
            revision: receipt.revision,
            ...(receipt.draftEpoch === undefined
              ? {}
              : { draftEpoch: receipt.draftEpoch }),
          };
        }),
        Effect.onExit(() =>
          Effect.sync(() => {
            claim.settle(outcome);
            if (this.#intakes.get(intakeId)?.claim === claim)
              this.#intakes.delete(intakeId);
            claim.releaseIfUnused();
          })
        )
      );
  }

  /**
   * The preview of image `index` of a message, read where its conversation keeps it (`files.read`: Comma's server, or
   * the station of a Task one hosts) and drawn by the host as a workspace image's is.
   */
  #readMessageImage(
    input: Extract<ChatReadGroupImageInput, { source: "attachment" }>
  ): Effect.Effect<Uint8Array, CoreError> {
    const ctx = this.#ctx;
    const hosted = this.hosted;
    return Effect.gen(function* () {
      const host = ctx.host;
      const mediaType = imageMediaTypeOfName(input.fileName);
      if (!host.renderImagePreview)
        return yield* Effect.fail(
          new CoreError("unsupported", "Image previews are unavailable.")
        );
      if (!mediaType) return yield* Effect.fail(CoreError.invalid("not an image"));
      const file = yield* readFile(ctx, hosted, {
        source: "attachment",
        group: input.groupId,
        conversation: input.conversationId,
        message: input.messageId,
        index: input.index,
      });
      const preview = yield* host
        .renderImagePreview({ bytes: file.bytes, mediaType })
        .pipe(Effect.mapError((error) => CoreError.host(error)));
      return chatGroupImagePreviewSchema.parse(preview);
    });
  }

  /** Whether `client` may act on the open intake `intake`: its own, or Main's client on one the core opened. */
  #mayAct(
    client: ClientId,
    intake: { client: ClientId | typeof DESKTOP } | undefined
  ): boolean {
    if (!intake) return false;
    return intake.client === DESKTOP
      ? this.#ctx.host.desktop !== undefined && !this.#surfaces.has(client)
      : intake.client === client;
  }

  /** Whether `client`'s intake `intakeId` is still open and its draft's (a file registration's fence). */
  intakeCurrent(client: ClientId, intakeId: string): boolean {
    const intake = this.#intakes.get(intakeId);
    if (!intake || !this.#mayAct(client, intake)) return false;
    try {
      this.#assertCurrent(intake);
      return true;
    } catch {
      return false;
    }
  }

  /** A call on an open intake (`received`: one of files received), by the client that opened it only. */
  #intakeCall<A>(
    run: (
      intake: {
        claim: ChatAttachmentIntakeClaim;
        target: ChatTarget;
        received?: Received;
      },
      params: unknown,
      id: string
    ) => A,
    only: { received?: true } = {}
  ) {
    return {
      run: (p: unknown, call: { client: ClientId }) =>
        this.#call(() => {
          const { intakeId } = parse(z.object({ intakeId: z.string() }).loose(), p);
          const intake = this.#intakes.get(intakeId);
          if (
            !intake ||
            !this.#mayAct(call.client, intake) ||
            (only.received && !intake.received)
          )
            throw new CoreError("not_found", "no such attachment intake");
          return run(intake, p, intakeId);
        }),
    };
  }
}

/** A refusal of the server's (`{error: "refused", message}`) as the core's error, with its words for the person. */
function refusedWithWhy(failure: Error): Error {
  const refusal = failure as Partial<CoreError>;
  const why = (refusal.detail as { message?: unknown } | undefined)?.message;
  return refusal.code === "refused" && typeof why === "string"
    ? new CoreError("refused", why, refusal.status)
    : failure;
}
