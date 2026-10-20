// Quick Chat sends a person's words to Home as an ordinary message with `message_type: quick_chat`. The Router
// decides whether to answer or create a Task. Select the Workspace once, ensure its Home, then keep that destination,
// request id and text through retries. Only accepted_message_id acknowledges this send: concurrent messages can make
// the conversation's latest message belong to someone else.
//
// Bounds: one Home request, then at most two message requests. A 5xx, timeout or network failure retries once after
// one second. Each request has the API's 30-second deadline. No Task read follows an accepted message.
import { CoreError, Priority } from "@comma/core-kernel";
import { Duration, Effect, Schedule } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { clientTimezone } from "./chat/http.ts";
import { commaConversationSchema } from "./comma/api-schemas.ts";
import type { QuickChatMessage, TaskWorkspace } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { Tasks } from "./tasks.ts";
import type { Workspaces } from "./workspaces.ts";

const receiptSchema = z
  .object({
    accepted_message_id: z.string().min(1).max(256),
  })
  .strip();

const string = (raw: unknown, name: string): string => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "") throw CoreError.invalid(`${name} is required`);
  return v;
};

const optionalString = (raw: unknown, name: string): string | undefined => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (v === undefined) return undefined;
  if (typeof v !== "string" || v === "")
    throw CoreError.invalid(`${name} must be a workspace id`);
  return v;
};

/** The server may have accepted the message without answering. */
const unanswered = (error: CoreError) =>
  (error.status ?? 0) >= 500 || error.code === "timeout" || error.code === "network";

export class QuickChat {
  readonly #ctx: Ctx;
  readonly #tasks: Tasks;
  readonly #workspaces: Workspaces;

  constructor(ctx: Ctx, tasks: Tasks, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#tasks = tasks;
    this.#workspaces = workspaces;
    ctx.kernel.calls({
      "quickChat.sendMessage": {
        doing: true,
        run: (p) =>
          this.#send(
            string(p, "client_request_id"),
            string(p, "text"),
            optionalString(p, "workspace")
          ),
      },
    });
  }

  #send(
    request: string,
    text: string,
    wanted: string | undefined
  ): Effect.Effect<QuickChatMessage, CoreError> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account();
      const workspace = yield* this.#workspaceOf(account, wanted ?? "");
      if (!workspace)
        return yield* Effect.fail(new CoreError("not_found", "no workspace"));
      const home = yield* ctx.api.request(
        account,
        "POST",
        route`/v1/comma/groups/${workspace.group_id}/assistant-chat?message_limit=1`,
        commaConversationSchema,
        {}
      );
      const receipt = yield* ctx.api
        .request(
          account,
          "POST",
          route`/v1/comma/groups/${workspace.group_id}/conversations/${home.id}/messages?message_limit=1`,
          receiptSchema,
          {
            message: { type: "text", text },
            client_request_id: request,
            message_type: "quick_chat",
            ...clientTimezone(),
          }
        )
        .pipe(
          Effect.retry({
            schedule: Schedule.spaced(Duration.seconds(1)),
            times: 1,
            while: unanswered,
          })
        );
      return {
        workspace_id: workspace.id,
        group_id: workspace.group_id,
        conversation_id: home.id,
        message_id: receipt.accepted_message_id,
      };
    });
  }

  /** `wanted`, or with "" the one in focus; null when the account has no such workspace. */
  #workspaceOf(account: Account, wanted: string): Effect.Effect<TaskWorkspace | null> {
    return Effect.gen({ self: this }, function* () {
      const known = this.#tasks.workspace(account, wanted);
      if (known) return known;
      yield* this.#workspaces.refresh(Priority.asked).pipe(Effect.ignore);
      return this.#tasks.workspace(account, wanted);
    });
  }
}
