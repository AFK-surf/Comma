// What the readers answer, by name: each module of reads adds its own. Every op runs in a reader thread over a
// read-only store, with the request's language set (`setSpoken`), and returns a JSON value.
import type { Store } from "./store.ts";
import { chats, entries } from "./views.ts";
import { usageOps } from "./ops-usage.ts";
import { sessionOps } from "./ops-sessions.ts";
import { saidNotices, turnNotices } from "./notices.ts";

export type ReadOp = (store: Store, args: any) => unknown;

export const ops: Record<string, ReadOp> = {
  chats: (store, a) => chats(store, a.viewer, a.archived),
  entries: (store, a) => entries(store, a.viewer, a.thread, a.params),
  ...usageOps,
  ...sessionOps,
  turnNotices: (store, a) => turnNotices(store, a.key, a.since, a.ended, a.lang),
  saidNotices: (store, a) => saidNotices(store, a.thread, a.entries, a.since, a.lang),
};
