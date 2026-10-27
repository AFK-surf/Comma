// One chat on a station, as the conversation view of the Task it hosts shows it (conversation.ts): its latest page of
// entries, older pages as asked, new entries as the station's `thread` events bring them (a gap is read), its agents as
// the station's chat row says, and what is being sent from here. A message sent goes into the chat's outbox, kept on
// this device, and to the station with its own key: sent again (a retry, or the next start), the station answers it as
// it answered the first, so it is never posted twice. It leaves the outbox once the chat holds it, and its entry there
// says, for the rest of the run, the id it was sent under (`sentAs`: the sender's, or the core's). An agent's post comes
// parsed as Markdown, as a Salix message does.
//
// A message that answers another quotes it, as the station's chats answer one; the chat is threaded as Salix threads
// a conversation: a message joins the thread of the one it answers (the one it quotes, or for an agent's post the
// last message its agent was given), any other starts its own (`replyTo`, `root`). What a message carries for its agent
// alone (the skills it tags, skills.ts) goes after the protocol marker, which no page shows.
//
// The chat's Activity is its agents' milestones, grouped as a Salix Task's are (chat/model/taskActivity.ts), each
// named as its conversation names the message (`thread:seq`). A post of milestones alone (a `milestone` entry) is shown
// nowhere else. The Activity reads the whole chat: the history before what the chat holds is read for it alone, cut to
// what it reads, when asked (`readActivity`).
//
// Bounds: per open chat, one read of its summary and latest page when it opens and again when its station's stream
// opens again; one read per gap and per older page asked; for the Activity, one read at a time of pages of
// ACTIVITY_PAGE entries, back to the chat's first. An agent's post is parsed once per version of it held.
import type { ChatTaskActivity } from "@comma/chat-contract";
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { route } from "../api.ts";
import {
  taskActivity,
  withEarlier,
  type TaskActivityMessage,
} from "../chat/model/taskActivity.ts";
import {
  COMMA_PROTOCOL_MARKER,
  stripCommaProtocolMarkers,
} from "../chat/model/protocol.ts";
import { messageMarkdown } from "../markdown/message.ts";
import type { MarkdownTree } from "../markdown/tree.ts";
import type {
  StationAttachment,
  StationCardShown,
  StationLinkState,
} from "../contract.ts";
import type { Ctx } from "../ctx.ts";
import { fromBase64 } from "../record.ts";
import type { StationActivity } from "./activity.ts";
import type { Stations } from "./index.ts";
import {
  entriesSchema,
  QUOTE_MAX,
  sentSchema,
  threadEventSchema,
  threadSchema,
  uploadedSchema,
  type StationChatRow,
  type StationEntry,
  type StationThread,
} from "./station-api.ts";
import { agentState, cardShown, firstLine, type Viewer } from "./views.ts";

/** The most a message's files may weigh, together. */
export const UPLOAD_MAX_BYTES = 8 * 1024 * 1024;
const PAGE = 50;
/** Entries one read of a chat's history for its Activity takes (the station gives at most 500). */
const ACTIVITY_PAGE = 500;
/** What the Activity keeps of a person's words: a request's first line is read from them. */
const ACTIVITY_TEXT = 500;

/** How a card in a chat stands: waiting, or how it ended. */
export interface StationCardState {
  resolved: boolean;
  outcome?:
    | { kind: "chose"; label: string }
    | { kind: "replied" }
    | { kind: "replaced" };
}

export interface StationChatMessage {
  seq: number;
  thread: number;
  kind: "person" | "agent" | "system";
  author: string;
  text: string;
  /** An agent's post as the core parsed it (`@comma/core/markdown`'s tree), as a Salix message's: no client parses it. */
  markdown?: MarkdownTree;
  /**
   * The id this device sent it under (a send's `clientRequestId`), while this run of the core knows it: a view keeps
   * the row it showed the message in while it was being sent.
   */
  sentAs?: string;
  attachments: StationAttachment[];
  createdAt: number;
  /**
   * The message it answers (its seq), as a Salix message's reply: the one of the chat it quotes, or for an agent's
   * post the last message its agent was given (a person's, or a request the Task was handed).
   */
  replyTo?: number;
  /** The first message of its thread (its seq): the thread of what it answers, or its own. */
  root: number;
  /** The words of what it quotes, but for a whole message of the chat it answers. */
  quotes: string[];
  /** The card it answers by quoting it (its seq). */
  answers?: number;
  card?: StationCardShown;
  cardState?: StationCardState;
}

/** A quote of a message of the chat, as the station keeps one: its words cut where the station cuts them. */
export type StationQuote = {
  ts: string;
  author: string;
  text: string;
  role: "agent" | "person";
};

/** A message being sent from this device, or one that failed (`error`: why). */
export interface StationOutgoing {
  id: string;
  text: string;
  /** The message it answers (its seq). */
  replyTo?: number;
  state: "sending" | "failed";
  error?: string;
}

export interface StationChatAgent {
  session: string;
  /** At work now: it can be stopped. */
  running: boolean;
}

/**
 * Where a chat's Task runs when it is on another station (its station's `runsOn`): that station, the Session there, the
 * runtime and model it was started with, and whether it is at work: something was said there it has not answered.
 */
export interface StationChatRun {
  station: string;
  session: string | null;
  runtime: string | null;
  model: string | null;
  working: boolean;
}

/** The chat as the conversation view of its Task reads it (conversation.ts). */
export interface StationChatValue {
  title: string | null;
  link: { state: StationLinkState; message?: string };
  agents: StationChatAgent[];
  /** Absent while it runs on its own station. */
  runsOn?: StationChatRun;
  messages: StationChatMessage[];
  /** Older messages can be read (`older`). */
  more: boolean;
  /**
   * The chat's Activity: its agents' milestones, grouped as a Salix Task's are, from the messages it holds and the
   * history before them `readActivity` reads. Absent while it has no milestone and nothing is being read.
   */
  activity?: ChatTaskActivity;
  outbox: StationOutgoing[];
  loading: boolean;
  error?: string;
}

type Outgoing = StationOutgoing & {
  attachments: StationAttachment[];
  /** The message it answers, quoted. */
  quotes?: StationQuote[];
  /** What goes after its words for the agent alone, after the protocol marker no page shows (skills.ts). */
  forModel?: string;
  /** The write's key: the station answers it again as it answered the first. */
  key: string;
  /** The chat's last entry when it was added: a message of mine after it with its text is it. */
  after: number;
  /** Its entry, once the station took it. */
  seq?: number;
};

type Open = {
  workspace: string;
  station: string;
  thread: number;
  /** Views showing it. */
  shown: number;
  view: StationThread | null;
  entries: Map<number, StationEntry>;
  /** The lowest entry held (more before it when above 1). */
  first: number | null;
  loading: boolean;
  error: string | undefined;
  /** The chat's history before `first`, read for its Activity alone (`readActivity`), cut to what it reads. */
  earlier: Map<number, StationEntry>;
  /** The lowest entry read for the Activity; 1 once it reached the chat's first. */
  earliest: number | null;
  /** Reading the history for the Activity, or stopped short of the chat's first entry. */
  activityEarlier: ChatTaskActivity["earlier"];
  readingActivity: boolean;
};

/** A chat on a station, in its workspace. */
export type ChatAt = { workspace: string; station: string; thread: number };

const outboxDoc = (station: string, thread: number) =>
  `stations.outbox.${station}.${thread}`;
const keyOf = (station: string, thread: number) => `${station}\t${thread}`;
const sameEmail = (a: string, b: string) =>
  a.trim().toLowerCase() === b.trim().toLowerCase();
const params = {
  text(raw: unknown, name: string, max = 256): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
};

export class StationChats {
  readonly #ctx: Ctx;
  readonly #stations: Stations;
  readonly #activity: StationActivity;
  readonly #open = new Map<string, Open>();
  /** Outboxes by chat, loaded from this device as a chat first needs its own. */
  readonly #outboxes = new Map<string, Outgoing[]>();
  /** Messages sent from here that left the outbox, by chat: the id each was sent under, by its entry (`sentAs`). */
  readonly #sent = new Map<string, Map<number, string>>();
  /** Agents' posts as parsed, by the entry held. */
  readonly #parsed = new WeakMap<StationEntry, MarkdownTree>();
  /** Told when what a station's chats show changed. */
  readonly #listeners: ((station: string) => void)[] = [];
  #nextId = 1;

  constructor(ctx: Ctx, stations: Stations, activity: StationActivity) {
    this.#ctx = ctx;
    this.#stations = stations;
    this.#activity = activity;
    activity.onEvent((station, event, value) => this.#event(station, event, value));
    activity.onOpened((station) => {
      for (const open of this.#open.values())
        if (open.station === station) this.#fork(open, this.#refresh(open));
    });
    stations.onChange((workspace) => {
      for (const open of this.#open.values())
        if (open.workspace === workspace) this.#changed(open);
    });
    stations.onAccount(() => {
      this.#open.clear();
      this.#outboxes.clear();
      this.#sent.clear();
    });

    ctx.kernel.calls({
      "stations.upload": {
        doing: true,
        run: (p) => {
          const workspace = params.text(p, "workspace");
          const station = params.text(p, "station");
          const name = params.text(p, "name", 1_024);
          const encoded = params.text(p, "bytes", Math.ceil(UPLOAD_MAX_BYTES / 3) * 4);
          return Effect.suspend(() => {
            let bytes: Uint8Array;
            try {
              bytes = fromBase64(encoded);
            } catch {
              return Effect.fail(CoreError.invalid("bytes are not base64"));
            }
            if (bytes.length > UPLOAD_MAX_BYTES)
              return Effect.fail(CoreError.invalid("The file is larger than 8 MB."));
            return this.#stations.ask(
              workspace,
              station,
              "POST",
              `/uploads?name=${encodeURIComponent(name)}`,
              undefined,
              { raw: { bytes, type: "application/octet-stream" } }
            );
          }).pipe(
            Effect.flatMap((answer) => {
              const file = uploadedSchema.safeParse(answer);
              return file.success
                ? Effect.succeed(file.data)
                : Effect.fail(
                    new CoreError("bad_response", "The station kept no file.")
                  );
            })
          );
        },
      },
    });
  }

  // ── a chat as a conversation view shows it (stations/conversation.ts) ─────

  /** Shows the chat `at` names: it is read, and kept current while shown. */
  show(at: ChatAt): void {
    this.#show(at);
  }

  hide(at: ChatAt): void {
    this.#hide(at);
  }

  /** The chat `at` names, as its page shows it. */
  value(at: ChatAt): StationChatValue {
    return this.#value(at);
  }

  /**
   * File `index` of the message `seq` the chat holds, and the sessions whose uploads may keep it: an agent's post in
   * its own, anything else in the chat's first (where what is sent goes), then the chat's others. Null when the chat
   * holds no such file.
   */
  attachment(
    at: ChatAt,
    seq: number,
    index: number
  ): { name: string; path: string; sessions: string[] } | null {
    const open = this.#open.get(keyOf(at.station, at.thread));
    const entry = open?.entries.get(seq) ?? open?.earlier.get(seq);
    const file = entry?.attachments[index];
    if (!entry || !file) return null;
    const agents = (this.#activity.rowOf(at.station, at.thread)?.agents ?? []).map(
      (agent) => agent.key
    );
    const first = entry.authorKind === "agent" ? [entry.author] : [];
    return {
      name: file.name,
      path: file.path,
      sessions: [...new Set([...first, ...agents])],
    };
  }

  /** Told with the station whenever what its chats show changed. */
  onChange(listener: (station: string) => void): void {
    this.#listeners.push(listener);
  }

  /**
   * Puts `text` (with `attachments`) in the chat's outbox under `id` (the caller's, else the core's) and sends it; one
   * that answers a message (`replyTo`, its seq) quotes it, as the station's chats answer one, and `forModel` goes after
   * its words for the agent alone. Sent again under its id (the caller retried before it heard back), it is the message
   * in the outbox already.
   */
  send(
    at: ChatAt,
    text: string,
    attachments: StationAttachment[],
    options: { id?: string; replyTo?: number; forModel?: string } = {}
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const { id, replyTo, forModel } = options;
      if (
        id !== undefined &&
        this.#outbox(at.station, at.thread).some((o) => o.id === id)
      )
        return Effect.void;
      const quote = replyTo === undefined ? null : this.#quote(at, replyTo);
      return this.#add(at, text, attachments, undefined, {
        ...(id !== undefined ? { id } : {}),
        ...(quote ? { quotes: [quote], replyTo: replyTo! } : {}),
        ...(forModel ? { forModel } : {}),
      });
    });
  }

  /** Message `seq` as a quote answering it; null when the chat does not hold it or the station names it by nothing. */
  #quote(at: ChatAt, seq: number): StationQuote | null {
    const entry = this.#open.get(keyOf(at.station, at.thread))?.entries.get(seq);
    if (!entry?.ts || entry.kind !== "message") return null;
    const text = quoted(entry);
    if (text === "") return null;
    return {
      ts: entry.ts,
      author: entry.authorName ?? entry.author,
      text,
      role: entry.authorKind === "agent" ? "agent" : "person",
    };
  }

  /** Sends a failed message again, as the same message. */
  retry(at: ChatAt, id: string): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const entry = this.#outbox(at.station, at.thread).find((o) => o.id === id);
      if (!entry) return Effect.fail(CoreError.invalid("No such message."));
      this.#update(at, id, { state: "sending" });
      return this.#deliver(at, id);
    });
  }

  /** Drops a message from the outbox. */
  discard(at: ChatAt, id: string): void {
    this.#setOutbox(
      at,
      this.#outbox(at.station, at.thread).filter((o) => o.id !== id)
    );
  }

  /** Reads the page of messages before those shown; with `through`, every message back to that one. */
  older(at: ChatAt, through?: number): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const open = this.#open.get(keyOf(at.station, at.thread));
      if (!open || open.first === null || open.first <= 1) return Effect.void;
      if (through !== undefined) return this.#readBack(open, through);
      return this.#read(open, `?before=${open.first}&limit=${PAGE}`);
    });
  }

  /** Reads the chat's history before what it holds, for its Activity. */
  readActivity(at: ChatAt): void {
    const open = this.#open.get(keyOf(at.station, at.thread));
    if (open) this.#readActivity(open);
  }

  /** Reads the chat's summary and latest page again. */
  refresh(at: ChatAt): void {
    const open = this.#open.get(keyOf(at.station, at.thread));
    if (open) this.#fork(open, this.#refresh(open));
  }

  // ── showing a chat ───────────────────────────────────────────────────

  #show(at: ChatAt): void {
    this.#activity.hold(at.workspace, `chat:${at.station}:${at.thread}`);
    this.#openThread(at.workspace, at.station, at.thread);
  }

  #hide(at: ChatAt): void {
    this.#activity.unhold(at.workspace, `chat:${at.station}:${at.thread}`);
    const open = this.#open.get(keyOf(at.station, at.thread));
    if (!open) return;
    open.shown--;
    if (open.shown <= 0) this.#open.delete(keyOf(open.station, open.thread));
  }

  #openThread(workspace: string, station: string, thread: number): Open {
    const key = keyOf(station, thread);
    let open = this.#open.get(key);
    if (open) {
      open.shown++;
      return open;
    }
    open = {
      workspace,
      station,
      thread,
      shown: 1,
      view: null,
      entries: new Map(),
      first: null,
      loading: true,
      error: undefined,
      earlier: new Map(),
      earliest: null,
      activityEarlier: undefined,
      readingActivity: false,
    };
    this.#open.set(key, open);
    const opened = open;
    this.#fork(
      opened,
      this.#refresh(opened).pipe(
        // What was sending when this device last stopped goes again, as the same messages.
        Effect.andThen(
          Effect.forEach(
            this.#outbox(station, thread).filter(
              (o) => o.state === "sending" && o.seq === undefined
            ),
            (o) => Effect.ignore(this.#deliver(opened, o.id)),
            { discard: true }
          )
        )
      )
    );
    return open;
  }

  #fork(open: Open, work: Effect.Effect<unknown, CoreError>): void {
    this.#ctx.runner.fork(
      work.pipe(
        Effect.catch((e: CoreError) =>
          Effect.sync(() => {
            open.error = e.message;
            open.loading = false;
            this.#changed(open);
          })
        )
      )
    );
  }

  /** Reads the chat's summary, and its latest page (or what came since what is held). */
  #refresh(open: Open): Effect.Effect<void, CoreError> {
    return this.#stations
      .ask(open.workspace, open.station, "GET", route`/threads/${String(open.thread)}`)
      .pipe(
        Effect.flatMap((answer) => {
          const view = threadSchema.safeParse(answer);
          if (!view.success)
            return Effect.fail(
              new CoreError("bad_response", "The station's chat is unreadable.")
            );
          open.view = view.data;
          return this.#read(
            open,
            open.entries.size > 0 ? `?after=${this.#top(open)}` : ""
          );
        }),
        Effect.tap(() =>
          Effect.sync(() => {
            open.loading = false;
            open.error = undefined;
            this.#changed(open);
          })
        )
      );
  }

  /** Reads entries (`query`), and holds them. */
  #read(open: Open, query: string): Effect.Effect<void, CoreError> {
    return this.#stations
      .ask(
        open.workspace,
        open.station,
        "GET",
        `${route`/threads/${String(open.thread)}`}/entries${query}`
      )
      .pipe(
        Effect.flatMap((answer) => {
          const page = entriesSchema.safeParse(answer);
          if (!page.success)
            return Effect.fail(
              new CoreError("bad_response", "The station's messages are unreadable.")
            );
          this.#hold(open, page.data.entries);
          // The page before the first held: nothing older when it came short.
          if (query === "" || query.startsWith("?before"))
            open.first =
              page.data.entries.length === 0
                ? (open.first ?? page.data.last + 1)
                : Math.min(...page.data.entries.map((e) => e.n));
          if (open.view && page.data.last > open.view.last)
            open.view = { ...open.view, last: page.data.last };
          this.#changed(open);
          return Effect.void;
        })
      );
  }

  /** Reads the pages before the first held until the chat holds entry `through`. */
  #readBack(open: Open, through: number): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      while (open.first !== null && open.first > through) {
        const before = open.first;
        yield* this.#read(open, `?before=${before}&limit=${ACTIVITY_PAGE}`);
        // A page that reaches no further back would be read again forever.
        if (open.first >= before) return;
      }
    });
  }

  #hold(open: Open, entries: readonly StationEntry[]): void {
    for (const entry of entries) open.entries.set(entry.n, entry);
    this.#settle(open);
  }

  #top(open: Open): number {
    let top = 0;
    for (const n of open.entries.keys()) if (n > top) top = n;
    return top;
  }

  /** A followed station said something: a chat's new entries. */
  #event(station: string, event: string, value: unknown): void {
    if (event !== "thread") return;
    const said = threadEventSchema.safeParse(value);
    if (!said.success) return;
    const open = this.#open.get(keyOf(station, said.data.id));
    if (!open) return;
    const top = this.#top(open);
    const lowest = Math.min(...said.data.entries.map((e) => e.n));
    this.#hold(open, said.data.entries);
    if (open.view)
      open.view = { ...open.view, last: Math.max(open.view.last, this.#top(open)) };
    this.#changed(open);
    // Entries between what was held and these were missed: they are read.
    if (top > 0 && lowest > top + 1)
      this.#fork(open, this.#read(open, `?after=${top}`));
  }

  #changed(open: { station: string }): void {
    for (const listener of this.#listeners) listener(open.station);
  }

  // ── the value ────────────────────────────────────────────────────────

  #value({ station, thread }: ChatAt): StationChatValue {
    const link = this.#stations.linkOf(station);
    const open = this.#open.get(keyOf(station, thread));
    const row = this.#activity.rowOf(station, thread);
    const agents: StationChatAgent[] = (row?.agents ?? []).map((agent) => ({
      session: agent.key,
      running: agentState(agent).status === "running" || agent.process === "running",
    }));
    const outbox = this.#outbox(station, thread);
    const messages = open ? this.#messages(open, row, outbox) : [];
    const activity = open ? this.#activityOf(open) : undefined;
    // As its row says it (kept live with the station's rows), else as its summary did.
    const run = row?.runsOn ?? (row ? undefined : open?.view?.runsOn);
    const runsOn = run
      ? { ...run, working: open ? runWorking(open, run.station) : false }
      : undefined;
    const shownOutbox = outbox.map(({ id, text, replyTo, state, error }) => ({
      id,
      text,
      ...(replyTo !== undefined ? { replyTo } : {}),
      state,
      ...(error !== undefined ? { error } : {}),
    }));
    return {
      title:
        row?.title ??
        open?.view?.title ??
        open?.view?.autoTitle ??
        (open?.view?.firstText ? firstLine(open.view.firstText) || null : null),
      link,
      agents,
      ...(runsOn ? { runsOn } : {}),
      messages,
      more: open?.first !== null && open?.first !== undefined && open.first > 1,
      ...(activity ? { activity } : {}),
      outbox: shownOutbox,
      loading: open ? open.loading : true,
      ...(open?.error !== undefined ? { error: open.error } : {}),
    };
  }

  #messages(
    open: Open,
    row: StationChatRow | null,
    outbox: Outgoing[]
  ): StationChatMessage[] {
    const viewer: Viewer = this.#stations.viewer() ?? { email: "" };
    // Milestones alone are shown only in the Activity.
    const list = messagesOf(open.entries.values()).filter((e) => e.kind === "message");
    // The card its station says waits, once the station's chats are read.
    const pending = this.#activity.rowsRead(open.station)
      ? ((row?.card ?? row?.decision)?.seq ?? null)
      : undefined;
    const sending = outbox.some((o) => o.state !== "failed");
    const sent = this.#sent.get(keyOf(open.station, open.thread));
    // How its messages answer one another, as Salix threads a chat's: a message answers the one it quotes and joins
    // its thread; an agent's post answers the last message its agent was handed (its station says which: `answers`;
    // a station from before it says nothing, and the last message given here before the post stands in); any other
    // starts its own thread.
    const byTs = new Map(list.flatMap((e) => (e.ts ? [[e.ts, e] as const] : [])));
    const roots = new Map<number, number>();
    let given: number | undefined;
    return list.map((entry, i): StationChatMessage => {
      const kind =
        entry.authorKind === "person"
          ? "person"
          : entry.authorKind === "agent"
            ? "agent"
            : "system";
      const mine = kind === "person" && sameEmail(entry.author, viewer.email);
      const sentAs = mine ? sent?.get(entry.n) : undefined;
      // A quote of an earlier message of the chat answers it; its words show unless they are the whole message (or
      // the card it answers).
      const named = entry.quotes.map((q) => {
        const found = q.ts ? byTs.get(q.ts) : undefined;
        const target = found && found.n < entry.n ? found : undefined;
        const whole =
          target !== undefined &&
          (target.card !== undefined || (q.text ?? "") === quoted(target));
        return { q, target, whole };
      });
      const answered = named.find((quote) => quote.target)?.target;
      const replyTo =
        kind === "person"
          ? answered?.n
          : kind === "agent" && !entry.request
            ? (entry.answers ?? given)
            : undefined;
      const root = replyTo === undefined ? entry.n : (roots.get(replyTo) ?? replyTo);
      roots.set(entry.n, root);
      if (kind === "person" || entry.request) given = entry.n;
      const message: StationChatMessage = {
        seq: entry.n,
        thread: open.thread,
        kind,
        author: entry.authorName ?? entry.author,
        text: entry.text ?? "",
        ...(kind === "agent" ? { markdown: this.#markdown(entry) } : {}),
        ...(sentAs !== undefined ? { sentAs } : {}),
        attachments: entry.attachments,
        createdAt: entry.at,
        ...(replyTo !== undefined ? { replyTo } : {}),
        root,
        quotes: named.flatMap(({ q, whole }) =>
          whole || !q.text?.trim() ? [] : [q.text]
        ),
        ...(kind === "person" && answered?.card ? { answers: answered.n } : {}),
      };
      const card = entry.card;
      if (card && row) message.card = cardShown(card, row, viewer);
      else if (card)
        message.card = cardShown(card, { creator: null } as StationChatRow, viewer);
      if (card) {
        const later = list.slice(i + 1);
        const replaced = later.some((e) => e.card !== undefined);
        const answer = later.find((e) => e.authorKind === "person");
        const answeredHere = !answer && !replaced && sending;
        const waitingNow =
          pending === undefined
            ? !answer && !replaced && !answeredHere
            : pending === entry.n;
        const label = answer?.text?.trim() ?? "";
        const chose =
          answer &&
          entry.ts &&
          answer.quotes.some((q) => q.ts === entry.ts) &&
          card.options?.some((o) => o.label.trim() === label);
        message.cardState = {
          resolved: !waitingNow,
          ...(waitingNow
            ? {}
            : answer
              ? chose
                ? { outcome: { kind: "chose", label } as const }
                : { outcome: { kind: "replied" } as const }
              : answeredHere
                ? { outcome: { kind: "replied" } as const }
                : replaced
                  ? { outcome: { kind: "replaced" } as const }
                  : {}),
        };
      }
      return message;
    });
  }

  // ── the Activity ─────────────────────────────────────────────────────

  /** The lowest entry the Activity holds (the chat's or the history read for it); null before the chat is read. */
  #activityStart(open: Open): number | null {
    if (open.first === null) return null;
    return Math.min(open.first, open.earliest ?? open.first);
  }

  /**
   * The chat's Activity, from the history read for it and what the chat holds: its first message, a person's, is its
   * brief once the Activity holds the chat's start.
   */
  #activityOf(open: Open): ChatTaskActivity | undefined {
    const all = messagesOf([...open.earlier.values(), ...open.entries.values()]);
    const first = all.find((e) => e.kind === "message");
    const brief =
      this.#activityStart(open) === 1 && first?.authorKind === "person"
        ? first
        : undefined;
    return withEarlier(
      taskActivity(all.map((e) => activityMessage(e, e === brief, open.thread))),
      open.activityEarlier
    );
  }

  /**
   * Reads the chat's history before what it holds, for its Activity alone: pages of ACTIVITY_PAGE entries, newest
   * first, back to the chat's first entry, each cut to what the Activity reads. One read at a time; one that fails
   * keeps what was read, and the next call goes on from there.
   */
  #readActivity(open: Open): void {
    const start = this.#activityStart(open);
    if (open.readingActivity || start === null || start <= 1) return;
    open.readingActivity = true;
    open.activityEarlier = "reading";
    this.#changed(open);
    const read = Effect.gen({ self: this }, function* () {
      for (;;) {
        const before = this.#activityStart(open);
        if (before === null || before <= 1) return;
        const answer = yield* this.#stations.ask(
          open.workspace,
          open.station,
          "GET",
          `${route`/threads/${String(open.thread)}`}/entries?before=${before}&limit=${ACTIVITY_PAGE}`
        );
        const page = entriesSchema.safeParse(answer);
        if (!page.success) return;
        for (const entry of page.data.entries)
          open.earlier.set(entry.n, forActivity(entry));
        // A page that reaches no further back: there is nothing older.
        const lowest = Math.min(before, ...page.data.entries.map((e) => e.n));
        open.earliest = lowest < before ? lowest : 1;
        this.#changed(open);
      }
    });
    this.#ctx.runner.fork(
      read.pipe(
        Effect.ignore,
        Effect.ensuring(
          Effect.sync(() => {
            open.readingActivity = false;
            const left = this.#activityStart(open);
            // Stopped short of the first entry: the Activity says so, and the next call goes on.
            open.activityEarlier = left !== null && left > 1 ? "unread" : undefined;
            this.#changed(open);
          })
        )
      )
    );
  }

  // ── sending ──────────────────────────────────────────────────────────

  /** The chat to send to: the one given, or the session's (made now when it has none). */
  #outbox(station: string, thread: number): Outgoing[] {
    const key = keyOf(station, thread);
    let outbox = this.#outboxes.get(key);
    if (!outbox) {
      outbox =
        this.#ctx.session.current()?.doc<Outgoing[]>(outboxDoc(station, thread))
          ?.value ?? [];
      for (const o of outbox) {
        const n = Number(o.id.replace("out-", ""));
        if (Number.isSafeInteger(n) && n >= this.#nextId) this.#nextId = n + 1;
      }
      this.#outboxes.set(key, outbox);
    }
    return outbox;
  }

  #setOutbox(
    at: { workspace: string; station: string; thread: number },
    outbox: Outgoing[]
  ): void {
    this.#outboxes.set(keyOf(at.station, at.thread), outbox);
    const account = this.#ctx.session.current();
    if (account && !account.closed)
      if (outbox.length === 0) account.deleteDoc(outboxDoc(at.station, at.thread));
      else account.putDoc(outboxDoc(at.station, at.thread), outbox, this.#ctx.now());
    this.#changed(at);
  }

  #update(
    at: { workspace: string; station: string; thread: number },
    id: string,
    change: Partial<Outgoing>
  ): void {
    this.#setOutbox(
      at,
      this.#outbox(at.station, at.thread).map((o) => {
        if (o.id !== id) return o;
        const next = { ...o, ...change };
        if (change.state === "sending") delete next.error;
        return next;
      })
    );
  }

  /** What the station holds now leaves the outbox, the chat's entry for each keeping the id it was sent under. */
  #settle(open: Open): void {
    const key = keyOf(open.station, open.thread);
    const outbox = this.#outboxes.get(key);
    if (!outbox || outbox.length === 0) return;
    const viewer = this.#stations.viewer();
    const top = this.#top(open);
    let matched = 0;
    /** The chat's entry for an outbox message, once it holds it. */
    const held = (o: Outgoing): number | undefined => {
      if (o.seq !== undefined) return top < o.seq ? undefined : o.seq;
      for (const entry of open.entries.values()) {
        if (
          entry.kind === "message" &&
          entry.authorKind === "person" &&
          entry.n > Math.max(o.after, matched) &&
          viewer !== null &&
          sameEmail(entry.author, viewer.email) &&
          (entry.text ?? "").trim() === wireText(o)
        ) {
          matched = entry.n;
          return entry.n;
        }
      }
      return undefined;
    };
    const kept = outbox.filter((o) => {
      const n = held(o);
      if (n === undefined) return true;
      let sent = this.#sent.get(key);
      if (!sent) this.#sent.set(key, (sent = new Map()));
      sent.set(n, o.id);
      return false;
    });
    if (kept.length !== outbox.length) this.#setOutbox(open, kept);
  }

  /** An agent's post as the core parses a Salix message's (`messageMarkdown`), once per version of it held. */
  #markdown(entry: StationEntry): MarkdownTree {
    let tree = this.#parsed.get(entry);
    if (!tree) {
      tree = messageMarkdown([{ kind: "markdown", text: entry.text ?? "" }]);
      this.#parsed.set(entry, tree);
    }
    return tree;
  }

  /**
   * Puts `text` (with `attachments`) in the chat's outbox and sends it, once under `key`: a message the outbox has
   * under it already is not added again (the first message of a Task made again, tasks.ts).
   */
  post(
    at: { workspace: string; station: string; thread: number },
    text: string,
    key: string,
    attachments: StationAttachment[] = []
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() =>
      this.#outbox(at.station, at.thread).some((o) => o.key === key)
        ? Effect.void
        : this.#add(at, text, attachments, key)
    );
  }

  #add(
    at: { workspace: string; station: string; thread: number },
    text: string,
    attachments: StationAttachment[],
    key = this.#stations.onceKey(),
    extra: Pick<Outgoing, "quotes" | "replyTo" | "forModel"> & { id?: string } = {}
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const open = this.#open.get(keyOf(at.station, at.thread));
      const { id, ...rest } = extra;
      const entry: Outgoing = {
        id: id ?? `out-${this.#nextId++}`,
        text,
        attachments,
        ...rest,
        state: "sending",
        key,
        after: open ? this.#top(open) : 0,
      };
      this.#setOutbox(at, [...this.#outbox(at.station, at.thread), entry]);
      // A message the station did not take stays in the outbox, failed: the call itself succeeded.
      return Effect.ignore(this.#deliver(at, entry.id));
    });
  }

  /** Sends an outbox message, with its own key. */
  #deliver(
    at: { workspace: string; station: string; thread: number },
    id: string
  ): Effect.Effect<void, CoreError> {
    return Effect.suspend(() => {
      const entry = this.#outbox(at.station, at.thread).find((o) => o.id === id);
      if (!entry) return Effect.void;
      return this.#stations
        .ask(
          at.workspace,
          at.station,
          "POST",
          `${route`/threads/${String(at.thread)}`}/messages`,
          {
            text: wireText(entry),
            ...(entry.attachments.length > 0 ? { attachments: entry.attachments } : {}),
            ...(entry.quotes?.length ? { quotes: entry.quotes } : {}),
          },
          { onceKey: entry.key }
        )
        .pipe(
          Effect.flatMap((answer) => {
            const sent = sentSchema.safeParse(answer);
            if (!sent.success)
              return Effect.fail(
                new CoreError("bad_response", "The station took no message.")
              );
            this.#update(at, id, { seq: sent.data.n });
            const open = this.#open.get(keyOf(at.station, at.thread));
            if (open) {
              this.#settle(open);
              if (this.#top(open) < sent.data.n)
                return this.#read(open, `?after=${this.#top(open)}`);
            }
            return Effect.void;
          }),
          Effect.tapError((e) =>
            Effect.sync(() =>
              this.#update(at, id, { state: "failed", error: e.message })
            )
          )
        );
    });
  }
}

/** An outbox message's words as the station is sent them: what goes for the agent alone after the protocol marker. */
function wireText(o: Outgoing): string {
  return (
    o.forModel ? `${o.text}\n\n${COMMA_PROTOCOL_MARKER}\n${o.forModel}` : o.text
  ).trim();
}

/** A message as a quote of it holds it: its words (or its files' names), cut where the station cuts them. */
function quoted(entry: StationEntry): string {
  const words =
    stripCommaProtocolMarkers(entry.text ?? "") ||
    entry.attachments.map((file) => file.name).join(", ");
  return [...words].slice(0, QUOTE_MAX).join("");
}

/** The files a message carries, as `stations.upload` answered them. */
export function attachmentsOf(raw: unknown): StationAttachment[] {
  if (raw === undefined) return [];
  if (!Array.isArray(raw) || raw.length > 20)
    throw CoreError.invalid("attachments are invalid");
  return raw.map((a) => {
    const v = a as Record<string, unknown> | null;
    if (
      typeof v?.name !== "string" ||
      typeof v.path !== "string" ||
      typeof v.size !== "number"
    )
      throw CoreError.invalid("attachments are invalid");
    return { name: v.name, path: v.path, size: v.size };
  });
}

/** A chat's messages as they read now (each with its latest edit), and its posts of milestones alone, by n. */
/**
 * Whether the Session on `station` running a chat's Task is at work: the chat's last message is a person's (or a
 * request it was handed), or one of its own that did not end its turn.
 */
function runWorking(open: Open, station: string): boolean {
  const said = messagesOf(open.entries.values()).filter(
    (e) => e.kind === "message" && e.authorKind !== "ember"
  );
  const last = said.at(-1);
  if (!last) return false;
  if (last.authorKind !== "agent") return true;
  if (!last.author.startsWith(`${station}/`)) return last.request === true;
  return last.ending !== "all_done" && last.ending !== "need_help";
}

function messagesOf(entries: Iterable<StationEntry>): StationEntry[] {
  const byN = new Map<number, StationEntry>();
  // A message held twice (read for the Activity, then for the chat) is the chat's: it comes later.
  for (const entry of [...entries].toSorted((a, b) => a.n - b.n)) {
    if (entry.kind === "message" || entry.kind === "milestone") byN.set(entry.n, entry);
    else if (entry.kind === "edit" && entry.target !== null) {
      const target = byN.get(entry.target);
      if (target)
        byN.set(entry.target, {
          ...target,
          text: entry.text,
          attachments: entry.attachments,
          quotes: entry.quotes,
        });
    }
  }
  return [...byN.values()].toSorted((a, b) => a.n - b.n);
}

/** An entry as the Activity keeps it: a person's words up to ACTIVITY_TEXT characters, no one else's, and no files. */
function forActivity(entry: StationEntry): StationEntry {
  const { card: _card, ...rest } = entry;
  return {
    ...rest,
    text:
      entry.text === null
        ? null
        : entry.authorKind === "person"
          ? entry.text.slice(0, ACTIVITY_TEXT)
          : "",
    attachments: [],
    quotes: [],
  };
}

/** An entry as the Activity reads it, named as its conversation names the message (`thread:seq`). */
function activityMessage(
  entry: StationEntry,
  brief: boolean,
  thread: number
): TaskActivityMessage {
  const person = entry.authorKind === "person";
  const agent = entry.authorKind === "agent";
  return {
    messageId: `${thread}:${entry.n}`,
    seq: entry.n,
    createdAt: entry.at,
    actorId: entry.author,
    actorType: person ? "user" : agent ? "agent" : "system",
    role: person ? "user" : agent ? "assistant" : "system",
    source: "server",
    text: entry.text ?? "",
    ...(entry.milestones && entry.milestones.length > 0
      ? {
          milestones: {
            titles: entry.milestones,
            standalone: entry.kind === "milestone",
          },
        }
      : {}),
    ...(brief ? { brief: true } : {}),
    ...(entry.request ? { routerRequest: true as const } : {}),
  };
}
