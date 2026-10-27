// When a session goes on in a new runtime session instead of taking up its own: its next turn runs on another account
// than the one its conversation last ran on. A prompt cache is an account's own, so taking the conversation up there
// would have the whole of it read again at full price; instead the agent reads back what it needs (session_history,
// chat_history). The runtime sessions a session ran in are kept in order (store `runtime_sessions`), and its history
// reads them as one (live.ts ChainTail).
import { afresh, threadAddress } from "../agents/instructions.ts";
import type { Profile } from "../agents/runtime.ts";
import type { Hub } from "./hub.ts";

/// What a session going on on `to` is told when it starts afresh rather than take up runtime session `id`, last run on
/// `was` (when the store has no record of it); null when it takes it up: on the account it ran on, or one not known.
/// A runtime session of another runtime than the session's now (it changed, configure) is never taken up. One that left
/// the runtime session it ran in (`id` null: its Task ran on another station meanwhile, tasks.ts moveHome) starts
/// afresh too; one that never ran starts as new.
export function startsAfresh(hub: Hub, key: string, id: string | null, to: Profile, was: string | null): string | null {
  const ran = hub.store.runtimeSessions(key);
  if (id === null) return ran.length > 0 ? told(hub, key) : null;
  const from = hub.store.ranOn(key, id) ?? was;
  const runtime = hub.store.getSession(key)?.runtime;
  const another = ran.some((r) => r.id === id && r.runtime !== runtime);
  if (!another && (from === null || from === to.id)) return null;
  return told(hub, key);
}

const told = (hub: Hub, key: string) => afresh(key, hub.store.sessionThreads(key).map((t) => threadAddress(t.thread.channel, t.thread.threadTs)));
