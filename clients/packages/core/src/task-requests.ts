// Settings › Task requests: another person asks a workspace for a Task (`Comma.TaskRequests` on the server).
//
// One page shows both sides. As a workspace owner: the requests waiting for a decision, and who may send (open invites
// and grants). As a sender: the workspaces whose invites the person accepted, and what they sent. Read while the page
// shows them and after each change; nothing is written to the device.
//
// Bounds: one read of four bounded lists (at most 50 or 100 rows each) and the workspace's own-request mode per page
// shown (`prefer`) and per change; each change is one request.
import { lazySchema } from "@comma/chat-contract";
import {
  CoreError,
  Priority,
  share,
  type Topic,
  type Value,
  utf8,
} from "@comma/core-kernel";
import { Effect, Option } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import type {
  FileSource,
  ProviderUserLink,
  TaskRequestContact,
  TaskRequestPerson,
  TaskRequestRun,
  TaskRequestGrant,
  TaskRequestIncoming,
  TaskRequestSent,
  TaskRequestTarget,
  TaskRequestsValue,
} from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

const personSchema = lazySchema(() =>
  z
    .object({
      id: z.string(),
      name: z.string().nullable(),
      email: z.string().nullable(),
      avatar_id: z.string().nullable().optional(),
    })
    .strip()
);

const workspaceSchema = lazySchema(() =>
  z
    .object({
      id: z.string(),
      name: z.string().nullable(),
      owner: personSchema.nullable(),
    })
    .strip()
);

const modeSchema = lazySchema(() => z.enum(["review", "auto_accept"]));

const grantSchema = lazySchema(() =>
  z
    .object({
      id: z.string(),
      status: z.enum(["invited", "active", "revoked"]),
      mode: modeSchema,
      daily_limit: z.number(),
      pending_limit: z.number(),
      grantee: personSchema.nullable(),
      invite_url: z.string().optional(),
      invite_expires_at: z.number().nullable().optional(),
      created_at: z.number().nullable(),
      accepted_at: z.number().nullable().optional(),
      from_invite: z.boolean().optional(),
    })
    .strip()
);

const ownSchema = lazySchema(() => z.object({ mode: modeSchema }).strip());

const statusSchema = lazySchema(() =>
  z.enum(["pending", "accepted", "declined", "withdrawn", "expired"])
);

const incomingSchema = lazySchema(() =>
  z
    .object({
      id: z.string(),
      sender: personSchema.nullable(),
      title: z.string(),
      content: z.string(),
      status: statusSchema,
      decline_reason: z.string().nullable(),
      task: z
        .object({ group_id: z.string().nullable(), id: z.string() })
        .strip()
        .nullable(),
      created_at: z.number().nullable(),
      expires_at: z.number().nullable(),
    })
    .strip()
);

const targetSchema = lazySchema(() =>
  z
    .object({
      grant_id: z.string(),
      workspace: workspaceSchema,
      mode: modeSchema,
      daily_limit: z.number(),
      pending_limit: z.number(),
      sent_today: z.number(),
      pending: z.number(),
    })
    .strip()
);

const sentSchema = lazySchema(() =>
  z
    .object({
      id: z.string(),
      workspace: workspaceSchema.nullable(),
      title: z.string(),
      content: z.string(),
      status: statusSchema,
      decline_reason: z.string().nullable(),
      task_status: z.string().nullable(),
      reply: z.string().nullable(),
      created_at: z.number().nullable(),
      decided_at: z.number().nullable().default(null),
      task_updated_at: z.number().nullable().default(null),
    })
    .strip()
);

const linkSchema = lazySchema(() =>
  z
    .object({
      id: z.string(),
      provider: z.string(),
      name: z.string().nullable(),
      email: z.string().nullable().default(null),
      workspace: z.string().nullable().default(null),
      bot: z.string().nullable().default(null),
      linked_at: z.number().nullable(),
    })
    .strip()
);

const page = <S extends z.ZodType>(row: S) => z.object({ data: z.array(row) }).strip();

const ownerPath = (workspace: string, rest: string) =>
  `${route`/v1/comma/workspaces/${workspace}`}${rest}`;

const params = {
  string(raw: unknown, name: string, max = 256): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  optional(raw: unknown, name: string, max: number): string | undefined {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (v === undefined || v === null) return undefined;
    if (typeof v !== "string" || v.length > max * 4)
      throw CoreError.invalid(`${name} is invalid`);
    const trimmed = v.trim();
    if (trimmed === "") return undefined;
    if (utf8(trimmed).length > max) throw CoreError.invalid(`${name} is invalid`);
    return trimmed;
  },
  mode(raw: unknown): "review" | "auto_accept" {
    const v = (raw as Record<string, unknown> | null)?.mode;
    if (v !== "review" && v !== "auto_accept")
      throw CoreError.invalid("mode is review or auto_accept");
    return v;
  },
};

/** A model of a runtime (Codex or Claude Code) for its default, or one it names. */
const runtime = (provider: string, model?: string) => ({
  kind: "runtime",
  provider,
  ...(model ? { model } : {}),
});

/** The server's place and model for a chosen run, as a Task create takes them (`SalixIM.TaskPlacement`). */
function placement(run: TaskRequestRun): Record<string, unknown> {
  switch (run.kind) {
    case "cloud":
      return run.model
        ? { model: { kind: "catalog", model: run.model, allow_paid: true } }
        : { runs_on: { kind: "salix" } };
    case "sandbox":
      return {
        runs_on: { kind: "sandbox" },
        repo: {
          owner: run.repo.owner,
          name: run.repo.name,
          ...(run.repo.baseRef ? { base_ref: run.repo.baseRef } : {}),
        },
        model: runtime(run.provider, run.model),
        ...(run.accountId ? { account_id: run.accountId } : {}),
      };
    case "station":
      return {
        runs_on: { kind: "station", device_id: run.station },
        model: runtime(run.provider, run.model),
      };
  }
}

/** The token of a chat account link (`…&link=<token>`) or a bare token. */
export function providerLinkToken(input: string): string | null {
  const match = /(?:^|[?&]link=)([A-Za-z0-9_-]{43})(?:[&#]|$)/.exec(input.trim());
  return match?.[1] ?? null;
}

/** The token of an invite link (`…/#/settings?category=task-requests&invite=<token>`) or a bare token. */
export function taskRequestInviteToken(input: string): string | null {
  const match = /(?:^|[?&]invite=)([A-Za-z0-9_-]{43})(?:[&#]|$)/.exec(input.trim());
  return match?.[1] ?? null;
}

/** What a read answered, else what the page had: a failed read keeps the last list on screen. */
const value = <T>(read: Option.Option<T>, kept: T | null): T | null =>
  Option.isSome(read) ? read.value : kept;

type Shown = TaskRequestsValue;

const empty: Shown = {
  workspace: null,
  incoming: null,
  received: null,
  grants: null,
  targets: null,
  sent: null,
  links: null,
  own: null,
  people: null,
  error: false,
};

const targetFull = (target: TaskRequestTarget) =>
  target.sent_today >= target.daily_limit || target.pending >= target.pending_limit;

/** The later of two times (seconds), either of which may be unknown. */
const later = (a: number | null, b: number | null | undefined) =>
  b != null && (a === null || b > a) ? b : a;

const contactName = (c: TaskRequestContact) => c.name || c.email || "";

/**
 * The people of a page's lists (People): each grantee and each target's owner once, by user id, with what either may
 * send the other and when the two last had to do with each other. The latest first, then by name.
 */
export function contactsOf(
  workspace: string | null,
  grants: readonly TaskRequestGrant[],
  targets: readonly TaskRequestTarget[],
  incoming: readonly TaskRequestIncoming[],
  sent: readonly TaskRequestSent[]
): TaskRequestContact[] {
  const byId = new Map<string, TaskRequestContact>();
  const of = (person: TaskRequestPerson) => {
    let contact = byId.get(person.id);
    if (!contact) {
      contact = {
        id: person.id,
        name: person.name,
        email: person.email,
        avatar: null,
        sends: null,
        receives: [],
        waiting: null,
        lastAt: null,
        lastTitle: null,
      };
      byId.set(person.id, contact);
    }
    contact.name ??= person.name;
    contact.email ??= person.email;
    return contact;
  };
  for (const target of targets) {
    const owner = target.workspace.owner;
    if (!owner) continue;
    const contact = of(owner);
    contact.receives.push({
      grant: target.grant_id,
      workspace: target.workspace.name,
      full: targetFull(target),
    });
    // A target's avatar is read through its grant, which the person holds.
    if (owner.avatar_id && !contact.avatar)
      contact.avatar = {
        source: "target-avatar",
        grant: target.grant_id,
        revision: owner.avatar_id,
      };
  }
  for (const grant of grants) {
    if (grant.status !== "active" || !grant.grantee) continue;
    const contact = of(grant.grantee);
    contact.sends = { grant: grant.id, mode: grant.mode };
    contact.lastAt = later(contact.lastAt, grant.created_at);
    if (!contact.avatar && workspace && grant.grantee.avatar_id)
      contact.avatar = {
        source: "grant-avatar",
        workspace,
        grant: grant.id,
        revision: grant.grantee.avatar_id,
      };
  }
  // The latest request either way names what the two last had to do with each other.
  const latest = new Map<string, number>();
  const note = (contact: TaskRequestContact, at: number | null, title: string) => {
    if (at === null || (latest.get(contact.id) ?? -1) >= at) return;
    latest.set(contact.id, at);
    contact.lastTitle = title;
  };
  // Requests either way: only of people still in the lists.
  for (const request of incoming) {
    const contact = request.sender && byId.get(request.sender.id);
    if (!contact) continue;
    if (request.status === "pending")
      contact.waiting = {
        count: (contact.waiting?.count ?? 0) + 1,
        // The list is the latest first: the last pending one came first.
        first: request.id,
      };
    contact.lastAt = later(contact.lastAt, request.created_at);
    note(contact, request.created_at, request.title);
    if (!contact.avatar && workspace && request.sender?.avatar_id) {
      const avatar: FileSource = {
        source: "sender-avatar",
        workspace,
        request: request.id,
        revision: request.sender.avatar_id,
      };
      contact.avatar = avatar;
    }
  }
  for (const request of sent) {
    const contact = request.workspace?.owner && byId.get(request.workspace.owner.id);
    if (!contact) continue;
    const at = request.task_updated_at ?? request.decided_at ?? request.created_at;
    contact.lastAt = later(contact.lastAt, at);
    note(contact, at, request.title);
  }
  return [...byId.values()].toSorted(
    (a, b) =>
      (b.lastAt ?? 0) - (a.lastAt ?? 0) || contactName(a).localeCompare(contactName(b))
  );
}

export class TaskRequests {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  /** What each shown page (`prefer`) has. */
  readonly #shown = new Map<string, Shown>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("taskRequests", {
      start: (topic) => this.#live.run(topic, this.#load(topic)),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(String(topic.prefer ?? ""));
      },
      compute: (topic): Value => ({
        ok: this.#shown.get(String(topic.prefer ?? "")) ?? empty,
      }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#shown.clear();
      for (const topic of this.#topics()) {
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#load(topic));
      }
    });

    // A new account's Workspace is made after sign-in: a page read before it was ready reads again once it is, so
    // its invite links and grants are there without a reload.
    workspaces.onChange(() => {
      for (const topic of this.#topics())
        if (!this.#shown.get(String(topic.prefer ?? ""))?.workspace)
          // Read without asking for the list again: that asking is what tells this listener.
          this.#live.run(topic, this.#load(topic, false));
    });

    const change = <S extends z.ZodType>(
      method: "POST" | "PATCH" | "DELETE",
      path: string,
      schema: S,
      body?: unknown
    ) =>
      ctx.session.account().pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, method, path, schema, body)
        ),
        Effect.tap(() => this.#reread())
      );

    kernel.calls({
      "taskRequests.refresh": {
        run: () => this.#reread().pipe(Effect.as(null)),
      },
      "taskRequests.createInvite": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return change(
            "POST",
            ownerPath(workspace, "/task-request-grants"),
            grantSchema,
            { mode: params.mode(p) }
          ).pipe(Effect.map((grant) => ({ inviteUrl: grant.invite_url ?? "" })));
        },
      },
      "taskRequests.setMode": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const grant = params.string(p, "grant");
          return change(
            "PATCH",
            ownerPath(workspace, route`/task-request-grants/${grant}`),
            grantSchema,
            { mode: params.mode(p) }
          ).pipe(Effect.as(null));
        },
      },
      "taskRequests.setOwnMode": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          return change("PATCH", ownerPath(workspace, "/task-request-own"), ownSchema, {
            mode: params.mode(p),
          }).pipe(Effect.as(null));
        },
      },
      "taskRequests.revokeGrant": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const grant = params.string(p, "grant");
          return change(
            "DELETE",
            ownerPath(workspace, route`/task-request-grants/${grant}`),
            z.object({ revoked: z.literal(true) }).strip()
          ).pipe(Effect.as(null));
        },
      },
      "taskRequests.accept": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const request = params.string(p, "request");
          const title = params.optional(p, "title", 200);
          const content = params.optional(p, "content", 16_000);
          const run = (p as { run?: TaskRequestRun } | null)?.run;
          return change(
            "POST",
            ownerPath(workspace, route`/task-requests/${request}/accept`),
            incomingSchema,
            {
              to: "task",
              ...(title === undefined ? {} : { title }),
              ...(content === undefined ? {} : { content }),
              ...(run ? placement(run) : {}),
            }
          ).pipe(Effect.map((accepted) => ({ task: accepted.task })));
        },
      },
      "taskRequests.decline": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const request = params.string(p, "request");
          const reason = params.optional(p, "reason", 1000);
          return change(
            "POST",
            ownerPath(workspace, route`/task-requests/${request}/decline`),
            incomingSchema,
            reason === undefined ? {} : { reason }
          ).pipe(Effect.as(null));
        },
      },
      "taskRequests.invitePreview": {
        run: (p) => {
          const token = taskRequestInviteToken(params.string(p, "invite", 2048));
          if (!token) throw CoreError.invalid("invite is not an invite link");
          const workspace = params.optional(p, "workspace", 256);
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "GET",
                `${route`/v1/comma/task-request-invites/${token}`}${
                  workspace === undefined
                    ? ""
                    : `?workspace_id=${encodeURIComponent(workspace)}`
                }`,
                z
                  .object({
                    workspace: workspaceSchema,
                    own: z.boolean(),
                    back: z
                      .object({
                        workspace: z
                          .object({ id: z.string(), name: z.string().nullable() })
                          .strip(),
                        mode: modeSchema,
                      })
                      .strip()
                      .nullable()
                      .default(null),
                    expires_at: z.number().nullable(),
                  })
                  .strip()
              )
            ),
            Effect.map((preview) => ({
              workspace: preview.workspace,
              own: preview.own,
              back: preview.back,
              expiresAt: preview.expires_at,
            }))
          );
        },
      },
      "taskRequests.acceptInvite": {
        doing: true,
        run: (p) => {
          const token = taskRequestInviteToken(params.string(p, "invite", 2048));
          if (!token) throw CoreError.invalid("invite is not an invite link");
          // The workspace the preview named, where the inviter may send back.
          const workspace = params.optional(p, "workspace", 256);
          return change(
            "POST",
            route`/v1/comma/task-request-invites/${token}/accept`,
            targetSchema.extend({ reciprocal: z.boolean().default(false) }),
            workspace === undefined ? {} : { workspace_id: workspace }
          ).pipe(Effect.map((target) => ({ reciprocal: target.reciprocal })));
        },
      },
      "taskRequests.send": {
        doing: true,
        run: (p) => {
          const grant = params.string(p, "grant");
          const content = params.string(p, "content", 16_000).trim();
          if (!content) throw CoreError.invalid("content is required");
          const title = params.optional(p, "title", 200);
          const workspace = params.optional(p, "workspace", 256);
          return change(
            "POST",
            route`/v1/comma/task-request-targets/${grant}/requests`,
            sentSchema,
            {
              content,
              client_request_id: params.string(p, "key", 128),
              ...(title === undefined ? {} : { title }),
              ...(workspace === undefined ? {} : { sender_workspace_id: workspace }),
            }
          ).pipe(Effect.map((sent) => ({ status: sent.status })));
        },
      },
      "taskRequests.linkPreview": {
        run: (p) => {
          const token = providerLinkToken(params.string(p, "link", 2048));
          if (!token) throw CoreError.invalid("link is not a Comma link");
          return ctx.session
            .account()
            .pipe(
              Effect.flatMap((account) =>
                ctx.api.request(
                  account,
                  "GET",
                  route`/v1/comma/provider-link-requests/${token}`,
                  z
                    .object({ provider: z.string(), name: z.string().nullable() })
                    .strip()
                )
              )
            );
        },
      },
      "taskRequests.acceptLink": {
        doing: true,
        run: (p) => {
          const token = providerLinkToken(params.string(p, "link", 2048));
          if (!token) throw CoreError.invalid("link is not a Comma link");
          return change(
            "POST",
            route`/v1/comma/provider-link-requests/${token}/accept`,
            linkSchema
          ).pipe(Effect.as(null));
        },
      },
      "taskRequests.removeLink": {
        doing: true,
        run: (p) => {
          const id = params.string(p, "id");
          return change(
            "DELETE",
            route`/v1/comma/provider-links/${id}`,
            z.object({ removed: z.literal(true) }).strip()
          ).pipe(Effect.as(null));
        },
      },
      "collaborations.start": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const people = (p as { people?: unknown } | null)?.people ?? [];
          const emails = (p as { emails?: unknown } | null)?.emails ?? [];
          if (
            !Array.isArray(people) ||
            !Array.isArray(emails) ||
            people.length + emails.length === 0 ||
            people.some((id) => typeof id !== "string" || id === "") ||
            emails.some((email) => typeof email !== "string" || !email.includes("@"))
          )
            throw CoreError.invalid("people is required");
          const content = params.string(p, "content", 16_000).trim();
          if (!content) throw CoreError.invalid("content is required");
          return change(
            "POST",
            ownerPath(workspace, "/collaborations"),
            z
              .object({
                task: z.object({ id: z.string(), group_id: z.string() }).strip(),
              })
              .strip(),
            {
              people,
              ...(emails.length > 0 ? { emails } : {}),
              content,
              client_request_id: params.string(p, "key", 128),
            }
          );
        },
      },
      "taskRequests.withdraw": {
        doing: true,
        run: (p) => {
          const request = params.string(p, "request");
          return change(
            "POST",
            route`/v1/comma/sent-task-requests/${request}/withdraw`,
            sentSchema
          ).pipe(Effect.as(null));
        },
      },
      "taskRequests.hide": {
        doing: true,
        run: (p) => {
          const request = params.string(p, "request");
          return change(
            "DELETE",
            route`/v1/comma/sent-task-requests/${request}`,
            z.object({ hidden: z.literal(true) }).strip()
          ).pipe(Effect.as(null));
        },
      },
    });
  }

  /** A request to a workspace came or was withdrawn (the owner's task stream says so): every shown page reads again. */
  changed(): void {
    for (const topic of this.#topics()) this.#live.run(topic, this.#load(topic));
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store
      .liveTopics()
      .filter((t) => t.topic === "taskRequests");
  }

  /** After a change: every shown page reads again; a failed read shows on the page. */
  #reread(): Effect.Effect<void> {
    return Effect.forEach(this.#topics(), (topic) => this.#load(topic)).pipe(
      Effect.asVoid
    );
  }

  /** The workspace a page prefers (the one it is in), else the first; then both sides' lists. */
  #load(topic: Topic, askWorkspaces = true): Effect.Effect<void> {
    const prefer = String(topic.prefer ?? "");
    return Effect.gen({ self: this }, function* () {
      const ctx = this.#ctx;
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const known = this.#workspaces.list(account.value);
      if (askWorkspaces && !known?.some((w) => w.id === prefer))
        yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
      const list = this.#workspaces.list(account.value) ?? [];
      const workspace = (list.find((w) => w.id === prefer) ?? list[0])?.id ?? null;
      const get = <S extends z.ZodType>(path: string, schema: S) =>
        ctx.api.request(account.value, "GET", path, schema).pipe(Effect.option);
      const [incoming, grants, targets, sent, links, own] = yield* Effect.all(
        [
          workspace
            ? // Every status: a person's page keeps what they asked after it is answered.
              get(
                ownerPath(workspace, "/task-requests?status=all"),
                page(incomingSchema)
              )
            : Effect.succeedNone,
          workspace
            ? get(ownerPath(workspace, "/task-request-grants"), z.array(grantSchema))
            : Effect.succeedNone,
          get("/v1/comma/task-request-targets", page(targetSchema)),
          get("/v1/comma/sent-task-requests", page(sentSchema)),
          get("/v1/comma/provider-links", page(linkSchema)),
          workspace
            ? get(ownerPath(workspace, "/task-request-own"), ownSchema)
            : Effect.succeedNone,
        ],
        { concurrency: "unbounded" }
      );
      const was = this.#shown.get(prefer) ?? empty;
      const shownReceived = value(
        Option.map(incoming, (p) => p.data as TaskRequestIncoming[]),
        was.received
      );
      const shownIncoming =
        shownReceived &&
        shownReceived.filter((request) => request.status === "pending");
      const shownGrants = value(
        grants as Option.Option<TaskRequestGrant[]>,
        was.grants
      );
      const shownTargets = value(
        Option.map(targets, (p) => p.data as TaskRequestTarget[]),
        was.targets
      );
      const shownSent = value(
        Option.map(sent, (p) => p.data as TaskRequestSent[]),
        was.sent
      );
      // Read again whole: what did not change stays as it was (keep.ts).
      this.#shown.set(
        prefer,
        share(was, {
          workspace,
          incoming: shownIncoming,
          received: shownReceived,
          grants: shownGrants,
          targets: shownTargets,
          sent: shownSent,
          // Without a workspace there are no grants: its people are those it may send to.
          people:
            shownTargets && (shownGrants || !workspace)
              ? contactsOf(
                  workspace,
                  shownGrants ?? [],
                  shownTargets,
                  shownReceived ?? [],
                  shownSent ?? []
                )
              : null,
          links: value(
            Option.map(links, (p) => p.data as ProviderUserLink[]),
            was.links
          ),
          own: value(
            Option.map(own, (o) => o.mode),
            was.own
          ),
          error:
            // The own-request mode is not among them: a server without it leaves the switch out.
            (workspace !== null &&
              (Option.isNone(incoming) || Option.isNone(grants))) ||
            Option.isNone(targets) ||
            Option.isNone(sent) ||
            Option.isNone(links),
        })
      );
      ctx.kernel.store.invalidate(topic);
    });
  }
}
