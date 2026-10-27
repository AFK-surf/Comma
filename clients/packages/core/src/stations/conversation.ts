// A Task a station hosts, as any Task is to the pages that show one: its conversation view (`chatView`, chat/views.ts)
// is its station's chat (chat.ts) in a Salix conversation's shape (a `ConversationProjection`), and the `chatView.*`
// calls, the Task's name, labels, status and its Worker's stop are made on its station. The agents' posts and the
// people's words (read as any Task's are), their threads, what is being sent and what failed, what is written and the files going up (composer.ts), the agents
// at work as the Worker at work, a card with options as a question card, and the Activity: a page draws it as it draws
// any Task. What a station's chat has no part of (a review, a Worker's steps, a share link) the projection has none of,
// and its list item and its page say what it cannot take (`HOSTED_UNSUPPORTED`).
//
// Bounds: a view shows its chat as the station's page does (chat.ts); each change of the chat or of what is written
// computes the views of that station's Tasks again.
import type {
  ChatBeginSendIntentReceipt,
  ChatCommandReceipt,
  ChatTaskRun,
  ChatLeasedTarget,
  ChatMessage,
  ChatMessagePart,
  ConversationProjection,
} from "@comma/chat-contract";
import { CoreError, type Topic } from "@comma/core-kernel";
import { route } from "../api.ts";
import { deviceSchema } from "../comma/schemas.ts";
import { Effect } from "effect";
import type { Account } from "../account.ts";
import type { TaskSummary } from "../contract.ts";
import { Live, type Ctx } from "../ctx.ts";
import {
  HOSTED_UNSUPPORTED,
  hostedChat,
  hostedId,
  taskStatusOf,
  type StationTasks,
} from "../station-tasks.ts";
import { HOSTED_PART, readFile, type HostedFiles } from "../files.ts";
import type { HostedTasks } from "../hosted-tasks.ts";
import type { Workspaces } from "../workspaces.ts";
import type { CardAt, StationActivity } from "./activity.ts";
import type {
  ChatAt,
  StationChatMessage,
  StationChatRun,
  StationChats,
} from "./chat.ts";
import type { ComposerFile, DraftAt, StationComposer } from "./composer.ts";
import type { Stations } from "./index.ts";
import { skillsBlock } from "./skills.ts";
import type { StationTaskActions } from "./tasks.ts";
import { firstLine } from "./views.ts";
import type { ChatAttachmentIntakeClaim } from "../chat/coordinator/hostContract.ts";
import {
  COMMA_PROTOCOL_MARKER,
  stripCommaProtocolMarkers,
} from "../chat/model/protocol.ts";
import { decodeUserMessage, userParts } from "../chat/model/userMessageText.ts";
import type {
  ConversationHolder,
  HostedConversations,
  PickRoom,
} from "../chat/views.ts";

/** A conversation view's target, as `chatView` names it. */
export type ConversationTarget = {
  workspace: string;
  group: string;
  conversation: string;
};

const IMAGE = /\.(png|jpe?g|gif|webp|heic|heif|avif|bmp|tiff?)$/i;

const unsupported = (what: string) =>
  new CoreError("unsupported", `A Task on a machine cannot ${what}.`);

/** A file of what is written, as a page shows a draft's. */
function shownFile(f: ComposerFile) {
  return {
    id: f.id,
    name: f.name,
    size: f.size,
    isImage: f.image,
    status: f.done
      ? ("uploaded" as const)
      : f.error
        ? ("failed" as const)
        : ("uploading" as const),
    ...(f.done ? { path: f.done.path } : {}),
    ...(f.error ? { error: f.error } : {}),
  };
}

/** What a call of the coordinator's takes. */
type In<K extends keyof ConversationHolder> = Parameters<ConversationHolder[K]>[0];

export class StationConversations
  implements HostedTasks, HostedConversations, HostedFiles
{
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #stations: Stations;
  readonly #chats: StationChats;
  readonly #activity: StationActivity;
  readonly #composer: StationComposer;
  readonly #tasks: StationTasks;
  readonly #actions: StationTaskActions;
  /** Counts every change of what the views show: a call's receipt is in every later value. */
  #revision = 0;
  /** The reads of each shown Task's facts, by its view. */
  readonly #keeping: Live;

  constructor(
    ctx: Ctx,
    deps: {
      workspaces: Workspaces;
      stations: Stations;
      chats: StationChats;
      activity: StationActivity;
      composer: StationComposer;
      tasks: StationTasks;
      actions: StationTaskActions;
    }
  ) {
    this.#ctx = ctx;
    this.#keeping = new Live(ctx.runner);
    this.#workspaces = deps.workspaces;
    this.#stations = deps.stations;
    this.#chats = deps.chats;
    this.#activity = deps.activity;
    this.#composer = deps.composer;
    this.#tasks = deps.tasks;
    this.#actions = deps.actions;
    deps.chats.onChange(() => this.#changed());
    // What its stations' chats say of the pins changed: the pins shown are computed again.
    deps.activity.onChanged(() => {
      for (const topic of this.#ctx.kernel.store.liveTopics())
        if (topic.topic === "taskPins") this.#ctx.kernel.store.invalidate(topic);
    });
    deps.composer.onChange(() => this.#changed());
    deps.tasks.onChange(() => this.#changed());
  }

  /** Whether a conversation (a Task's id) is one a station hosts. */
  owns(conversation: string): boolean {
    return hostedChat(conversation) !== null;
  }

  // ── its conversation view ────────────────────────────────────────────

  /** A window shows it: its chat is followed, and its facts (its list's) are read while it is shown, as a list's are. */
  show(target: ConversationTarget, view: Topic): void {
    this.#chats.show(this.#at(target));
    this.#keeping.run(view, this.#tasks.keep(view));
  }

  hide(target: ConversationTarget, view: Topic): void {
    this.#chats.hide(this.#at(target));
    this.#keeping.stop(view);
    this.#tasks.stop(view);
  }

  revision(): number {
    return this.#revision;
  }

  draftEpoch(target: ConversationTarget): number {
    return this.#composer.draft(this.#at(target)).epoch;
  }

  /** The Task's conversation, as a Salix Task's conversation view has it. */
  projection(target: ConversationTarget): ConversationProjection {
    const at = this.#at(target);
    const chat = this.#chats.value(at);
    const draft = this.#composer.draft(at);
    const account = this.#ctx.session.current();
    const listed = account
      ? this.#tasks.task(account, target.workspace, target.conversation)
      : null;
    const messages = chat.messages.flatMap((m) => this.#message(m, chat.messages));
    const open = new Set(
      chat.messages.flatMap((m) => (m.card && !m.cardState?.resolved ? [m.seq] : []))
    );
    const questions = this.#composer.questions(at).filter((q) => open.has(q.question));
    const seqs = messages.flatMap((m) => (m.seq === undefined ? [] : [m.seq]));
    // At work: its own agents here, or the Session running it on another station.
    const working = chat.runsOn
      ? chat.runsOn.working
      : chat.agents.some((agent) => agent.running);
    const offline = chat.link.state === "offline" || chat.link.state === "reconnecting";
    const failed = chat.error !== undefined && messages.length === 0;
    return {
      awaitingReply: false,
      awaitingTimedOut: false,
      connection:
        chat.link.state === "online"
          ? "live"
          : chat.link.state === "connecting"
            ? "connecting"
            : "reconnecting",
      conversation: {
        id: target.conversation,
        groupId: target.group,
        workspaceId: target.workspace,
        kind: "agent_task",
        title: chat.title ?? listed?.title ?? "",
        ...(listed
          ? this.#tasks.shownStatus(listed)
          : { status: taskStatusOf("in_progress") }),
        labels: listed?.labels ?? [],
        ...(listed?.createdAt ? { createdAt: listed.createdAt } : {}),
        ...(listed?.lastActivityAt ? { updatedAt: listed.lastActivityAt } : {}),
      },
      draft: draft.text,
      draftAttachments: draft.files.map(shownFile),
      // The files given for an open card's answer in its own words, apart from the draft.
      ...(questions.length > 0
        ? {
            questionAttachments: Object.fromEntries(
              questions.map((q) => [
                `${at.thread}:${q.question}`,
                q.files.map(shownFile),
              ])
            ),
          }
        : {}),
      ...(offline || failed ? { errorKind: "network" as const } : {}),
      history: {
        hasOlder: chat.more,
        loadingOlder: false,
        ranges:
          seqs.length > 0
            ? [[Math.min(...seqs), Math.max(...seqs)] as [number, number]]
            : [],
      },
      lastBackoffMs: 0,
      messages,
      pending: chat.outbox.map((o) => ({
        clientRequestId: o.id,
        createdAt: 0,
        status: o.state,
        text: o.text,
        ...(o.replyTo !== undefined
          ? { replyToMessageId: `${at.thread}:${o.replyTo}` }
          : {}),
        ...(o.error !== undefined ? { error: o.error } : {}),
      })),
      // Where it runs and its model, as a Task's run says them: its machine, and the model its station runs; or the
      // station it runs on now, with the model its Session there was started with.
      ...(chat.runsOn
        ? { taskRun: this.#elsewhere(target.workspace, chat.runsOn) }
        : listed
          ? {
              taskRun: {
                place: {
                  kind: "station" as const,
                  deviceId: listed.device ?? listed.station,
                  ...(listed.machine?.name ? { name: listed.machine.name } : {}),
                },
                ...(listed.model || listed.runtime
                  ? {
                      model: {
                        kind: "runtime" as const,
                        ...(listed.runtime ? { provider: listed.runtime } : {}),
                        ...(listed.model ? { name: listed.model } : {}),
                      },
                    }
                  : {}),
              },
            }
          : {}),
      unsupported: HOSTED_UNSUPPORTED,
      reply: {
        coming: false,
        thinking: false,
        streaming: false,
        working,
        failed: false,
        timedOut: false,
      },
      serverMessages: messages,
      status:
        chat.loading && messages.length === 0 ? "loading" : failed ? "error" : "ready",
      ...(chat.activity ? { taskActivity: chat.activity } : {}),
    };
  }

  /**
   * A message of the station's chat, as a Salix message is: a person's words read as any Task's are (with what they
   * quote on the station), threaded as Salix threads them; nothing for one that shows nothing.
   */
  #message(
    m: StationChatMessage,
    messages: readonly StationChatMessage[]
  ): ChatMessage[] {
    const text = m.text.trim();
    if (text === "" && m.attachments.length === 0) return [];
    const person = m.kind === "person";
    const id = `${m.thread}:${m.seq}`;
    const words = person ? stripCommaProtocolMarkers(text) : text;
    const decoded = person ? decodeUserMessage(words) : null;
    const display = decoded
      ? { ...decoded, quotes: [...m.quotes, ...decoded.quotes] }
      : null;
    const parts: ChatMessagePart[] = display
      ? userParts(display)
      : text === ""
        ? []
        : [{ kind: "markdown", text }];
    const answer = m.answers === undefined ? null : this.#answerPart(m, messages);
    if (answer) parts.push(answer);
    const question = this.#question(id, m);
    if (question) parts.push(question);
    return [
      {
        messageId: id,
        seq: m.seq,
        role: person ? "user" : "assistant",
        actorType: person ? "user" : m.kind === "agent" ? "agent" : "system",
        // Its files are read from its station (`readAttachment`), as a Salix message's are from Comma's server.
        attachments: m.attachments.map((file, attachmentIndex) => ({
          attachmentIndex,
          blockType: IMAGE.test(file.name) ? "image" : "file",
          fileName: file.name,
          size: file.size,
        })),
        ...(m.sentAs !== undefined ? { clientRequestId: m.sentAs } : {}),
        createdAt: m.createdAt,
        ...(person ? { createdBy: m.author } : {}),
        delivery: "sent",
        ...(display ? { display } : {}),
        ...(m.markdown ? { markdown: m.markdown as ChatMessage["markdown"] } : {}),
        parts,
        refs: [],
        ...(m.replyTo !== undefined
          ? { replyToMessageId: `${m.thread}:${m.replyTo}` }
          : {}),
        threadRootMessageId: `${m.thread}:${m.root}`,
        source: "server",
        text: words,
      },
    ];
  }

  /** A person's answer to a question card, as a Salix answer's part: the option its words pick, or its own words. */
  #answerPart(
    m: StationChatMessage,
    messages: readonly StationChatMessage[]
  ): ChatMessagePart | null {
    const card = messages.find((other) => other.seq === m.answers);
    const options = card?.card?.type === "options" ? (card.card.options ?? []) : [];
    if (!card || options.length < 2 || options.length > 6) return null;
    const words = m.text.trim();
    const choice = options.findIndex((o) => o.label.trim() === words);
    return {
      kind: "question-answer",
      questionMessageId: `${card.thread}:${card.seq}`,
      choiceIds: choice >= 0 ? [String(choice)] : [],
      ...(choice < 0 && words !== "" ? { other: words } : {}),
      skipped: false,
    };
  }

  /** A card with options to pick from, as a question card: its options its choices (by their place), open or how it ended. */
  #question(messageId: string, m: StationChatMessage): ChatMessagePart | null {
    const options = m.card?.type === "options" ? (m.card.options ?? []) : [];
    if (options.length < 2 || options.length > 6) return null;
    const outcome = m.cardState?.outcome;
    const chose =
      outcome?.kind === "chose"
        ? options.findIndex((o) => o.label === outcome.label)
        : -1;
    return {
      kind: "question",
      messageId,
      prompt: firstLine(m.text) || options.map((o) => o.label).join(" / "),
      choices: options.map((o, i) => ({
        id: String(i),
        label: o.label,
        ...(o.detail ? { description: o.detail } : {}),
        ...(o.recommended ? { recommended: true } : {}),
      })),
      multiSelect: false,
      allowOther: true,
      state: !m.cardState?.resolved
        ? { status: "open" }
        : outcome?.kind === "chose"
          ? {
              status: "answered",
              ...(chose >= 0 ? { choiceIds: [String(chose)] } : {}),
            }
          : outcome?.kind === "replaced"
            ? { status: "replaced" }
            : { status: "replied" },
    };
  }

  // ── what is done to it, as the coordinator does it to any Task ────────

  setDraft(input: In<"setDraft">): ChatCommandReceipt {
    const at = this.#leased(input);
    this.#composer.setText(at, input.draft);
    return this.#receipt(at);
  }

  prefillDraft(
    input: In<"prefillDraft">
  ): Effect.Effect<ChatCommandReceipt, CoreError> {
    return Effect.sync(() => this.setDraft(input));
  }

  /** A send reserves nothing here: what is written is taken as it sends. */
  beginSendIntent(input: In<"beginSendIntent">): ChatBeginSendIntentReceipt {
    const at = this.#leased(input);
    return {
      revision: this.#revision,
      draftEpoch: this.#composer.draft(at).epoch,
      sendIntentId: input.sendIntentId,
    };
  }

  cancelSendIntent(input: In<"cancelSendIntent">): ChatCommandReceipt {
    return this.#receipt(this.#leased(input));
  }

  /**
   * Sends what is written: the words the page sends, with the draft's files (unless `consumeDraft: false`) once nothing
   * is still being got or going up for it (`StationComposer.settled`), and the files given for this message alone,
   * which go up first. One that answers a message quotes it, and the skills it tags go with it for the agent. A
   * message the core could not put in the chat's outbox comes back to what is written.
   */
  send(
    input: In<"send">,
    onAccepted?: () => void
  ): Effect.Effect<ChatCommandReceipt, CoreError> {
    const at = this.#leased(input);
    const ctx = this.#ctx;
    const composer = this.#composer;
    const chats = this.#chats;
    const drafted = input.consumeDraft !== false;
    const [thread, seq] = (input.replyToMessageId ?? "").split(":").map(Number);
    const replyTo = thread === at.thread && Number.isSafeInteger(seq) ? seq : undefined;
    return Effect.gen(function* () {
      if (drafted) yield* composer.settled(at);
      const text = input.text.trim();
      const taken = drafted
        ? yield* Effect.try({
            try: () => composer.take(at),
            catch: (e) => e as CoreError,
          })
        : { attachments: [] };
      const restore = Effect.sync(() => {
        if (drafted) composer.restore(at, text, taken.attachments);
      });
      const given = input.files?.length
        ? yield* composer.put(at, input.files).pipe(Effect.tapError(() => restore))
        : [];
      const attachments = [...taken.attachments, ...given];
      if (text === "" && attachments.length === 0)
        return yield* restore.pipe(
          Effect.andThen(Effect.fail(CoreError.invalid("text is required")))
        );
      // The skills it tags go to the agent after the protocol marker, as Salix gives them (skills.ts); a person's own
      // marker is a word of theirs, as Salix escapes it.
      const account = ctx.session.current();
      const forModel =
        input.skills?.length && account
          ? yield* skillsBlock(ctx, account, at.workspace, input.skills)
          : "";
      onAccepted?.();
      yield* chats
        .send(
          at,
          text.replaceAll(COMMA_PROTOCOL_MARKER, "[[comma-protocol-user]]"),
          attachments,
          {
            ...(input.clientRequestId ? { id: input.clientRequestId } : {}),
            ...(replyTo !== undefined ? { replyTo } : {}),
            ...(forModel ? { forModel } : {}),
          }
        )
        .pipe(Effect.tapError(() => restore));
    }).pipe(Effect.map(() => this.#receipt(at)));
  }

  retry(input: In<"retry">): Effect.Effect<ChatCommandReceipt, CoreError> {
    const at = this.#leased(input);
    return this.#chats
      .retry(at, input.clientRequestId)
      .pipe(Effect.map(() => this.#receipt(at)));
  }

  discard(input: In<"discard">): ChatCommandReceipt {
    const at = this.#leased(input);
    this.#chats.discard(at, input.clientRequestId);
    return this.#receipt(at);
  }

  refresh(input: In<"refresh">): ChatCommandReceipt {
    const at = this.#leased(input);
    this.#chats.refresh(at);
    return this.#receipt(at);
  }

  /** Reads the page before the oldest message held: the views show it once it is read. */
  older(input: In<"older">): ChatCommandReceipt {
    const at = this.#leased(input);
    this.#ctx.runner.fork(this.#chats.older(at).pipe(Effect.ignore));
    return this.#receipt(at);
  }

  readTaskActivity(input: In<"readTaskActivity">): ChatCommandReceipt {
    const at = this.#leased(input);
    this.#chats.readActivity(at);
    return this.#receipt(at);
  }

  clearPresentation(input: In<"clearPresentation">): ChatCommandReceipt {
    return this.#receipt(this.#leased(input));
  }

  /** Its review accepted: it is done, on its station, as a person marks it there. */
  acceptTaskReview(
    input: In<"acceptTaskReview">
  ): Effect.Effect<ChatCommandReceipt, CoreError> {
    const at = this.#leased(input);
    return this.#actions
      .setStatus(at, "done")
      .pipe(Effect.map(() => this.#receipt(at)));
  }

  /** Accepts its review from its list: it is done, on its station. */
  accept(group: string, conversation: string): Effect.Effect<void, CoreError> {
    return Effect.suspend(() =>
      this.#actions.setStatus(this.#atOf(group, conversation), "done")
    ).pipe(Effect.asVoid);
  }

  setTaskStatus(
    input: In<"setTaskStatus">
  ): Effect.Effect<ChatCommandReceipt, CoreError> {
    const at = this.#leased(input);
    return this.#actions
      .setStatus(at, input.status === "completed" ? "done" : "cancelled")
      .pipe(Effect.map(() => this.#receipt(at)));
  }

  /** A run on another station, as a Task's run names it: that station by its name, with its Session's model. */
  #elsewhere(workspace: string, run: StationChatRun): ChatTaskRun {
    const named = this.#stations.named(workspace).find((s) => s.id === run.station);
    return {
      place: {
        kind: "station",
        deviceId: run.station,
        ...(named ? { name: named.name } : {}),
      },
      ...(run.runtime || run.model
        ? {
            model: {
              kind: "runtime" as const,
              ...(run.runtime ? { provider: run.runtime } : {}),
              ...(run.model ? { name: run.model } : {}),
            },
          }
        : {}),
    };
  }

  /**
   * Where it runs from its next turn, and with what: on another computer's station, whose Session is given it (the
   * device's station, as Comma's server knows it); or on its own station, where its chat's session takes another runtime
   * or model (another runtime goes on afresh, its past read back) and takes it up again when it ran elsewhere. Never
   * inside Comma (`HOSTED_UNSUPPORTED`'s `comma`).
   */
  setTaskRun(input: In<"setTaskRun">): Effect.Effect<ChatCommandReceipt, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const at = this.#leased(input);
      const account = this.#ctx.session.current();
      const listed = account
        ? this.#tasks.task(account, at.workspace, hostedId(at.station, at.thread))
        : null;
      const { runsOn, model } = input.run;
      if (runsOn.kind !== "station" || model?.kind === "catalog")
        return yield* Effect.fail(unsupported("run inside Comma"));
      const runtime = model?.kind === "runtime" ? model.provider : undefined;
      const named = model?.kind === "runtime" ? (model.model ?? null) : null;
      const station =
        runsOn.deviceId === (listed?.device ?? at.station) ||
        runsOn.deviceId === at.station
          ? at.station
          : yield* this.#stationOf(at.workspace, runsOn.deviceId);
      const chat = this.#chats.value(at);
      if (station !== at.station || chat.runsOn) {
        yield* this.#actions.runOn(at, {
          ...(station !== at.station ? { station } : {}),
          ...(runtime !== undefined ? { runtime } : {}),
          model: named,
        });
        return this.#receipt(at);
      }
      const session =
        this.#activity.rowOf(at.station, at.thread)?.session ?? chat.agents[0]?.session;
      if (!session)
        return yield* Effect.fail(
          new CoreError("not_found", "The machine has no session for it.")
        );
      yield* this.#actions.setRun(at, session, {
        ...(runtime !== undefined && runtime !== listed?.runtime ? { runtime } : {}),
        model: named,
      });
      return this.#receipt(at);
    });
  }

  /** The station a computer of the workspace runs, as Comma's server knows it. */
  #stationOf(workspace: string, device: string): Effect.Effect<string, CoreError> {
    return Effect.suspend(() => {
      const account = this.#ctx.session.current();
      if (!account)
        return Effect.fail(new CoreError("signed_out", "No one is signed in."));
      return this.#ctx.api
        .request(
          account,
          "GET",
          route`/v1/comma/workspaces/${workspace}/devices/${device}`,
          deviceSchema
        )
        .pipe(
          Effect.flatMap((found) =>
            found.station_id
              ? Effect.succeed(found.station_id)
              : Effect.fail(
                  new CoreError(
                    "unsupported",
                    "That computer runs no station that takes Tasks."
                  )
                )
          )
        );
    });
  }

  attach(input: In<"attach">): ChatCommandReceipt {
    const at = this.#leased(input);
    this.#composer.add(at, [{ name: input.name, bytes: input.bytes }]);
    return this.#receipt(at);
  }

  attachLocalFiles(input: In<"attachLocalFiles">): ChatCommandReceipt {
    const at = this.#leased(input);
    this.#composer.addLocal(
      at,
      input.files.map((f) => ({ ref: f.localFileRef, name: f.name, size: f.size }))
    );
    return this.#receipt(at);
  }

  /**
   * Files of another conversation's messages: each is read from where it is kept (`files.read`: Comma's server, or the
   * station of a Task one hosts), then goes up as a file given whole.
   */
  attachConversationFiles(input: In<"attachConversationFiles">): ChatCommandReceipt {
    const at = this.#leased(input);
    this.#composer.addFetched(
      at,
      input.files.map((file) => ({
        name: file.name,
        size: file.size,
        read: readFile(this.#ctx, this, {
          source: "attachment",
          group: input.groupId,
          conversation: file.conversationId,
          message: file.messageId,
          index: file.index,
        }).pipe(Effect.map((read) => read.bytes)),
      }))
    );
    return this.#receipt(at);
  }

  /**
   * The messages around `messageId` (`thread:seq`), as its view holds them once its chat is read back to it from its
   * station (a reply's quote, an Activity step's message, not loaded yet).
   */
  messageContext(
    group: string,
    conversation: string,
    messageId: string
  ): Effect.Effect<ChatMessage[], CoreError> {
    return Effect.suspend(() => {
      const at = this.#atOf(group, conversation);
      const seq = Number(messageId.split(":")[1]);
      if (!Number.isSafeInteger(seq) || seq <= 0)
        return Effect.fail(CoreError.invalid("No such message."));
      return this.#chats
        .older(at, seq)
        .pipe(
          Effect.map(
            () =>
              this.projection({ workspace: at.workspace, group, conversation })
                .serverMessages
          )
        );
    });
  }

  removeAttachment(input: In<"removeAttachment">): ChatCommandReceipt {
    const at = this.#leased(input);
    this.#composer.remove(at, input.attachmentId);
    return this.#receipt(at);
  }

  retryAttachment(input: In<"retryAttachment">): ChatCommandReceipt {
    const at = this.#leased(input);
    this.#composer.retry(at, input.attachmentId);
    return this.#receipt(at);
  }

  /** Files for a card's answer in its own words: they go up now, apart from the draft, and go with that answer. */
  attachQuestion(input: In<"attachQuestion">): ChatCommandReceipt {
    const at = this.#card(input);
    this.#composer.add(at, input.files);
    return this.#receipt(at);
  }

  removeQuestionAttachment(input: In<"removeQuestionAttachment">): ChatCommandReceipt {
    const at = this.#card(input);
    this.#composer.remove(at, input.attachmentId);
    return this.#receipt(at);
  }

  retryQuestionAttachment(input: In<"retryQuestionAttachment">): ChatCommandReceipt {
    const at = this.#card(input);
    this.#composer.retry(at, input.attachmentId);
    return this.#receipt(at);
  }

  answerQuestion(
    input: In<"answerQuestion">
  ): Effect.Effect<ChatCommandReceipt, CoreError> {
    const at = this.#leased(input);
    return this.#answer(at, input).pipe(Effect.map(() => this.#receipt(at)));
  }

  claimAttachmentIntake(input: In<"claimAttachmentIntake">): ChatAttachmentIntakeClaim {
    return this.#composer.claim(this.#leased(input));
  }

  room(target: ConversationTarget): PickRoom | null {
    return this.#composer.room(this.#at(target));
  }

  /** The files of the answer to the card `questionMessageId` names (`thread:seq`). */
  #card(input: ChatLeasedTarget & { questionMessageId: string }): DraftAt {
    const at = this.#leased(input);
    const seq = Number(input.questionMessageId.split(":")[1]);
    if (!Number.isSafeInteger(seq) || seq <= 0)
      throw CoreError.invalid("No such question.");
    return { ...at, question: seq };
  }

  #leased(input: ChatLeasedTarget): ChatAt {
    return this.#at({
      workspace: input.workspaceId,
      group: input.groupId,
      conversation: input.conversationId,
    });
  }

  /** A call's receipt, as the coordinator answers one: the views' revision and the draft's epoch. */
  #receipt(at: ChatAt): ChatCommandReceipt {
    return { revision: this.#revision, draftEpoch: this.#composer.draft(at).epoch };
  }

  /** A question card answered: a choice picks the card's option, words reply to it, a skip leaves it. */
  #answer(at: ChatAt, input: In<"answerQuestion">): Effect.Effect<null, CoreError> {
    const seq = Number(input.questionMessageId.split(":")[1]);
    if (!Number.isSafeInteger(seq) || seq <= 0)
      return Effect.fail(CoreError.invalid("No such question."));
    const card: CardAt = { ...at, seq };
    if (input.skipped === true) return this.#activity.dismiss(card);
    const other = input.other?.trim() ?? "";
    const files: DraftAt = { ...at, question: seq };
    if (other !== "" || this.#composer.draft(files).files.length > 0) {
      const composer = this.#composer;
      const activity = this.#activity;
      // Its own words go with the files that went up for it, once none is still going up.
      return Effect.gen(function* () {
        yield* composer.settled(files);
        const taken = yield* Effect.try({
          try: () => composer.take(files),
          catch: (e) => e as CoreError,
        });
        return yield* activity
          .reply(card, other, taken.attachments)
          .pipe(
            Effect.tapError(() =>
              Effect.sync(() => composer.restore(files, "", taken.attachments))
            )
          );
      });
    }
    const message = this.#chats.value(at).messages.find((m) => m.seq === seq);
    const choice = Number(input.choiceIds[0]);
    const label = message?.card?.options?.[choice]?.label;
    if (label === undefined) return Effect.fail(CoreError.invalid("No such choice."));
    return this.#activity.answer(card, label);
  }

  // ── the Task, as its list and its page change it ───────────────────────

  /** Names the Task. */
  rename(
    group: string,
    conversation: string,
    title: string
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() =>
      this.#actions.rename(this.#atOf(group, conversation), title)
    );
  }

  setLabels(
    group: string,
    conversation: string,
    labels: string[]
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() =>
      this.#actions.setLabels(this.#atOf(group, conversation), labels)
    ).pipe(Effect.asVoid);
  }

  archive(
    group: string,
    conversation: string,
    archived: boolean
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() =>
      this.#actions.archive(this.#atOf(group, conversation), archived)
    );
  }

  archived(account: Account, group: string): TaskSummary[] {
    const workspace = this.#workspaceOf(account, group);
    if (!workspace) return [];
    return this.#tasks
      .archived(account, workspace)
      .flatMap((task) => this.summary(account, group, task.id) ?? [])
      .toSorted((a, b) => (b.updated_at ?? 0) - (a.updated_at ?? 0));
  }

  keep(topic: Topic): Effect.Effect<void> {
    return this.#tasks.keep(topic);
  }

  pin(
    group: string,
    conversation: string,
    pinned: boolean
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const at = this.#atOf(group, conversation);
      return this.#activity.pin(at.workspace, at.station, at.thread, pinned);
    });
  }

  pinned(account: Account, group: string): string[] {
    const workspace = this.#workspaceOf(account, group);
    if (!workspace) return [];
    return this.#stations
      .named(workspace)
      .flatMap((station) =>
        this.#activity
          .rowsOf(station.id)
          .flatMap((row) =>
            row.pinned != null && row.thread !== null
              ? [{ id: hostedId(station.id, row.thread), at: row.pinned }]
              : []
          )
      )
      .toSorted((a, b) => a.at - b.at)
      .map((pin) => pin.id);
  }

  /** Its stations' chats are followed while a Group's pins are shown: they say which are pinned. */
  showPins(group: string): void {
    const account = this.#ctx.session.current();
    const workspace = account ? this.#workspaceOf(account, group) : undefined;
    if (workspace) this.#activity.hold(workspace, `pins:${group}`);
  }

  hidePins(group: string): void {
    const account = this.#ctx.session.current();
    const workspace = account ? this.#workspaceOf(account, group) : undefined;
    if (workspace) this.#activity.unhold(workspace, `pins:${group}`);
  }

  stop(topic: Topic): void {
    this.#tasks.stop(topic);
  }

  /** Stops the Task's agents at work. */
  cancel(group: string, conversation: string): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const at = this.#atOf(group, conversation);
      const running = this.#chats.value(at).agents.filter((agent) => agent.running);
      return Effect.forEach(
        running,
        (agent) =>
          this.#stations.ask(
            at.workspace,
            at.station,
            "POST",
            `/sessions/${encodeURIComponent(agent.session)}/stop`
          ),
        { discard: true }
      );
    });
  }

  /**
   * File `index` of message `message` (`thread:seq`), read from its station, at most `max` bytes: from the uploads of
   * each session that may keep it (StationChats.attachment), the first that has it.
   */
  readAttachment(
    group: string,
    conversation: string,
    message: string,
    index: number,
    max: number
  ): Effect.Effect<{ bytes: Uint8Array; type: string }, CoreError> {
    return this.#fromUploads(group, conversation, message, index, (at, session, name) =>
      this.#stations.file(
        at.workspace,
        at.station,
        `${route`/sessions/${session}/files`}?name=${encodeURIComponent(name)}`,
        max
      )
    ).pipe(Effect.map(({ bytes, type }) => ({ bytes, type })));
  }

  /**
   * Up to `length` bytes of it from `offset` (at most HOSTED_PART: its station's part), and its whole size: a file of
   * any size is read a part at a time (`GET /sessions/:key/parts`).
   */
  readAttachmentPart(
    group: string,
    conversation: string,
    message: string,
    index: number,
    offset: number,
    length: number
  ): Effect.Effect<{ bytes: Uint8Array; type: string; size: number }, CoreError> {
    const want = Math.min(length, HOSTED_PART);
    return this.#fromUploads(group, conversation, message, index, (at, session, name) =>
      this.#stations.file(
        at.workspace,
        at.station,
        `${route`/sessions/${session}/parts`}?name=${encodeURIComponent(name)}&offset=${offset}&length=${want}`,
        want
      )
    ).pipe(
      Effect.map(({ bytes, type, total }) => ({
        bytes,
        type,
        size: total ?? offset + bytes.byteLength,
      }))
    );
  }

  /**
   * Reads file `index` of message `message` (`thread:seq`) with `read`, from the uploads of each session that may
   * keep it (StationChats.attachment), the first that has it.
   */
  #fromUploads<A>(
    group: string,
    conversation: string,
    message: string,
    index: number,
    read: (at: ChatAt, session: string, name: string) => Effect.Effect<A, CoreError>
  ): Effect.Effect<A, CoreError> {
    return Effect.suspend(() => {
      const at = this.#atOf(group, conversation);
      const seq = Number(message.split(":")[1]);
      const file = Number.isSafeInteger(seq)
        ? this.#chats.attachment(at, seq, index)
        : null;
      const none = new CoreError("not_found", "The Task has no such file.");
      if (!file) return Effect.fail(none);
      const name = file.path.split(/[/\\]/).at(-1) ?? file.name;
      const from = (sessions: string[]): Effect.Effect<A, CoreError> =>
        sessions.length === 0
          ? Effect.fail(none)
          : read(at, sessions[0]!, name).pipe(
              Effect.catchIf(
                (error) => error.code === "not_found",
                () => from(sessions.slice(1))
              )
            );
      return from(file.sessions);
    });
  }

  /** The Task's facts as a summary has them (`taskSummaries`); null when this device does not list it. */
  summary(account: Account, group: string, id: string): TaskSummary | null {
    const workspace = this.#workspaceOf(account, group);
    const task = workspace ? this.#tasks.task(account, workspace, id) : null;
    if (!task) return null;
    return {
      id,
      group_id: group,
      kind: "agent_task",
      status: this.#tasks.shownStatus(task).status,
      title: task.title ?? "",
      labels: task.labels,
      ...(task.lastActivityAt ? { updated_at: task.lastActivityAt } : {}),
    };
  }

  #at(target: ConversationTarget): ChatAt {
    const chat = hostedChat(target.conversation);
    if (!chat) throw CoreError.invalid("This is not a Task a machine hosts.");
    return { workspace: target.workspace, ...chat };
  }

  #atOf(group: string, conversation: string): ChatAt {
    const account = this.#ctx.session.current();
    const workspace = account ? this.#workspaceOf(account, group) : undefined;
    if (!workspace) throw new CoreError("not_found", "No such workspace.");
    return this.#at({ workspace, group, conversation });
  }

  #workspaceOf(account: Account, group: string): string | undefined {
    return this.#workspaces.list(account)?.find((w) => w.group_id === group)?.id;
  }

  /** What a Task a station hosts shows changed: its conversation views compute again. */
  #changed(): void {
    this.#revision++;
    for (const topic of this.#ctx.kernel.store.liveTopics())
      if (topic.topic === "chatView" && this.owns(String(topic.conversation)))
        this.#ctx.kernel.store.invalidate(topic);
  }
}
