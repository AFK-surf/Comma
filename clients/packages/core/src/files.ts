// A chat file's bytes (`files.read`): a message's attachment, an agent's blob, an image uploaded to the group, or the
// person's own avatar, read for the account's session and answered whole with the type the server gave. The UI shows,
// saves, copies or opens them; it never names the request. A read is whole, so it is bounded at 10 MB and the bytes
// come back through the core's channel like any answer; a larger attachment plays or downloads in ranges instead
// (`fileStream`, file-streams.ts). It asks for no more than its bound: an attachment, which can be of any size, answers
// that span and names its whole size; the other sources are bounded by the server and answer whole.
//
// The desktop app also saves a chat file into Downloads (`files.save`): Main reads it, a message's attachment from its
// media URL and any other file under the session, and writes it as it arrives, so a file of any size saves without the
// core or a window holding it. Elsewhere (the web) a browser downloads a message's attachment from its media URL itself
// (`files.link`). A media URL is the blob store's signed URL: the bytes never pass through the Comma server.
//
// A message's attachment in a Task a station hosts (`hosted`) is read from its station: whole and bounded as a read is,
// or a part at a time (HOSTED_PART, its station's `/parts`) for a span or a save, at any size. The desktop saves it
// into Downloads a part at a time (Main's `saveOpen` / `saveWrite` / `saveClose`). It has no link (`no_link`): the
// web reads it a part at a time and hands it to the browser.
//
// Bounds: one request per call, stopped when the UI lets the call go; nothing kept and no automatic retry (the person's
// next action reads again); a file over 10 MB fails `too_large` after at most 10 MB and a byte arrived; a read is given
// up after 10 minutes.
import {
  chatAgentBlobRefSchema,
  chatAttachmentDownloadMaxBytes,
} from "@comma/chat-contract";
import { CoreError, type HostError, utf8 } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { isGroupImagePreviewPath } from "./chat/model/protocol.ts";
import type { FileBytes, FileRange } from "./contract.ts";

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

/** The most of a file of a Task a station hosts one read of a part takes: its station's part. */
export const HOSTED_PART = 8 * 1024 * 1024;

/** The files of Tasks Comma's server does not keep (a Task a station hosts): read where they are kept. */
export interface HostedFiles {
  owns(conversation: string): boolean;
  /** File `index` of message `message`: at most `max` bytes, failing `too_large` past them. */
  readAttachment(
    group: string,
    conversation: string,
    message: string,
    index: number,
    max: number
  ): Effect.Effect<{ bytes: Uint8Array; type: string }, CoreError>;
  /** Up to `length` bytes of it from `offset` (at most HOSTED_PART), and its whole size. */
  readAttachmentPart(
    group: string,
    conversation: string,
    message: string,
    index: number,
    offset: number,
    length: number
  ): Effect.Effect<{ bytes: Uint8Array; type: string; size: number }, CoreError>;
}

/**
 * Reads attachment `source` of a Task `hosted` keeps a part at a time from its start, giving each part to `write` in
 * order: its whole size once the last is written. An empty file has no part.
 */
export function readHostedParts(
  hosted: HostedFiles,
  source: { group: string; conversation: string; message: string; index: number },
  write: (bytes: Uint8Array, size: number) => Effect.Effect<void, CoreError | HostError>
): Effect.Effect<number, CoreError | HostError> {
  return Effect.gen(function* () {
    let offset = 0;
    for (;;) {
      const part = yield* hosted.readAttachmentPart(
        source.group,
        source.conversation,
        source.message,
        source.index,
        offset,
        HOSTED_PART
      );
      if (part.bytes.byteLength > 0) yield* write(part.bytes, part.size);
      offset += part.bytes.byteLength;
      if (offset >= part.size) return part.size;
      // A part that gave nothing would be asked for again forever: the file changed under it.
      if (part.bytes.byteLength === 0)
        return yield* Effect.fail(
          new CoreError("not_found", "The file changed on the machine; open it again.")
        );
    }
  });
}

type Source = z.output<typeof fileSourceSchema>;

/** `source` when it is a message's attachment in a Task `hosted` keeps. */
function hostedAttachment(
  hosted: HostedFiles | undefined,
  source: Source
): (Source & { source: "attachment" }) | null {
  return source.source === "attachment" && hosted?.owns(source.conversation)
    ? source
    : null;
}

/**
 * `pendingAvatar` answers an avatar revision the server does not have yet: one on its way up, which the profile shows
 * meanwhile (profile.ts). `hosted` reads the files of Tasks Comma's server does not keep.
 */
export function registerFiles(
  ctx: Ctx,
  pendingAvatar: (revision: string) => FileBytes | undefined = () => undefined,
  hosted: () => HostedFiles | undefined = () => undefined
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
        return local ? Effect.succeed(local) : readFile(ctx, hosted(), parsed.data);
      },
    },
    "files.readRange": {
      cancellable: true,
      run: (p) => {
        const parsed = rangeSchema.safeParse(p);
        if (!parsed.success) throw CoreError.invalid("not a span of a file");
        return readRange(
          ctx,
          hosted(),
          parsed.data.source,
          parsed.data.offset,
          parsed.data.length
        );
      },
    },
    "files.link": {
      run: (p) => {
        const parsed = fileSourceSchema.safeParse(p);
        if (!parsed.success) throw CoreError.invalid("not a file source");
        return link(ctx, hosted(), parsed.data);
      },
    },
    "files.save": {
      run: (p) => {
        const parsed = saveSchema.safeParse(p);
        if (!parsed.success) throw CoreError.invalid("not a file to save");
        return save(ctx, hosted(), parsed.data.source, parsed.data.name);
      },
    },
  });
}

const saveSchema = z.object({
  source: fileSourceSchema,
  name: z.string().min(1).max(1024),
});
const rangeSchema = z.object({
  source: fileSourceSchema,
  offset: z.number().int().nonnegative(),
  length: z.number().int().positive().max(chatAttachmentDownloadMaxBytes),
});
const CONTENT_RANGE = /^bytes (?:\d+-\d+|\*)\/(\d+)$/;

/**
 * The span a `Range` names: a server that serves ranges (an attachment) answers just it; one that does not answers the
 * whole file, bounded as `files.read`, and the span is cut from it. A span past the end is empty.
 */
function readRange(
  ctx: Ctx,
  hosted: HostedFiles | undefined,
  source: Source,
  offset: number,
  length: number
): Effect.Effect<FileRange, CoreError> {
  const onStation = hostedAttachment(hosted, source);
  // Its station answers the span a part at a time: up to its part of it.
  if (onStation)
    return hosted!.readAttachmentPart(
      onStation.group,
      onStation.conversation,
      onStation.message,
      onStation.index,
      offset,
      length
    );
  const request = fileRequest(source);
  return Effect.gen(function* () {
    const account = yield* ctx.session.account();
    const response = yield* ctx.api
      .raw(account, request.method, request.path, {
        timeoutMs: FILE_READ_TIMEOUT_MS,
        headers: [
          ["range", `bytes=${offset}-${offset + length - 1}`],
          ...("body" in request
            ? ([["content-type", "application/json"]] as [string, string][])
            : []),
        ],
        ...("body" in request ? { body: utf8(JSON.stringify(request.body)) } : {}),
      })
      .pipe(
        Effect.catchIf(
          (error) => error.status === 416,
          () => Effect.succeed(null)
        )
      );
    if (response === null) return { bytes: new Uint8Array(), type: "", size: offset };
    const type = header(response, "content-type") ?? "";
    const total = header(response, "content-range")?.match(CONTENT_RANGE)?.[1];
    if (response.status === 206 && total !== undefined)
      return { bytes: response.body, type, size: Number(total) };
    if (response.body.byteLength > chatAttachmentDownloadMaxBytes)
      return yield* Effect.fail(
        new CoreError("too_large", "The file is larger than 10 MB.")
      );
    return {
      bytes: response.body.subarray(offset, offset + length),
      type,
      size: response.body.byteLength,
    };
  });
}

/** A hosted attachment whole, bounded as a read is. */
function hostedWhole(hosted: HostedFiles, source: Source & { source: "attachment" }) {
  return hosted
    .readAttachment(
      source.group,
      source.conversation,
      source.message,
      source.index,
      chatAttachmentDownloadMaxBytes
    )
    .pipe(
      Effect.mapError((error) =>
        error.code === "too_large"
          ? new CoreError("too_large", "The file is larger than 10 MB.")
          : error
      )
    );
}

const fromHost = (error: HostError) => CoreError.host(error);

function save(
  ctx: Ctx,
  hosted: HostedFiles | undefined,
  source: Source,
  fileName: string
): Effect.Effect<{ downloadRef: string; fileName: string } | null, CoreError> {
  const desktop = ctx.host.desktop;
  const onStation = hostedAttachment(hosted, source);
  const request = fileRequest(source);
  return Effect.gen(function* () {
    if (!desktop)
      return yield* Effect.fail(new CoreError("unsupported", "No Downloads folder."));
    // Read from its station a part at a time, it is written into Downloads as it is read; a read that fails leaves
    // nothing of it there.
    if (onStation) {
      const { id: saving } = yield* desktop
        .saveOpen(fileName)
        .pipe(Effect.mapError(fromHost));
      yield* readHostedParts(hosted!, onStation, (bytes) =>
        desktop.saveWrite(saving, bytes).pipe(Effect.mapError(fromHost))
      ).pipe(
        Effect.mapError((error) =>
          error instanceof CoreError ? error : CoreError.host(error)
        ),
        Effect.tapError(() => Effect.ignore(desktop.saveClose(saving, false)))
      );
      return yield* desktop.saveClose(saving, true).pipe(Effect.mapError(fromHost));
    }
    if (request.method !== "GET")
      return yield* Effect.fail(CoreError.invalid("not a file read with a GET"));
    const account = yield* ctx.session.account();
    // An attachment is read from its media URL, so its bytes never pass through the Comma server; any other file
    // through the API under the session.
    const from =
      source.source === "attachment"
        ? { url: (yield* mintMediaUrl(ctx, account, request.path)).url }
        : { path: request.path, lease: account.lease };
    const saved = yield* desktop
      .saveStream({ ...from, fileName })
      .pipe(Effect.mapError((error) => CoreError.host(error)));
    if (saved && "status" in saved) {
      if (saved.status === 401) ctx.session.rejected(account.lease, 401);
      return yield* Effect.fail(
        new CoreError(saved.code, "The server refused the file.", saved.status)
      );
    }
    return saved;
  });
}

const mediaSchema = z.object({
  url: z.string().regex(/^https?:\/\//),
  expires_at: z.number(),
});

/**
 * The media URL for the attachment `path` names (`POST …/media`), and when it expires: a URL the blob store signed, which
 * anyone holding it reads the attachment from until then, with no session.
 */
export function mintMediaUrl(ctx: Ctx, account: Account, path: string) {
  return ctx.api.request(account, "POST", `${path}/media`, mediaSchema).pipe(
    Effect.map((media) => ({
      url: media.url,
      expiresAtMs: media.expires_at * 1000,
    }))
  );
}

/**
 * A URL a browser downloads a message's attachment from itself, at any size: its media URL, which answers it as an
 * attachment under its own name. Not on the desktop, which saves through Main (`files.save`), nor for other sources.
 */
function link(
  ctx: Ctx,
  hosted: HostedFiles | undefined,
  source: Source
): Effect.Effect<{ url: string }, CoreError> {
  return Effect.gen(function* () {
    if (ctx.host.desktop)
      return yield* Effect.fail(
        new CoreError("unsupported", "The desktop saves files.")
      );
    if (hostedAttachment(hosted, source))
      return yield* Effect.fail(
        new CoreError(
          "no_link",
          "A file on a machine has no link to download it from: it is read whole (`files.read`)."
        )
      );
    if (source.source !== "attachment")
      return yield* Effect.fail(
        new CoreError("unsupported", "Not a message's attachment.")
      );
    const account = yield* ctx.session.account();
    const media = yield* mintMediaUrl(ctx, account, fileRequest(source).path);
    return { url: media.url };
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

/**
 * The whole file, asked as its span up to one byte past the bound: an attachment answers no more than that and names its
 * whole size, so a larger one fails without the rest of it arriving.
 */
/** A chat file whole (`files.read`): one a Task a station hosts from its station (`hosted`), else from Comma's server. */
export function readFile(
  ctx: Ctx,
  hosted: HostedFiles | undefined,
  source: Source
): Effect.Effect<FileBytes, CoreError> {
  // Its station answers it whole, bounded as a read is.
  const onStation = hostedAttachment(hosted, source);
  if (onStation) return hostedWhole(hosted!, onStation);
  return readRange(ctx, hosted, source, 0, chatAttachmentDownloadMaxBytes + 1).pipe(
    Effect.flatMap((span) =>
      span.size > chatAttachmentDownloadMaxBytes
        ? Effect.fail(new CoreError("too_large", "The file is larger than 10 MB."))
        : Effect.succeed({ bytes: span.bytes, type: span.type })
    )
  );
}
