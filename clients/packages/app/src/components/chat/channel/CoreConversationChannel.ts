import type { ManualTaskStatus } from "@comma/chat-contract";
import type { CoreClient } from "@comma/core-client";
import type { ChatViewValue } from "@comma/core/contract";
import {
  idleConversationChannelState,
  isImageAttachment,
  isTranscodedImageAttachment,
  pickQuota,
  type AttachmentUploadInput,
  type ChatImagePreviewRef,
  type ConversationChannelState,
  type DraftAttachment,
} from "@comma/core/chat";
import { messages, type CommaLocale } from "@comma/i18n";
import type { CommaNativeBridge } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import type { ChatChannel, ChatSendOptions, QuestionCardAnswer } from "./ChatChannel";
import { LocalFilePreviews } from "./LocalFilePreviews";
import { OptimisticDraft } from "./optimisticDraft";

/** A file this window is reading or handing over, shown until the view has it; a failed one keeps its files. */
type LocalRow = {
  row: DraftAttachment;
  /** The receipt's revision once the core has the file: the row goes once the view is that new. */
  shownFrom?: number;
  files?: AttachmentUploadInput[];
};

type Receipt = { revision: number; draftEpoch?: number | undefined };

/**
 * A window's channel on one conversation: the core's view of it (`chatView`), which retains it while subscribed, and
 * the `chatView.*` calls. The window keeps only what is under way: its draft edits (shown before the core has them)
 * and the files it is reading. Calls go out in the order they were made; one waits behind a file still being read.
 */
export class CoreConversationChannel implements ChatChannel {
  readonly #client: CoreClient;
  readonly #bridge: CommaNativeBridge;
  readonly #locale: CommaLocale;
  readonly #session: SessionProductLease;
  readonly #topic: {
    topic: "chatView";
    workspace: string;
    group: string;
    conversation: string;
    surface: string;
  };
  readonly #previews: LocalFilePreviews;
  readonly #listeners = new Set<() => void>();
  #draft = new OptimisticDraft();
  #local: LocalRow[] = [];
  #localIds = 0;
  #value: ChatViewValue | undefined;
  #state: ConversationChannelState;
  /** Showing a transcript carried over from before (`initialState`) until the core's is ready. */
  #seeded: boolean;
  #unsubscribe: (() => void) | undefined;
  /** Calls holding the line (queued, or a drop under way), and when it is free: each goes out once it is. */
  #holding = 0;
  #line: Promise<void> = Promise.resolve();
  /** Resolved once the core retained the view (its lease is known), or the channel stopped. */
  #leased: Promise<void> = Promise.resolve();
  #onLeased: () => void = noop;
  /** How many times the core forgot this window (it started again, or another tab runs it now). */
  #restarts = 0;
  /** Calls the core lost as it started again, waiting for the next restart's view. */
  #restartWaiters: ((leased: Promise<void>) => void)[] = [];
  #stopRejoin: (() => void) | undefined;

  readonly transcodesImages: boolean;
  readonly pickAttachments: (() => unknown) | undefined;

  constructor({
    client,
    bridge,
    conversationId,
    groupId,
    initialState,
    locale,
    session,
    workspaceId,
  }: {
    client: CoreClient;
    bridge: CommaNativeBridge;
    conversationId: string;
    groupId: string;
    /**
     * A transcript this session showed before (ChatProvider's seeds), shown at once and until the core's is ready.
     * Display only: no draft, attachments or sends.
     */
    initialState?: ConversationChannelState;
    locale: CommaLocale;
    session: SessionProductLease;
    workspaceId: string;
  }) {
    this.#client = client;
    this.#bridge = bridge;
    this.#locale = locale;
    this.#session = session;
    this.#topic = {
      topic: "chatView",
      workspace: workspaceId,
      group: groupId,
      conversation: conversationId,
      surface: bridge.self.windowId,
    };
    this.#previews = new LocalFilePreviews(client, bridge, { groupId, session });
    this.#state = initialState ?? idleConversationChannelState;
    this.#seeded = initialState !== undefined;
    // Main transcodes HEIC on macOS only: the composer turns an undecodable camera file away before it attaches.
    this.transcodesImages = bridge.os === "macos";
    this.pickAttachments =
      bridge.platform === "electron"
        ? () => this.#call<boolean>("chatView.pickAttachments", {})
        : undefined;
  }

  start() {
    if (this.#unsubscribe) return;
    this.#previews.replace();
    this.#leased = new Promise((resolve) => (this.#onLeased = resolve));
    // A core that forgot this window holds its view again once the subscription comes back: calls it lost run then.
    this.#stopRejoin = this.#client.onRejoin(() => {
      this.#restarts += 1;
      this.#leased = new Promise((resolve) => (this.#onLeased = resolve));
      for (const wake of this.#restartWaiters.splice(0)) wake(this.#leased);
    });
    this.#unsubscribe = this.#client.subscribe(
      this.#topic,
      (value) => this.#adopt(value as ChatViewValue),
      () => undefined
    );
  }

  stop() {
    this.#previews.dispose();
    if (!this.#unsubscribe) return;
    this.#unsubscribe();
    this.#unsubscribe = undefined;
    this.#stopRejoin?.();
    this.#stopRejoin = undefined;
    this.#onLeased();
    for (const wake of this.#restartWaiters.splice(0)) wake(Promise.resolve());
    this.#value = undefined;
    this.#draft = new OptimisticDraft();
    this.#local = [];
    this.#state = { ...this.#state, draftAttachments: [] };
    this.#emit();
  }

  subscribe(listener: () => void) {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }

  getSnapshot() {
    return this.#state;
  }

  setDraft(draft: string) {
    const optimistic = this.#draft;
    optimistic.beginEdit();
    this.#state = { ...this.#state, draft };
    this.#emit();
    const edit = this.#call<Receipt>("chatView.setDraft", { draft });
    void edit.then(
      (receipt) => {
        optimistic.acknowledgeEdit(receipt.draftEpoch);
        if (optimistic === this.#draft) this.#show();
      },
      () => {
        optimistic.rejectEdit();
        if (optimistic === this.#draft) this.#show();
      }
    );
    return edit;
  }

  prefillDraft(text: string) {
    return this.#call("chatView.prefillDraft", { draft: text });
  }

  /** Answers once the server has the message; `accepted` once it is pending (the core owns it from there). */
  send(text: string, options: ChatSendOptions = {}) {
    // Sent as it is: the core's next draft (empty, or what came after) decides the text.
    if (options.consumeDraft !== false && text === this.#state.draft)
      this.#draft.handOver();
    let accept!: () => void;
    const accepted = new Promise<void>((resolve) => (accept = resolve));
    const completion = this.#call(
      "chatView.send",
      {
        text,
        ...(options.consumeDraft === false ? { consumeDraft: false } : {}),
        ...(options.replyToMessageId
          ? { replyToMessageId: options.replyToMessageId }
          : {}),
        ...(options.skills ? { skills: options.skills } : {}),
        ...(options.files?.length ? { files: options.files } : {}),
      },
      () => accept()
    );
    const admission = Promise.race([accepted, completion.then(() => undefined)]);
    void admission.catch(() => undefined);
    void completion.catch(() => undefined);
    return Object.assign(completion, { accepted: admission });
  }

  clearPresentation() {
    return this.#call("chatView.clearPresentation", {});
  }

  retry(clientRequestId: string) {
    return this.#call("chatView.retry", { clientRequestId });
  }

  discard(clientRequestId: string) {
    return this.#call("chatView.discard", { clientRequestId });
  }

  acceptTaskReview(reviewVersion: number) {
    return this.#call("chatView.acceptTaskReview", { reviewVersion });
  }

  setTaskStatus(status: ManualTaskStatus, expectedUpdatedAt: number) {
    return this.#call("chatView.setTaskStatus", { status, expectedUpdatedAt });
  }

  refresh() {
    return this.#call("chatView.refresh", {});
  }

  readTaskActivity() {
    return this.#call("chatView.readTaskActivity", {});
  }

  /**
   * Files dropped or pasted on the composer. On Electron, files from disk go to Main, which reads them and attaches
   * what the draft has room for; otherwise this window reads each and attaches its bytes. A question card's images
   * (`questionMessageId`) are read here and attached as bytes to the card, apart from the draft.
   */
  attachFiles(files: AttachmentUploadInput[], questionMessageId?: string) {
    if (!this.#unsubscribe || files.length === 0) return undefined;
    if (questionMessageId !== undefined)
      return this.#attachToCard(questionMessageId, files);
    if (
      this.#bridge.platform === "electron" &&
      files.every((file) => typeof File !== "undefined" && file.data instanceof File)
    ) {
      this.#drop(files);
      return undefined;
    }
    for (const file of files) this.#upload(file);
    return undefined;
  }

  previewLocalFile(previewRef: ChatImagePreviewRef, signal?: AbortSignal) {
    return this.#previews.acquire(previewRef, signal);
  }

  removeAttachment(attachmentId: string, questionMessageId?: string) {
    if (questionMessageId === undefined && this.#dropLocal(attachmentId)) return;
    void this.#call("chatView.removeAttachment", {
      attachmentId,
      ...(questionMessageId !== undefined ? { questionMessageId } : {}),
    }).catch(() => undefined);
  }

  retryAttachment(attachmentId: string, questionMessageId?: string) {
    if (questionMessageId !== undefined) {
      void this.#call("chatView.retryAttachment", {
        attachmentId,
        questionMessageId,
      }).catch(() => undefined);
      return;
    }
    const local = this.#local.find((entry) => entry.row.id === attachmentId);
    if (local?.files) {
      this.#dropLocal(attachmentId);
      this.attachFiles(local.files);
      return;
    }
    void this.#call("chatView.retryAttachment", { attachmentId }).catch(
      () => undefined
    );
  }

  answerQuestion(answer: QuestionCardAnswer) {
    return this.#call("chatView.answerQuestion", {
      questionMessageId: answer.questionMessageId,
      choiceIds: answer.choiceIds,
      ...(answer.other !== undefined ? { other: answer.other } : {}),
      ...(answer.skipped ? { skipped: true } : {}),
    });
  }

  #attachToCard(questionMessageId: string, files: AttachmentUploadInput[]) {
    const read = Promise.all(
      files.map((file) =>
        file.data.arrayBuffer().then((buffer) => ({
          name: file.name,
          size: file.size,
          bytes: new Uint8Array(buffer),
        }))
      )
    );
    const attached = this.#call(
      "chatView.attach",
      () => read.then((bytes) => ({ questionMessageId, files: bytes })),
      undefined
    );
    void attached.catch(() => undefined);
    return attached;
  }

  /** One file read here and attached as bytes: shown as uploading meanwhile. */
  #upload(file: AttachmentUploadInput) {
    const local: LocalRow = {
      row: {
        error: undefined,
        id: `local-upload:${++this.#localIds}`,
        isImage: isImageAttachment(file.name) || isTranscodedImageAttachment(file.name),
        name: file.name,
        path: undefined,
        size: file.size,
        status: "uploading",
      },
    };
    this.#local = [...this.#local, local];
    this.#show();
    const read = file.data.arrayBuffer();
    this.#call<Receipt>(
      "chatView.attach",
      () =>
        read.then((buffer) => ({
          files: [{ name: file.name, size: file.size, bytes: new Uint8Array(buffer) }],
        })),
      undefined
    ).then(
      (receipt) => this.#settleLocal(local, { shownFrom: receipt.revision }),
      (error: unknown) => this.#failLocal(local, error, [file])
    );
  }

  /** Files from disk, which Electron's Main reads; a pick that fails before Main has them shows as one failed row. */
  // The drop holds the line until Main attached the files: a send made meanwhile carries them.
  #drop(files: AttachmentUploadInput[]) {
    void this.#inLine(
      () => {
        const lease = this.#value?.lease;
        if (!lease)
          return Promise.reject(new Error("Chat is not available in this window."));
        const quota = pickQuota(this.#state.draftAttachments);
        if (!quota) return Promise.resolve(undefined);
        return this.#bridge.chat.pickAttachments({
          workspaceId: this.#topic.workspace,
          groupId: this.#topic.group,
          conversationId: this.#topic.conversation,
          ...lease,
          surfaceId: this.#topic.surface,
          session: this.#session,
          ...quota,
          files: files.map((file) => file.data as File),
        });
      },
      { until: "done", before: this.#leased }
    ).catch((error: unknown) => {
      const local: LocalRow = {
        row: {
          error: undefined,
          id: `local-drop:${++this.#localIds}`,
          isImage: false,
          name: files[0]!.name,
          path: undefined,
          size: 0,
          status: "uploading",
        },
      };
      this.#failLocal(local, error, files);
    });
  }

  #settleLocal(local: LocalRow, change: Partial<LocalRow>) {
    if (!this.#local.includes(local)) return;
    this.#local = this.#local.map((entry) =>
      entry === local ? { ...entry, ...change } : entry
    );
    this.#show();
  }

  #failLocal(local: LocalRow, error: unknown, files: AttachmentUploadInput[]) {
    if (!this.#unsubscribe) return;
    const failed: LocalRow = {
      row: {
        ...local.row,
        status: "failed",
        error:
          error instanceof Error && error.message
            ? error.message
            : messages.chat_attachment_admission_failed({}, { locale: this.#locale }),
      },
      files,
    };
    this.#local = this.#local.includes(local)
      ? this.#local.map((entry) => (entry === local ? failed : entry))
      : [...this.#local, failed];
    this.#show();
  }

  #dropLocal(attachmentId: string) {
    const kept = this.#local.filter((entry) => entry.row.id !== attachmentId);
    if (kept.length === this.#local.length) return false;
    this.#local = kept;
    this.#show();
    return true;
  }

  /**
   * A `chatView.*` call for this view, in line: it goes out once every call made before it did. `params` may be a
   * promise of them (a file being read): calls made after it wait.
   */
  #call<R = unknown>(
    name: string,
    params: object | (() => Promise<object>),
    onProgress?: (value: unknown) => void
  ): Promise<R> {
    const named = {
      workspace: this.#topic.workspace,
      group: this.#topic.group,
      conversation: this.#topic.conversation,
      surface: this.#topic.surface,
      session: { sessionId: this.#session.sessionId, audience: this.#session.audience },
    };
    if (typeof params !== "function")
      return this.#inLine(() =>
        this.#survivingRestart<R>(name, { ...params, ...named }, onProgress)
      );
    const ready = params();
    return this.#inLine(
      () =>
        ready.then((resolved: object) =>
          this.#survivingRestart<R>(name, { ...resolved, ...named }, onProgress)
        ),
      { before: ready }
    );
  }

  /**
   * A call the core lost as it started again (another tab ran it and closed, Electron's core process restarted) runs
   * again once the new core holds this window's view. The loss can be heard before the new core is reached (Electron)
   * or after (the web's takeover): then it waits for that restart.
   */
  #survivingRestart<R>(
    name: string,
    params: object,
    onProgress: ((value: unknown) => void) | undefined
  ): Promise<R> {
    const restartsAtStart = this.#restarts;
    const run = () => this.#client.call(name, params, onProgress) as Promise<R>;
    return run().catch((error: unknown) => {
      if (
        (error as { code?: unknown })?.code !== "core_restarted" ||
        !this.#unsubscribe
      )
        throw error;
      const leased =
        this.#restarts !== restartsAtStart
          ? this.#leased
          : new Promise<void>((resolve) =>
              this.#restartWaiters.push((next) => void next.then(resolve))
            );
      return leased.then(() => {
        if (!this.#unsubscribe) throw error;
        return run();
      });
    });
  }

  /**
   * Makes `call` once every call queued before it was made, and those holding the line (`until: "done"`) ended; and
   * once `before` settled. At once when nothing holds the line.
   */
  #inLine<R>(
    call: () => Promise<R>,
    {
      before,
      until = "made",
    }: { before?: Promise<unknown>; until?: "made" | "done" } = {}
  ): Promise<R> {
    if (this.#holding === 0 && !before && until === "made") return call();
    this.#holding += 1;
    const made = Promise.all([this.#line, before?.catch(() => undefined)]).then(() => ({
      result: call(),
    }));
    const result = made.then((out) => out.result);
    const free = until === "done" ? result.then(noop, noop) : made.then(noop);
    this.#line = free;
    void free.then(() => {
      this.#holding -= 1;
    });
    return result;
  }

  /** The core's view, if it is of this window's session. */
  #adopt(value: ChatViewValue) {
    const session = value.session;
    if (
      !session ||
      session.sessionId !== this.#session.sessionId ||
      session.audience !== this.#session.audience
    )
      return;
    if (!value.state && this.#value?.state) {
      // The conversation is no longer retained (the account changed): nothing of it stays.
      this.#draft = new OptimisticDraft();
      this.#local = [];
      this.#seeded = false;
      this.#previews.dispose();
      this.#value = value;
      this.#state = idleConversationChannelState;
      this.#emit();
      return;
    }
    if (value.state) this.#previews.ensure();
    this.#value = value;
    if (value.lease) this.#onLeased();
    if (value.state)
      this.#draft.observe(value.state.draft, value.draftEpoch ?? undefined);
    this.#show();
  }

  /** Shows the core's view, with what is under way here. */
  #show() {
    const value = this.#value;
    const core = value?.state;
    if (!value || !core) {
      if (this.#local.length === 0) return;
      this.#state = { ...this.#state, draftAttachments: this.#rows([]) };
      this.#emit();
      return;
    }
    let next = core;
    if (this.#seeded) {
      // The core's first views of a conversation it is opening (idle, loading) do not blank the transcript carried
      // over: it yields once the core's is ready. Rows sent meanwhile show above it; an error shows over it.
      if (next.status === "ready") this.#seeded = false;
      else next = overlaySeededTranscript(next, this.#state);
    }
    this.#local = this.#local.filter(
      (entry) => entry.shownFrom === undefined || entry.shownFrom > value.revision
    );
    this.#state = {
      ...next,
      draft: this.#draft.adoptable() ?? this.#state.draft,
      draftAttachments: this.#rows(next.draftAttachments),
    };
    this.#emit();
  }

  #rows(core: DraftAttachment[]): DraftAttachment[] {
    return this.#local.length === 0
      ? core
      : [...core, ...this.#local.map((entry) => entry.row)];
  }

  #emit() {
    for (const listener of this.#listeners) listener();
  }
}

/** The core's view of a conversation still opening, over the transcript carried over. */
export function overlaySeededTranscript(
  next: ConversationChannelState,
  seeded: ConversationChannelState
): ConversationChannelState {
  const pendingRows = next.messages.filter((item) => item.source === "pending");
  const showError = next.status === "error" || seeded.status === "error";
  return {
    ...next,
    conversation: next.conversation ?? seeded.conversation,
    errorKind: showError ? (next.errorKind ?? seeded.errorKind) : next.errorKind,
    messages: [...seeded.serverMessages, ...pendingRows],
    serverMessages: seeded.serverMessages,
    status: showError ? ("error" as const) : ("ready" as const),
    syncWarning: "stale",
  };
}

function noop() {}
