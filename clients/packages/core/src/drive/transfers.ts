// Drive's uploads and downloads on this device (`drive`'s `transfers`, `drive.download`, `drive.upload`,
// `drive.retryTransfer`, `drive.dismissTransfers`): every window shows the same list.
//
// A download of a file of this device's node streams into Downloads through Main (`saveDownload`); any other file's
// bytes are read through Drive and saved into Downloads by Main on the desktop, or handed to the page to save on the
// web. An upload imports a file a window staged with Main (Electron) by its opaque reference; the reference is kept
// while the row may be retried and released once it may not.
//
// Bounds: two transfers move at a time per device, the rest wait; the list keeps 500 rows, the oldest finished ones
// dropped past them; a failed transfer is run again only when asked (`drive.retryTransfer`).
import { CoreError } from "@comma/core-kernel";
import { Effect, Result, Semaphore } from "effect";
import type { DriveDownloaded, DriveFile, DriveTransfer } from "../contract.ts";
import type { DesktopPorts, LocalDriveOps, LocalDrivePorts } from "../host.ts";
import { driveFileIdFor, driveWritePath, fullPath } from "./node-files.ts";

const AT_ONCE = 2;
const MAX_ROWS = 500;

/** What transfers use of Drive: its files, their bytes, the node and the desktop's Downloads folder. */
export interface TransferDeps {
  /** A listed file of this device's node (absent: another source's). */
  nodeFile(id: string): DriveFile | undefined;
  /** Any listed file. */
  file(id: string): DriveFile | undefined;
  read(id: string): Effect.Effect<{ bytes: Uint8Array; mediaType: string }, CoreError>;
  /** Fails when the space takes no files on this device. */
  writable(space: string): Effect.Effect<void, CoreError>;
  run<O extends keyof LocalDriveOps>(
    node: LocalDrivePorts,
    op: O,
    input: LocalDriveOps[O]["input"]
  ): Effect.Effect<LocalDriveOps[O]["result"], CoreError>;
  node: LocalDrivePorts | undefined;
  desktop: DesktopPorts | undefined;
  /** The list changed. */
  changed(): void;
  /** An upload landed: Drive reads the node again. */
  imported(): void;
  /** Runs `work` on its own (the core's runner). */
  fork(work: Effect.Effect<void>): void;
}

type Upload = { ref: string; space: string; path: string };

const failed = (message: string) => new CoreError("failed", message);

export class DriveTransfers {
  readonly #deps: TransferDeps;
  readonly #permits = Semaphore.makeUnsafe(AT_ONCE);
  #rows: DriveTransfer[] = [];
  /** What each upload row imports, while it may be retried. */
  readonly #uploads = new Map<string, Upload>();
  #seq = 0;

  constructor(deps: TransferDeps) {
    this.#deps = deps;
  }

  get rows(): DriveTransfer[] {
    return this.#rows;
  }

  download(fileId: string): Effect.Effect<DriveDownloaded, CoreError> {
    return Effect.suspend(() => {
      const file = this.#deps.file(fileId);
      if (!file)
        return Effect.fail(new CoreError("not_found", "The file is not in Drive."));
      const id = this.#begin({ direction: "download", fileName: file.name, fileId });
      return this.#download(id, file);
    });
  }

  /** Begins a row for each file at once; fails before any when a path has an unsafe segment. */
  upload(
    space: string,
    folderPath: string | undefined,
    files: readonly { ref: string; name: string; relativeDir?: string | undefined }[]
  ): Effect.Effect<{ uploaded: number; failed: number }, CoreError> {
    const planned = files.map((file) => {
      const folder = [folderPath, file.relativeDir].filter(Boolean).join("/");
      const path = driveWritePath(folder || undefined, file.name);
      if (!path) throw CoreError.invalid("the path has an unsafe segment");
      return { path, file };
    });
    const ids = planned.map(({ path, file }) => {
      const id = this.#begin({
        direction: "upload",
        fileName: file.name,
        spaceId: space,
      });
      this.#uploads.set(id, { ref: file.ref, space, path });
      return id;
    });
    return Effect.forEach(ids, (id) => Effect.result(this.#upload(id)), {
      concurrency: "unbounded",
    }).pipe(
      Effect.map((results) => {
        const uploaded = results.filter(Result.isSuccess).length;
        return { uploaded, failed: results.length - uploaded };
      })
    );
  }

  retry(id: string): Effect.Effect<DriveDownloaded | null, CoreError> {
    return Effect.suspend(() => {
      const row = this.#rows.find((entry) => entry.id === id);
      if (!row || row.status !== "error")
        return Effect.fail(
          new CoreError("not_found", "There is no failed transfer to retry.")
        );
      if (row.direction === "upload") {
        if (!this.#uploads.has(id))
          return Effect.fail(
            new CoreError("not_found", "The upload's file is no longer kept.")
          );
        this.#update(id, { status: "in_progress" });
        return this.#upload(id).pipe(Effect.as(null));
      }
      const file = row.fileId ? this.#deps.file(row.fileId) : undefined;
      if (!file)
        return Effect.fail(new CoreError("not_found", "The file is not in Drive."));
      this.#update(id, { status: "in_progress" });
      return this.#download(id, file);
    });
  }

  /** Drops every finished row; rows still moving stay. */
  dismiss(): Effect.Effect<void> {
    return this.#drop((row) => row.status !== "in_progress");
  }

  /** Another account (or none): nothing of the one before stays. */
  clear(): Effect.Effect<void> {
    return this.#drop(() => true);
  }

  #begin(row: Omit<DriveTransfer, "id" | "status">): string {
    this.#seq += 1;
    const id = `transfer-${this.#seq}`;
    this.#rows = [{ ...row, id, status: "in_progress" }, ...this.#rows];
    const over = this.#rows.length - MAX_ROWS;
    if (over > 0) {
      const dropped = this.#rows
        .filter((entry) => entry.status !== "in_progress")
        .slice(-over);
      this.#release(dropped.map((entry) => entry.id));
      this.#rows = this.#rows.filter((entry) => !dropped.includes(entry));
    }
    this.#deps.changed();
    return id;
  }

  #update(id: string, change: Partial<DriveTransfer>): void {
    this.#rows = this.#rows.map((row) => (row.id === id ? { ...row, ...change } : row));
    this.#deps.changed();
  }

  /** Marks the row by how `work` ended. */
  #settle<A>(
    id: string,
    work: Effect.Effect<A, CoreError>,
    done: (a: A) => Partial<DriveTransfer>
  ): Effect.Effect<A, CoreError> {
    return this.#permits
      .withPermits(1)(work)
      .pipe(
        Effect.tap((a) =>
          Effect.sync(() => this.#update(id, { status: "success", ...done(a) }))
        ),
        Effect.tapError(() => Effect.sync(() => this.#update(id, { status: "error" }))),
        Effect.onInterrupt(() =>
          Effect.sync(() => this.#update(id, { status: "error" }))
        )
      );
  }

  #download(id: string, file: DriveFile): Effect.Effect<DriveDownloaded, CoreError> {
    const deps = this.#deps;
    const work = Effect.gen(function* () {
      const node = deps.node;
      // A file of this device's node streams from the node straight into Downloads.
      if (node && deps.nodeFile(file.id)) {
        const saved = yield* deps.run(node, "saveDownload", {
          space: file.spaceId,
          path: fullPath(file),
          policy: file.deviceId ? `origin=${file.deviceId}` : "newest",
          fileName: file.name,
        });
        if (!saved) return yield* Effect.fail(failed("The file could not be saved."));
        return { transfer: id, saved };
      }
      const { bytes, mediaType } = yield* deps.read(file.id);
      const desktop = deps.desktop;
      if (!desktop) return { transfer: id, bytes, mediaType };
      const saved = yield* desktop
        .saveDownload(file.name, bytes)
        .pipe(Effect.mapError((error) => failed(error.message)));
      if (!saved) return yield* Effect.fail(failed("The file could not be saved."));
      return { transfer: id, saved };
    });
    return this.#settle(id, work, (done) =>
      "saved" in done ? { downloadRef: done.saved.downloadRef } : {}
    );
  }

  #upload(id: string): Effect.Effect<void, CoreError> {
    const deps = this.#deps;
    const upload = this.#uploads.get(id);
    if (!upload)
      return Effect.fail(
        new CoreError("not_found", "The upload's file is no longer kept.")
      );
    const work = Effect.gen(function* () {
      const node = deps.node;
      if (!node)
        return yield* Effect.fail(
          new CoreError("unavailable", "This Drive is read-only here.")
        );
      yield* deps.writable(upload.space);
      yield* deps.run(node, "importStaged", upload);
    });
    return this.#settle(id, work, () => ({
      fileId: driveFileIdFor(upload.space, upload.path),
    })).pipe(
      Effect.tap(() =>
        Effect.sync(() => {
          deps.imported();
          // A landed upload is not retried: Main may forget its file.
          this.#release([id]);
        })
      )
    );
  }

  #drop(drop: (row: DriveTransfer) => boolean): Effect.Effect<void> {
    return Effect.sync(() => {
      const dropped = this.#rows.filter(drop);
      if (dropped.length === 0) return;
      this.#release(dropped.map((row) => row.id));
      this.#rows = this.#rows.filter((row) => !drop(row));
      this.#deps.changed();
    });
  }

  /** Main forgets the staged files of rows that will not import again. */
  #release(ids: readonly string[]): void {
    const refs = ids.flatMap((id) => {
      const upload = this.#uploads.get(id);
      this.#uploads.delete(id);
      return upload ? [upload.ref] : [];
    });
    const node = this.#deps.node;
    if (node && refs.length > 0)
      this.#deps.fork(Effect.ignore(node.run("releaseStaged", { refs })));
  }
}
