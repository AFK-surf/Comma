// A document's public link (the Share dialog of a document beside a chat) and a Group's active document links
// (Settings › Shared tasks). A document is its Task and its file name; its link shows the version the owner last
// shared.
//
// Each call is one request, and its answer is what the dialog or the list shows: nothing is kept here.
//
// Bounds: one request per call. A list call reads one page of at most 50 links.
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import { documentSharePageSchema, documentShareSchema } from "./comma/schemas.ts";
import type { DocumentShare } from "./contract.ts";
import type { Ctx } from "./ctx.ts";

const string = (raw: unknown, name: string): string => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > 1024)
    throw CoreError.invalid(`${name} is required`);
  return v;
};

const sharePath = (p: unknown) =>
  `${route`/v1/comma/groups/${string(p, "group")}/conversations/${string(p, "conversation")}`}/document-share`;
const named = (p: unknown) =>
  `?${new URLSearchParams({ file_name: string(p, "fileName") })}`;

/** Gives the core its calls for document links. */
export function documentShares(ctx: Ctx): void {
  const send = <S extends z.ZodType>(
    method: "GET" | "PUT" | "POST" | "DELETE",
    path: string,
    schema: S,
    body?: unknown
  ) =>
    ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, method, path, schema, body)
        )
      );
  ctx.kernel.calls({
    "documentShare.get": {
      run: (p) =>
        send("GET", `${sharePath(p)}${named(p)}`, documentShareSchema).pipe(
          Effect.map((share): DocumentShare | null => share),
          // No link: the document is not shared.
          Effect.catchIf(
            (e: CoreError) => e.status === 404,
            () => Effect.succeed(null)
          )
        ),
    },
    "documentShare.publish": {
      doing: true,
      run: (p) => {
        const index = (p as { index?: unknown } | null)?.index;
        if (typeof index !== "number" || !Number.isInteger(index) || index < 0)
          throw CoreError.invalid("index is required");
        return send("PUT", sharePath(p), documentShareSchema, {
          message_id: string(p, "message"),
          index,
        });
      },
    },
    "documentShare.reset": {
      doing: true,
      run: (p) => send("POST", `${sharePath(p)}/reset${named(p)}`, documentShareSchema),
    },
    "documentShare.revoke": {
      doing: true,
      run: (p) =>
        send(
          "DELETE",
          `${sharePath(p)}${named(p)}`,
          z.object({ revoked: z.literal(true) }).strip()
        ).pipe(Effect.as(null)),
    },
    "documentShares.list": {
      run: (p) => {
        const cursor = (p as { cursor?: unknown } | null)?.cursor;
        const query =
          typeof cursor === "string" && cursor
            ? `?${new URLSearchParams({ cursor })}`
            : "";
        return send(
          "GET",
          `${route`/v1/comma/groups/${string(p, "group")}/document-shares`}${query}`,
          documentSharePageSchema
        ).pipe(
          Effect.map((page) => ({
            shares: page.data.map((entry) => ({
              url: entry.url,
              fileName: entry.file_name,
              conversation: entry.conversation.id,
              task: entry.conversation.title,
              shared_at: entry.shared_at,
            })),
            cursor: page.has_more ? page.next_cursor : null,
          }))
        );
      },
    },
  });
}
