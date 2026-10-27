// What is being written in a chat on a station (a Task it hosts), as the core keeps it for the chat's conversation
// view (conversation.ts), as still.fail's core keeps what is written in its chats: the words, and the files going up
// to the station, which the core uploads in parts (`POST /uploads/parts`, on from where it was after a broken
// connection) and says how far each went. The page only draws it and says what was done. The words and the files that
// went up are kept on this device as the chat's draft; one still going up when the app stopped is not, and is added
// again. Taken to send, the files that went up go with the message (chat.ts's outbox).
//
// A file is given whole (its bytes), or by a ref the app holds it under (`host.readLocalFile`, read a part at a time).
// Files a dialog, a drop or AirDrop is still getting for what is written come through an intake (`claim`), as they
// come to any Task's draft; what it could not get stays as a failed file. A send waits until nothing is still being
// got or going up (`settled`).
//
// Bounds: one part of one file going up at a time per chat, PART bytes a request; files up to MAX_FILE, MAX_FILES a
// message.
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import type { Account } from "../account.ts";
import type {
  ChatAttachmentIntakeClaim,
  ChatAttachmentIntakeOutcome,
} from "../chat/coordinator/hostContract.ts";
import { INTAKE_FAILURE_PREFIX, type PickRoom } from "../chat/views.ts";
import type { StationAttachment } from "../contract.ts";
import type { Ctx } from "../ctx.ts";
import type { ChatAt } from "./chat.ts";
import type { Stations } from "./index.ts";

/** How much of a file goes up in one request. */
const PART = 4 * 1024 * 1024;
/** Bigger files are not taken: the station would refuse them. */
export const MAX_FILE = 1024 * 1024 * 1024;
/** The most files one message carries. */
export const MAX_FILES = 8;

/** A file being written with a message: going up, up (`done`, as the station keeps it), or failed (`error`). */
export type ComposerFile = {
  id: string;
  name: string;
  size: number;
  image: boolean;
  done: StationAttachment | null;
  error: string | null;
};

/** What is written in a chat (its composer's), or the files given for a card's answer in its own words (`question`, the card's seq). */
export type DraftAt = ChatAt & { question?: number };

/** What is written in a chat. `epoch` counts its changes. */
export type ComposerDraft = { text: string; files: ComposerFile[]; epoch: number };

/**
 * Where a file's bytes are read from while it goes up: given, a file the app holds (by ref), or read first from where
 * it is kept (another conversation's attachment), once.
 */
type Source =
  | { kind: "bytes"; bytes: Uint8Array }
  | { kind: "local"; ref: string }
  | { kind: "fetch"; read: Effect.Effect<Uint8Array, CoreError> };
/** A source a file goes up from: one read from elsewhere is read first (`#upload`). */
type Readable = Exclude<Source, { kind: "fetch" }>;

type Draft = ComposerDraft & {
  /** The bytes of files still going up, or to go up again, by id. */
  sources: Map<string, Source>;
  /** Taken to send this many times: an intake opened before a send adds nothing after it. */
  sent: number;
  /** The intakes open on it, by id. */
  intakes: Set<string>;
  /** Sends waiting for its next change (`settled`). */
  waiting: Set<() => void>;
  /** Going up now. */
  uploading: boolean;
  /** Read from this device, the first time it was asked for. */
  loaded: boolean;
};

const keptSchema = z.object({
  text: z.string(),
  files: z
    .array(
      z.object({
        id: z.string(),
        name: z.string(),
        size: z.number(),
        image: z.boolean(),
        done: z.object({ name: z.string(), path: z.string(), size: z.number() }),
      })
    )
    .max(MAX_FILES),
});

const partSchema = z.object({
  have: z.number(),
  file: z.object({ name: z.string(), path: z.string(), size: z.number() }).optional(),
});

const keyOf = (at: DraftAt) =>
  `${at.station}\t${at.thread}${at.question === undefined ? "" : `\t${at.question}`}`;
/** Where the chat's draft is kept on this device; a card's answer's files are not kept. */
const docOf = (at: DraftAt) =>
  at.question === undefined ? `stations.draft.${at.station}.${at.thread}` : null;
const IMAGE = /\.(png|jpe?g|gif|webp|heic|heif|avif|bmp|tiff?)$/i;

export class StationComposer {
  readonly #ctx: Ctx;
  readonly #stations: Stations;
  readonly #drafts = new Map<string, Draft>();
  readonly #listeners: ((at: DraftAt) => void)[] = [];

  constructor(ctx: Ctx, stations: Stations) {
    this.#ctx = ctx;
    this.#stations = stations;
    stations.onAccount(() => {
      const drafts = [...this.#drafts.values()];
      this.#drafts.clear();
      // The last account's drafts are gone: a send waiting on one looks again.
      for (const draft of drafts) this.#wake(draft);
    });
  }

  /** Told whenever what is written in a chat changed. */
  onChange(listener: (at: DraftAt) => void): void {
    this.#listeners.push(listener);
  }

  /** What is written in the chat `at` names. */
  draft(at: DraftAt): ComposerDraft {
    const { text, files, epoch } = this.#draft(at);
    return { text, files, epoch };
  }

  /** The cards of the chat `at` names that have files for an answer in their own words: each card's seq and files. */
  questions(at: ChatAt): { question: number; files: ComposerFile[] }[] {
    const chat = keyOf(at);
    return [...this.#drafts].flatMap(([key, draft]) => {
      const question = Number(key.slice(chat.length + 1));
      return key.startsWith(`${chat}\t`) && draft.files.length > 0
        ? [{ question, files: draft.files }]
        : [];
    });
  }

  /** What one pick may add: files up to MAX_FILES a message, each up to MAX_FILE; null when no more fit. */
  room(at: DraftAt): PickRoom | null {
    const left = MAX_FILES - this.#draft(at).files.length;
    return left > 0
      ? { maxFiles: left, maxUploadFiles: left, maxTotalSize: left * MAX_FILE }
      : null;
  }

  /**
   * Opens an intake on what is written: files a dialog, a drop or AirDrop is getting for it. It adds files only until
   * what is written is sent or the account changes; it settles once, with what could not be got (each a failed file),
   * or clean when given up unused. A send waits until it settled (`settled`).
   */
  claim(at: DraftAt): ChatAttachmentIntakeClaim {
    const draft = this.#draft(at);
    const intakeId = `intake-${this.#stations.onceKey()}`;
    const sent = draft.sent;
    draft.intakes.add(intakeId);
    this.#changed(at, draft);
    let active = true;
    const settle = (outcome: ChatAttachmentIntakeOutcome) => {
      if (!draft.intakes.delete(intakeId)) return;
      if (this.#drafts.get(keyOf(at)) === draft && draft.sent === sent)
        this.#failed(draft, intakeId, outcome);
      this.#changed(at, draft);
    };
    return {
      intakeId,
      assertCurrent: () => {
        if (!active || this.#drafts.get(keyOf(at)) !== draft || draft.sent !== sent)
          throw new Error("The Chat attachment intake claim is no longer active.");
      },
      markDialogClosed: () => undefined,
      settle,
      releaseIfUnused: () => {
        if (!active) return;
        active = false;
        settle({ cancelled: true, errorCount: 0 });
      },
    };
  }

  /**
   * Waits until nothing is still being got or going up for what is written in the chat `at` names: no intake open,
   * and each file up or failed.
   */
  settled(at: DraftAt): Effect.Effect<void> {
    return Effect.suspend(() => {
      const draft = this.#draft(at);
      if (draft.intakes.size === 0 && draft.files.every((f) => f.done || f.error))
        return Effect.void;
      return Effect.callback<void>((resume) => {
        const changed = () => resume(Effect.void);
        draft.waiting.add(changed);
        return Effect.sync(() => void draft.waiting.delete(changed));
      }).pipe(Effect.andThen(this.settled(at)));
    });
  }

  setText(at: DraftAt, text: string): void {
    const draft = this.#draft(at);
    if (draft.text === text) return;
    draft.text = text;
    this.#changed(at, draft);
  }

  /** Adds files given whole; each starts going up. Returns their ids. */
  add(at: DraftAt, files: { name: string; bytes: Uint8Array }[]): string[] {
    return files.map((f) =>
      this.#add(at, f.name, f.bytes.length, { kind: "bytes", bytes: f.bytes })
    );
  }

  /** Adds files the app holds by ref (`host.readLocalFile` reads them); each starts going up. */
  addLocal(
    at: DraftAt,
    files: { ref: string; name: string; size: number }[]
  ): string[] {
    if (!this.#ctx.host.readLocalFile)
      throw new CoreError(
        "unsupported",
        "This app cannot send that file to the machine."
      );
    return files.map((f) =>
      this.#add(at, f.name, f.size, { kind: "local", ref: f.ref })
    );
  }

  /** Adds files read first from where they are kept (`read`, once); each goes up once read. */
  addFetched(
    at: DraftAt,
    files: { name: string; size: number; read: Effect.Effect<Uint8Array, CoreError> }[]
  ): string[] {
    return files.map((f) =>
      this.#add(at, f.name, f.size, { kind: "fetch", read: f.read })
    );
  }

  /**
   * Puts files that go with one message alone (an inspected element's screenshot) on the station, apart from what is
   * written: each in parts, as a draft's file goes up. Fails when one does not go up; the message is not sent.
   */
  put(
    at: DraftAt,
    files: readonly { name: string; bytes: Uint8Array }[]
  ): Effect.Effect<StationAttachment[], CoreError> {
    return Effect.forEach(files, (f) =>
      f.bytes.length > MAX_FILE
        ? Effect.fail(CoreError.invalid("The file is larger than the machine takes."))
        : Effect.suspend(() =>
            this.#send(
              at,
              {
                id: this.#stations.onceKey(),
                name: f.name,
                size: f.bytes.length,
                image: IMAGE.test(f.name),
                done: null,
                error: null,
              },
              { kind: "bytes", bytes: f.bytes }
            )
          )
    );
  }

  /** A failed file goes up again, from the start. One an intake could not get is settled by the pick made for it. */
  retry(at: DraftAt, id: string): void {
    if (id.startsWith(INTAKE_FAILURE_PREFIX)) return this.remove(at, id);
    const draft = this.#draft(at);
    const file = draft.files.find((f) => f.id === id);
    if (!file || !file.error || !draft.sources.has(id)) return;
    draft.files = draft.files.map((f) => (f.id === id ? { ...f, error: null } : f));
    this.#changed(at, draft);
    this.#upload(at, draft);
  }

  remove(at: DraftAt, id: string): void {
    const draft = this.#draft(at);
    if (!draft.files.some((f) => f.id === id)) return;
    draft.files = draft.files.filter((f) => f.id !== id);
    draft.sources.delete(id);
    this.#changed(at, draft);
  }

  /**
   * What is written, taken to send: its words and the files that went up; the chat's draft is empty after. Fails while
   * a file is still going up (a send waits for it, `settled`) or failed (it is retried or removed).
   */
  take(at: DraftAt): { text: string; attachments: StationAttachment[] } {
    const draft = this.#draft(at);
    if (draft.files.some((f) => !f.done))
      throw new CoreError("upload", "A file has not gone up to the machine yet.");
    const taken = { text: draft.text, attachments: draft.files.map((f) => f.done!) };
    draft.text = "";
    draft.files = [];
    draft.sources.clear();
    draft.sent++;
    this.#changed(at, draft);
    return taken;
  }

  /** A message that could not be sent comes back to what is written, unless something was written since. */
  restore(at: DraftAt, text: string, attachments: StationAttachment[]): void {
    const draft = this.#draft(at);
    if (draft.text !== "" || draft.files.length > 0) return;
    draft.text = text;
    draft.files = attachments.map((done, i) => ({
      id: `${draft.epoch}-${i}`,
      name: done.name,
      size: done.size,
      image: IMAGE.test(done.name),
      done,
      error: null,
    }));
    this.#changed(at, draft);
  }

  #add(at: DraftAt, name: string, size: number, source: Source): string {
    const draft = this.#draft(at);
    if (draft.files.length >= MAX_FILES)
      throw CoreError.invalid(`A message carries at most ${MAX_FILES} files.`);
    const id = this.#stations.onceKey();
    draft.files = [
      ...draft.files,
      {
        id,
        name,
        size,
        image: IMAGE.test(name),
        done: null,
        error: size > MAX_FILE ? "The file is larger than the machine takes." : null,
      },
    ];
    if (size <= MAX_FILE) draft.sources.set(id, source);
    this.#changed(at, draft);
    this.#upload(at, draft);
    return id;
  }

  /** What intake `intakeId` could not get: a failed file each, which a send waits for until it is removed. */
  #failed(draft: Draft, intakeId: string, outcome: ChatAttachmentIntakeOutcome): void {
    const count = Math.max(outcome.errorCount, outcome.errors?.length ?? 0);
    const failed = Array.from({ length: count }, (_, i): ComposerFile => {
      const error = outcome.errors?.[i];
      return {
        id: `${INTAKE_FAILURE_PREFIX}${intakeId}:${i}`,
        name: error?.name ?? "Selected file",
        size: 0,
        image: error?.isImage ?? false,
        done: null,
        error: error?.message ?? "The selected file could not be attached.",
      };
    });
    draft.files = [...draft.files, ...failed];
  }

  /** Sends up, one after another, the files that have not gone up and have not failed. */
  #upload(at: DraftAt, draft: Draft): void {
    if (draft.uploading) return;
    const next = draft.files.find(
      (f) => !f.done && !f.error && draft.sources.has(f.id)
    );
    if (!next) return;
    draft.uploading = true;
    const source = draft.sources.get(next.id)!;
    // One read from where it is kept is read once: going up again starts from its bytes.
    const ready: Effect.Effect<Readable, CoreError> =
      source.kind === "fetch"
        ? source.read.pipe(
            Effect.map((bytes) => {
              const read: Readable = { kind: "bytes", bytes };
              if (draft.sources.get(next.id) === source)
                draft.sources.set(next.id, read);
              return read;
            })
          )
        : Effect.succeed(source);
    this.#ctx.runner.fork(
      ready.pipe(
        Effect.flatMap((from) => this.#send(at, next, from)),
        Effect.match({
          onSuccess: (done) => this.#settle(at, draft, next.id, { done }),
          onFailure: (e) =>
            this.#settle(at, draft, next.id, {
              error: e.message || "The file could not go up to the machine.",
            }),
        }),
        Effect.ensuring(
          Effect.sync(() => {
            draft.uploading = false;
            // The account changed meanwhile: what this one held is gone.
            if (this.#drafts.get(keyOf(at)) === draft) this.#upload(at, draft);
          })
        )
      )
    );
  }

  /** One file up, in parts: each request says how much the station has, and the next part goes from there. */
  #send(
    at: DraftAt,
    file: ComposerFile,
    source: Readable
  ): Effect.Effect<StationAttachment, CoreError> {
    const ctx = this.#ctx;
    const stations = this.#stations;
    return Effect.gen(function* () {
      let have = 0;
      for (;;) {
        const length = Math.min(PART, file.size - have);
        const bytes =
          source.kind === "bytes"
            ? source.bytes.subarray(have, have + length)
            : yield* ctx.host.readLocalFile!(source.ref, have, length).pipe(
                Effect.mapError((e) => new CoreError("upload", e.message))
              );
        if (bytes.length !== length)
          return yield* Effect.fail(
            new CoreError("upload", "The file changed or is gone; add it again.")
          );
        const answer = partSchema.safeParse(
          yield* stations.ask(
            at.workspace,
            at.station,
            "POST",
            `/uploads/parts?id=${file.id}&name=${encodeURIComponent(file.name)}&size=${file.size}&offset=${have}`,
            undefined,
            { raw: { bytes, type: "application/octet-stream" } }
          )
        );
        if (!answer.success)
          return yield* Effect.fail(
            new CoreError("bad_response", "The machine kept no file.")
          );
        if (answer.data.file) return answer.data.file;
        // A part that added nothing would be sent again forever.
        if (answer.data.have <= have)
          return yield* Effect.fail(
            new CoreError("upload", "The file could not go up to the machine.")
          );
        have = answer.data.have;
      }
    });
  }

  #settle(
    at: DraftAt,
    draft: Draft,
    id: string,
    outcome: { done: StationAttachment } | { error: string }
  ): void {
    if (this.#drafts.get(keyOf(at)) !== draft || !draft.files.some((f) => f.id === id))
      return;
    draft.files = draft.files.map((f) =>
      f.id === id
        ? "done" in outcome
          ? { ...f, done: outcome.done, error: null }
          : { ...f, error: outcome.error }
        : f
    );
    if ("done" in outcome) draft.sources.delete(id);
    this.#changed(at, draft);
  }

  #draft(at: DraftAt): Draft {
    const key = keyOf(at);
    let draft = this.#drafts.get(key);
    if (!draft) {
      draft = {
        text: "",
        files: [],
        epoch: 0,
        sources: new Map(),
        sent: 0,
        intakes: new Set(),
        waiting: new Set(),
        uploading: false,
        loaded: false,
      };
      this.#drafts.set(key, draft);
    }
    const doc = docOf(at);
    if (!draft.loaded) {
      draft.loaded = true;
      const account = this.#ctx.session.current();
      const kept =
        account && doc ? keptSchema.safeParse(account.doc(doc)?.value) : null;
      if (kept?.success) {
        draft.text = kept.data.text;
        draft.files = kept.data.files.map((f) => ({ ...f, error: null }));
      }
    }
    return draft;
  }

  #changed(at: DraftAt, draft: Draft): void {
    draft.epoch++;
    this.#keep(at, draft);
    this.#wake(draft);
    for (const listener of this.#listeners) listener(at);
  }

  /** Wakes the sends waiting for `draft` to change: one still waiting after waits for the next change. */
  #wake(draft: Draft): void {
    const waiting = [...draft.waiting];
    draft.waiting.clear();
    for (const changed of waiting) changed();
  }

  /** The words and the files that went up, kept on this device; nothing kept for an empty draft. */
  #keep(at: DraftAt, draft: Draft): void {
    const account: Account | null = this.#ctx.session.current();
    const doc = docOf(at);
    if (!account || account.closed || !doc) return;
    const files = draft.files.filter((f) => f.done);
    if (draft.text === "" && files.length === 0) account.deleteDoc(doc);
    else
      account.putDoc(
        doc,
        {
          text: draft.text,
          files: files.map(({ id, name, size, image, done }) => ({
            id,
            name,
            size,
            image,
            done,
          })),
        },
        this.#ctx.now()
      );
  }
}
