// The Slack channels and people a message can name (the composer's @ menu): those a workspace's Slack grant of this
// person can see. Read when the menu first shows them, one page of each list at a time at Slack's pace, and shown as
// they come; a complete answer is kept in memory for this account for five minutes, and a later read shows it until
// the new one is complete, so typing in the menu and opening it again ask Slack nothing. A composer keeps the topic
// shown, so the menu asks for a new read (`slackDirectory.reread`) as it is used; that reads only once what is kept ran
// out. A failed read keeps what was shown and its place for 30 seconds, then goes on from there; after three failures
// in a row it starts over, since Slack's cursors expire.
//
// Bounds: one read in flight per workspace, two requests per 7 s (`conversations.list` and `users.list` allow about 20
// a minute); at most 16 workspaces kept (the least recently shown go first, never one shown now).
import { share, type Topic, type Value } from "@comma/core-kernel";
import { Duration, Effect, Option, Result } from "effect";
import type { z } from "zod";
import { route } from "./api.ts";
import {
  commaSlackChannelPageSchema,
  commaSlackPersonPageSchema,
} from "./comma/api-schemas.ts";
import type { SlackChannel, SlackDirectory, SlackPerson } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

export const SLACK_DIRECTORY_KEEP_MS = 5 * 60_000;
export const SLACK_DIRECTORY_PACE_MS = 7_000;
const FAILED_KEEP_MS = 30_000;
const MAX_FAILURES = 3;
const MAX_KEPT = 16;

/** How far a read got: each list's rows so far and its next page; a null cursor is a list read to its end. */
type Progress = {
  channels: SlackChannel[];
  people: SlackPerson[];
  channelsCursor: string | null;
  peopleCursor: string | null;
  failures: number;
};

type Kept = {
  expiresAt: number;
  directory: SlackDirectory;
  /** `directory` is a complete answer: a read under way does not replace it until it is complete too. */
  complete: boolean;
  /** The read to go on with; null: nothing is left to read. */
  progress: Progress | null;
};

const start = (): Progress => ({
  channels: [],
  people: [],
  channelsCursor: "",
  peopleCursor: "",
  failures: 0,
});

const byName = (a: string, b: string) => {
  const [x, y] = [a.toLowerCase(), b.toLowerCase()];
  return x < y ? -1 : x > y ? 1 : 0;
};

/** Channels the person joined first, then by name; people by name. */
const directoryOf = ({ channels, people }: Progress): SlackDirectory => ({
  channels: channels.toSorted(
    (a, b) => Number(b.member) - Number(a.member) || byName(a.name, b.name)
  ),
  people: people.toSorted((a, b) => byName(a.name, b.name)),
});

const workspaceOf = (topic: Topic) => String(topic.workspace);

export class SlackDirectories {
  readonly #ctx: Ctx;
  readonly #live: Live;
  /** In the order last shown: the first is the next to go. */
  readonly #kept = new Map<string, Kept>();
  /** The read in flight of each workspace. */
  readonly #reading = new Map<string, object>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("slackDirectory", {
      start: (topic) => {
        const workspace = workspaceOf(topic);
        const kept = this.#kept.get(workspace);
        if (kept) {
          // Shown again: it goes to the back of the line.
          this.#kept.delete(workspace);
          this.#kept.set(workspace, kept);
        }
        this.#readIfOut(topic);
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#evict();
      },
      compute: (topic): Value => ({
        ok: this.#kept.get(workspaceOf(topic))?.directory ?? null,
      }),
      // A later showing checks what is kept again.
      evictAfterMs: 0,
    });
    kernel.calls({
      "slackDirectory.reread": {
        run: ({ workspace }: { workspace: string }) =>
          Effect.sync(() => {
            const topic = this.#shown().find((t) => workspaceOf(t) === workspace);
            if (topic) this.#readIfOut(topic);
            return null;
          }),
      },
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      // Nothing one account could see is shown to another.
      this.#kept.clear();
      for (const topic of this.#shown()) {
        this.#live.stop(topic);
        this.#reading.delete(workspaceOf(topic));
        kernel.store.invalidate(topic);
        this.#readIfOut(topic);
      }
    });
  }

  #shown(): Topic[] {
    return this.#ctx.kernel.store
      .liveTopics()
      .filter((t) => t.topic === "slackDirectory");
  }

  #readIfOut(topic: Topic): void {
    const workspace = workspaceOf(topic);
    const kept = this.#kept.get(workspace);
    if ((kept && kept.expiresAt > this.#ctx.now()) || this.#reading.has(workspace))
      return;
    const reading = {};
    this.#reading.set(workspace, reading);
    this.#live.run(
      topic,
      this.#read(topic).pipe(
        Effect.ensuring(
          Effect.sync(() => {
            if (this.#reading.get(workspace) === reading)
              this.#reading.delete(workspace);
          })
        )
      )
    );
  }

  #page<S extends z.ZodType>(
    account: Parameters<Ctx["api"]["request"]>[0],
    workspace: string,
    list: "channels" | "people",
    cursor: string,
    schema: S
  ) {
    const query = cursor ? `?${new URLSearchParams({ cursor })}` : "";
    return this.#ctx.api
      .request(
        account,
        "GET",
        `${route`/v1/comma/workspaces/${workspace}/plugins/slack/${list}`}${query}`,
        schema
      )
      .pipe(Effect.result);
  }

  #read(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    const workspace = workspaceOf(topic);
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const before = this.#kept.get(workspace);
      const progress = before?.progress ?? start();
      // A complete answer stays shown until the new one is complete; otherwise the lists grow as they come.
      const complete = before?.complete ? before.directory : null;
      const keep = (expiresAt: number, kept: Progress | null) => {
        this.#kept.delete(workspace);
        this.#kept.set(workspace, {
          expiresAt,
          // Read again whole: the channels and people that did not change stay as they were (keep.ts).
          directory:
            kept && complete
              ? complete
              : share(before?.directory, directoryOf(progress)),
          complete: !kept || !!complete,
          progress: kept,
        });
        this.#evict();
        ctx.kernel.store.invalidate(topic);
      };
      for (;;) {
        const channels =
          progress.channelsCursor === null
            ? null
            : yield* this.#page(
                account.value,
                workspace,
                "channels",
                progress.channelsCursor,
                commaSlackChannelPageSchema
              );
        const people =
          progress.peopleCursor === null
            ? null
            : yield* this.#page(
                account.value,
                workspace,
                "people",
                progress.peopleCursor,
                commaSlackPersonPageSchema
              );
        let failed = false;
        if (channels) {
          if (Result.isSuccess(channels)) {
            progress.channels.push(
              ...channels.success.data.map(({ id, name, member, team_id }) => ({
                id,
                name,
                member,
                teamId: team_id,
              }))
            );
            progress.channelsCursor = channels.success.next_cursor;
          } else failed = true;
        }
        if (people) {
          if (Result.isSuccess(people)) {
            progress.people.push(
              ...people.success.data.map(
                ({ id, name, handle, avatar_ref, team_id }) => ({
                  id,
                  name,
                  handle,
                  avatarRef: avatar_ref ?? null,
                  teamId: team_id,
                })
              )
            );
            progress.peopleCursor = people.success.next_cursor;
          } else failed = true;
        }
        if (failed) {
          progress.failures += 1;
          const again = progress.failures < MAX_FAILURES;
          keep(ctx.now() + FAILED_KEEP_MS, again ? progress : start());
          return;
        }
        progress.failures = 0;
        if (progress.channelsCursor === null && progress.peopleCursor === null) {
          keep(ctx.now() + SLACK_DIRECTORY_KEEP_MS, null);
          return;
        }
        keep(0, progress);
        yield* Effect.sleep(Duration.millis(SLACK_DIRECTORY_PACE_MS));
      }
    });
  }

  /** Drops the least recently shown beyond 16, but never one shown now. */
  #evict(): void {
    if (this.#kept.size <= MAX_KEPT) return;
    const shown = new Set(this.#shown().map(workspaceOf));
    for (const key of this.#kept.keys()) {
      if (this.#kept.size <= MAX_KEPT) return;
      if (!shown.has(key)) this.#kept.delete(key);
    }
  }
}
