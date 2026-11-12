// Task files (`taskFiles.list`): the files and images Agents attached to a Group's Tasks, as Comma's index answers
// them, newest first. The page asks; nothing is kept here. A file's bytes are its Message's attachment (`files.read`
// with source `attachment`). A Task a station hosts (`hosted`) has none here.
//
// Bounds: each call is one request of at most 200 files.
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { taskFilesPageSchema } from "./comma/schemas.ts";
import type { TaskFilesValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";

const PAGE = 200;

/** One page of the Group's Task files; `conversation`: only that Task's, `query`: names that contain it. */
export function listTaskFiles(
  ctx: Ctx,
  account: Account,
  group: string,
  options: { conversation?: string; cursor?: string; query?: string; limit?: number }
): Effect.Effect<TaskFilesValue, CoreError> {
  const params = new URLSearchParams({ limit: String(options.limit ?? PAGE) });
  if (options.conversation) params.set("conversation_id", options.conversation);
  if (options.cursor) params.set("cursor", options.cursor);
  if (options.query) params.set("q", options.query);
  return ctx.api
    .request(
      account,
      "GET",
      `${route`/v1/comma/groups/${group}/task-files`}?${params}`,
      taskFilesPageSchema
    )
    .pipe(
      Effect.map(
        (page): TaskFilesValue => ({
          status: "ready",
          files: page.data,
          nextCursor: page.next_cursor,
        })
      )
    );
}

/** Whether the server is still indexing the files of older Messages (503 `task_files_indexing`). */
export const indexing = (error: CoreError) =>
  error.status === 503 && error.code === "task_files_indexing";

export function registerTaskFiles(
  ctx: Ctx,
  hosted: () => { owns(conversation: string): boolean } | undefined
): void {
  ctx.kernel.calls({
    "taskFiles.list": {
      cancellable: true,
      run: (p) => {
        const raw = p as {
          group?: unknown;
          conversation?: unknown;
          cursor?: unknown;
        } | null;
        if (typeof raw?.group !== "string" || raw.group === "")
          throw CoreError.invalid("group is required");
        const conversation =
          typeof raw.conversation === "string" ? raw.conversation : "";
        const cursor = typeof raw.cursor === "string" ? raw.cursor : "";
        const group = raw.group;
        if (conversation && hosted()?.owns(conversation))
          return Effect.succeed<TaskFilesValue>({
            status: "ready",
            files: [],
            nextCursor: null,
          });
        return ctx.session.account().pipe(
          Effect.flatMap((account) =>
            listTaskFiles(ctx, account, group, {
              ...(conversation ? { conversation } : {}),
              ...(cursor ? { cursor } : {}),
            })
          ),
          Effect.catch((error: CoreError) =>
            Effect.succeed<TaskFilesValue>({
              status: indexing(error) ? "indexing" : "error",
              files: [],
              nextCursor: null,
            })
          )
        );
      },
    },
  });
}
