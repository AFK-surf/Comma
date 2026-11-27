// Chat's requests (chat/api.ts) made by the core for one account: each through the host, which adds the session's
// credential (Electron's Main) or cookie (the web); each answer read through its schema. A request the server refused
// fails with a CommaApiError (its status and body); one that got no answer fails with a plain Error, which the
// engine treats as the network. Interrupting one stops the request.
import { lazySchema } from "@comma/chat-contract";
import { CoreError, utf8 } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import type { Account } from "../account.ts";
import { REQUEST_TIMEOUT_MS, route } from "../api.ts";
import {
  commaConversationEventSchema,
  commaConversationListEventSchema,
  commaConversationSchema,
  type CommaGroupFile,
  commaGroupFileSchema,
  commaMessagePageSchema,
  commaSkillSchema,
  commaPageSchema,
  commaTaskParticipantStatusesSchema,
  commaWorkspaceBootstrapSchema,
  commaWorkspaceSchema,
} from "../comma/api-schemas.ts";
import type { Ctx } from "../ctx.ts";
import {
  conversationBasePath,
  isTaskTogether,
  memberRouteGone,
  membershipsKnown,
} from "../collaborations.ts";
import { isTaskFilePath, taskFileTask } from "./model/protocol.ts";
import type { ClientLocation } from "../location-sharing.ts";
import { header } from "../host.ts";
import { readEvents } from "../sse.ts";
import { type ChatApi, CommaApiError, type CommaApiErrorBody } from "./api.ts";
import type { ChatEnv } from "./env.ts";

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

function withClientLocation(location: ClientLocation | undefined): {
  client_location?: ClientLocation;
} {
  return location ? { client_location: location } : {};
}

/** Main's word for a stream it ended because the session's credential was replaced while it was open. */
const credentialRenewed = (error: CoreError) =>
  error.code === "network" && /Session lease changed/.test(error.message);

/**
 * Messages a conversation stream's snapshot carries at most: its newest ones, as a window first shows them. A stream
 * opens again every window (30 s) and on each new message; one asked after the newest seq held carries only what came
 * since, and what is older than this the channel pages in.
 */
const STREAM_MESSAGE_LIMIT = 24;
const mutationQuery = `?message_limit=${STREAM_MESSAGE_LIMIT}`;

const uploadSchema = lazySchema(() =>
  z.object({
    upload_id: z.string().min(1),
    part_size: z.number().int().positive(),
  })
);
const uploadPartSchema = lazySchema(() => z.object({ etag: z.string().min(1) }));

/** An upload's JSON answer, read through `schema`. */
const parsed = <S extends z.ZodType>(schema: S, body: Uint8Array) => {
  const out = schema.safeParse(JSON.parse(new TextDecoder().decode(body)));
  return out.success
    ? Effect.succeed(out.data as z.output<S>)
    : Effect.fail(
        new CoreError("bad_response", "an upload's answer was not as expected")
      );
};

/** A path may be a function: a Task's is named once the account's memberships are known. */
const at = (path: string | (() => string)) =>
  typeof path === "string" ? path : path();

export function createChatApi(
  ctx: Ctx,
  account: Account,
  env: ChatEnv,
  clientLocation: () => ClientLocation | undefined = () => undefined
): ChatApi {
  // A Task the account joined as a member is read and written through its member route.
  const conversationPath = (group: string, conversation: string) =>
    conversationBasePath(ctx, group, conversation);
  // A member route that finds its Task gone (404): the account is out of it; its memberships are read again.
  const memberGone = (path: string, error: CoreError) => {
    const task = /^\/v1\/comma\/collaborations\/[^/]+\/([^/?]+)/.exec(path)?.[1];
    return error.status === 404 && task
      ? memberRouteGone(ctx, decodeURIComponent(task))
      : Effect.void;
  };
  // Every request first knows the account's memberships, so its path is the right one.
  const lift = <A>(effect: Effect.Effect<A, CoreError>): Effect.Effect<A, Error> =>
    membershipsKnown(ctx).pipe(Effect.andThen(effect), Effect.mapError(asApiError));
  const json = <S extends z.ZodType>(
    method: "GET" | "POST" | "PATCH" | "PUT",
    path: string | (() => string),
    schema: S,
    body?: unknown
  ) =>
    lift(
      Effect.suspend(() => {
        const named = at(path);
        return ctx.api
          .request(account, method, named, schema, body)
          .pipe(Effect.tapError((error) => memberGone(named, error)));
      })
    );
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
  const stream = (
    path: string | (() => string),
    onEvent: (value: unknown, name: string) => void
  ) =>
    lift(
      Effect.scoped(
        Effect.gen(function* () {
          const named = at(path);
          const body = yield* ctx.api
            .stream(account, named)
            .pipe(Effect.tapError((error) => memberGone(named, error)));
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
  // A file sent in parts: `POST …/uploads` begins it, a `PUT` per part, then `…/complete`. No request carries more
  // than a part, so a file larger than a proxy lets one request carry still arrives.
  const uploadInParts = (
    groupId: string,
    file: { name: string; size: number },
    read: (offset: number, length: number) => Effect.Effect<Uint8Array, CoreError>
  ): Effect.Effect<CommaGroupFile, Error> =>
    Effect.gen(function* () {
      const upload = yield* json(
        "POST",
        route`/v1/comma/groups/${groupId}/uploads`,
        uploadSchema,
        { size: file.size }
      );
      const path = route`/v1/comma/groups/${groupId}/uploads/${upload.upload_id}`;
      const etags: string[] = [];
      for (let offset = 0; offset < file.size; offset += upload.part_size) {
        const body = yield* lift(
          read(offset, Math.min(upload.part_size, file.size - offset))
        );
        const answer = yield* lift(
          ctx.api.raw(account, "PUT", `${path}/parts/${etags.length + 1}`, {
            headers: [["content-type", "application/octet-stream"]],
            body,
            // The request's own bound plus a second for every 32 KiB: a slow uplink still finishes.
            timeoutMs: REQUEST_TIMEOUT_MS + Math.ceil(body.length / 32_768) * 1_000,
          })
        );
        etags.push((yield* lift(parsed(uploadPartSchema, answer.body))).etag);
      }
      const done = yield* lift(
        ctx.api.raw(account, "POST", `${path}/complete`, {
          headers: [["content-type", "application/json"]],
          body: utf8(JSON.stringify({ name: file.name, etags })),
          // The server reads the whole file back once to hash it.
          timeoutMs: REQUEST_TIMEOUT_MS + Math.ceil(file.size / 8_388_608) * 1_000,
        })
      );
      return yield* lift(parsed(commaGroupFileSchema, done.body));
    });
  // A file into a Task together's own folder (its host's or a member's): the raw bytes, named in the query.
  const uploadTaskFile = (
    groupId: string,
    conversationId: string,
    attrs: { data: Blob; name: string }
  ): Effect.Effect<CommaGroupFile, Error> =>
    Effect.gen(function* () {
      const body = new Uint8Array(
        yield* Effect.promise(() => attrs.data.arrayBuffer())
      );
      const answer = yield* lift(
        ctx.api.raw(
          account,
          "POST",
          `${route`/v1/comma/collaborations/${groupId}/${conversationId}/files`}?${new URLSearchParams({ name: attrs.name })}`,
          {
            headers: [["content-type", "application/octet-stream"]],
            body,
            timeoutMs: REQUEST_TIMEOUT_MS + Math.ceil(body.length / 32_768) * 1_000,
          }
        )
      );
      return yield* lift(parsed(commaGroupFileSchema, answer.body));
    });
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
        () => `${conversationPath(groupId, conversationId)}/accept${mutationQuery}`,
        commaConversationSchema,
        {
          review_version: reviewVersion,
        }
      ),
    setTaskStatus: (groupId, conversationId, status, expectedUpdatedAt) =>
      json(
        "POST",
        () => `${conversationPath(groupId, conversationId)}/status${mutationQuery}`,
        commaConversationSchema,
        {
          status,
          expected_updated_at: expectedUpdatedAt,
        }
      ),
    setTaskRun: (groupId, conversationId, run) =>
      json(
        "PUT",
        () => `${conversationPath(groupId, conversationId)}/run${mutationQuery}`,
        commaConversationSchema,
        {
          runs_on:
            run.runsOn.kind === "station"
              ? { kind: "station", device_id: run.runsOn.deviceId }
              : { kind: run.runsOn.kind },
          model:
            run.model === null
              ? null
              : run.model.kind === "catalog"
                ? {
                    kind: "catalog",
                    model: run.model.model,
                    // As a model named in a message runs: a subscription first, an API key when none can.
                    allow_paid: true,
                    ...(run.model.reasoningEffort
                      ? { reasoning_effort: run.model.reasoningEffort }
                      : {}),
                  }
                : {
                    kind: "runtime",
                    provider: run.model.provider,
                    ...(run.model.model ? { model: run.model.model } : {}),
                  },
        }
      ),
    listMessages: (groupId, conversationId, query) => {
      const params = new URLSearchParams({ limit: String(query.limit) });
      if (query.before !== undefined) params.set("before", String(query.before));
      if (query.after !== undefined) params.set("after", String(query.after));
      if (query.view !== undefined) params.set("view", query.view);
      return json(
        "GET",
        () => `${conversationPath(groupId, conversationId)}/messages?${params}`,
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
        Effect.suspend(() =>
          ctx.api
            .get(
              account,
              opts.afterSeq === undefined
                ? conversationPath(groupId, conversationId)
                : `${conversationPath(groupId, conversationId)}?after_seq=${opts.afterSeq}`,
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
        )
      ),
    listWorkspaceSkills: (workspaceId) =>
      json(
        "GET",
        route`/v1/comma/workspaces/${workspaceId}/skills`,
        z.object({ data: z.array(commaSkillSchema) }).passthrough()
      ).pipe(Effect.map((page) => page.data)),
    uploadGroupFile: (groupId, attrs) =>
      attrs.conversation !== undefined && isTaskTogether(ctx, attrs.conversation)
        ? uploadTaskFile(groupId, attrs.conversation, attrs)
        : Effect.gen(function* () {
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
                  headers: [
                    ["content-type", `multipart/form-data; boundary=${boundary}`],
                  ],
                  body,
                  // As a part of a local file: a slow uplink, shared by the photos picked together, still finishes.
                  timeoutMs:
                    REQUEST_TIMEOUT_MS + Math.ceil(body.length / 32_768) * 1_000,
                })
                .pipe(
                  Effect.flatMap((response) => {
                    const out = commaGroupFileSchema.safeParse(
                      JSON.parse(new TextDecoder().decode(response.body))
                    );
                    return out.success
                      ? Effect.succeed(out.data)
                      : Effect.fail(
                          new CoreError(
                            "bad_response",
                            "an upload's answer was not a file"
                          )
                        );
                  })
                )
            );
          }),
    ...(ctx.host.uploadsLocalFiles && ctx.host.readLocalFile
      ? {
          uploadLocalFile: (
            groupId: string,
            attrs: {
              localFileRef: string;
              name: string;
              size: number;
              conversation?: string | undefined;
            }
          ) => {
            const read = ctx.host.readLocalFile!.bind(ctx.host);
            // A Task together's file goes whole into its own folder (25 MB at most, which the server checks).
            if (
              attrs.conversation !== undefined &&
              isTaskTogether(ctx, attrs.conversation)
            ) {
              const conversation = attrs.conversation;
              return lift(
                read(attrs.localFileRef, 0, attrs.size).pipe(
                  Effect.mapError((error) => new CoreError("network", error.message))
                )
              ).pipe(
                Effect.flatMap((whole) =>
                  uploadTaskFile(groupId, conversation, {
                    data: new Blob([whole as Uint8Array<ArrayBuffer>]),
                    name: attrs.name,
                  })
                )
              );
            }
            return uploadInParts(groupId, attrs, (offset, length) =>
              read(attrs.localFileRef, offset, length).pipe(
                Effect.mapError((error) => new CoreError("network", error.message))
              )
            );
          },
        }
      : {}),
    storeConversationFile: (groupId, file) =>
      json(
        "POST",
        route`/v1/comma/groups/${groupId}/conversations/${file.conversationId}/messages/${file.messageId}/attachments/${String(file.index)}/workspace-file`,
        commaGroupFileSchema,
        {}
      ),
    fetchGroupFile: (groupId, path, options) => {
      const task = isTaskFilePath(path)
        ? (taskFileTask(path) ?? options?.taskId)
        : undefined;
      const endpoint = task
        ? route`/v1/comma/collaborations/${groupId}/${task}/files`
        : route`/v1/comma/groups/${groupId}/files`;
      return bytes("GET", `${endpoint}?${new URLSearchParams({ path })}`);
    },
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
        () => `${conversationPath(groupId, conversationId)}/messages${mutationQuery}`,
        commaConversationSchema,
        {
          message,
          client_request_id: attrs.clientRequestId ?? env.uuid(),
          ...(attrs.replyToMessageId
            ? { reply_to_message_id: attrs.replyToMessageId }
            : {}),
          ...(attrs.clientDeviceId ? { client_device_id: attrs.clientDeviceId } : {}),
          ...(attrs.messageType ? { message_type: attrs.messageType } : {}),
          ...(attrs.clientEntry ? { client_entry: attrs.clientEntry } : {}),
          ...clientTimezone(),
          ...withClientLocation(clientLocation()),
          ...(attrs.skills?.length ? { skills: attrs.skills } : {}),
        }
      );
    },
    streamConversationEvents: (groupId, conversationId, opts) => {
      const query = new URLSearchParams({
        message_limit: String(STREAM_MESSAGE_LIMIT),
      });
      if (opts.afterSeq !== undefined) query.set("after_seq", String(opts.afterSeq));
      if (opts.waitMs !== undefined) query.set("wait", String(opts.waitMs));
      return stream(
        () => `${conversationPath(groupId, conversationId)}/events?${query}`,
        (value, name) => opts.onEvent(commaConversationEventSchema.parse(value), name)
      );
    },
    streamConversationListEvents: (groupId, opts) => {
      const query = new URLSearchParams();
      if (opts.waitMs !== undefined) query.set("wait", String(opts.waitMs));
      if (opts.conversationId) query.set("conversation_id", opts.conversationId);
      const search = query.size ? `?${query}` : "";
      // A member follows their one Task through its own stream.
      return stream(
        () =>
          (opts.conversationId &&
          conversationBasePath(ctx, groupId, opts.conversationId).startsWith(
            "/v1/comma/collaborations/"
          )
            ? `${conversationBasePath(ctx, groupId, opts.conversationId)}/events`
            : route`/v1/comma/groups/${groupId}/conversations/events`) + search,
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
