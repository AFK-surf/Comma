// Slack as a chat surface (chat/slack.rs): Socket Mode for what Slack tells the station (no public endpoint needed),
// the Web API for what the station and its agents say and ask. One SlackSurface per connected connect; its Socket Mode
// loop is a fiber in the surface's scope, and stopping the surface closes the scope (the socket with it).
import { readFile } from "node:fs/promises";
import { Clock, Deferred, Effect, Exit, FiberSet, Result, Scope } from "effect";
import WebSocket from "ws";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import type { Attachment } from "../store/store.ts";
import { type ChatEvent, type ChatMessage, type ChatSurface, type Handler, type InboundFile, type Person, type ThreadRef, splitForSlack } from "../sessions/chat.ts";
import type { NameBook } from "./names.ts";
import { ThreadStatus } from "./status.ts";
import { type Params, SlackClient, field } from "./web.ts";
import { wall } from "../ops/fibers.ts";

type Json = any;

/// Who a bot token belongs to, as Slack reports it.
export type SlackIdentity = {
  team: string;
  teamId: string;
  /// Workspace URL, e.g. https://acme.slack.com/
  url: string;
  botUserId: string;
  botName: string;
  /// Its bot's picture (the app's icon), as Slack shows it; null when Slack does not say.
  botImage: string | null;
  /// Its app's bot id (B…), which its own messages carry besides its user; not for the pages.
  botId: string;
};

/// An identity as the pages are given it (without its bot id).
export const shownIdentity = (i: SlackIdentity) => ({ team: i.team, teamId: i.teamId, url: i.url, botUserId: i.botUserId, botName: i.botName, botImage: i.botImage });

/// Whether the socket is up, and the last connection error.
export type SocketStatus = { connected: boolean; lastError: string | null };

const text = (v: unknown): string => (typeof v === "string" ? v : "");
/// A number as Rust's `str::parse::<f64>` reads one (a Slack ts); null where it does not.
const number = (s: string): number | null => (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s) ? Number(s) : null);
const firstString = (values: unknown[], ok: (s: string) => boolean): string | null => {
  for (const v of values) if (typeof v === "string" && ok(v)) return v;
  return null;
};

/// Who the bot is, and where: its name as people see it in that workspace (not its handle), when Slack says.
export async function identityOf(client: SlackClient, token: string): Promise<SlackIdentity> {
  const auth = await client.api("auth.test", [], token);
  const botUserId = text(auth.user_id);
  let user: Json = null;
  try {
    user = (await client.api("users.info", [["user", botUserId]], token)).user ?? null;
  } catch {}
  const profile = user?.profile ?? null;
  const shown = firstString([profile?.display_name, user?.real_name, profile?.real_name], (n) => n.trim() !== "");
  const image = firstString([profile?.image_72, profile?.image_48, profile?.image_original], (u) => u.startsWith("https://"));
  return {
    team: text(auth.team),
    teamId: text(auth.team_id),
    url: text(auth.url),
    botUserId,
    botName: shown ?? text(auth.user),
    botImage: image,
    botId: text(auth.bot_id),
  };
}

/// Checks a token pair without connecting: the bot token must authenticate, and the app-level token must be allowed to
/// open a Socket Mode connection. Its problems are said in `lang`.
export async function verifySlackTokens(client: SlackClient, appToken: string, botToken: string, lang: Lang = stationLang()): Promise<[SlackIdentity | null, string[]]> {
  const errors: string[] = [];
  let identity: SlackIdentity | null = null;
  if (!botToken.startsWith("xoxb-")) errors.push(tr(lang, "station.slackTokens.botPrefix"));
  else {
    try {
      identity = await identityOf(client, botToken);
    } catch (e) {
      errors.push(tr(lang, "station.slackTokens.botInvalid", { error: (e as Error).message }));
    }
  }
  if (!appToken.startsWith("xapp-")) errors.push(tr(lang, "station.slackTokens.appPrefix"));
  else {
    try {
      await client.api("apps.connections.open", [], appToken);
    } catch (e) {
      errors.push(tr(lang, "station.slackTokens.appNoSocket", { error: (e as Error).message }));
    }
  }
  return [identity, errors];
}

/// A rich_text element as Slack's own text writes it (links <url|label>, mentions <@U…>), so it reads like the rest.
function richText(el: Json): string {
  const kind = text(el?.type);
  if (Array.isArray(el?.elements)) {
    const inner = el.elements.map(richText);
    if (kind === "rich_text_list") return inner.map((s: string) => `• ${s}`).join("\n");
    return inner.join(kind === "rich_text" ? "\n" : "");
  }
  switch (kind) {
    case "text":
      return text(el.text);
    case "link":
      return el.text ? `<${text(el.url)}|${text(el.text)}>` : `<${text(el.url)}>`;
    case "user":
      return `<@${text(el.user_id)}>`;
    case "usergroup":
      return `<!subteam^${text(el.usergroup_id)}>`;
    case "channel":
      return `<#${text(el.channel_id)}>`;
    case "broadcast":
      return `<!${text(el.range)}>`;
    case "emoji":
      return `:${text(el.name)}:`;
    case "date":
      return text(el.fallback);
    default:
      return text(el?.text);
  }
}

/// A table cell's content on one line, its pipes kept from closing the cell (those inside <url|label> stay as Slack's).
function cellText(cell: Json): string {
  const kind = text(cell?.type);
  const raw = kind === "rich_text" ? richText(cell) : kind === "raw_number" ? String(cell?.number ?? cell?.text ?? "") : text(cell?.text);
  return raw.replace(/\s*\n\s*/g, " ").replace(/(<[^<>]*>)|\|/g, (m, slack) => slack ?? "\\|").trim();
}

/// A table block as a Markdown table, its first row the header (as Slack shows it).
function tableText(block: Json): string {
  const rows: string[][] = (Array.isArray(block?.rows) ? block.rows : []).map((row: Json) => (Array.isArray(row) ? row.map(cellText) : []));
  if (rows.length === 0) return "";
  const width = Math.max(...rows.map((r) => r.length));
  const line = (r: string[]) => `| ${Array.from({ length: width }, (_, i) => r[i] ?? "").join(" | ")} |`;
  return [line(rows[0]), line(Array(width).fill("---")), ...rows.slice(1).map(line)].join("\n");
}

/// What a message says: its text, and the tables in its blocks and attachments, which Slack leaves out of the text
/// (a table drawn in Slack's composer arrives as a table block in an attachment).
export function messageText(m: Json): string {
  const blocks = [...(Array.isArray(m?.blocks) ? m.blocks : []), ...(Array.isArray(m?.attachments) ? m.attachments : []).flatMap((a: Json) => (Array.isArray(a?.blocks) ? a.blocks : []))];
  const tables = blocks.filter((b: Json) => b?.type === "table").map(tableText).filter((t: string) => t !== "");
  return [text(m?.text), ...tables].filter((t) => t !== "").join("\n\n");
}

/// The files shared with a message. Ones Slack keeps back (over a free workspace's limit, deleted) or that live
/// elsewhere (external: Google Drive and the like) have no url.
export function messageFiles(m: Json): InboundFile[] {
  return (Array.isArray(m?.files) ? m.files : [])
    .filter((f: Json) => text(f?.id) !== "")
    .map((f: Json) => {
      const held = !["tombstone", "hidden_by_limit", "external"].includes(text(f?.mode));
      const url = text(f?.url_private_download) || text(f?.url_private);
      return { id: text(f.id), name: text(f?.name) || text(f?.title) || text(f.id), size: typeof f?.size === "number" ? f.size : 0, url: held && url !== "" ? url : null };
    });
}

/// A Slack event as the station takes it: someone's message (a person, or another app's bot: agents work together in
/// threads), an edit, or nothing it keeps (its own messages, deletes). `botId`: this app's bot id (B…).
export function toEvent(event: Json, botUserId: string, botId: string): ChatEvent | null {
  // A message this bot posted itself: the station records those as it posts them.
  const own = (e: Json) => {
    const is = (key: string, mine: string) => mine !== "" && e?.[key] === mine;
    return is("user", botUserId) || is("bot_id", botId);
  };
  const kind = text(event?.type);
  const subtype = typeof event?.subtype === "string" ? event.subtype : null;
  if (kind === "message" && subtype === "message_changed") {
    const changed = event.message ?? null;
    const ts = text(changed?.ts);
    if (ts === "" || own(changed)) return null;
    // A message outside any thread is the root of its own.
    const threadTs = typeof changed?.thread_ts === "string" ? changed.thread_ts : ts;
    return { type: "changed", channel: text(event.channel), threadTs, ts, text: messageText(changed) };
  }
  // The station has no retraction: a deleted message stays as it was said.
  if (kind === "message" && subtype === "message_deleted") return null;
  if (kind !== "app_mention" && kind !== "message") return null;
  // Message subtypes that are someone talking: a person, or another app's bot.
  if (![null, "file_share", "thread_broadcast", "bot_message"].includes(subtype) || own(event)) return null;
  // Its bot user when Slack gives one, else its bot id.
  const by = event.user !== undefined && event.user !== null ? event.user : event.bot_id;
  const user = text(by);
  if (user === "") return null;
  const body = messageText(event);
  const ts = text(event.ts);
  const files = messageFiles(event);
  return {
    type: "message",
    message: {
      channel: text(event.channel),
      threadTs: typeof event.thread_ts === "string" ? event.thread_ts : ts,
      ts,
      user,
      text: body,
      addressed: kind === "app_mention" || event.channel_type === "im" || body.includes(`<@${botUserId}>`),
      ...(files.length > 0 ? { files } : {}),
    },
  };
}

/// The name a users.info answer gives a person, and their email.
function personOf(answer: Json): Person {
  const u = answer?.user ?? null;
  const p = u?.profile ?? null;
  const name = firstString([p?.display_name, u?.real_name, u?.name], (n) => n !== "") ?? "";
  return { name, email: text(p?.email).toLowerCase() };
}

async function channelNameOf(client: SlackClient, channel: string, token: string): Promise<string | null> {
  let r: Json;
  try {
    r = await client.api("conversations.info", [["channel", channel]], token);
  } catch {
    return null;
  }
  const c = r?.channel ?? null;
  if (c?.is_im === true) return null;
  return typeof c?.name === "string" && c.name !== "" ? c.name : null;
}

export type SlackSurfaceOptions = {
  appToken: string;
  botToken: string;
  client?: SlackClient;
  /// Keeps names across restarts and lets the admin API ask without waiting (knownPerson, knownChannel).
  book?: NameBook | null;
  /// How often the socket is pinged, and how long it may say nothing before it is taken for dead.
  pingMs?: number;
  staleMs?: number;
  /// The first wait before connecting again after a failure (doubling up to a minute).
  backoffMs?: number;
  /// The clock its pings, its waits for a socket and between tries run on (a TestClock in tests).
  clock?: Clock.Clock;
  /// Told each time a socket said something (a pong too): what a test waits for before it moves that clock on.
  onHeard?: () => void;
};

const MAX_BACKOFF_MS = 60_000;

export class SlackSurface implements ChatSurface {
  readonly appToken: string;
  readonly botToken: string;
  readonly client: SlackClient;
  private book: NameBook | null;
  private me: SlackIdentity | null = null;
  private names = new Map<string, Person>();
  private channels = new Map<string, string | null>();
  private status: SocketStatus = { connected: false, lastError: null };
  private listeners = new Set<() => void>();
  /// Each thread an agent works for: its status line (status.ts).
  private lines = new Map<string, ThreadStatus>();
  private pingMs: number;
  private staleMs: number;
  private backoffMs: number;
  private clock: Clock.Clock | undefined;
  private onHeard: () => void;
  private stopped = false;
  private scope: Scope.Closeable;
  private run: (effect: Effect.Effect<void, never>) => Promise<void>;

  constructor(options: SlackSurfaceOptions) {
    if (!options.appToken.startsWith("xapp-")) throw new Error("slack.appToken must be an app-level token (xapp-…)");
    if (!options.botToken.startsWith("xoxb-")) throw new Error("slack.botToken must be a bot token (xoxb-…)");
    this.appToken = options.appToken;
    this.botToken = options.botToken;
    this.client = options.client ?? new SlackClient();
    this.book = options.book ?? null;
    // Like Slack's Python SDK (slack_sdk.socket_mode.builtin): a ping every 5 s, dead after 20 s of nothing (4 pings).
    this.pingMs = options.pingMs ?? 5_000;
    this.staleMs = options.staleMs ?? 20_000;
    this.backoffMs = options.backoffMs ?? 1_000;
    this.clock = options.clock;
    this.onHeard = options.onHeard ?? (() => {});
    this.scope = Effect.runSync(Scope.make());
    const runtime = Scope.provide(FiberSet.makeRuntimePromise<never, void, never>(), this.scope);
    this.run = Effect.runSync(options.clock ? runtime.pipe(Effect.provideService(Clock.Clock, options.clock)) : runtime);
  }

  identity(): SlackIdentity | null {
    return this.me;
  }

  socket(): SocketStatus {
    return { ...this.status };
  }

  /// Hears each change of the socket's status, and of the identity; gives the function that stops it.
  onChange(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private changed() {
    for (const listener of this.listeners) {
      try {
        listener();
      } catch {}
    }
  }

  private setStatus(connected: boolean, lastError: string | null) {
    if (this.status.connected === connected && this.status.lastError === lastError) return;
    this.status = { connected, lastError };
    this.changed();
  }

  /// Reads again who the bot is and where (its name changed in Slack, say); listeners hear of it.
  async refreshIdentity() {
    this.me = await identityOf(this.client, this.botToken);
    this.changed();
  }

  botUserId(): string {
    return this.me?.botUserId ?? "";
  }

  botName(): string {
    return this.me?.botName ?? "";
  }

  workspace(): string | null {
    const team = this.me?.teamId ?? "";
    return team === "" ? null : team;
  }

  async start(handler: Handler) {
    const identity = await identityOf(this.client, this.botToken);
    log.info("slack", "slack authenticated", { botUserId: identity.botUserId, team: identity.team });
    this.me = identity;
    void this.run(this.connectLoop(handler)).catch(() => {});
  }

  async stop() {
    if (this.stopped) return;
    this.stopped = true;
    await Effect.runPromise(Scope.close(this.scope, Exit.void));
  }

  /// Connects again whenever the socket closes (Slack rotates connections routinely) or fails (after a wait that
  /// doubles up to a minute), until the surface stops.
  private connectLoop(handler: Handler): Effect.Effect<void> {
    const self = this;
    return Effect.gen(function* () {
      let backoff = self.backoffMs;
      for (;;) {
        const ran = yield* Effect.result(
          Effect.gen(function* () {
            const open = yield* Effect.tryPromise({ try: () => self.client.api("apps.connections.open", [], self.appToken), catch: (e) => e as Error });
            if (typeof open?.url !== "string") return yield* Effect.fail(new Error("slack gave no socket url"));
            yield* self.runSocket(open.url, handler);
          }),
        );
        if (Result.isSuccess(ran)) backoff = self.backoffMs;
        else {
          const said = ran.failure.message;
          self.setStatus(false, said);
          log.warn("slack", "slack socket failed", { error: said, retryInMs: backoff });
          yield* Effect.sleep(backoff);
          backoff = Math.min(backoff * 2, MAX_BACKOFF_MS);
        }
      }
    });
  }

  /// One Socket Mode connection: ends when the socket closes, and fails when it went quiet: a connection cut off on the
  /// way (a network blip) can look open forever, and nothing would come through it again (2026-09-30 on bft). So it is
  /// pinged every `pingMs`, and taken for dead when it said nothing (not even a pong) for `staleMs`. Each event is
  /// acknowledged once its handler kept it; one that failed is not, and Slack sends it again.
  runSocket(url: string, handler: Handler): Effect.Effect<void, Error> {
    const self = this;
    const socket = Effect.gen(function* () {
      const clock = yield* Clock.Clock;
      const opened = yield* Deferred.make<void>();
      let ws: WebSocket | undefined;
      let heard = clock.currentTimeMillisUnsafe();
      // The socket itself: ends when it closes, fails on its error. Interrupted (it went quiet, or the surface stops),
      // it is cut off.
      const open = Effect.callback<void, Error>((resume) => {
        const socket = new WebSocket(url);
        ws = socket;
        let finished = false;
        const cut = () => {
          finished = true;
          socket.removeAllListeners();
          socket.on("error", () => {});
          if (socket.readyState !== WebSocket.CLOSED) socket.terminate();
        };
        const end = (error: Error | null) => {
          if (finished) return;
          cut();
          if (error !== null) resume(Effect.fail(error));
          else {
            self.setStatus(false, self.status.lastError);
            resume(Effect.void);
          }
        };
        const bot = self.botUserId();
        const botId = self.me?.botId ?? "";
        socket.on("open", () => {
          heard = clock.currentTimeMillisUnsafe();
          self.setStatus(true, null);
          Deferred.doneUnsafe(opened, Effect.void);
        });
        const alive = () => {
          heard = clock.currentTimeMillisUnsafe();
          self.onHeard();
        };
        socket.on("pong", alive);
        socket.on("ping", alive);
        socket.on("message", (data, binary) => {
          alive();
          if (binary) return;
          let envelope: Json;
          try {
            envelope = JSON.parse(data.toString());
          } catch {
            return;
          }
          if (envelope?.type === "disconnect") {
            log.info("slack", "slack asked to reconnect", { reason: JSON.stringify(envelope.reason ?? null) });
            try {
              socket.close();
            } catch {}
            return end(null);
          }
          if (envelope?.type !== "events_api") return;
          const event = toEvent(envelope.payload?.event ?? null, bot, botId);
          const envelopeId = envelope.envelope_id ?? null;
          void (async () => {
            try {
              if (event !== null) await handler(event);
            } catch (error) {
              // Not acknowledged: Slack redelivers, and the store dedupes.
              log.error("slack", "failed to accept slack event", { error: (error as Error).message });
              return;
            }
            if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ envelope_id: envelopeId }));
          })();
        });
        socket.on("close", () => end(null));
        socket.on("error", (error) => end(error));
        return Effect.sync(() => {
          if (!finished) cut();
        });
      });
      // Its watch: open within `staleMs`, then a ping every `pingMs`; it fails once the socket said nothing for `staleMs`.
      const watch = Deferred.await(opened).pipe(
        Effect.timeoutOrElse({
          duration: self.staleMs,
          orElse: () => Effect.fail(new Error(`slack socket did not open within ${self.staleMs / 1000}s`)),
        }),
        Effect.andThen(
          Effect.forever(
            Effect.sleep(self.pingMs).pipe(
              Effect.andThen(
                Effect.suspend(() => {
                  const quiet = clock.currentTimeMillisUnsafe() - heard;
                  if (quiet >= self.staleMs) return Effect.fail(new Error(`slack socket said nothing for ${quiet / 1000}s`));
                  try {
                    ws?.ping();
                  } catch {}
                  return Effect.void;
                }),
              ),
            ),
          ),
        ),
      );
      return yield* Effect.raceFirst(open, watch);
    });
    return this.clock ? socket.pipe(Effect.provideService(Clock.Clock, this.clock)) : socket;
  }

  /// Posted as written (the agent writes Slack's formatting); a long message goes out in parts, the first part's ts
  /// standing for the whole. Files are uploaded before anything is posted (an app without `files:write` fails there,
  /// with nothing said), then shared into the thread below the text.
  async post(thread: ThreadRef, message: string, files: Attachment[]): Promise<string> {
    const uploaded: [string, string][] = [];
    for (const file of files) uploaded.push(await this.upload(file));
    let first: string | null = null;
    for (const part of splitForSlack(message, 3500).filter((t) => t !== "")) {
      const posted = await this.client.api(
        "chat.postMessage",
        [
          ["channel", thread.channel],
          ["thread_ts", thread.threadTs],
          ["text", part],
          ["unfurl_links", "false"],
        ],
        this.botToken,
      );
      if (first === null && typeof posted?.ts === "string") first = posted.ts;
    }
    if (uploaded.length > 0) {
      const list = JSON.stringify(uploaded.map(([id, title]) => ({ id, title })));
      const shared = await this.client.api(
        "files.completeUploadExternal",
        [
          ["files", list],
          ["channel_id", thread.channel],
          ["thread_ts", thread.threadTs],
        ],
        this.botToken,
      );
      if (first === null) {
        first = await this.sharedTs(shared, uploaded[0]![0], thread.channel);
        if (first === null) {
          log.warn("slack", "slack: shared files without text, their message's ts did not show up");
          first = (wall.now() / 1000).toFixed(6);
        }
      }
    }
    if (first === null) throw new Error("nothing to post");
    return first;
  }

  /// Sends a file's bytes to Slack (not yet shared anywhere): its file id and title.
  private async upload(file: Attachment): Promise<[string, string]> {
    const bytes = await readFile(file.path);
    const url = await this.client.api(
      "files.getUploadURLExternal",
      [
        ["filename", file.name],
        ["length", String(bytes.length)],
      ],
      this.botToken,
    );
    if (typeof url?.upload_url !== "string" || typeof url?.file_id !== "string") throw new Error("slack files.getUploadURLExternal: no upload_url");
    await this.client.upload(url.upload_url, bytes, file.name);
    return [url.file_id, file.name];
  }

  /// The ts of the message files were shared in, which Slack fills in a moment after the share.
  private async sharedTs(completed: Json, file: string, channel: string): Promise<string | null> {
    const find = (f: Json): string | null => {
      for (const k of ["public", "private"]) {
        const ts = f?.shares?.[k]?.[channel]?.[0]?.ts;
        if (typeof ts === "string") return ts;
      }
      return null;
    };
    const now = find(completed?.files?.[0]);
    if (now !== null) return now;
    for (let i = 0; i < 10; i++) {
      await wall.sleep(500);
      let info: Json;
      try {
        info = await this.client.api("files.info", [["file", file]], this.botToken);
      } catch {
        return null;
      }
      const ts = find(info?.file);
      if (ts !== null) return ts;
    }
    return null;
  }

  private async profile(user: string): Promise<Person | null> {
    const known = this.names.get(user);
    if (known) return known;
    let answer: Json;
    try {
      answer = await this.client.api("users.info", [["user", user]], this.botToken);
    } catch {
      return null;
    }
    const person = personOf(answer);
    this.names.set(user, person);
    return person;
  }

  /// Display name via users.info, kept for the connection's lifetime.
  async userName(user: string): Promise<string | null> {
    const name = (await this.profile(user))?.name ?? "";
    return name === "" ? null : name;
  }

  /// The person's email (users:read.email), which ties a Slack user to a still.fail cloud account.
  async userEmail(user: string): Promise<string | null> {
    const email = (await this.profile(user))?.email ?? "";
    return email === "" ? null : email;
  }

  /// A person as far as already known, without waiting; an unknown one is looked up in the background.
  knownPerson(user: string): Person | null {
    if (!this.book) return null;
    const team = this.workspace() ?? "?";
    return this.book.person(`u:${team}:${user}`, async () => {
      try {
        return personOf(await this.client.api("users.info", [["user", user]], this.botToken));
      } catch {
        return null;
      }
    });
  }

  /// A channel's name as far as already known (null for DMs or not yet known), without waiting.
  knownChannel(channel: string): string | null {
    if (!this.book) return null;
    const team = this.workspace() ?? "?";
    return this.book.channel(`c:${team}:${channel}`, () => channelNameOf(this.client, channel, this.botToken));
  }

  /// Channel name via conversations.info (null for DMs), kept for the connection's lifetime.
  async channelName(channel: string): Promise<string | null> {
    if (this.channels.has(channel)) return this.channels.get(channel) ?? null;
    const name = await channelNameOf(this.client, channel, this.botToken);
    this.channels.set(channel, name);
    return name;
  }

  history(thread: ThreadRef, before: string, limit: number): Promise<ChatMessage[]> {
    const bot = this.botUserId();
    return (async () => {
      const all: ChatMessage[] = [];
      let cursor: string | null = null;
      for (;;) {
        const params: Params = [
          ["channel", thread.channel],
          ["ts", thread.threadTs],
          ["limit", "200"],
        ];
        if (cursor !== null) params.push(["cursor", cursor]);
        const page = await this.client.api("conversations.replies", params, this.botToken);
        for (const m of Array.isArray(page?.messages) ? page.messages : []) {
          const by = m?.user !== undefined && m?.user !== null ? m.user : m?.bot_id;
          const user = typeof by === "string" ? by : "unknown";
          const fromBot = (m?.bot_id !== undefined && m?.bot_id !== null) || user === bot;
          const files = messageFiles(m);
          all.push({ ts: text(m?.ts), user, text: messageText(m), fromBot, ...(files.length > 0 ? { files } : {}) });
        }
        const next = page?.response_metadata?.next_cursor;
        cursor = typeof next === "string" && next !== "" ? next : null;
        if (cursor === null) break;
      }
      const until = number(before) ?? Number.MAX_VALUE;
      const earlier = all.filter((m) => (number(m.ts) ?? 0) < until);
      return earlier.slice(Math.max(0, earlier.length - limit));
    })();
  }

  /// A shared file's bytes, read as the bot (files:read).
  async download(file: InboundFile): Promise<Uint8Array> {
    if (file.url === null) throw new Error("Slack does not give its contents");
    return this.client.download(file.url, file.name, this.botToken);
  }

  /// Any Web API method as the bot; values that are not strings (blocks, arrays) go as JSON, as Slack takes them.
  async api(method: string, params: Record<string, Json>): Promise<Json> {
    const form: Params = Object.entries(params)
      .filter(([, v]) => v !== null && v !== undefined)
      .map(([k, v]) => [k, field(v)]);
    return this.client.api(method, form, this.botToken);
  }

  working(thread: ThreadRef, messageTs: string | null, status: string) {
    if (this.stopped) return;
    const key = `${thread.channel}/${thread.threadTs}`;
    let line = this.lines.get(key);
    if (!line) {
      const call = async (method: string, params: Params) => void (await this.client.api(method, params, this.botToken));
      line = new ThreadStatus(call, this.run, thread.channel, thread.threadTs);
      this.lines.set(key, line);
    }
    if (status === "" && this.lines.size > 200) this.lines.delete(key);
    line.say(status, messageTs);
  }
}
