// Settings › Task requests: another person asks a workspace for a Task (`Comma.TaskRequests` on the server).
//
// One page shows both sides. As a workspace owner: the requests waiting for a decision, and who may send (open invites
// and grants). As a sender: the workspaces whose invites the person accepted, and what they sent. Read while the page
// shows them and after each change; nothing is written to the device.
//
// Bounds: one read of four bounded lists (at most 50 or 100 rows each) and the workspace's own-request mode per page
// shown (`prefer`) and per change; each change is one request.
import { lazySchema } from "@comma/chat-contract";
import { CoreError, Priority, share, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import type {
  ProviderUserLink,
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
      accepted_as: z.enum(["task", "router"]).nullable().optional(),
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
    if (typeof v !== "string" || v.length > max)
      throw CoreError.invalid(`${name} is invalid`);
    return v.trim() === "" ? undefined : v.trim();
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
      return { model: { kind: "catalog", model: run.model, allow_paid: true } };
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
  grants: null,
  targets: null,
  sent: null,
  links: null,
  own: null,
  error: false,
};

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
          const to = (p as { to?: unknown } | null)?.to ?? "task";
          if (to !== "task" && to !== "router")
            throw CoreError.invalid("to is task or router");
          const run = (p as { run?: TaskRequestRun } | null)?.run;
          return change(
            "POST",
            ownerPath(workspace, route`/task-requests/${request}/accept`),
            incomingSchema,
            {
              to,
              ...(title === undefined ? {} : { title }),
              ...(content === undefined ? {} : { content }),
              ...(run && to === "task" ? placement(run) : {}),
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
  #load(topic: Topic): Effect.Effect<void> {
    const prefer = String(topic.prefer ?? "");
    return Effect.gen({ self: this }, function* () {
      const ctx = this.#ctx;
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      const known = this.#workspaces.list(account.value);
      if (!known?.some((w) => w.id === prefer))
        yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
      const list = this.#workspaces.list(account.value) ?? [];
      const workspace = (list.find((w) => w.id === prefer) ?? list[0])?.id ?? null;
      const get = <S extends z.ZodType>(path: string, schema: S) =>
        ctx.api.request(account.value, "GET", path, schema).pipe(Effect.option);
      const [incoming, grants, targets, sent, links, own] = yield* Effect.all(
        [
          workspace
            ? get(ownerPath(workspace, "/task-requests"), page(incomingSchema))
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
      // Read again whole: what did not change stays as it was (keep.ts).
      this.#shown.set(
        prefer,
        share(was, {
          workspace,
          incoming: value(
            Option.map(incoming, (p) => p.data as TaskRequestIncoming[]),
            was.incoming
          ),
          grants: value(grants as Option.Option<TaskRequestGrant[]>, was.grants),
          targets: value(
            Option.map(targets, (p) => p.data as TaskRequestTarget[]),
            was.targets
          ),
          sent: value(
            Option.map(sent, (p) => p.data as TaskRequestSent[]),
            was.sent
          ),
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
