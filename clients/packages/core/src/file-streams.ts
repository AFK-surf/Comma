// Files a window's media element (audio, video, image) reads in ranges (`fileStream`), so a file of any size plays or
// shows without being held whole.
// A message's attachment plays from its media URL (`POST …/attachments/:index/media`): a URL the blob store signed, so
// its bytes never pass through the Comma server. It expires on its own, so it is minted again before it does. On the desktop app the host opens a URL for the file (Main's
// `comma-file://stream/<token>`) and forgets it once no window shows the topic: for an attachment Main reads the media
// URL with no credential; for any other file whose bytes are a GET it adds the session's credential to each range the
// element asks for. An attachment of a Task a station hosts (`hosted`), which only the core reaches, Main asks the core
// for a range at a time (`core`: `files.readRange`, its station's part). Elsewhere (the web) the window reads the media
// URL itself; any other file there, a station's among them, says `unsupported`, and the UI reads it (`files.read`, or
// a part at a time).
//
// Bounds: one URL per file and type, however many surfaces show it; it opens when a window first shows the topic and
// closes once none has for the store's eviction delay; a failed open is not retried (the next showing opens again); a
// media URL is minted again a minute before it expires, while shown; signing out, or in as another account, or a new
// lease of the same account (Main renewed the session: it refuses reads under the old one) closes every URL and opens
// what is still shown again.
import type { Topic, Value } from "@comma/core-kernel";
import { Effect, type Fiber } from "effect";
import type { FileStreamValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import { fileRequest, fileSourceSchema, mintMediaUrl } from "./files.ts";
import type { DesktopPorts } from "./host.ts";

const TOPIC = "fileStream";
const MEDIA_TYPE = /^(?:audio|video|image)\/[a-z0-9][a-z0-9.+-]*$/;
/** A media URL is minted again this long before it expires. */
const REMINT_BEFORE_MS = 60_000;
type Open =
  | {
      status: "opening" | "ready";
      url: string | null;
      fiber?: Fiber.Fiber<unknown, unknown>;
    }
  | { status: "failed" | "unsupported" };

export class FileStreams {
  /** Tasks Comma's server does not keep: their attachments are read whole. */
  hosted: { owns(conversation: string): boolean } | undefined;
  readonly #ctx: Ctx;
  readonly #ports: Pick<DesktopPorts, "openStream" | "closeStream"> | undefined;
  /** By topic: the stream each shown file has. */
  readonly #open = new Map<string, Open>();
  #accountKey: string | null | undefined = undefined;
  /** The lease the shown URLs were opened under; kept while none is given (a session change under way). */
  #leaseKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#ports = ctx.host.desktop;
    ctx.kernel.source(TOPIC, {
      start: (topic) => this.#start(topic),
      stop: (topic) => this.#stop(topic),
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      const lease = ctx.session.lease();
      const leaseKey = lease
        ? JSON.stringify([
            lease.audience,
            lease.authorityInstanceId,
            lease.sessionId,
            lease.generation,
          ])
        : this.#leaseKey;
      if (key === this.#accountKey && leaseKey === this.#leaseKey) return;
      // The same account under a new lease keeps showing each URL until its new one is open.
      const sameAccount = key === this.#accountKey && key !== null;
      this.#accountKey = key;
      this.#leaseKey = leaseKey;
      const shown = ctx.kernel.store
        .liveTopics()
        .filter((topic) => topic.topic === TOPIC);
      for (const topic of shown) {
        const kept = sameAccount ? this.#detach(topic) : null;
        if (!kept) this.#stop(topic);
        this.#start(topic, kept);
      }
    });
  }

  #value(topic: Topic): FileStreamValue {
    const open = this.#open.get(topicKey(topic));
    if (open?.status === "ready") return { status: "ready", url: open.url };
    return { status: open?.status ?? "opening", url: null };
  }

  /** The URL `topic` shows now, its opening stopped but the URL left open; null when it shows none. */
  #detach(topic: Topic): string | null {
    const open = this.#open.get(topicKey(topic));
    if (!open || !("url" in open) || open.status !== "ready" || !open.url) return null;
    if (open.fiber) this.#ctx.runner.interrupt(open.fiber);
    return open.url;
  }

  #hostedFile(topic: Topic): boolean {
    const conversation = hostedConversation(topic);
    return conversation !== null && this.hosted?.owns(conversation) === true;
  }

  /** Opens a URL for `topic`; `shown`, a URL it shows already, stays shown until the new one replaces it. */
  #start(topic: Topic, shown: string | null = null): void {
    const ports = this.#ports;
    const key = topicKey(topic);
    const request = streamRequest(topic);
    if (!this.#ctx.session.current() || !request) {
      this.#release(shown);
      this.#set(key, topic, { status: "failed" });
      return;
    }
    // A file of a Task a station hosts streams where Main asks the core for it (the desktop); elsewhere it is read whole.
    const hosted = this.#hostedFile(topic);
    if ((!ports && !request.attachment) || (hosted && !ports)) {
      this.#release(shown);
      this.#set(key, topic, { status: "unsupported" });
      return;
    }
    const open: Extract<Open, { url: string | null }> = shown
      ? { status: "ready", url: shown }
      : { status: "opening", url: null };
    this.#set(key, topic, open);
    const current = () => this.#open.get(key) === open;
    const ready = (url: string) =>
      Effect.sync(() => {
        const replaced = open.url;
        open.status = "ready";
        open.url = url;
        this.#ctx.kernel.store.invalidate(topic);
        if (replaced !== url) this.#release(replaced);
      });
    open.fiber = this.#ctx.runner.fork(
      Effect.gen({ self: this }, function* () {
        if (hosted && ports) {
          const url = yield* ports.openStream({
            core: String(topic.source),
            type: request.type,
          });
          if (current()) yield* ready(url);
          else yield* Effect.ignore(ports.closeStream(url));
          return;
        }
        // It opens for the session as it is now: `account()` brings the account's lease up to date.
        const account = yield* this.#ctx.session.account();
        if (ports && !request.attachment) {
          const url = yield* ports.openStream({
            path: request.path,
            type: request.type,
            lease: account.lease,
          });
          // Let go while Main opened it: nothing shows it.
          if (current()) yield* ready(url);
          else yield* Effect.ignore(ports.closeStream(url));
          return;
        }
        for (;;) {
          const media = yield* mintMediaUrl(this.#ctx, account, request.path);
          if (!current()) return;
          const url = ports
            ? yield* ports.openStream({ url: media.url, type: request.type })
            : media.url;
          if (!current()) {
            if (ports) yield* Effect.ignore(ports.closeStream(url));
            return;
          }
          yield* ready(url);
          yield* Effect.sleep(
            Math.max(media.expiresAtMs - this.#ctx.now() - REMINT_BEFORE_MS, 0)
          );
        }
      }).pipe(Effect.catch(() => this.#failed(key, topic, current)))
    );
  }

  #failed(key: string, topic: Topic, current: () => boolean) {
    return Effect.sync(() => {
      if (!current()) return;
      const open = this.#open.get(key);
      if (open && "url" in open) this.#release(open.url);
      this.#set(key, topic, { status: "failed" });
    });
  }

  /** Main forgets a URL it opened; a media URL expires on its own. */
  #release(url: string | null): void {
    if (url && this.#ports)
      this.#ctx.runner.fork(Effect.ignore(this.#ports.closeStream(url)));
  }

  #stop(topic: Topic): void {
    const key = topicKey(topic);
    const open = this.#open.get(key);
    this.#open.delete(key);
    if (!open || !("url" in open)) return;
    if (open.fiber) this.#ctx.runner.interrupt(open.fiber);
    if (open.status === "ready") this.#release(open.url);
  }

  #set(key: string, topic: Topic, open: Open): void {
    this.#open.set(key, open);
    this.#ctx.kernel.store.invalidate(topic);
  }
}

function topicKey(topic: Topic): string {
  return JSON.stringify([String(topic.source), String(topic.type)]);
}

/** The GET that reads the file the topic names, the type it plays as, and whether it is an attachment; null otherwise. */
/** Whether `topic` shows an attachment of a Task `hosted` keeps. */
function hostedConversation(topic: Topic): string | null {
  try {
    const parsed = fileSourceSchema.safeParse(JSON.parse(String(topic.source)));
    return parsed.success && parsed.data.source === "attachment"
      ? parsed.data.conversation
      : null;
  } catch {
    return null;
  }
}

function streamRequest(
  topic: Topic
): { path: string; type: string; attachment: boolean } | null {
  const type = String(topic.type);
  if (!MEDIA_TYPE.test(type)) return null;
  try {
    const parsed = fileSourceSchema.safeParse(JSON.parse(String(topic.source)));
    if (!parsed.success) return null;
    const request = fileRequest(parsed.data);
    return request.method === "GET"
      ? { path: request.path, type, attachment: parsed.data.source === "attachment" }
      : null;
  } catch {
    return null;
  }
}
