// A chat file's bytes (`files.read`): a message's attachment, an agent's blob, an image uploaded to the group, or the
// person's own avatar, read for the account's session and answered whole with the type the server gave. The UI shows,
// saves, copies or opens them; it never names the request. Every source here is bounded by the attachment limit
// (10 MB), so the bytes come back through the core's channel like any answer.
//
// Bounds: one request per call, stopped when the UI lets the call go; nothing kept and no automatic retry (the person's
// next action reads again); an answer over 10 MB fails `too_large`; a read is given up after 10 minutes.
import {
  chatAgentBlobRefSchema,
  chatAttachmentDownloadMaxBytes,
} from "@comma/chat-contract";
import { CoreError, utf8 } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { isGroupImagePreviewPath } from "./chat/model/protocol.ts";
import type { FileBytes } from "./contract.ts";

type FileRequest =
  | { method: "GET"; path: string }
  | { method: "POST"; path: string; body: unknown };
import type { Ctx } from "./ctx.ts";
import { header } from "./host.ts";

export const FILE_READ_TIMEOUT_MS = 600_000;

const id = z.string().min(1).max(160);
export const fileSourceSchema = z.discriminatedUnion("source", [
  z
    .object({
      source: z.literal("attachment"),
      group: id,
      conversation: id,
      message: id,
      index: z.number().int().nonnegative(),
    })
    .strict(),
  z
    .object({
      source: z.literal("agent-blob"),
      group: id,
      agent: id,
      blobRef: chatAgentBlobRefSchema,
    })
    .strict(),
  z
    .object({
      source: z.literal("group-file"),
      group: id,
      path: z.string().max(1024).refine(isGroupImagePreviewPath),
    })
    .strict(),
  z.object({ source: z.literal("avatar"), revision: id }).strict(),
]);

/**
 * `pendingAvatar` answers an avatar revision the server does not have yet: one on its way up, which the profile shows
 * meanwhile (profile.ts).
 */
export function registerFiles(
  ctx: Ctx,
  pendingAvatar: (revision: string) => FileBytes | undefined = () => undefined
): void {
  ctx.kernel.calls({
    "files.read": {
      // A read the UI let go (the preview closed, the person cancelled) stops its request.
      cancellable: true,
      run: (p) => {
        const parsed = fileSourceSchema.safeParse(p);
        if (!parsed.success) throw CoreError.invalid("not a file source");
        const local =
          parsed.data.source === "avatar"
            ? pendingAvatar(parsed.data.revision)
            : undefined;
        return local ? Effect.succeed(local) : read(ctx, parsed.data);
      },
    },
  });
}

/** The request that reads `source`: for the core's own read, and for a download to the device (downloads.ts). */
export function fileRequest(source: z.output<typeof fileSourceSchema>): FileRequest {
  const groupPath =
    source.source === "avatar" ? "" : route`/v1/comma/groups/${source.group}`;
  return source.source === "avatar"
    ? { method: "GET" as const, path: route`/v1/comma/me/avatar/${source.revision}` }
    : source.source === "attachment"
      ? {
          method: "GET" as const,
          path: `${groupPath}${route`/conversations/${source.conversation}/messages/${source.message}/attachments/${String(source.index)}`}`,
        }
      : source.source === "agent-blob"
        ? {
            method: "POST" as const,
            path: `${groupPath}${route`/agents/${source.agent}/resources`}`,
            body: { ref: source.blobRef },
          }
        : {
            method: "GET" as const,
            path: `${groupPath}/files?${new URLSearchParams({ path: source.path })}`,
          };
}

function read(
  ctx: Ctx,
  source: z.output<typeof fileSourceSchema>
): Effect.Effect<FileBytes, CoreError> {
  const request = fileRequest(source);
  return Effect.gen(function* () {
    const account = yield* ctx.session.account();
    const response = yield* ctx.api.raw(account, request.method, request.path, {
      timeoutMs: FILE_READ_TIMEOUT_MS,
      ...("body" in request
        ? {
            headers: [["content-type", "application/json"]] as [string, string][],
            body: utf8(JSON.stringify(request.body)),
          }
        : {}),
    });
    if (response.body.byteLength > chatAttachmentDownloadMaxBytes)
      return yield* Effect.fail(
        new CoreError("too_large", "The file is larger than 10 MB.")
      );
    return {
      bytes: response.body,
      type: header(response, "content-type") ?? "",
    };
  });
}
