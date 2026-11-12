// Drive's Task Files space: the files and images Agents attached to the Group's Tasks (task-files.ts), one folder per
// Task, read-only. Comma lists them on every platform; a file's bytes are its Message's attachment. Nothing here is
// copied into a device's Drive.
//
// Bounds: a load lists the newest 1,000 files, in at most 5 pages of 200.
import type { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import type { Account } from "../account.ts";
import type { DriveFile, TaskFile, TaskFilesValue } from "../contract.ts";
import type { Ctx } from "../ctx.ts";
import { listTaskFiles } from "../task-files.ts";

export const TASK_FILES_SPACE = "comma-task-files";
const MAX_PAGES = 5;

/** The newest Task files of the Group, each in its Task's folder. */
export function loadTaskFiles(
  ctx: Ctx,
  account: Account,
  groupId: string
): Effect.Effect<DriveFile[], CoreError> {
  return Effect.gen(function* () {
    const files: TaskFile[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < MAX_PAGES; page += 1) {
      const listed: TaskFilesValue = yield* listTaskFiles(
        ctx,
        account,
        groupId,
        cursor ? { cursor } : {}
      );
      files.push(...listed.files);
      cursor = listed.nextCursor;
      if (!cursor) break;
    }
    const folders = taskFolders(files);
    return files.map((file) =>
      taskFileFor(groupId, file, folders.get(file.conversation_id)!)
    );
  });
}

/**
 * Each Task's folder: its title, without "/". Tasks listed with the same title each add the end of their id; a Task
 * without a title is named by its id.
 */
function taskFolders(files: readonly TaskFile[]): Map<string, string> {
  const titles = new Map<string, string>();
  for (const file of files)
    if (!titles.has(file.conversation_id))
      titles.set(
        file.conversation_id,
        file.task_title.replaceAll("/", "-").trim() || file.conversation_id
      );
  const counts = new Map<string, number>();
  for (const title of titles.values()) counts.set(title, (counts.get(title) ?? 0) + 1);
  return new Map(
    [...titles].map(([conversation, title]) => [
      conversation,
      (counts.get(title) ?? 0) > 1 ? `${title} · ${conversation.slice(-6)}` : title,
    ])
  );
}

function taskFileFor(groupId: string, file: TaskFile, folder: string): DriveFile {
  return {
    // A Message's attachment never changes: its place names its content.
    contentsHash: `${file.message_id}:${file.index}`,
    deviceId: "",
    folderPath: folder,
    id: `task:${file.conversation_id}:${file.message_id}:${file.index}`,
    modifiedAt: file.created_at,
    name: file.file_name.replaceAll("/", "-"),
    sizeBytes: file.size,
    spaceId: TASK_FILES_SPACE,
    system: {
      kind: "task_file",
      group: groupId,
      conversation: file.conversation_id,
      message: file.message_id,
      index: file.index,
    },
    writable: false,
  };
}
