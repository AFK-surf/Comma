// A chat named by its agent (the Rust station's hub/titles.rs, chat_post's title): the first name at once, a new one only when
// the talk has moved on (people said enough since, and it was not changed too often), never over a name people gave
// it, and not while someone has the chat open: then it waits until they leave. Redesigned on one point: a name that
// waits looks again when the chat would no longer count as open (its last read plus OPEN_MS), not every minute.
import { Effect } from "effect";
import { log } from "../ops/log.ts";
import type { ThreadRow } from "../store/store.ts";
import type { Hub } from "./hub.ts";

/// How long a title may run.
const LONGEST = 30;
/// Messages people write after a title before it may change.
const SAID_BEFORE_CHANGE = 5;
/// Changes after the first title.
const CHANGES = 2;
/// A chat read this lately is taken as open.
const OPEN_MS = 3 * 60 * 1000;

/// A title as a chat shows it: one line, spaces collapsed, no closing full stop, at most LONGEST characters.
export function cleanTitle(title: string): string {
  const line = title.split(/\s+/u).filter((w) => w !== "").join(" ");
  const trimmed = line.replace(/[.。]+$/u, "").trimEnd();
  return Array.from(trimmed).slice(0, LONGEST).join("").trimEnd();
}

/// Names `thread` `title` as its agent asked; what came of it, for the agent.
export function nameChat(hub: Hub, thread: ThreadRow, given: string): string {
  const title = cleanTitle(given);
  if (title === "") return "";
  const may = mayName(hub, thread.id, title);
  if (typeof may === "string") return ` Title not changed: ${may}.`;
  if (!may) return "";
  if (isOpen(hub, thread.id) && hub.store.autoTitle(thread.id).title !== null) {
    waitToName(hub, thread.id, title);
    return ` The chat will be titled "${title}" once nobody has it open.`;
  }
  applyTitle(hub, thread.id, title);
  return ` Titled the chat "${title}".`;
}

/// Whether `title` may name the chat now (false: it already does), or why not.
function mayName(hub: Hub, thread: number, title: string): boolean | string {
  const row = hub.store.getThread(thread);
  if (!row) return "the chat is gone";
  if (row.title !== null && row.title.trim() !== "") return "people named this chat";
  const given = hub.store.autoTitle(thread);
  if (given.title === null) return true;
  if (given.title === title) return false;
  if (given.changes >= CHANGES) return "it has been changed as often as it may be";
  // A watch started since: the name may say so at once (job_start's watch), not only once the talk moved on.
  if (hub.store.peopleSaidAfter(thread, given.n) < SAID_BEFORE_CHANGE && !watchingIn(hub, thread)) {
    return "people have said too little since it was given; change it only when it no longer says what the chat is about";
  }
  return true;
}

/// Whether one of the chat's agents keeps watch (a watch job of its runs).
const watchingIn = (hub: Hub, thread: number) => hub.store.threadSessions(thread).some((m) => hub.store.listJobs(m.session).some((j) => j.watch && j.state === "running"));

const isOpen = (hub: Hub, thread: number) => {
  const at = hub.store.lastReadAt(thread);
  return at !== null && hub.now() - at < OPEN_MS;
};

function applyTitle(hub: Hub, thread: number, title: string) {
  const changed = hub.store.autoTitle(thread).title !== null;
  hub.store.setAutoTitle(thread, title, changed);
}

/// Keeps `title` for when nobody has the chat open (the latest one given wins), and looks again when it would be left.
function waitToName(hub: Hub, thread: number, title: string) {
  const waiting = hub.titles.has(thread);
  hub.titles.set(thread, title);
  if (waiting) return;
  const look: Effect.Effect<void> = Effect.suspend(() => {
    const at = hub.store.lastReadAt(thread);
    const left = at === null ? 0 : at + OPEN_MS - hub.now();
    return Effect.sleep(Math.max(1, left)).pipe(
      Effect.andThen(
        Effect.suspend(() => {
          if (isOpen(hub, thread)) return look;
          const title = hub.titles.get(thread);
          hub.titles.delete(thread);
          if (title === undefined) return Effect.void;
          // Looked at again: people may have named the chat meanwhile.
          try {
            if (mayName(hub, thread, title) === true) applyTitle(hub, thread, title);
          } catch (error) {
            log.warn("hub", `titling chat ${thread}: ${(error as Error).message}`);
          }
          return Effect.void;
        }),
      ),
    );
  });
  hub.fork(look);
}
