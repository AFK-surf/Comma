// Cold storage of archived sessions' files (the Rust station's hub.rs: archive_room, clean_rebuildable, pack_archive,
// archive_history_files, restore_archive, archive_has_jobs, archive_is_cold): once an archived session is idle, what a
// build makes again is removed from its own directory, and the rest of its workspace and the transcripts its runtime
// keeps in station storage are packed (archive.ts); they are restored before its runtime starts again, or when it is
// shown again. The hub calls it (ColdStorage) from the session's queue, so no turn starts halfway through.
import { existsSync, realpathSync } from "node:fs";
import { rm, unlink, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { log } from "../ops/log.ts";
import { transcriptPath } from "../read/transcript.ts";
import * as archive from "./archive.ts";
import { runtimeNamed } from "./config.ts";
import { measureRoom, roomOf, safeToRemove, within } from "./footprint.ts";
import type { ColdStorage, Hub } from "./hub.ts";

const canonical = (path: string): string | null => {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
};

export class ColdRooms implements ColdStorage {
  /// The hub it works for (made after it).
  private readonly hub: () => Hub;

  constructor(hub: () => Hub) {
    this.hub = hub;
  }

  private dataDir() {
    return this.hub().config().dataDir;
  }

  /// An archived session's own directory, while nothing needs it: not back in the lists or at work, and no other
  /// session or active job (running, or a service waiting to restart) using it.
  archiveRoom(key: string): string | null {
    const hub = this.hub();
    const row = hub.store.getSession(key);
    if (!row) return null;
    const dir = roomOf(this.dataDir(), row.workspace);
    if (dir === null || row.archivedAt === null || row.running || hub.processState(key) === "running") return null;
    const shared = hub.store
      .listSessions()
      .some(
        (s) =>
          s.key !== key &&
          (s.archivedAt === null || s.running) &&
          [s.workspace, s.cwd ?? s.workspace].some((path) => {
            const cwd = canonical(path);
            return cwd !== null && within(cwd, dir);
          }),
      );
    if (shared || this.hasJobs(key, dir)) return null;
    return dir;
  }

  private hasJobs(key: string, dir: string): boolean {
    let jobs;
    try {
      jobs = this.hub().store.listJobs(null);
    } catch {
      return true;
    }
    return jobs.some((job) => {
      const active = job.state === "running" || (job.port !== null && job.state === "exited");
      const cwd = canonical(job.cwd);
      return active && (job.sessionKey === key || (cwd !== null && within(cwd, dir)));
    });
  }

  /// Removes what a build or an install makes again (node_modules, a Cargo target, …; footprint.ts `rebuildable`) from
  /// an archived session's own directory: it may come back, and is built again then. Left as it is while the session is
  /// back in the lists or at work, or a session/job still uses its directory. Returns removed allocated file bytes.
  async cleanRebuildable(key: string): Promise<number> {
    const dir = this.archiveRoom(key);
    if (dir === null) return 0;
    let freed = 0;
    for (const [path, bytes] of (await measureRoom(dir)).rebuild) {
      // Restoring a chat updates the store before its next message reaches the actor queue.
      const row = this.hub().store.getSession(key);
      if (!(row && row.archivedAt !== null && !row.running) || this.hasJobs(key, dir)) break;
      if (!(await safeToRemove(path))) continue;
      try {
        await rm(path, { recursive: true });
        freed += bytes;
      } catch (error) {
        log.warn("hub", "not removed", { path, error: (error as Error).message });
      }
    }
    if (freed > 0) log.info("hub", "rebuildable files of an archived session cleaned", { session: key, freed });
    return freed;
  }

  /// Runtime-owned files outside station storage are never removed. A shared runtime session is left hot while another
  /// chat can still use it. The main transcript and Claude's subagent files are compressed together.
  historyFiles(key: string, packing: boolean): string[] {
    const hub = this.hub();
    const row = hub.store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    const id = row.runtimeSessionId;
    if (!id) return [];
    if (
      packing &&
      hub.store.listSessions().some((s) => s.key !== key && s.runtime === row.runtime && s.runtimeSessionId === id && (s.archivedAt === null || s.running))
    )
      return [];
    const config = hub.config();
    const profile = config.profiles.find((p) => p.id === row.profile);
    const runtime = runtimeNamed(row.runtime);
    if (!profile || !runtime) return [];
    const root = realpathSync(config.dataDir);
    const files: string[] = [];
    // With those of the runtime sessions it ran in before (sessions/afresh.ts).
    for (const each of hub.store.runtimeSessions(key)) {
      const path = transcriptPath(runtime, profile.home, each);
      if (path === null) continue;
      const parent = realpathSync(dirname(path));
      if (!within(parent, root)) continue;
      files.push(join(parent, basename(path)));
      if (runtime === "claude") archive.jsonlFiles(join(parent, each), files);
    }
    return files;
  }

  isCold(key: string): boolean {
    const row = this.hub().store.getSession(key);
    const room = row ? roomOf(this.dataDir(), row.workspace) : null;
    if (room !== null && (existsSync(join(room, "cold")) || existsSync(archive.workspaceArchive(room)) || existsSync(join(room, "workspace-locks.json"))))
      return true;
    try {
      return this.historyFiles(key, false).some((path) => !existsSync(path) && existsSync(archive.packed(path)));
    } catch {
      return false;
    }
  }

  async restore(key: string): Promise<void> {
    const row = this.hub().store.getSession(key);
    if (!row) throw new Error(`unknown session ${key}`);
    const room = roomOf(this.dataDir(), row.workspace);
    if (room === null) return;
    await archive.withLock(room, async () => {
      await archive.restoreWorkspace(room);
      // Restoration must work even after the store has already brought this chat back.
      for (const path of this.historyFiles(key, false)) await archive.restoreFile(path);
      if (existsSync(join(room, "cold"))) await unlink(join(room, "cold"));
    });
  }

  async pack(key: string): Promise<void> {
    const room = this.archiveRoom(key);
    if (room === null) return;
    const ready = () => this.archiveRoom(key) !== null;
    await archive.withLock(room, async () => {
      if (!ready()) return;
      await this.cleanRebuildable(key);
      if (!ready()) return;
      await writeFile(join(room, "cold"), "workspace and history may be compressed\n");
      await archive.packWorkspaceIf(room, ready);
      if (!ready()) return;
      const files = this.historyFiles(key, true);
      for (const path of files) {
        await archive.packFileIf(path, () => ready() && this.historyFiles(key, true).length > 0);
      }
      if (files.length > 0 && files.every((path) => !existsSync(path) && existsSync(archive.packed(path)))) {
        // The legacy copy of an archived session's transcript, redundant once the transcript itself is packed.
        const copy = join(this.hub().store.archiveDir(), "transcripts", `${key}.jsonl.zst`);
        if (existsSync(copy)) await unlink(copy);
      }
    });
  }
}
