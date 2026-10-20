// The iPhone's push notifications: the device's APNs token and the Live Activity tokens registered with the server, and
// what a notification or a Live Activity reads when it shows (the Tasks a Live Activity follows, the Router chat's
// unread replies). The app decides when to register (the person's choice and the system's permission are the app's);
// the core makes every request. A registration names the session it is for: one asked for a session that is no
// longer the current one is refused (`session_changed`), so a token never lands on the next account. Delivery stops
// on its own for a session that ends (the server delivers only to open sessions).
//
// Bounds: each call is one request.
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { taskConversationSchema } from "./comma/schemas.ts";
import type {
  NotificationRegistration,
  RouterUnread,
  TaskActivity,
} from "./contract.ts";
import type { Ctx } from "./ctx.ts";

const registrationSchema = z.object({
  id: z.string().min(1).max(256),
  status: z.string(),
});
const routerUnreadSchema = z.object({
  conversation_id: z.string().min(1).max(256).nullable(),
  unread_count: z.number().int().nonnegative(),
  latest_message_id: z.string().max(256).nullable(),
  latest_seq: z.number().int().nonnegative(),
});
const activitySchema = z.object({ data: z.array(taskConversationSchema).max(2) });

const REASONS = [
  "dismissed",
  "expired",
  "finished",
  "stopped",
  "disabled",
  "authority_changed",
] as const;

const params = {
  string(raw: unknown, name: string, max = 256): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  optional(raw: unknown, name: string, max = 256): string | undefined {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (v === undefined || v === null) return undefined;
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is a string`);
    return v;
  },
};

/** What a registration says of the device, as the server takes it. */
function target(p: unknown) {
  const environment = params.string(p, "environment");
  if (environment !== "sandbox" && environment !== "production")
    throw CoreError.invalid("environment is sandbox or production");
  return {
    token: params.string(p, "token", 4_096),
    environment,
    workspace_id: params.string(p, "workspace"),
    group_id: params.string(p, "group"),
    bundle_id: params.string(p, "bundleId"),
    locale: params.string(p, "locale", 64),
  };
}

const unread = (answer: z.output<typeof routerUnreadSchema>): RouterUnread => ({
  conversationId: answer.conversation_id,
  unreadCount: answer.unread_count,
  latestMessageId: answer.latest_message_id,
  latestSeq: answer.latest_seq,
});

export class Notifications {
  readonly #ctx: Ctx;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    const api = ctx.api;
    ctx.kernel.calls({
      "notifications.registerDevice": {
        run: (p) => {
          const body = target(p);
          return this.#for(params.string(p, "session"), (account) =>
            api.request(
              account,
              "POST",
              "/v1/comma/notifications/devices",
              registrationSchema,
              body
            )
          ).pipe(Effect.flatMap(active));
        },
      },
      "notifications.unregisterDevice": {
        run: () =>
          ctx.session.account().pipe(
            Effect.flatMap((account) =>
              api.request(
                account,
                "DELETE",
                "/v1/comma/notifications/devices",
                z.unknown()
              )
            ),
            Effect.as(null)
          ),
      },
      "notifications.registerActivity": {
        run: (p) => {
          const activity = params.optional(p, "activity");
          const body = {
            ...target(p),
            registration_id: params.string(p, "registration"),
            activity_schema: "tasks_v1",
            ...(activity ? { activity_id: activity } : {}),
          };
          const path = activity
            ? "/v1/comma/notifications/live-activities"
            : "/v1/comma/notifications/push-to-start";
          return this.#for(params.string(p, "session"), (account) =>
            api.request(account, "POST", path, registrationSchema, body)
          ).pipe(Effect.flatMap(active));
        },
      },
      "notifications.unregister": {
        run: (p) => {
          const id = params.string(p, "id");
          const reason = params.optional(p, "reason");
          if (reason !== undefined && !(REASONS as readonly string[]).includes(reason))
            throw CoreError.invalid("reason is not one the server takes");
          const query = reason ? `?reason=${encodeURIComponent(reason)}` : "";
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              api.request(
                account,
                "DELETE",
                `${route`/v1/comma/notifications/registrations/${id}`}${query}`,
                z.unknown()
              )
            ),
            Effect.as(null)
          );
        },
      },
      "notifications.taskActivity": {
        run: (p) => {
          const group = params.string(p, "group");
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              api.request(
                account,
                "GET",
                route`/v1/comma/groups/${group}/task-activity`,
                activitySchema
              )
            ),
            Effect.map(
              (answer): TaskActivity => ({
                tasks: answer.data
                  .filter(
                    (task) => task.group_id === group && task.kind === "agent_task"
                  )
                  .map((task) => ({
                    id: task.id,
                    title: task.title,
                    status: task.status,
                    ...(task.activity_status === undefined
                      ? {}
                      : { activityStatus: task.activity_status }),
                    ...(task.updated_at === undefined
                      ? {}
                      : { updatedAt: task.updated_at }),
                  })),
              })
            )
          );
        },
      },
      "notifications.routerUnread": {
        run: (p) => {
          const group = params.string(p, "group");
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              api.request(
                account,
                "GET",
                route`/v1/comma/groups/${group}/router-notifications`,
                routerUnreadSchema
              )
            ),
            Effect.map(unread)
          );
        },
      },
      "notifications.readRouter": {
        run: (p) => {
          const group = params.string(p, "group");
          const message = params.string(p, "messageId");
          return ctx.session.account().pipe(
            Effect.flatMap((account) =>
              api.request(
                account,
                "POST",
                route`/v1/comma/groups/${group}/router-notifications/read`,
                routerUnreadSchema,
                { message_id: message }
              )
            ),
            Effect.map(unread)
          );
        },
      },
    });
  }

  /** `send` for the signed-in account, when it is the session `session` the app asked for. */
  #for<A>(
    session: string,
    send: (account: Account) => Effect.Effect<A, CoreError>
  ): Effect.Effect<A, CoreError> {
    return this.#ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          account.lease.sessionId === session
            ? send(account)
            : Effect.fail(
                new CoreError("session_changed", "Another session is signed in now.")
              )
        )
      );
  }
}

function active(
  registration: z.output<typeof registrationSchema>
): Effect.Effect<NotificationRegistration, CoreError> {
  return registration.status === "active"
    ? Effect.succeed({ id: registration.id })
    : Effect.fail(
        new CoreError("bad_response", `the registration is ${registration.status}`)
      );
}
