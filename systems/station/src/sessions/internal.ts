// The station's own chat (the Rust station's chat/internal.rs): conversations on its pages. To the agent it is one more chat
// platform, like Slack: people's messages arrive with their source, and the agent answers with chat_post to their
// thread. Every chat lives in one channel, INTERNAL_CHANNEL; its thread_ts is its address. The messages themselves are
// the store's, like every thread's.
import type { Clock } from "effect";
import { liveClock } from "../ops/fibers.ts";
import type { Attachment } from "../store/store.ts";
import type { ChatSurface, ThreadRef } from "./chat.ts";

/// The connect id the station's own chat goes by. Not configurable; never in config.json.
export const INTERNAL_CONNECT = "ember";
export const INTERNAL_CHANNEL = "EMBER";
/// How the agent is named in these chats.
export const INTERNAL_BOT_USER = "UEMBER";

/// The last ts given, in microseconds: they only go up within this process (a clock, not a registry).
let lastMicros = 0;

/// Slack-style timestamps ("seconds.micros") at `nowMs` (its clock's now), strictly increasing within this process.
export function nextTsAt(nowMs: number): string {
  const next = Math.max(lastMicros + 1, nowMs * 1000);
  lastMicros = next;
  return `${Math.floor(next / 1_000_000)}.${String(next % 1_000_000).padStart(6, "0")}`;
}

export class InternalChat implements ChatSurface {
  /// Display names of page users (an email; "local" in chats written on the page this machine had, before it went).
  private names: (user: string) => string;
  private clock: Clock.Clock;

  constructor(names: (user: string) => string = (user) => (user === "local" ? "管理员" : user), clock: Clock.Clock = liveClock) {
    this.names = names;
    this.clock = clock;
  }

  botUserId(): string {
    return INTERNAL_BOT_USER;
  }

  workspace(): string | null {
    return null;
  }

  /// Nothing to send anywhere: the message is recorded under the ts this gives, and the page reads it from there.
  async post(thread: ThreadRef, _message: string, _files: Attachment[]): Promise<string> {
    if (thread.channel !== INTERNAL_CHANNEL) throw new Error(`no still.fail chat ${thread.channel}/${thread.threadTs}`);
    return nextTsAt(this.clock.currentTimeMillisUnsafe());
  }

  async userName(user: string): Promise<string | null> {
    return user !== INTERNAL_BOT_USER ? this.names(user) : null;
  }
}
