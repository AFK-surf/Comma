// Collaborative Tasks another person hosts (`Comma.Collaborations` on the server): the account's invites and the Tasks
// it is a member of. Read while a surface shows them and after each answer; nothing is written to the device.
//
// Bounds: one read of at most 100 rows per shown topic and per answer; each answer is one request.
import { lazySchema } from "@comma/chat-contract";
import { CoreError, share, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import type {
  Collaboration,
  CollaborationMember,
  CollaborationsValue,
} from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";

const personSchema = lazySchema(() =>
  z
    .object({
      id: z.string(),
      name: z.string().nullable(),
      email: z.string().nullable().default(null),
      avatar_id: z.string().nullable().optional(),
    })
    .strip()
);

const memberSchema = lazySchema(() =>
  z
    .object({
      /** The seat's id: what the host's resend names. */
      id: z.string().optional(),
      person: personSchema.nullable(),
      /** The host's view of a seat no account took yet: the address it invited. */
      invited_email: z.string().max(254).optional(),
      /** The name a guest gave when they joined by the emailed link without an account. */
      guest_name: z.string().nullable().optional(),
      /** When the emailed link of a seat no account took stops opening (ISO 8601). */
      invite_expires_at: z.string().nullable().optional(),
      status: z.enum(["invited", "active", "declined", "left", "removed"]),
    })
    .strip()
);

const membersKey = (topic: Topic) => `${String(topic.workspace)}/${String(topic.task)}`;

const collaborationSchema = lazySchema(() =>
  z
    .object({
      id: z.string(),
      status: z.enum(["invited", "active"]),
      title: z.string(),
      task: z
        .object({ id: z.string(), group_id: z.string(), workspace_id: z.string() })
        .strip(),
      host: personSchema.nullable(),
      members: z.array(memberSchema),
      invited_at: z.number().nullable(),
    })
    .strip()
);

const empty: CollaborationsValue = { items: null, error: false };

/**
 * The Tasks a core's account is an active member of, but does not host: their transcript is read and written through
 * the member routes (`/v1/comma/collaborations/:group/:task`), never the host's Group routes.
 */
const memberTasks = new WeakMap<Ctx, ReadonlySet<string>>();
/** The host Groups of those Tasks: the account's own Groups are never among them. */
const memberGroups = new WeakMap<Ctx, ReadonlySet<string>>();

/** The Tasks together the account hosts, as its Task lists name them (`together`). */
const hostedTogether = new WeakMap<Ctx, Set<string>>();

/** A Task list said Task `conversation` is a Task together the account hosts. */
export function noteHostedTogether(ctx: Ctx, conversation: string) {
  let hosted = hostedTogether.get(ctx);
  if (!hosted) hostedTogether.set(ctx, (hosted = new Set()));
  hosted.add(conversation);
}

/** Whether Task `conversation` is a Task together the account hosts or joined: its files go in its own folder. */
export function isTaskTogether(ctx: Ctx, conversation: string): boolean {
  return (
    memberTasks.get(ctx)?.has(conversation) === true ||
    hostedTogether.get(ctx)?.has(conversation) === true
  );
}

/** Each core's reader of its account's memberships, for the chat API to wait on before it names a Task's route. */
const readers = new WeakMap<Ctx, () => Effect.Effect<void>>();

/**
 * Settles once the account's memberships were read at least once, so a Task opened first (a deep link, a reload) goes
 * to the right route. A failed read settles too: the Group's route then answers as it would.
 */
export function membershipsKnown(ctx: Ctx): Effect.Effect<void> {
  if (memberTasks.has(ctx)) return Effect.void;
  return readers.get(ctx)?.() ?? Effect.void;
}

/**
 * A member route of Task `conversation` answered that the Task is not there (404): the account left it or was taken
 * out, so its memberships are read again and the Task's view learns it at once. Any other Task is left alone.
 */
export function memberRouteGone(ctx: Ctx, conversation: string): Effect.Effect<void> {
  if (!memberTasks.get(ctx)?.has(conversation)) return Effect.void;
  return readers.get(ctx)?.() ?? Effect.void;
}

/** The base path of a Task's transcript: a member's own route for a Task they joined, else the Group's. */
export function conversationBasePath(
  ctx: Ctx,
  group: string,
  conversation: string
): string {
  return memberTasks.get(ctx)?.has(conversation)
    ? route`/v1/comma/collaborations/${group}/${conversation}`
    : route`/v1/comma/groups/${group}/conversations/${conversation}`;
}

export class Collaborations {
  readonly #ctx: Ctx;
  readonly #live: Live;
  #shown: CollaborationsValue = empty;
  readonly #members = new Map<string, CollaborationMember[]>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    readers.set(ctx, () => this.#load());
    // The host's Group routes of a Task the account joined are the host's: the panels a Task view opens (its files,
    // labels, suggestions, the Group's change feed) are refused here, not asked of a server that refuses them.
    ctx.api.refuse((path) => {
      const groups = memberGroups.get(ctx);
      if (!groups || !path.startsWith("/v1/comma/groups/")) return false;
      const group = decodeURIComponent(
        path.slice("/v1/comma/groups/".length).split(/[/?]/)[0] ?? ""
      );
      return groups.has(group);
    });
    const { kernel } = ctx;
    kernel.source("collaborations", {
      start: (topic) => this.#live.run(topic, this.#load()),
      stop: (topic) => this.#live.stop(topic),
      compute: (): Value => ({ ok: this.#shown }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#shown = empty;
      memberTasks.delete(ctx);
      memberGroups.delete(ctx);
      this.#invalidate();
    });
    // The people of a Task the account hosts, read when its details show: one indexed read per Task opened.
    kernel.source("taskMembers", {
      start: (topic) => this.#live.run(topic, this.#loadMembers(topic)),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#members.delete(membersKey(topic));
      },
      compute: (topic): Value => ({
        ok: { members: this.#members.get(membersKey(topic)) ?? null },
      }),
    });
    kernel.calls({
      // The people of a hosted Task read again: the Task view asks on each change of its conversation (a member who
      // joined writes, the Worker answers), so their standing follows without a poll.
      "taskMembers.refresh": {
        run: (p) => {
          const task = (p as { task?: unknown } | null)?.task;
          return Effect.forEach(
            ctx.kernel.store
              .liveTopics()
              .filter((topic) => topic.topic === "taskMembers" && topic.task === task),
            (topic) => this.#loadMembers(topic)
          ).pipe(Effect.as(null));
        },
      },
      "collaborations.remove": {
        doing: true,
        run: (p) => {
          const given = (p ?? {}) as Record<string, unknown>;
          const [workspace, task, person] = (
            ["workspace", "task", "person"] as const
          ).map((key) => {
            const value = given[key];
            if (typeof value !== "string" || value === "")
              throw CoreError.invalid(`${key} is required`);
            return value;
          }) as [string, string, string];
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "DELETE",
                route`/v1/comma/workspaces/${workspace}/collaborations/${task}/members/${person}`,
                z.object({ removed: z.boolean() }).strip()
              )
            ),
            Effect.tap(() =>
              Effect.forEach(
                ctx.kernel.store
                  .liveTopics()
                  .filter(
                    (topic) => topic.topic === "taskMembers" && topic.task === task
                  ),
                (topic) => this.#loadMembers(topic)
              )
            ),
            Effect.as(null)
          );
        },
      },
      // The host sends a seat given by email a fresh link (the last one may have expired): it counts toward the
      // host's invite emails of the day, as starting a Task does.
      "collaborations.resend": {
        doing: true,
        run: (p) => {
          const given = (p ?? {}) as Record<string, unknown>;
          const [workspace, task, member] = (
            ["workspace", "task", "member"] as const
          ).map((key) => {
            const value = given[key];
            if (typeof value !== "string" || value === "")
              throw CoreError.invalid(`${key} is required`);
            return value;
          }) as [string, string, string];
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                route`/v1/comma/workspaces/${workspace}/collaborations/${task}/members/${member}/resend`,
                z.object({ id: z.string() }).strip()
              )
            ),
            Effect.tap(() =>
              Effect.forEach(
                ctx.kernel.store
                  .liveTopics()
                  .filter(
                    (topic) => topic.topic === "taskMembers" && topic.task === task
                  ),
                (topic) => this.#loadMembers(topic)
              )
            ),
            Effect.as(null)
          );
        },
      },
      "collaborations.refresh": { run: () => this.#load().pipe(Effect.as(null)) },
      "collaborations.answer": {
        doing: true,
        run: (p) => {
          const id = (p as { id?: unknown } | null)?.id;
          const answer = (p as { answer?: unknown } | null)?.answer;
          if (typeof id !== "string" || id === "")
            throw CoreError.invalid("id is required");
          if (answer !== "accept" && answer !== "decline" && answer !== "leave")
            throw CoreError.invalid("answer is accept, decline or leave");
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                route`/v1/comma/collaborations/${id}/${answer}`,
                z.object({ id: z.string(), status: z.string() }).strip()
              )
            ),
            Effect.tap(() => this.#load()),
            Effect.as(null)
          );
        },
      },
    });
  }

  /** The Task of a membership the account holds, by its id: a member reads it through `/v1/comma/collaborations`. */
  memberTask(conversationId: string): Collaboration | undefined {
    return this.#shown.items?.find(
      (item) => item.status === "active" && item.task.id === conversationId
    );
  }

  #loadMembers(topic: Topic): Effect.Effect<void> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const read = yield* ctx.api
        .request(
          account.value,
          "GET",
          route`/v1/comma/workspaces/${String(topic.workspace)}/collaborations/${String(topic.task)}/members`,
          z.object({ data: z.array(memberSchema) }).strip()
        )
        .pipe(Effect.option);
      this.#members.set(
        membersKey(topic),
        Option.isSome(read) ? (read.value.data as CollaborationMember[]) : []
      );
      ctx.kernel.store.invalidate(topic);
    });
  }

  #invalidate(): void {
    for (const topic of this.#ctx.kernel.store.liveTopics())
      if (topic.topic === "collaborations") this.#ctx.kernel.store.invalidate(topic);
  }

  /** One read of the list; a failed read keeps what the surface had and says so. */
  #load(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const ctx = this.#ctx;
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const read = yield* ctx.api
        .request(
          account.value,
          "GET",
          "/v1/comma/collaborations",
          z.object({ data: z.array(collaborationSchema) }).strip()
        )
        .pipe(Effect.option);
      if (Option.isSome(read))
        memberGroups.set(
          ctx,
          new Set(
            read.value.data
              .filter((item) => item.status === "active")
              .map((item) => item.task.group_id)
          )
        );
      if (Option.isSome(read))
        memberTasks.set(
          ctx,
          new Set(
            read.value.data
              .filter((item) => item.status === "active")
              .map((item) => item.task.id)
          )
        );
      // Read again whole: what did not change stays as it was (keep.ts).
      this.#shown = share(
        this.#shown,
        Option.isSome(read)
          ? { items: read.value.data as Collaboration[], error: false }
          : { items: this.#shown.items, error: true }
      );
      this.#invalidate();
    });
  }
}
