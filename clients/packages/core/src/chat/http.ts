// Chat's requests (chat/api.ts) made by the core for one account: each through the host, which adds the session's
// credential (Electron's Main) or cookie (the web); each answer read through its schema. A request the server refused
// fails with a CommaApiError (its status and body); one that got no answer fails with a plain Error, which the
// engine treats as the network. Interrupting one stops the request.
import { CoreError, utf8 } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import type { Account } from "../account.ts";
import { route } from "../api.ts";
import {
  commaConversationEventSchema,
  commaConversationListEventSchema,
  commaConversationSchema,
  commaGroupFileSchema,
  commaMessagePageSchema,
  commaSkillSchema,
  commaPageSchema,
  commaTaskParticipantStatusesSchema,
  commaWorkspaceBootstrapSchema,
  commaWorkspaceSchema,
} from "../comma/api-schemas.ts";
import type { Ctx } from "../ctx.ts";
import { header } from "../host.ts";
import { readEvents } from "../sse.ts";
import { type ChatApi, CommaApiError, type CommaApiErrorBody } from "./api.ts";
import type { ChatEnv } from "./env.ts";

const conversationPath = (group: string, conversation: string) =>
  route`/v1/comma/groups/${group}/conversations/${conversation}`;

/** The error the engine expects for a core error. */
function asApiError(error: unknown): Error {
  if (error instanceof CoreError && error.status !== undefined)
    return new CommaApiError(
      error.status,
      error.message,
      (typeof error.detail === "object" && error.detail !== null
        ? error.detail
        : { error: error.code }) as CommaApiErrorBody
    );
  return error instanceof Error ? error : new Error(String(error));
}

export function clientTimezone(): { client_timezone?: string } {
  try {
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    return timezone ? { client_timezone: timezone } : {};
  } catch {
    return {};
  }
}

/** Main's word for a stream it ended because the session's credential was replaced while it was open. */
const credentialRenewed = (error: CoreError) =>
  error.code === "network" && /Session lease changed/.test(error.message);

const wait = (waitMs: number | undefined) =>
  waitMs === undefined ? "" : `?${new URLSearchParams({ wait: String(waitMs) })}`;

export function createChatApi(ctx: Ctx, account: Account, env: ChatEnv): ChatApi {
  const lift = <A>(effect: Effect.Effect<A, CoreError>): Effect.Effect<A, Error> =>
    effect.pipe(Effect.mapError(asApiError));
  const json = <S extends z.ZodType>(
    method: "GET" | "POST" | "PATCH",
    path: string,
    schema: S,
    body?: unknown
  ) => lift(ctx.api.request(account, method, path, schema, body));
  const bytes = (method: "GET" | "POST", path: string, body?: unknown) =>
    lift(
      ctx.api
        .raw(account, method, path, {
          headers: body === undefined ? [] : [["content-type", "application/json"]],
          body: body === undefined ? null : utf8(JSON.stringify(body)),
        })
        .pipe(
          Effect.map(
            (response) =>
              new Blob([response.body as Uint8Array<ArrayBuffer>], {
                type: header(response, "content-type") ?? "",
              })
          )
        )
    );
  const stream = (path: string, onEvent: (value: unknown, name: string) => void) =>
    lift(
      Effect.scoped(
        Effect.gen(function* () {
          const body = yield* ctx.api.stream(account, path);
          yield* readEvents(body, (value, name) =>
            Effect.try({
              try: () => onEvent(value, name ?? "message"),
              catch: (error) =>
                new CoreError(
                  "bad_response",
                  error instanceof Error ? error.message : String(error)
                ),
            })
          );
        })
      ).pipe(
        // Electron's Main ends a stream whose credential it replaced (the same session, renewed): opened again at once
        // under the current one, as a window's stream is, not after a network backoff. Once: a session that is gone
        // fails the reopen.
        Effect.retry({ times: 1, while: credentialRenewed })
      )
    );
  return {
    // Each run asks again, with the account's credential as it is then.
    bootstrapWorkspace: Effect.suspend(() =>
      json("POST", "/v1/comma/me/bootstrap", commaWorkspaceBootstrapSchema, {})
    ),
    listWorkspaces: Effect.suspend(() =>
      json("GET", "/v1/comma/workspaces", commaPageSchema(commaWorkspaceSchema)).pipe(
        Effect.map((page) => page.data)
      )
    ),
    ensureGroupChat: (groupId) =>
      json(
        "POST",
        route`/v1/comma/groups/${groupId}/assistant-chat`,
        commaConversationSchema,
        {}
      ),
    acceptTaskReview: (groupId, conversationId, reviewVersion) =>
      json(
        "POST",
        `${conversationPath(groupId, conversationId)}/accept`,
        commaConversationSchema,
        {
          review_version: reviewVersion,
        }
      ),
    setTaskStatus: (groupId, conversationId, status, expectedUpdatedAt) =>
      json(
        "POST",
        `${conversationPath(groupId, conversationId)}/status`,
        commaConversationSchema,
        {
          status,
          expected_updated_at: expectedUpdatedAt,
        }
      ),
    listMessages: (groupId, conversationId, query) => {
      const params = new URLSearchParams({ limit: String(query.limit) });
      if (query.before !== undefined) params.set("before", String(query.before));
      if (query.after !== undefined) params.set("after", String(query.after));
      if (query.view !== undefined) params.set("view", query.view);
      return json(
        "GET",
        `${conversationPath(groupId, conversationId)}/messages?${params}`,
        commaMessagePageSchema
      ).pipe(
        Effect.map((page) => ({
          messages: page.data,
          covered: page.covered ?? undefined,
          bounds: page.bounds ?? undefined,
          hasOlder: page.has_older === true,
        }))
      );
    },
    pollConversation: (groupId, conversationId, opts = {}) =>
      lift(
        ctx.api
          .get(
            account,
            conversationPath(groupId, conversationId),
            commaConversationSchema,
            opts.etag
          )
          .pipe(
            Effect.map((answer) =>
              answer.notModified
                ? { notModified: true, ...(opts.etag ? { etag: opts.etag } : {}) }
                : {
                    notModified: false,
                    conversation: answer.value,
                    ...((answer.etag ?? opts.etag)
                      ? { etag: (answer.etag ?? opts.etag)! }
                      : {}),
                  }
            )
          )
      ),
    listWorkspaceSkills: (workspaceId) =>
      json(
        "GET",
        route`/v1/comma/workspaces/${workspaceId}/skills`,
        z.object({ data: z.array(commaSkillSchema) }).passthrough()
      ).pipe(Effect.map((page) => page.data)),
    uploadGroupFile: (groupId, attrs) =>
      Effect.gen(function* () {
        const boundary = `----comma-${env.uuid()}`;
        const file = new Uint8Array(
          yield* Effect.promise(() => attrs.data.arrayBuffer())
        );
        const name = attrs.name.replace(/["\r\n]/g, "_");
        const head = utf8(
          `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${name}"\r\n` +
            `Content-Type: ${attrs.data.type || "application/octet-stream"}\r\n\r\n`
        );
        const tail = utf8(`\r\n--${boundary}--\r\n`);
        const body = new Uint8Array(head.length + file.length + tail.length);
        body.set(head, 0);
        body.set(file, head.length);
        body.set(tail, head.length + file.length);
        return yield* lift(
          ctx.api
            .raw(account, "POST", route`/v1/comma/groups/${groupId}/files`, {
              headers: [["content-type", `multipart/form-data; boundary=${boundary}`]],
              body,
            })
            .pipe(
              Effect.flatMap((response) => {
                const out = commaGroupFileSchema.safeParse(
                  JSON.parse(new TextDecoder().decode(response.body))
                );
                return out.success
                  ? Effect.succeed(out.data)
                  : Effect.fail(
                      new CoreError("bad_response", "an upload's answer was not a file")
                    );
              })
            )
        );
      }),
    fetchGroupFile: (groupId, path) =>
      bytes(
        "GET",
        `${route`/v1/comma/groups/${groupId}/files`}?${new URLSearchParams({ path })}`
      ),
    fetchAgentBlob: (groupId, agentId, ref) =>
      bytes("POST", route`/v1/comma/groups/${groupId}/agents/${agentId}/resources`, {
        ref,
      }),
    sendMessage: (groupId, conversationId, attrs) => {
      const answer = attrs.questionAnswer;
      const message =
        attrs.localFiles?.length || answer
          ? {
              content: [
                ...(attrs.text ? [{ type: "text" as const, text: attrs.text }] : []),
                ...(attrs.localFiles ?? []).map((file) => ({
                  type: "local_file" as const,
                  local_file_ref: file.localFileRef,
                  display_name: file.displayName,
                  media_type: file.mediaType,
                  size: file.size,
                })),
                ...(answer
                  ? [
                      {
                        type: "question_answer" as const,
                        question_message_id: answer.questionMessageId,
                        choice_ids: answer.choiceIds,
                        ...(answer.other !== undefined ? { other: answer.other } : {}),
                        ...(answer.skipped ? { skipped: true } : {}),
                      },
                    ]
                  : []),
              ],
            }
          : { type: "text" as const, text: attrs.text };
      return json(
        "POST",
        `${conversationPath(groupId, conversationId)}/messages`,
        commaConversationSchema,
        {
          message,
          client_request_id: attrs.clientRequestId ?? env.uuid(),
          ...(attrs.replyToMessageId
            ? { reply_to_message_id: attrs.replyToMessageId }
            : {}),
          ...(attrs.clientDeviceId ? { client_device_id: attrs.clientDeviceId } : {}),
          ...clientTimezone(),
          ...(attrs.skills?.length ? { skills: attrs.skills } : {}),
        }
      );
    },
    streamConversationEvents: (groupId, conversationId, opts) =>
      stream(
        `${conversationPath(groupId, conversationId)}/events${wait(opts.waitMs)}`,
        (value, name) => opts.onEvent(commaConversationEventSchema.parse(value), name)
      ),
    streamConversationListEvents: (groupId, opts) => {
      const query = new URLSearchParams();
      if (opts.waitMs !== undefined) query.set("wait", String(opts.waitMs));
      if (opts.conversationId) query.set("conversation_id", opts.conversationId);
      const search = query.size ? `?${query}` : "";
      return stream(
        route`/v1/comma/groups/${groupId}/conversations/events` + search,
        (value, name) => {
          if (name === "task_participant_statuses") {
            opts.onParticipantStatuses?.(
              commaTaskParticipantStatusesSchema.parse(value)
            );
            return;
          }
          opts.onEvent(commaConversationListEventSchema.parse(value));
        }
      );
    },
  };
}
