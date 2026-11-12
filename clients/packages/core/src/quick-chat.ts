// Quick Chat sends a person's words to Home as an ordinary message with `message_type: quick_chat`. The Router
// decides whether to answer or create a Task. Select the Workspace once, ensure its Home, then keep that destination,
// request id and text through retries. A Home a window resolved needs no ensuring, and while it is open the message
// shows in it at once, as being sent, as a typed one does. Only accepted_message_id acknowledges this send: concurrent
// messages can make the conversation's latest message belong to someone else.
//
// Words still being prepared (the last spoken ones settle on the server) show in the open Home from Return, as a
// message being sent: `prepareMessage` shows or replaces them and makes no request, the send of the same request id
// puts the final words in that message, and `failPreparation` ends it as a failed one. Electron's Main owns the
// preparation and its deadline, and ends each one it showed.
//
// Bounds: at most one Home request, then at most two message requests. A 5xx, timeout or network failure retries once after
// one second. Each request has the API's 30-second deadline. No Task read follows an accepted message.
import { lazySchema, type ChatTarget } from "@comma/chat-contract";
import { CoreError, Priority } from "@comma/core-kernel";
import { Duration, Effect, Schedule } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import type { Chat } from "./chat/index.ts";
import { route } from "./api.ts";
import { commaConversationSchema } from "./comma/api-schemas.ts";
import type {
  QuickChatDictationTicket,
  QuickChatMessage,
  TaskWorkspace,
} from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { Tasks } from "./tasks.ts";
import type { Workspaces } from "./workspaces.ts";

const dictationTicketSchema = lazySchema(() =>
  z
    .object({
      url: z.string().min(1).max(2048),
      ticket: z.string().min(1).max(512),
      expires_at: z.number(),
    })
    .strip()
);

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
  /** The core's chat, which sends the message: set once it is made. */
  chat: Chat | undefined;

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
      "quickChat.prepareMessage": {
        run: (p) => {
          const request = string(p, "client_request_id");
          const text = string(p, "text");
          return this.#inHome(string(p, "workspace"), (chat, account, home) =>
            chat.holdRequest(account, home, text, request, "quick_chat")
          );
        },
      },
      "quickChat.failPreparation": {
        run: (p) => {
          const request = string(p, "client_request_id");
          return this.#inHome(string(p, "workspace"), (chat, account, home) =>
            chat.failHeldRequest(account, home, request)
          );
        },
      },
      "quickChat.dictationTicket": {
        run: () =>
          ctx.session
            .account()
            .pipe(
              Effect.flatMap(
                (account): Effect.Effect<QuickChatDictationTicket, CoreError> =>
                  ctx.api.request(
                    account,
                    "POST",
                    "/v1/comma/me/dictation/tickets",
                    dictationTicketSchema,
                    {}
                  )
              )
            ),
      },
    });
  }

  /** Sends `text` to the Home of `workspace` (else the one in focus), as `quickChat.sendMessage` does. */
  send(
    request: string,
    text: string,
    workspace: string | undefined
  ): Effect.Effect<QuickChatMessage, CoreError> {
    return this.#send(request, text, workspace);
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
      const chat = this.chat;
      if (!chat) return yield* Effect.fail(new CoreError("not_found", "no chat"));
      const home = chat.knownHome(workspace.id) ?? {
        workspaceId: workspace.id,
        groupId: workspace.group_id,
        conversationId: (yield* ctx.api.request(
          account,
          "POST",
          route`/v1/comma/groups/${workspace.group_id}/assistant-chat?message_limit=1`,
          commaConversationSchema,
          {}
        )).id,
      };
      const messageId = yield* chat
        .sendRequest(account, home, text, request, "quick_chat")
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
        conversation_id: home.conversationId,
        message_id: messageId,
      };
    });
  }

  /** Changes the Home of `workspace` when a window resolved it this session; else nothing, with no request. */
  #inHome(
    workspace: string,
    change: (
      chat: Chat,
      account: Account,
      home: ChatTarget
    ) => Effect.Effect<void, CoreError>
  ): Effect.Effect<null, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account();
      const chat = this.chat;
      const home = chat?.knownHome(workspace);
      if (chat && home) yield* change(chat, account, home);
      return null;
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
