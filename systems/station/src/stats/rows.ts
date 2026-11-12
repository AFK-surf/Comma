// The station's statistics in one structure, whatever they come from (docs: the station's Stats index): what the
// agents spent, by day, chat, person, account and model, and the chats they worked in. Each source gives these rows:
// the station itself (`self`, stats/self.ts). The station keeps them in its Stats index and Salix a copy.

/// What was spent in one day (in the source's time zone, UTC here) for one chat, person, account, runtime and model.
export type UsageRow = {
  day: string;
  session: string;
  thread: number | null;
  person: string | null;
  account: string | null;
  runtime: string;
  model: string | null;
  calls: number;
  input: number;
  cacheRead: number;
  cacheWrite: number;
  output: number;
  /// At list prices, dollars; null for a model without one.
  cost: number | null;
  /// Of an outside source with stations of its own (Comma's workspace): the one it was spent on, when not the
  /// one on this machine.
  station?: string;
};

/// A chat: where it is, its title, how it stands, who started it and when, its latest activity, and its agents.
export type TaskRow = {
  thread: number;
  surface: string;
  title: string;
  /// `working`, `all_done`, `need_human`, `waiting`, `ended`; null before a turn.
  state: string | null;
  creator: string | null;
  createdAt: number;
  lastActiveAt: number;
  archived: boolean;
  agents: { runtime: string; model: string | null }[];
  /// As a usage row's: the outside source's station the chat is on, when not the one on this machine.
  station?: string;
};

/// How an outside source stands on this machine: being asked, granted (with what), refused, revoked, or failed to be
/// asked or read (`message` says why); `at` when that became so.
export type SourceStatus = { state: "asking" | "granted" | "refused" | "revoked" | "failed"; at: number; scopes?: string[]; message?: string };

/// What a source gives for a span of days: its usage rows of those days, the chats with something in them, and (an
/// outside source) how it stands. A part not given (`usage`, `tasks`) keeps what it gave before; so do the usage rows
/// of its stations not read this time (`unread`: one that could not be reached; "" the one on this machine).
export type SourceRows = { usage?: UsageRow[]; tasks?: TaskRow[]; status?: SourceStatus; unread?: string[] };

/// A source of rows: its id in the Stats index (`self`), and its rows from `from` (ms) on.
export type StatsSource = { id: string; rows(from: number): Promise<SourceRows | null> };

/// How a chat stands, said as today's states from how its agents' latest turn ended.
export function stateOf(turn: { outcome?: unknown; declared?: unknown; ending?: unknown } | null): string | null {
  if (turn === null) return null;
  if (turn.outcome === null || turn.outcome === undefined) return "working";
  const said = typeof turn.ending === "string" ? turn.ending : typeof turn.declared === "string" ? turn.declared : null;
  if (said === null) return "ended";
  if (said === "final" || said === "all_done") return "all_done";
  if (said === "block" || said === "need_decision" || said === "need_help" || said === "need_human") return "need_human";
  return said;
}
