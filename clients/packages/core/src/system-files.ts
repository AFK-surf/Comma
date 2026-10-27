// Drive's System Files space: the files of a Group Router's Agent VFS under `/memory` and `/imports`, and the Router's
// effective instructions, which the Workspace owner may replace. The page asks; nothing is kept here. The server decides what is visible and writable.
//
// Bounds: each call is one request; a listing page holds at most 500 files.
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import type { z } from "zod";
import { route } from "./api.ts";
import {
  routerInstructionsSchema,
  systemFileDeletedSchema,
  systemFileSchema,
  systemFilesPageSchema,
  systemFileWrittenSchema,
} from "./comma/schemas.ts";
import type { Ctx } from "./ctx.ts";

const base = (group: string) => route`/v1/comma/groups/${group}/system-files`;

function text(raw: unknown, name: string, max: number): string {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > max)
    throw CoreError.invalid(`${name} is required`);
  return v;
}

const optional = (raw: unknown, name: string): string | undefined => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (v === undefined || v === null || v === "") return undefined;
  if (typeof v !== "string" || v.length > 256)
    throw CoreError.invalid(`${name} is invalid`);
  return v;
};

const query = (params: Record<string, string | undefined>) =>
  Object.entries(params)
    .flatMap(([key, value]) =>
      value === undefined ? [] : [`${key}=${encodeURIComponent(value)}`]
    )
    .join("&");

/** Answers `systemFiles.list`, `.read`, `.write`, `.delete`, `.instructions` and `.writeInstructions`. */
export function registerSystemFiles(ctx: Ctx): void {
  const request = <S extends z.ZodType>(
    method: "GET" | "PUT" | "DELETE",
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
    "systemFiles.list": {
      cancellable: true,
      run: (p) => {
        const group = text(p, "group", 256);
        const path = text(p, "path", 1024);
        const cursor = (p as { cursor?: unknown } | null)?.cursor;
        return request(
          "GET",
          `${base(group)}?${query({
            path,
            cursor: typeof cursor === "string" && cursor ? cursor : undefined,
          })}`,
          systemFilesPageSchema
        );
      },
    },
    "systemFiles.read": {
      cancellable: true,
      run: (p) =>
        request(
          "GET",
          `${base(text(p, "group", 256))}/content?${query({ path: text(p, "path", 1024) })}`,
          systemFileSchema
        ),
    },
    "systemFiles.write": {
      doing: true,
      run: (p) => {
        const content = (p as { content?: unknown } | null)?.content;
        if (typeof content !== "string") throw CoreError.invalid("content is required");
        return request(
          "PUT",
          `${base(text(p, "group", 256))}/content`,
          systemFileWrittenSchema,
          {
            path: text(p, "path", 1024),
            content,
            expected_hash: optional(p, "expectedHash"),
          }
        );
      },
    },
    "systemFiles.delete": {
      doing: true,
      run: (p) =>
        request(
          "DELETE",
          `${base(text(p, "group", 256))}/content?${query({
            path: text(p, "path", 1024),
            expected_hash: optional(p, "expectedHash"),
          })}`,
          systemFileDeletedSchema
        ),
    },
    "systemFiles.instructions": {
      cancellable: true,
      run: (p) =>
        request(
          "GET",
          `${base(text(p, "group", 256))}/instructions`,
          routerInstructionsSchema
        ),
    },
    "systemFiles.writeInstructions": {
      doing: true,
      run: (p) => {
        const content = (p as { content?: unknown } | null)?.content;
        if (typeof content !== "string") throw CoreError.invalid("content is required");
        return request(
          "PUT",
          `${base(text(p, "group", 256))}/instructions`,
          routerInstructionsSchema,
          { content, expected_hash: optional(p, "expectedHash") }
        );
      },
    },
  });
}
