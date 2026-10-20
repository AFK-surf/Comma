// Drive (`drive`): the spaces and files a window's Drive page shows, and what changes them. Three sources:
//
// - this installation's Drive node (desktop: the synchronicity daemon Main runs, the host's `localDrive`), read and
//   changed through the host: its spaces and their listings, versions, pins, sync, and the files' bytes;
// - without a node (the web), the Workspace's hosted Drive, read-only through Comma;
// - the System Files of the workspace the app works in (system-files.ts), on every platform.
//
// While `drive` is shown one worker keeps it current: the node's state every 1.5 s while it starts; once it is ready
// its listing every 20 s, 150 ms after its files last changed, and on `drive.refresh` (a window came back to the
// front). A fresh node is enrolled in the Workspace's network once (drive.ts). Every change waits for the load before
// it and reads Drive again after it, one at a time.
//
// Bounds: one load or change at a time per device; a load lists each space in pages of 500 entries and at most 50,000
// files in all; a read takes at most 256 MiB from the node in ranges of 10 MB (10 MB of the hosted Drive); a write
// at most 10 MB; the sync history keeps 500 lines.
import { CoreError, type Scoped, type Value } from "@comma/core-kernel";
import { Duration, Effect, Option, Queue, Result, Semaphore } from "effect";
import { z } from "zod";
import type { Account } from "../account.ts";
import { route } from "../api.ts";
import type {
  DriveAdoptionCounts,
  DriveDevice,
  DriveFile,
  DriveFileVersion,
  DriveSpace,
  DriveSyncHistoryEntry,
  DriveValue,
  DriveVersionPolicy,
} from "../contract.ts";
import type { Ctx } from "../ctx.ts";
import { enrollNode } from "../drive.ts";
import type { LocalDrivePorts, LocalDriveState } from "../host.ts";
import type { Skills } from "../skills.ts";
import type { Workspaces } from "../workspaces.ts";
import {
  attestedBy,
  devicesOf,
  driveFileIdFor,
  driveFolderName,
  driveMediaType,
  driveSpaceIdFor,
  driveSpacesRoot,
  driveWritePath,
  entryToFile,
  fullPath,
  listedSpaces,
  spaceToDrive,
  versionsToDrive,
} from "./node-files.ts";
import { DriveTransfers } from "./transfers.ts";
import {
  deleteSystemFile,
  loadSystemFiles,
  readSystemFile,
  saveSystemFile,
  SYSTEM_SPACE,
} from "./system-files.ts";

export const DRIVE_POLL_MS = 1_500;
export const DRIVE_REFRESH_MS = 20_000;
export const DRIVE_SETTLE_MS = 150;
/** The space Comma binds as the Workspace's Drive, as the web reads it. */
export const HOSTED_SPACE = "comma-drive";
const PAGE = 500;
const MAX_FILES = 50_000;
const MAX_HISTORY = 500;
const READ_MAX = 256 * 1024 * 1024;
const RANGE = 10_000_000;
const HOSTED_READ_MAX = 10_000_000;
const WRITE_MAX = 10_000_000;

const hostedTreeSchema = z
  .object({
    entries: z.array(
      z
        .object({
          path: z.string(),
          name: z.string(),
          kind: z.string(),
          size: z.number().nullable().optional(),
          modified_at: z.number().nullable().optional(),
        })
        .strip()
    ),
    truncated: z.boolean().optional(),
  })
  .strip();

type Wake = "refresh" | "change";

const empty = { spaces: [] as DriveSpace[], files: [] as DriveFile[] };

const fileIds = (p: unknown, name = "files"): string[] => {
  const ids = (p as Record<string, unknown> | null)?.[name];
  if (
    !Array.isArray(ids) ||
    ids.length === 0 ||
    ids.length > 1000 ||
    !ids.every((id): id is string => typeof id === "string" && id !== "")
  )
    throw CoreError.invalid(`${name} are file ids`);
  return ids;
};

const text = (p: unknown, name: string, max = 1024): string => {
  const v = (p as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || v === "" || v.length > max)
    throw CoreError.invalid(`${name} is required`);
  return v;
};

const refused = (message = "The local Drive node refused it.") =>
  new CoreError("refused", message);

export class DriveFiles {
  readonly #ctx: Ctx;
  readonly #node: LocalDrivePorts | undefined;
  readonly #workspaces: Workspaces;
  readonly #skills: Skills;
  readonly #lock = Semaphore.makeUnsafe(1);
  #status: DriveValue["node"];
  #state: LocalDriveState | null = null;
  #nodeSpaces: DriveSpace[] = [];
  #nodeFiles: DriveFile[] = [];
  #devices: DriveDevice[] = [];
  #hosted = empty;
  #system: { groupId: string; files: DriveFile[] } | null = null;
  /** The device whose copies are listed; null: this one. */
  #origin: string | null = null;
  #policy: DriveVersionPolicy = "newest";
  /** The copies read of diverged paths, for the content they were read for. */
  readonly #versions = new Map<
    string,
    { hash: string; versions: DriveFileVersion[] }
  >();
  #history: DriveSyncHistoryEntry[] = [];
  #historySeq = 0;
  #enrolled = false;
  #accountKey: string | null = null;
  #worker: { scope: Scoped; wakes: Queue.Queue<Wake> } | null = null;
  readonly #transfers: DriveTransfers;

  constructor(ctx: Ctx, workspaces: Workspaces, skills: Skills) {
    this.#ctx = ctx;
    this.#node = ctx.host.localDrive;
    this.#workspaces = workspaces;
    this.#skills = skills;
    this.#status = { status: this.#node ? "starting" : "off" };
    this.#transfers = new DriveTransfers({
      nodeFile: (id) =>
        this.#node ? this.#nodeFiles.find((entry) => entry.id === id) : undefined,
      file: (id) => this.#file(id),
      read: (id) => this.#read(id),
      writable: (space) => this.#writable(space),
      run: (node, op, input) => this.#run(node, op, input),
      node: this.#node,
      desktop: ctx.host.desktop,
      changed: () => this.#changed(),
      imported: () => this.#wake("change"),
      fork: (work) => void ctx.runner.fork(work),
    });
    ctx.kernel.source("drive", {
      start: () => this.#show(),
      stop: () => {
        if (this.#worker) ctx.runner.close(this.#worker.scope);
        this.#worker = null;
      },
      compute: (): Value => ({ ok: this.#value() }),
    });
    this.#node?.onChange(() => this.#wake("change"));
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      // Another account (or none): nothing of the one before is shown.
      this.#accountKey = key;
      this.#hosted = empty;
      this.#system = null;
      this.#history = [];
      this.#versions.clear();
      this.#enrolled = false;
      ctx.runner.fork(this.#transfers.clear());
      this.#changed();
      this.#wake("refresh");
    });
    workspaces.onChange(() => this.#wake("refresh"));
    this.#registerCalls();
  }

  #registerCalls(): void {
    const ctx = this.#ctx;
    const changing = <A>(work: Effect.Effect<A, CoreError>) =>
      this.#lock.withPermits(1)(work.pipe(Effect.tap(() => this.#loadAll())));
    ctx.kernel.calls({
      "drive.refresh": {
        run: () =>
          Effect.sync(() => {
            this.#wake("refresh");
            return null;
          }),
      },
      "drive.setView": {
        run: (p) => {
          const { originDeviceId, versionPolicy } = (p ?? {}) as {
            originDeviceId?: unknown;
            versionPolicy?: unknown;
          };
          if (
            (originDeviceId !== undefined && typeof originDeviceId !== "string") ||
            (versionPolicy !== undefined &&
              versionPolicy !== "newest" &&
              versionPolicy !== "strict")
          )
            throw CoreError.invalid(
              "originDeviceId is a device, versionPolicy newest or strict"
            );
          return changing(
            Effect.sync(() => {
              if (typeof originDeviceId === "string")
                this.#origin =
                  originDeviceId && originDeviceId !== this.#state?.origin
                    ? originDeviceId
                    : null;
              if (versionPolicy) this.#policy = versionPolicy;
              return null;
            })
          );
        },
      },
      "drive.versions": {
        run: (p) => {
          const id = text(p, "file");
          return this.#lock.withPermits(1)(this.#readVersions(id));
        },
      },
      "drive.settle": {
        doing: true,
        run: (p) => {
          const id = text(p, "file");
          const versionId = text(p, "version");
          return changing(
            Effect.gen({ self: this }, function* () {
              const { node, file } = yield* this.#nodeFile(id);
              const version = this.#versions
                .get(id)
                ?.versions.find((entry) => entry.id === versionId);
              if (!version)
                return yield* Effect.fail(CoreError.invalid("no such version"));
              yield* this.#writable(file.spaceId);
              yield* this.#run(node, "adopt", {
                space: file.spaceId,
                path: fullPath(file),
                select: `origin=${version.deviceId}`,
              });
              return null;
            })
          );
        },
      },
      "drive.adoptNewest": {
        doing: true,
        run: (p) => {
          const ids = fileIds(p);
          return changing(this.#adoptNewest(ids).pipe(Effect.as(null)));
        },
      },
      "drive.delete": {
        doing: true,
        run: (p) => {
          const ids = fileIds(p);
          return changing(
            Effect.forEach(ids, (id) => this.#delete(id), { discard: true }).pipe(
              Effect.as(null)
            )
          );
        },
      },
      "drive.keepOffline": {
        doing: true,
        run: (p) => {
          const ids = fileIds(p);
          const keepOffline = (p as { keepOffline?: unknown }).keepOffline;
          if (typeof keepOffline !== "boolean")
            throw CoreError.invalid("keepOffline is true or false");
          return changing(
            Effect.forEach(
              ids,
              (id) =>
                this.#nodeFile(id).pipe(
                  Effect.flatMap(({ node, file }) =>
                    this.#run(node, "pin", {
                      space: file.spaceId,
                      path: fullPath(file),
                      action: keepOffline ? "add" : "rm",
                    })
                  )
                ),
              { discard: true }
            ).pipe(Effect.as(null))
          );
        },
      },
      "drive.addSpace": {
        doing: true,
        run: () =>
          changing(
            Effect.gen({ self: this }, function* () {
              const node = yield* this.#requireNode();
              const path = yield* this.#run(node, "pickFolder", {});
              if (!path) return null;
              const taken = new Set(
                (this.#state?.spaces ?? []).map((space) => space.id)
              );
              const name = driveFolderName(path);
              const space = driveSpaceIdFor(name, taken);
              yield* this.#run(node, "sourceAdd", { space, path });
              return { space, name, path };
            })
          ),
      },
      "drive.renameSpace": {
        doing: true,
        run: (p) => {
          const space = text(p, "space");
          const name = text(p, "name", 256);
          return changing(
            this.#requireNode().pipe(
              Effect.flatMap((node) =>
                this.#run(node, "setSpaceSettings", { space, label: name })
              ),
              Effect.as(null)
            )
          );
        },
      },
      "drive.removeSpace": {
        doing: true,
        run: (p) => {
          const space = text(p, "space");
          return changing(
            Effect.gen({ self: this }, function* () {
              const node = yield* this.#requireNode();
              if (space === this.#state?.defaultSpace)
                return yield* Effect.fail(
                  CoreError.invalid("the install's own space stays")
                );
              const known = this.#state?.spaces.find((entry) => entry.id === space);
              if (known?.replica)
                yield* this.#run(node, "replicaSet", { space, checkoutPath: "" });
              if (known?.writable) yield* this.#run(node, "sourceRemove", { space });
              return null;
            })
          );
        },
      },
      "drive.setSpaceSynced": {
        doing: true,
        run: (p) => {
          const space = text(p, "space");
          const synced = (p as { synced?: unknown }).synced;
          if (typeof synced !== "boolean")
            throw CoreError.invalid("synced is true or false");
          return changing(this.#setSpaceSynced(space, synced));
        },
      },
      "drive.planSpaceSync": {
        run: (p) => {
          const space = text(p, "space");
          return this.#requireNode().pipe(
            Effect.flatMap((node) =>
              this.#run(node, "adoptTree", { space, dryRun: true, replace: false })
            )
          );
        },
      },
      "drive.retrySync": {
        doing: true,
        run: () =>
          changing(
            Effect.gen({ self: this }, function* () {
              const open = this.#history.filter(
                (entry) =>
                  entry.status === "failed" && entry.resolved !== true && entry.fileId
              );
              const files = yield* this.#adoptNewest(
                open.flatMap((entry) => (entry.fileId ? [entry.fileId] : []))
              );
              const settled = new Set(open.map((entry) => entry.id));
              this.#history = this.#history.map((entry) =>
                settled.has(entry.id) ? { ...entry, resolved: true } : entry
              );
              this.#record(
                files.map((file) => ({
                  direction: "download" as const,
                  kind: "file" as const,
                  name: file.name,
                  operation: "updated" as const,
                  sizeBytes: file.sizeBytes,
                  status: "success" as const,
                }))
              );
              return null;
            })
          ),
      },
      "drive.restart": {
        doing: true,
        run: () =>
          changing(
            Effect.gen({ self: this }, function* () {
              const node = yield* this.#requireNode();
              this.#setStatus({ status: "starting" });
              yield* this.#run(node, "restart", {});
              return null;
            })
          ),
      },
      "drive.read": {
        cancellable: true,
        run: (p) => this.#read(text(p, "file")),
      },
      "drive.write": {
        doing: true,
        run: (p) => {
          const space = text(p, "space");
          const name = text(p, "name", 255);
          const folderPath = (p as { folderPath?: unknown }).folderPath;
          const bytes = (p as { bytes?: unknown }).bytes;
          const expectedHash = (p as { expectedHash?: unknown }).expectedHash;
          if (
            (folderPath !== undefined && typeof folderPath !== "string") ||
            !(bytes instanceof Uint8Array) ||
            bytes.length > WRITE_MAX ||
            (expectedHash !== undefined && typeof expectedHash !== "string")
          )
            throw CoreError.invalid("bytes are at most 10 MB");
          const path = driveWritePath(folderPath || undefined, name);
          if (!path) throw CoreError.invalid("the path has an unsafe segment");
          return changing(this.#write(space, path, bytes, expectedHash));
        },
      },
      "drive.reveal": {
        run: (p) => {
          const space = text(p, "space");
          const path = text(p, "path", 4096);
          return this.#lock.withPermits(1)(this.#reveal(space, path));
        },
      },
      "drive.download": {
        doing: true,
        run: (p) => this.#transfers.download(text(p, "file")),
      },
      "drive.upload": {
        doing: true,
        run: (p) => {
          const space = text(p, "space");
          const { folderPath, files } = (p ?? {}) as {
            folderPath?: unknown;
            files?: unknown;
          };
          if (
            (folderPath !== undefined && typeof folderPath !== "string") ||
            !Array.isArray(files) ||
            files.length === 0 ||
            files.length > 1000 ||
            !files.every(
              (
                file: unknown
              ): file is { ref: string; name: string; relativeDir?: string } => {
                const f = file as Record<string, unknown> | null;
                return (
                  typeof f?.ref === "string" &&
                  f.ref !== "" &&
                  typeof f.name === "string" &&
                  f.name !== "" &&
                  (f.relativeDir === undefined || typeof f.relativeDir === "string")
                );
              }
            )
          )
            throw CoreError.invalid("files are staged files with names");
          return this.#transfers.upload(space, folderPath || undefined, files);
        },
      },
      "drive.retryTransfer": {
        doing: true,
        run: (p) => this.#transfers.retry(text(p, "transfer")),
      },
      "drive.dismissTransfers": {
        run: () => this.#transfers.dismiss().pipe(Effect.as(null)),
      },
    });
  }

  // ---- the value

  #value(): DriveValue {
    const source = this.#node
      ? { spaces: this.#nodeSpaces, files: this.#nodeFiles }
      : this.#hosted;
    const system = this.#system;
    const files = source.files.map((file) => {
      const read = this.#versions.get(file.id);
      return read && read.hash === file.contentsHash && read.versions.length > 1
        ? { ...file, versions: read.versions }
        : file;
    });
    return {
      node: this.#status,
      spaces: [
        ...source.spaces,
        ...(system
          ? [{ id: SYSTEM_SPACE, name: "", remote: true, writable: false }]
          : []),
      ],
      files: [...files, ...(system?.files ?? [])],
      devices: this.#devices,
      originDeviceId: this.#origin ?? this.#state?.origin ?? "",
      versionPolicy: this.#policy,
      localSyncEnabled: this.#nodeSpaces.some((space) => space.synced === true),
      localSyncRoot: this.#state?.localRoot ?? "",
      syncHistory: this.#history,
      transfers: this.#transfers.rows,
    };
  }

  #changed(): void {
    this.#ctx.kernel.store.invalidate({ topic: "drive" });
  }

  #setStatus(status: DriveValue["node"]): void {
    if (this.#status.status === status.status && this.#status.reason === status.reason)
      return;
    this.#status = status;
    this.#changed();
  }

  // ---- keeping it current

  #wake(wake: Wake): void {
    if (this.#worker) Queue.offerUnsafe(this.#worker.wakes, wake);
  }

  #show(): void {
    if (this.#worker) return;
    const { runner } = this.#ctx;
    const scope = runner.child();
    const wakes = Effect.runSync(Queue.unbounded<Wake>());
    this.#worker = { scope, wakes };
    runner.fork(this.#keep(wakes), scope);
  }

  /** Loads, then waits: 1.5 s while the node starts, the 20 s refresh while it is ready, else a wake. */
  #keep(wakes: Queue.Queue<Wake>): Effect.Effect<void> {
    const wake = Queue.take(wakes).pipe(
      Effect.flatMap((first) =>
        first === "change"
          ? // A burst of commits: wait for it to settle, and take what came meanwhile with it.
            Effect.sleep(Duration.millis(DRIVE_SETTLE_MS)).pipe(
              Effect.andThen(Queue.clear(wakes))
            )
          : Queue.clear(wakes)
      )
    );
    return Effect.forever(
      Effect.gen({ self: this }, function* () {
        yield* this.#lock.withPermits(1)(this.#loadAll());
        if (this.#node && this.#status.status === "starting")
          yield* Effect.raceFirst(Effect.sleep(Duration.millis(DRIVE_POLL_MS)), wake);
        else if (this.#node && this.#status.status === "ready")
          yield* Effect.raceFirst(
            Effect.sleep(Duration.millis(DRIVE_REFRESH_MS)),
            wake
          );
        else yield* wake;
      })
    );
  }

  /** Reads every source; one that fails keeps what it showed. */
  #loadAll(): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) {
        this.#nodeFiles = [];
        this.#nodeSpaces = [];
        this.#changed();
        return;
      }
      let resolved = this.#workspaces.resolve("");
      if (resolved.status === "loading") {
        // Drive shows the workspace the app works in: its list is read first when no surface has read it yet.
        yield* this.#workspaces.refresh().pipe(Effect.ignore);
        resolved = this.#workspaces.resolve("");
      }
      const workspace = resolved.status === "ready" ? resolved.workspace : null;
      if (this.#node) yield* this.#loadNode(this.#node);
      else if (workspace) yield* this.#loadHosted(account.value, workspace.groupId);
      if (workspace)
        yield* this.#loadSystem(account.value, workspace.id, workspace.groupId);
      else if (resolved.status === "ready") this.#system = null;
      this.#changed();
    });
  }

  #loadNode(node: LocalDrivePorts): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const read = yield* node.state.pipe(Effect.result);
      if (Result.isFailure(read)) {
        this.#setStatus({ status: "error", reason: read.failure.message });
        return;
      }
      let state = read.success;
      this.#state = state;
      if (state.status !== "ready") {
        this.#setStatus(
          state.status === "starting"
            ? { status: "starting" }
            : { status: "error", reason: state.reason ?? "" }
        );
        return;
      }
      if (!this.#enrolled) {
        this.#enrolled = true;
        const named = yield* this.#enroll(node, state).pipe(Effect.option);
        if (Option.isSome(named) && named.value) {
          state = named.value;
          this.#state = state;
          // The node restarts under its zone: it is read again once it is ready.
          if (state.status !== "ready") {
            this.#setStatus({ status: "starting" });
            return;
          }
        }
      }
      const listed = yield* this.#listNode(node, state).pipe(Effect.result);
      if (Result.isFailure(listed)) {
        this.#setStatus({ status: "error", reason: listed.failure.message });
        return;
      }
      this.#nodeSpaces = listed.success.spaces;
      this.#nodeFiles = listed.success.files;
      this.#devices = devicesOf(state, listed.success.files);
      if (this.#origin && !this.#devices.some((device) => device.id === this.#origin))
        this.#origin = null;
      this.#setStatus({ status: "ready" });
    });
  }

  /** A node named by its key joins the Workspace's network once; the zone it gets names it from then on. */
  #enroll(
    node: LocalDrivePorts,
    state: LocalDriveState
  ): Effect.Effect<LocalDriveState | null, CoreError> {
    if (state.domain || !state.origin.startsWith("key:")) return Effect.succeed(null);
    return enrollNode(this.#ctx, state.origin.slice(4), state.deviceName).pipe(
      Effect.flatMap((device) =>
        device
          ? this.#run(node, "setDomain", { domain: device.domain })
          : Effect.succeed(null)
      )
    );
  }

  #listNode(
    node: LocalDrivePorts,
    state: LocalDriveState
  ): Effect.Effect<{ spaces: DriveSpace[]; files: DriveFile[] }, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const listed = listedSpaces(state);
      const spaces = listed.map((space) => spaceToDrive(space, state));
      const pins = new Set(state.pins);
      const origin =
        this.#origin && state.origins.includes(this.#origin)
          ? this.#origin
          : state.origin;
      const policy = origin !== state.origin ? `origin=${origin}` : this.#policy;
      const files: DriveFile[] = [];
      for (const space of listed) {
        // A space this device publishes and keeps in sync takes the cluster's files as they appear, path by path:
        // never a path this device deleted (its own tombstone reads as an empty slot to fill).
        if (space.sourcePath && space.autoAdopt && !space.sourcePaused) {
          const candidates = yield* this.#listSpace(
            node,
            space.id,
            "newest",
            pins,
            MAX_FILES
          );
          yield* this.#adoptFromCluster(node, space.id, candidates, state.origin);
        }
        files.push(
          ...(yield* this.#listSpace(
            node,
            space.id,
            policy,
            pins,
            MAX_FILES - files.length
          ))
        );
      }
      return { spaces, files };
    });
  }

  #listSpace(
    node: LocalDrivePorts,
    space: string,
    policy: string,
    pins: ReadonlySet<string>,
    room: number
  ): Effect.Effect<DriveFile[], CoreError> {
    return Effect.gen(function* () {
      const files: DriveFile[] = [];
      let cursor = "";
      while (files.length < room) {
        const page = yield* node
          .list({ space, policy, limit: PAGE, ...(cursor ? { cursor } : {}) })
          .pipe(Effect.mapError(CoreError.host));
        for (const entry of page.entries)
          if (entry.kind === "file")
            files.push(entryToFile(space, entry, pins.has(`${space}/${entry.path}`)));
        // The listing ends with no cursor; a short page may still have more behind it.
        if (!page.nextCursor) break;
        if (page.nextCursor === cursor)
          return yield* Effect.fail(
            new CoreError("bad_response", "The node repeated a listing cursor.")
          );
        cursor = page.nextCursor;
      }
      return files.slice(0, room);
    });
  }

  /**
   * Takes into this device's folder every path only other devices hold, one at a time, and counts the space's shape:
   * a path this device deleted keeps its tombstone, and a path the devices disagree about is left for the versions.
   */
  #adoptFromCluster(
    node: LocalDrivePorts,
    space: string,
    files: readonly DriveFile[],
    origin: string
  ): Effect.Effect<DriveAdoptionCounts, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const counts: DriveAdoptionCounts = {
        adopt: 0,
        current: 0,
        differing: 0,
        skipped: 0,
      };
      for (const file of files) {
        if ((file.versionCount ?? 1) > 1) {
          counts.differing += 1;
          continue;
        }
        if (file.deviceId === origin) {
          counts.current += 1;
          continue;
        }
        const path = fullPath(file);
        const versions = yield* this.#run(node, "versions", { space, path });
        if (versions.some((v) => v.kind === "tombstone" && attestedBy(v, origin))) {
          counts.skipped += 1;
          continue;
        }
        const adopted = yield* this.#run(node, "adopt", {
          space,
          path,
          select: `origin=${file.deviceId}`,
          automatic: true,
        });
        if (adopted.skipped) counts.skipped += 1;
        else counts.adopt += 1;
      }
      return counts;
    });
  }

  #loadHosted(account: Account, groupId: string): Effect.Effect<void> {
    return this.#ctx.api
      .request(
        account,
        "GET",
        route`/v1/comma/groups/${groupId}/drive/tree`,
        hostedTreeSchema
      )
      .pipe(
        Effect.map((tree) => {
          this.#hosted = {
            spaces: [
              {
                id: HOSTED_SPACE,
                name: "Drive",
                remote: true,
                writable: false,
                synced: true,
              },
            ],
            files: tree.entries.flatMap((entry): DriveFile[] => {
              if (entry.kind !== "file") return [];
              const slash = entry.path.lastIndexOf("/");
              const modifiedAt = (entry.modified_at ?? 0) * 1000;
              const size = entry.size ?? 0;
              return [
                {
                  // The listing names no content root; size and time stand in for it.
                  contentsHash: `${size}:${modifiedAt}`,
                  deviceId: "",
                  id: driveFileIdFor(HOSTED_SPACE, entry.path),
                  modifiedAt,
                  name: entry.name,
                  sizeBytes: size,
                  spaceId: HOSTED_SPACE,
                  writable: false,
                  ...(slash === -1 ? {} : { folderPath: entry.path.slice(0, slash) }),
                },
              ];
            }),
          };
        }),
        Effect.ignore
      );
  }

  #loadSystem(
    account: Account,
    workspaceId: string,
    groupId: string
  ): Effect.Effect<void> {
    return this.#skills.list(workspaceId).pipe(
      Effect.orElseSucceed(() => []),
      Effect.flatMap((skills) =>
        loadSystemFiles(this.#ctx, account, { groupId, workspaceId, skills })
      ),
      Effect.map((files) => {
        this.#system = { groupId, files };
      }),
      Effect.ignore
    );
  }

  // ---- reading and changing

  #file(id: string): DriveFile | undefined {
    return (
      this.#nodeFiles.find((file) => file.id === id) ??
      this.#hosted.files.find((file) => file.id === id) ??
      this.#system?.files.find((file) => file.id === id)
    );
  }

  #requireNode(): Effect.Effect<LocalDrivePorts, CoreError> {
    return this.#node
      ? Effect.succeed(this.#node)
      : Effect.fail(new CoreError("unavailable", "This Drive is read-only here."));
  }

  #nodeFile(
    id: string
  ): Effect.Effect<{ node: LocalDrivePorts; file: DriveFile }, CoreError> {
    return this.#requireNode().pipe(
      Effect.flatMap((node) => {
        const file = this.#nodeFiles.find((entry) => entry.id === id);
        return file
          ? Effect.succeed({ node, file })
          : Effect.fail(new CoreError("not_found", "The file is not in Drive."));
      })
    );
  }

  #run<O extends keyof import("../host.ts").LocalDriveOps>(
    node: LocalDrivePorts,
    op: O,
    input: import("../host.ts").LocalDriveOps[O]["input"]
  ): Effect.Effect<import("../host.ts").LocalDriveOps[O]["result"], CoreError> {
    return node.run(op, input).pipe(Effect.mapError((error) => refused(error.message)));
  }

  #writable(space: string): Effect.Effect<void, CoreError> {
    const state = this.#state;
    const known = state?.spaces.find((entry) => entry.id === space);
    const defaultSource =
      state && space === state.defaultSpace && state.localRoot !== "" && !known;
    return known?.writable || defaultSource
      ? Effect.void
      : Effect.fail(
          new CoreError("read_only", "This Drive space is read-only on this device.")
        );
  }

  #readVersions(id: string): Effect.Effect<DriveFileVersion[], CoreError> {
    return Effect.gen({ self: this }, function* () {
      const file = this.#file(id);
      if (!file || file.spaceId === SYSTEM_SPACE || this.#hostedFile(file)) return [];
      const kept = this.#versions.get(id);
      if (kept && kept.hash === file.contentsHash) return kept.versions;
      if ((file.versionCount ?? 1) < 2) return [];
      const { node } = yield* this.#nodeFile(id);
      const read = yield* this.#run(node, "versions", {
        space: file.spaceId,
        path: fullPath(file),
      });
      const versions = versionsToDrive(read, file, [
        this.#state?.origin ?? "",
        ...this.#devices.map((device) => device.id),
      ]);
      this.#versions.set(id, { hash: file.contentsHash, versions });
      this.#changed();
      return versions;
    });
  }

  #adoptNewest(ids: readonly string[]): Effect.Effect<DriveFile[], CoreError> {
    return Effect.forEach(ids, (id) =>
      this.#nodeFile(id).pipe(
        Effect.tap(({ file }) => this.#writable(file.spaceId)),
        Effect.tap(({ node, file }) =>
          this.#run(node, "adopt", {
            space: file.spaceId,
            path: fullPath(file),
            select: "newest",
          })
        ),
        Effect.map(({ file }) => file)
      )
    );
  }

  #delete(id: string): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const file = this.#file(id);
      if (!file)
        return yield* Effect.fail(
          new CoreError("not_found", "The file is not in Drive.")
        );
      if (file.system) {
        const account = yield* this.#ctx.session.account();
        return yield* deleteSystemFile(this.#ctx, account, file);
      }
      const { node } = yield* this.#nodeFile(id);
      yield* this.#writable(file.spaceId);
      yield* this.#run(node, "delete", { space: file.spaceId, path: fullPath(file) });
    });
  }

  #setSpaceSynced(
    spaceId: string,
    synced: boolean
  ): Effect.Effect<DriveAdoptionCounts | null, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const node = yield* this.#requireNode();
      const state = this.#state;
      const space = this.#nodeSpaces.find((entry) => entry.id === spaceId);
      if (!state || !space)
        return yield* Effect.fail(new CoreError("not_found", "No such space."));
      // What the write will do is decided before it runs: paths only other devices have land, and paths the cluster
      // disagrees about are left and recorded as failed, so the history can retry them with the cluster's copy.
      const files = this.#nodeFiles.filter((file) => file.spaceId === spaceId);
      const arriving = files.filter((file) => file.deviceId !== state.origin);
      const conflicts = files.filter((file) => (file.versionCount ?? 1) > 1);
      const known = state.spaces.find((entry) => entry.id === spaceId);
      let counts: DriveAdoptionCounts | null = null;
      if (known?.sourcePath || spaceId === state.defaultSpace) {
        this.#state = yield* this.#run(node, "setSpaceSettings", {
          space: spaceId,
          syncEnabled: synced,
        });
        if (synced) {
          const candidates = yield* this.#listSpace(
            node,
            spaceId,
            "newest",
            new Set(state.pins),
            MAX_FILES
          );
          counts = yield* this.#adoptFromCluster(
            node,
            spaceId,
            candidates,
            state.origin
          );
        }
      } else {
        // A checkout is named by the space's id, which every device shares.
        yield* this.#run(node, "replicaSet", {
          space: spaceId,
          checkoutPath: synced ? `${driveSpacesRoot(state.localRoot)}/${spaceId}` : "",
        });
      }
      this.#record([
        {
          direction: "download",
          kind: "folder",
          name: space.name,
          operation: synced ? "added" : "removed",
          status: "success",
        },
        ...(synced && counts
          ? [
              ...arriving.slice(0, counts.adopt).map((file) => ({
                direction: "download" as const,
                kind: "file" as const,
                name: file.name,
                operation: "added" as const,
                sizeBytes: file.sizeBytes,
                status: "success" as const,
              })),
              ...conflicts.map((file) => ({
                direction: "download" as const,
                fileId: file.id,
                kind: "file" as const,
                name: file.name,
                operation: "updated" as const,
                reason: "conflict" as const,
                sizeBytes: file.sizeBytes,
                status: "failed" as const,
              })),
            ]
          : []),
      ]);
      return counts;
    });
  }

  /** Lines on top of the history, newest first. */
  #record(entries: readonly Omit<DriveSyncHistoryEntry, "at" | "id">[]): void {
    if (entries.length === 0) return;
    const at = this.#ctx.now();
    const recorded = entries.map((entry) => {
      this.#historySeq += 1;
      return { ...entry, at, id: `drive-sync-${this.#historySeq}` };
    });
    this.#history = [...recorded.toReversed(), ...this.#history].slice(0, MAX_HISTORY);
    this.#changed();
  }

  /** A node's file by its id (`synch:<space>:<path>`) while Drive has not listed it (a search found it). */
  #unlisted(id: string): DriveFile | undefined {
    if (!this.#node || !id.startsWith("synch:")) return undefined;
    const rest = id.slice("synch:".length);
    const colon = rest.indexOf(":");
    if (colon <= 0) return undefined;
    const space = rest.slice(0, colon);
    const path = rest.slice(colon + 1);
    if (!driveWritePath(undefined, path.split("/").at(-1) ?? "") || path === "")
      return undefined;
    const slash = path.lastIndexOf("/");
    return {
      id,
      spaceId: space,
      name: path.slice(slash + 1),
      ...(slash === -1 ? {} : { folderPath: path.slice(0, slash) }),
      contentsHash: "",
      deviceId: "",
      modifiedAt: 0,
      sizeBytes: 0,
    };
  }

  #read(
    id: string
  ): Effect.Effect<{ bytes: Uint8Array; mediaType: string }, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const file = this.#file(id) ?? this.#unlisted(id);
      if (!file)
        return yield* Effect.fail(
          new CoreError("not_found", "The file is not in Drive.")
        );
      const account = yield* this.#ctx.session.account();
      if (file.system) {
        const read = yield* readSystemFile(this.#ctx, account, file);
        // A memory file read with a newer hash than the listing's takes it, so an edit starts from the text shown.
        if (read.hash && file.system.kind === "vfs" && read.hash !== file.system.hash)
          this.#putSystem({
            ...file,
            contentsHash: read.hash,
            ...(read.size === undefined ? {} : { sizeBytes: read.size }),
            system: { ...file.system, hash: read.hash },
          });
        return {
          bytes: new TextEncoder().encode(read.text),
          mediaType: "text/markdown",
        };
      }
      if (this.#hostedFile(file)) {
        if (file.sizeBytes > HOSTED_READ_MAX)
          return yield* Effect.fail(
            new CoreError("too_large", "This file is too large to read here.")
          );
        const response = yield* this.#ctx.api.raw(
          account,
          "GET",
          `${route`/v1/comma/groups/${this.#hostedGroup()}/drive/file`}?path=${encodeURIComponent(fullPath(file))}`
        );
        const bytes = response.body ?? new Uint8Array();
        if (bytes.length > HOSTED_READ_MAX)
          return yield* Effect.fail(
            new CoreError("too_large", "This file is too large to read here.")
          );
        return { bytes, mediaType: driveMediaType(file.name) };
      }
      const node = yield* this.#requireNode();
      // Every range comes from the object the first one selected: a file replaced mid-read fails instead of
      // splicing two versions together.
      const parts: Uint8Array[] = [];
      let first: { root: string; size: number } | undefined;
      let offset = 0;
      for (;;) {
        // An unlisted file's size is learned from its first range.
        const size = first?.size ?? (file.sizeBytes || RANGE);
        if (size > READ_MAX)
          return yield* Effect.fail(
            new CoreError("too_large", "This file is too large to read here.")
          );
        const range = yield* this.#run(node, "read", {
          space: file.spaceId,
          path: fullPath(file),
          policy: file.deviceId ? `origin=${file.deviceId}` : "newest",
          offset,
          length: Math.max(1, Math.min(RANGE, size - offset)),
        });
        first ??= { root: range.contentRoot, size: range.size };
        if (
          range.offset !== offset ||
          range.contentRoot !== first.root ||
          range.size !== first.size ||
          range.eof !== offset + range.content.length >= range.size ||
          (!range.eof && range.content.length === 0)
        )
          return yield* Effect.fail(
            new CoreError("bad_response", "The node returned an incomplete file.")
          );
        parts.push(range.content);
        offset += range.content.length;
        if (range.eof) break;
      }
      const bytes = new Uint8Array(offset);
      let at = 0;
      for (const part of parts) {
        bytes.set(part, at);
        at += part.length;
      }
      return { bytes, mediaType: driveMediaType(file.name) };
    });
  }

  /** A file of the hosted Drive: listed while there is no node (the node's own space has the same id). */
  #hostedFile(file: DriveFile): boolean {
    return !this.#node && file.spaceId === HOSTED_SPACE;
  }

  #hostedGroup(): string {
    const resolved = this.#workspaces.resolve("");
    return resolved.status === "ready" ? (resolved.workspace?.groupId ?? "") : "";
  }

  #putSystem(file: DriveFile): void {
    if (!this.#system) return;
    this.#system = {
      ...this.#system,
      files: this.#system.files.map((entry) => (entry.id === file.id ? file : entry)),
    };
    this.#changed();
  }

  #write(
    space: string,
    path: string,
    bytes: Uint8Array,
    expectedHash: string | undefined
  ): Effect.Effect<{ file: string }, CoreError> {
    return Effect.gen({ self: this }, function* () {
      if (space === SYSTEM_SPACE) {
        const file = this.#system?.files.find((entry) => fullPath(entry) === path);
        if (!file)
          return yield* Effect.fail(
            new CoreError("not_found", "The file is not in Drive.")
          );
        const account = yield* this.#ctx.session.account();
        const written = yield* saveSystemFile(
          this.#ctx,
          account,
          file,
          new TextDecoder().decode(bytes),
          expectedHash
        ).pipe(
          // The Router changed it meanwhile: the space takes its latest text, and the caller keeps theirs.
          // The refusal names the version now held, so a save after it replaces that one.
          Effect.catchIf(
            (error) => error.code === "changed",
            (error) =>
              this.#read(file.id).pipe(
                Effect.ignore,
                Effect.flatMap(() => {
                  const latest = this.#system?.files.find(
                    (entry) => entry.id === file.id
                  )?.system;
                  return Effect.fail(
                    new CoreError("changed", error.message, error.status, {
                      hash: latest?.kind === "vfs" ? latest.hash : undefined,
                    })
                  );
                })
              )
          )
        );
        this.#putSystem({
          ...file,
          // A new content key, so bytes read before the save are not taken for it.
          contentsHash: written.hash ?? `saved:${this.#ctx.now()}`,
          modifiedAt: this.#ctx.now(),
          sizeBytes: written.size,
          ...(file.system?.kind === "vfs"
            ? { system: { ...file.system, hash: written.hash ?? undefined } }
            : {}),
        });
        return { file: file.id };
      }
      const node = yield* this.#requireNode();
      yield* this.#writable(space);
      yield* this.#run(node, "write", { space, path, content: bytes });
      return { file: driveFileIdFor(space, path) };
    });
  }

  /** One file of a space by its path, without listing the rest. */
  #reveal(space: string, path: string): Effect.Effect<{ file: string }, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const node = yield* this.#requireNode();
      const state = yield* node.state.pipe(Effect.mapError(CoreError.host));
      if (state.status !== "ready")
        return yield* Effect.fail(
          new CoreError("unavailable", "Drive is unavailable.")
        );
      const known = state.spaces.find((entry) => entry.id === space);
      if (!known)
        return yield* Effect.fail(
          new CoreError("not_found", "The space is unavailable.")
        );
      const page = yield* node
        .list({ space, policy: "newest", limit: 1, prefix: path })
        .pipe(Effect.mapError(CoreError.host));
      const entry = page.entries[0];
      if (!entry || entry.path !== path || entry.kind !== "file")
        return yield* Effect.fail(
          new CoreError("not_found", "The file is no longer at this place.")
        );
      this.#state = state;
      const file = entryToFile(space, entry, state.pins.includes(`${space}/${path}`));
      this.#nodeFiles = [
        ...this.#nodeFiles.filter((listed) => listed.id !== file.id),
        file,
      ];
      if (!this.#nodeSpaces.some((listed) => listed.id === space))
        this.#nodeSpaces = [...this.#nodeSpaces, spaceToDrive(known, state)];
      this.#origin = null;
      this.#devices = devicesOf(state, this.#nodeFiles);
      this.#changed();
      return { file: file.id };
    });
  }
}
