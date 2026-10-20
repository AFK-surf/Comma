// Drive's System Files space: what the Workspace's Router keeps in its Agent VFS, served by Comma on every platform
// next to the spaces devices publish. The server decides what is visible and writable; `writable` here only offers
// what it will accept.
//
//   memory/          the Router's memory; files in the memory layout are editable
//   imports/         raw files of a migration, read-only
//   Comma/           what Comma renders for the owner (Notebook.md), read-only
//   Skills/          one read-only file per skill, its SKILL.md
//   Instructions.md  the Router's effective instructions, read-only
//
// Bounds: a load lists each root in at most 20 pages of 500 files and reads the instructions once.
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import type { Account } from "../account.ts";
import { route } from "../api.ts";
import {
  routerInstructionsSchema,
  skillDetailSchema,
  systemFileDeletedSchema,
  systemFileSchema,
  systemFilesPageSchema,
  systemFileWrittenSchema,
} from "../comma/schemas.ts";
import type { DriveFile, Skill } from "../contract.ts";
import type { Ctx } from "../ctx.ts";

export const SYSTEM_SPACE = "comma-system-files";
const ROOTS = ["/memory/", "/imports/", "/Comma/"] as const;
const MAX_PAGES = 20;
// The paths `memory.write` may write (`SalixAgent.Tools.Memory.allowed_write_path?/1`).
const MEMORY_WRITABLE =
  /^\/memory\/(index\.md|semantic\/(user|agent|people)\.md|semantic\/environments\/[^/]+\.md|scoped\/[^/]+\.md|episodes\/\d{4}-\d{2}-\d{2}\.md)$/;

const base = (group: string) => route`/v1/comma/groups/${group}/system-files`;
const utf8 = new TextEncoder();

/** The workspace whose System Files show: its Group and its skills. */
export interface SystemTarget {
  groupId: string;
  workspaceId: string;
  skills: readonly Skill[];
}

export function systemFileFor(
  groupId: string,
  entry: {
    path: string;
    size: number;
    hash?: string | null | undefined;
    modified_at?: number | null | undefined;
  }
): DriveFile {
  const relative = entry.path.slice(1);
  const slash = relative.lastIndexOf("/");
  return {
    contentsHash: entry.hash ?? `${entry.size}`,
    deviceId: "",
    id: `system:${relative}`,
    modifiedAt: (entry.modified_at ?? 0) * 1000,
    name: relative.slice(slash + 1),
    sizeBytes: entry.size,
    spaceId: SYSTEM_SPACE,
    system: {
      kind: "vfs",
      group: groupId,
      path: entry.path,
      hash: entry.hash ?? undefined,
    },
    writable: MEMORY_WRITABLE.test(entry.path),
    ...(slash > 0 ? { folderPath: relative.slice(0, slash) } : {}),
  };
}

/** Every entry of the space. */
export function loadSystemFiles(
  ctx: Ctx,
  account: Account,
  { groupId, workspaceId, skills }: SystemTarget
): Effect.Effect<DriveFile[], CoreError> {
  const listRoot = (root: string) =>
    Effect.gen(function* () {
      const files: DriveFile[] = [];
      let cursor: string | null = null;
      for (let page = 0; page < MAX_PAGES; page += 1) {
        const query: string = `path=${encodeURIComponent(root)}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
        const listed = yield* ctx.api.request(
          account,
          "GET",
          `${base(groupId)}?${query}`,
          systemFilesPageSchema
        );
        files.push(...listed.files.map((entry) => systemFileFor(groupId, entry)));
        cursor = listed.next_cursor;
        if (!cursor) break;
      }
      return files;
    });
  return Effect.all(
    [
      Effect.all(ROOTS.map(listRoot)),
      ctx.api.request(
        account,
        "GET",
        `${base(groupId)}/instructions`,
        routerInstructionsSchema
      ),
    ],
    { concurrency: "unbounded" }
  ).pipe(
    Effect.map(([listed, instructions]) => [
      ...listed.flat(),
      ...skills.map(
        (skill): DriveFile => ({
          contentsHash: skill.skill_id,
          deviceId: "",
          folderPath: "Skills",
          id: `system:skill:${skill.skill_id}`,
          modifiedAt: 0,
          name: `${skill.name.replaceAll("/", "-")}.md`,
          sizeBytes: 0,
          spaceId: SYSTEM_SPACE,
          system: { kind: "skill", skill: skill.skill_id, workspace: workspaceId },
          writable: false,
        })
      ),
      {
        contentsHash: `${instructions.content.length}:${instructions.content.slice(0, 64)}`,
        deviceId: "",
        id: "system:Instructions.md",
        modifiedAt: 0,
        name: "Instructions.md",
        sizeBytes: utf8.encode(instructions.content).length,
        spaceId: SYSTEM_SPACE,
        system: { kind: "instructions", group: groupId },
        writable: false,
      },
    ])
  );
}

/** An entry's text, and for a memory file the hash it has now (an edit starts from it). */
export function readSystemFile(
  ctx: Ctx,
  account: Account,
  file: DriveFile
): Effect.Effect<
  { text: string; hash?: string | undefined; size?: number },
  CoreError
> {
  const ref = file.system;
  if (!ref) return Effect.fail(CoreError.invalid("not a System Files entry"));
  if (ref.kind === "vfs")
    return ctx.api
      .request(
        account,
        "GET",
        `${base(ref.group)}/content?path=${encodeURIComponent(ref.path)}`,
        systemFileSchema
      )
      .pipe(
        Effect.map((read) => ({
          text: read.content,
          hash: read.hash ?? undefined,
          size: read.size,
        }))
      );
  if (ref.kind === "skill")
    return ctx.api
      .request(
        account,
        "GET",
        `${route`/v1/comma/workspaces/${ref.workspace}/skills`}/${encodeURIComponent(ref.skill)}`,
        skillDetailSchema
      )
      .pipe(Effect.map((skill) => ({ text: skill.content })));
  return ctx.api
    .request(
      account,
      "GET",
      `${base(ref.group)}/instructions`,
      routerInstructionsSchema
    )
    .pipe(Effect.map((instructions) => ({ text: instructions.content })));
}

/** Saves a memory file if it still holds `expectedHash`; a 409 (the Router changed it) fails `changed`. */
export function saveSystemFile(
  ctx: Ctx,
  account: Account,
  file: DriveFile,
  text: string,
  expectedHash: string | undefined
): Effect.Effect<{ hash?: string | undefined; size: number }, CoreError> {
  const ref = file.system;
  if (ref?.kind !== "vfs" || !file.writable)
    return Effect.fail(CoreError.invalid("this file is read-only"));
  return ctx.api
    .request(account, "PUT", `${base(ref.group)}/content`, systemFileWrittenSchema, {
      path: ref.path,
      content: text,
      expected_hash: expectedHash,
    })
    .pipe(
      Effect.map((written) => ({
        hash: written.hash ?? undefined,
        size: written.size,
      })),
      Effect.mapError(changedOn409)
    );
}

/** Deletes a memory file if it still holds what was read. */
export function deleteSystemFile(
  ctx: Ctx,
  account: Account,
  file: DriveFile
): Effect.Effect<void, CoreError> {
  const ref = file.system;
  if (ref?.kind !== "vfs" || !file.writable)
    return Effect.fail(CoreError.invalid("this file is read-only"));
  const hash = ref.hash ? `&expected_hash=${encodeURIComponent(ref.hash)}` : "";
  return ctx.api
    .request(
      account,
      "DELETE",
      `${base(ref.group)}/content?path=${encodeURIComponent(ref.path)}${hash}`,
      systemFileDeletedSchema
    )
    .pipe(Effect.asVoid, Effect.mapError(changedOn409));
}

const changedOn409 = (error: CoreError) =>
  error.status === 409 ? new CoreError("changed", "the file changed", 409) : error;
