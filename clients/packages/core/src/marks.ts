// What the reader did, per account: the needs-review Tasks they have seen (`taskReviewSeen`), the Inbox notifications
// they deleted (`inboxDeleted`) and marked unread (`inboxUnread`), and the settled Tasks they acknowledged out of the
// chat task panel (`chatTaskDismissed`), and the coding Tasks whose pull request prompt they closed
// (`codingPullRequestPromptDismissed`, by Task, or by Task and the merged pull request it follows). A mark records the
// projection revision (`updatedAt`) at which it happened, or for ids marked "now" the core's time; a mark never moves
// back. All but the acknowledgements stay on this device. An
// acknowledgement records the Task run it covers (`run_started_at`; 0 for no known run, as for ids), and the server
// keeps it for every device (task-panel-dismissals.ts).
//
// Bounds: at most 300 seen, acknowledged and closed-prompt marks and 500 of each Inbox kind; past that the oldest
// revisions go first (a lost mark only shows a row, a dot or a prompt again).
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Effect } from "effect";
import type { MarkKind, MarksValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import { TaskPanelDismissals } from "./task-panel-dismissals.ts";

const LIMITS: Record<MarkKind, number> = {
  taskReviewSeen: 300,
  inboxDeleted: 500,
  inboxUnread: 500,
  chatTaskDismissed: 300,
  codingPullRequestPromptDismissed: 300,
};
const metaKey = (kind: MarkKind) =>
  kind === "chatTaskDismissed" ? "marks:chatTaskDismissed:runs" : `marks:${kind}`;
/** The acknowledgements kept before they recorded a run: each at the time the device's clock said. */
const DISMISSED_BEFORE_RUNS = "marks:chatTaskDismissed";
const isKind = (v: unknown): v is MarkKind => typeof v === "string" && v in LIMITS;
const EMPTY: Record<string, number> = {};

function kindOf(p: unknown): MarkKind {
  const kind = (p as { kind?: unknown } | null)?.kind;
  if (!isKind(kind))
    throw CoreError.invalid(`kind is one of ${Object.keys(LIMITS).join(", ")}`);
  return kind;
}

export class Marks {
  readonly #ctx: Ctx;
  readonly #dismissals: TaskPanelDismissals;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#dismissals = new TaskPanelDismissals(
      ctx,
      () => this.#read("chatTaskDismissed"),
      (next) => this.#write("chatTaskDismissed", next)
    );
    const { kernel } = ctx;
    kernel.source("marks", {
      start: (topic) => {
        if (topic.kind === "chatTaskDismissed") this.#dismissals.read();
      },
      stop: () => undefined,
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    ctx.session.onChange(() => this.#invalidate());
    kernel.calls({
      "marks.mark": {
        run: (p) =>
          Effect.sync(() => {
            const kind = kindOf(p);
            const { entries = [], ids = [] } = p as {
              entries?: unknown;
              ids?: unknown;
            };
            if (
              !Array.isArray(entries) ||
              entries.length > 1000 ||
              !Array.isArray(ids) ||
              ids.length > 1000
            )
              throw CoreError.invalid("entries are [id, revision] pairs, ids are ids");
            // An acknowledgement of no known run is at 0, never at a device's time: no clock hides a later run.
            const idsAt = kind === "chatTaskDismissed" ? 0 : ctx.now();
            const marked: [string, number][] = [
              ...entries.filter(
                (e): e is [string, number] =>
                  Array.isArray(e) &&
                  typeof e[0] === "string" &&
                  e[0] !== "" &&
                  typeof e[1] === "number" &&
                  Number.isFinite(e[1])
              ),
              ...ids
                .filter((id): id is string => typeof id === "string" && id !== "")
                .map((id): [string, number] => [id, idsAt]),
            ];
            this.#merge(kind, marked);
            if (kind === "chatTaskDismissed") this.#dismissals.dismissed(marked);
            return null;
          }),
      },
      "marks.unmark": {
        run: (p) =>
          Effect.sync(() => {
            const kind = kindOf(p);
            // An acknowledgement ends with its Task's next run, on every device; none is lifted by a call.
            if (kind === "chatTaskDismissed")
              throw CoreError.invalid(
                "an acknowledgement ends with its Task's next run"
              );
            const ids = (p as { ids?: unknown }).ids;
            if (!Array.isArray(ids)) throw CoreError.invalid("ids are required");
            const current = this.#read(kind);
            if (!ids.some((id) => typeof id === "string" && id in current)) return null;
            const next = { ...current };
            for (const id of ids) if (typeof id === "string") delete next[id];
            this.#write(kind, next);
            return null;
          }),
      },
      "marks.refresh": {
        run: (p) =>
          Effect.sync(() => {
            if (kindOf(p) === "chatTaskDismissed") this.#dismissals.refresh();
            return null;
          }),
      },
    });
  }

  #read(kind: MarkKind): Record<string, number> {
    const account = this.#ctx.session.current();
    if (!account) return EMPTY;
    const kept = account.meta<Record<string, number>>(metaKey(kind));
    if (kept || kind !== "chatTaskDismissed") return kept ?? EMPTY;
    // Until the first write, the acknowledgements kept before they recorded a run stand at no known run (0): the
    // Task's next run shows it again whatever the device's clock said. The handover sends them so.
    const before = account.meta<Record<string, number>>(DISMISSED_BEFORE_RUNS);
    return before
      ? Object.fromEntries(Object.keys(before).map((id) => [id, 0]))
      : EMPTY;
  }

  #value(topic: Topic): MarksValue {
    return { marks: isKind(topic.kind) ? this.#read(topic.kind) : EMPTY };
  }

  #merge(kind: MarkKind, entries: [string, number][]): void {
    const current = this.#read(kind);
    let next: Record<string, number> | undefined;
    for (const [id, revision] of entries) {
      const existing = (next ?? current)[id];
      if (existing !== undefined && existing >= revision) continue;
      next ??= { ...current };
      next[id] = revision;
    }
    if (!next) return;
    const ids = Object.keys(next);
    if (ids.length > LIMITS[kind]) {
      const sorted = ids.toSorted((a, b) => next![a]! - next![b]!);
      for (const id of sorted.slice(0, ids.length - LIMITS[kind])) delete next[id];
    }
    this.#write(kind, next);
  }

  #write(kind: MarkKind, next: Record<string, number>): void {
    const account = this.#ctx.session.current();
    if (!account) return;
    account.setMeta(metaKey(kind), next);
    this.#invalidate(kind);
  }

  #invalidate(kind?: MarkKind): void {
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "marks" && (kind === undefined || topic.kind === kind))
        store.invalidate(topic);
  }
}
