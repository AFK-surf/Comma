import {
  fileOpenApplicationMaxCount,
  type FilesCopyDownloadResult,
  type FilesListOpenApplicationsInput,
  type FilesListOpenApplicationsResult,
  type FilesOpenDownloadInput,
  type FilesDownloadRefInput,
  type FilesOpenDownloadResult,
  type FilesRevealDownloadResult,
  type FilesSaveDownloadInput,
  type FilesSaveDownloadResult,
} from "@comma/native-bridge";
import { randomBytes as nodeRandomBytes } from "node:crypto";
import { mkdir, open, rm, stat } from "node:fs/promises";
import { extname, join } from "node:path";
import type { FileApplicationsPlatform } from "./open-applications";

/**
 * Downloads a renderer resolved but could not place: Main owns the Downloads
 * directory, mints the only handle to what it wrote, and never returns a host
 * path. Reveal and open resolve that handle back to a path inside this
 * process, so a renderer can act on a file it can neither name nor address.
 */
export interface FilesProvider {
  copyDownload(input: FilesDownloadRefInput): Promise<FilesCopyDownloadResult>;
  listOpenApplications(
    input: FilesListOpenApplicationsInput
  ): Promise<FilesListOpenApplicationsResult>;
  openDownload(input: FilesOpenDownloadInput): Promise<FilesOpenDownloadResult>;
  revealDownload(input: FilesDownloadRefInput): Promise<FilesRevealDownloadResult>;
  saveDownload(input: FilesSaveDownloadInput): Promise<FilesSaveDownloadResult>;
}

/** Saved-download handles live for the process; the map stays bounded. */
const MAX_TRACKED_DOWNLOADS = 256;
const MAX_TRACKED_APPLICATIONS = 256;
/** `name (1).ext` … `name (999).ext` before a save is reported as failed. */
const MAX_NAME_COLLISION_ATTEMPTS = 1_000;
const MAX_FILE_NAME_BYTES = 200;
const FALLBACK_FILE_NAME = "download";

export class DownloadNameCollisionError extends Error {
  constructor(fileName: string) {
    super(`Unable to allocate a Downloads name for ${fileName}.`);
    this.name = "DownloadNameCollisionError";
  }
}

const pathSeparators = new Set(["/", "\\", ":"]);

const isControlCharacter = (character: string) => {
  const codePoint = character.codePointAt(0) ?? 0;
  return codePoint < 0x20 || codePoint === 0x7f;
};

const truncateUtf8 = (value: string, maxBytes: number) => {
  let byteLength = 0;
  let result = "";
  for (const character of value) {
    const characterBytes = Buffer.byteLength(character, "utf8");
    if (byteLength + characterBytes > maxBytes) break;
    byteLength += characterBytes;
    result += character;
  }
  return result;
};

/**
 * A renderer supplied name is untrusted text, not a path. Everything that
 * could steer the write out of the Downloads directory — separators, drive
 * prefixes, traversal, NUL and other control bytes — is removed here rather
 * than relied on to be absent.
 */
export function sanitizeDownloadFileName(fileName: string) {
  const flattened = Array.from(fileName)
    .map((character) => {
      if (isControlCharacter(character)) return "";
      return pathSeparators.has(character) ? " " : character;
    })
    .join("")
    .replace(/^[.\s]+/, "")
    .replace(/[.\s]+$/, "")
    .trim();
  if (!flattened) return FALLBACK_FILE_NAME;

  const extension = extname(flattened);
  const stem = flattened.slice(0, flattened.length - extension.length);
  if (!stem) return truncateUtf8(flattened, MAX_FILE_NAME_BYTES);

  const extensionBytes = Buffer.byteLength(extension, "utf8");
  const budget = MAX_FILE_NAME_BYTES - extensionBytes;
  return budget > 0
    ? `${truncateUtf8(stem, budget)}${extension}`
    : truncateUtf8(stem, MAX_FILE_NAME_BYTES);
}

function collisionCandidate(fileName: string, attempt: number) {
  if (attempt === 0) return fileName;

  const extension = extname(fileName);
  const stem = fileName.slice(0, fileName.length - extension.length);
  return `${stem} (${attempt})${extension}`;
}

type DownloadFileOperations = Readonly<{
  createExclusive(path: string, content: Uint8Array): Promise<void>;
  createExclusiveStream(path: string, chunks: AsyncIterable<Uint8Array>): Promise<void>;
  ensureDirectory(path: string): Promise<void>;
  exists(path: string): Promise<boolean>;
}>;

const nodeDownloadFileOperations: DownloadFileOperations = {
  async createExclusive(path, content) {
    const handle = await open(path, "wx");
    try {
      await handle.writeFile(content);
    } finally {
      await handle.close();
    }
  },
  async createExclusiveStream(path, chunks) {
    const handle = await open(path, "wx");
    try {
      let position = 0;
      for await (const chunk of chunks) {
        let written = 0;
        while (written < chunk.byteLength) {
          const result = await handle.write(
            chunk,
            written,
            chunk.byteLength - written,
            position
          );
          if (result.bytesWritten === 0) {
            throw new Error(`Writing ${path} made no progress.`);
          }
          written += result.bytesWritten;
          position += result.bytesWritten;
        }
      }
      await handle.close();
    } catch (error) {
      await handle.close().catch(() => undefined);
      await rm(path, { force: true }).catch(() => undefined);
      throw error;
    }
  },
  async ensureDirectory(path) {
    await mkdir(path, { recursive: true });
  },
  async exists(path) {
    try {
      await stat(path);
      return true;
    } catch {
      return false;
    }
  },
};

const isFileExistsError = (error: unknown) =>
  typeof error === "object" &&
  error !== null &&
  (error as { code?: unknown }).code === "EEXIST";

export class DownloadsService implements FilesProvider {
  readonly #fileOperations: DownloadFileOperations;
  readonly #openPath: (path: string) => Promise<string>;
  readonly #pathsByRef = new Map<string, string>();
  readonly #applicationsById = new Map<string, string>();
  readonly #applications: FileApplicationsPlatform | undefined;
  readonly #randomBytes: (size: number) => Buffer;
  readonly #resolveDownloadsDirectory: () => string;
  readonly #revealPath: (path: string) => void;

  constructor({
    fileOperations = nodeDownloadFileOperations,
    applications,
    openPath,
    randomBytes = nodeRandomBytes,
    resolveDownloadsDirectory,
    revealPath,
  }: {
    fileOperations?: DownloadFileOperations;
    applications?: FileApplicationsPlatform | undefined;
    openPath: (path: string) => Promise<string>;
    randomBytes?: (size: number) => Buffer;
    resolveDownloadsDirectory: () => string;
    revealPath: (path: string) => void;
  }) {
    this.#fileOperations = fileOperations;
    this.#applications = applications;
    this.#openPath = openPath;
    this.#randomBytes = randomBytes;
    this.#resolveDownloadsDirectory = resolveDownloadsDirectory;
    this.#revealPath = revealPath;
  }

  async saveDownload({ content, fileName }: FilesSaveDownloadInput) {
    return this.#save(fileName, (path) =>
      this.#fileOperations.createExclusive(path, content)
    );
  }

  /**
   * Main-owned producers use the same safe naming and opaque handles while
   * yielding bounded chunks directly to disk. This is intentionally not a
   * renderer capability: no resumable stream/session crosses IPC.
   */
  async saveDownloadStream({
    chunks,
    fileName,
  }: {
    chunks: AsyncIterable<Uint8Array>;
    fileName: string;
  }): Promise<FilesSaveDownloadResult> {
    return this.#save(fileName, (path) =>
      this.#fileOperations.createExclusiveStream(path, chunks)
    );
  }

  async #save(
    fileName: string,
    create: (path: string) => Promise<void>
  ): Promise<FilesSaveDownloadResult> {
    const directory = this.#resolveDownloadsDirectory();
    await this.#fileOperations.ensureDirectory(directory);

    const safeName = sanitizeDownloadFileName(fileName);
    for (let attempt = 0; attempt < MAX_NAME_COLLISION_ATTEMPTS; attempt += 1) {
      const candidate = collisionCandidate(safeName, attempt);
      const path = join(directory, candidate);
      try {
        await create(path);
      } catch (error) {
        if (isFileExistsError(error)) continue;
        throw error;
      }

      return {
        downloadRef: this.#trackDownload(path),
        fileName: candidate,
        status: "saved",
      } as const;
    }

    throw new DownloadNameCollisionError(safeName);
  }

  async copyDownload({
    downloadRef,
  }: FilesDownloadRefInput): Promise<FilesCopyDownloadResult> {
    const path = await this.#resolveSavedPath(downloadRef);
    if (!path || !this.#applications?.copyFileToClipboard)
      return { status: "unavailable" };
    try {
      return {
        status: (await this.#applications.copyFileToClipboard(path))
          ? "copied"
          : "unavailable",
      };
    } catch {
      return { status: "unavailable" };
    }
  }

  async revealDownload({ downloadRef }: FilesDownloadRefInput) {
    const path = await this.#resolveSavedPath(downloadRef);
    if (!path) return { status: "unavailable" } as const;

    this.#revealPath(path);
    return { status: "revealed" } as const;
  }

  async listOpenApplications({
    fileName,
  }: FilesListOpenApplicationsInput): Promise<FilesListOpenApplicationsResult> {
    if (!this.#applications) return { status: "unavailable" };
    try {
      const applications = await this.#applications.listApplicationsForFileName(
        sanitizeDownloadFileName(fileName)
      );
      if (!applications) return { status: "unavailable" };

      return {
        status: "available",
        applications: applications
          .slice(0, fileOpenApplicationMaxCount)
          .map(({ applicationPath, ...application }) => ({
            ...application,
            id: this.#trackApplication(applicationPath),
          })),
      };
    } catch {
      return { status: "unavailable" };
    }
  }

  // FileAction.tla Dispatch/NativeEffect models the UI dispatch boundary and
  // late outcomes of this local effect, not OS application identity or exactly
  // once launch. The current OS-handler decision below is covered by IPC tests.
  async openDownload({ downloadRef, applicationId }: FilesOpenDownloadInput) {
    const path = await this.#resolveSavedPath(downloadRef);
    if (!path) return { status: "unavailable" } as const;

    if (applicationId !== undefined) {
      const applicationPath = this.#applicationsById.get(applicationId);
      if (!applicationPath || !this.#applications) {
        return { status: "unavailable" } as const;
      }
      try {
        // The OS's handlers for the actual saved file are the authority. A
        // menu handle only selects a precise installation, never a publisher
        // identity or a renderer-supplied executable path. Do not fall back
        // to another application when that selection is no longer available.
        const current = await this.#applications.listApplicationsForFile(path);
        const selected = current?.find(
          (application) => application.applicationPath === applicationPath
        );
        if (!selected) return { status: "unavailable" } as const;
        const opened = await this.#applications.openFileWithApplication(
          path,
          selected.applicationPath
        );
        return { status: opened ? "opened" : "unavailable" } as const;
      } catch {
        return { status: "unavailable" } as const;
      }
    }

    // Electron resolves with a non-empty message when no application took it.
    const failure = await this.#openPath(path);
    return failure
      ? ({ status: "unavailable" } as const)
      : ({ status: "opened" } as const);
  }

  #trackApplication(path: string) {
    const existing = [...this.#applicationsById].find(([, value]) => value === path);
    const id = existing?.[0] ?? `fap1_${this.#randomBytes(32).toString("base64url")}`;
    this.#applicationsById.delete(id);
    this.#applicationsById.set(id, path);
    while (this.#applicationsById.size > MAX_TRACKED_APPLICATIONS) {
      this.#applicationsById.delete(this.#applicationsById.keys().next().value!);
    }
    return id;
  }

  /**
   * A handle is retired when its saved path no longer exists, including after
   * a move or deletion. This existence check does not establish file identity
   * if another file has since been placed at the same path.
   */
  async #resolveSavedPath(downloadRef: string) {
    const path = this.#pathsByRef.get(downloadRef);
    if (!path) return undefined;

    if (await this.#fileOperations.exists(path)) return path;

    this.#pathsByRef.delete(downloadRef);
    return undefined;
  }

  #trackDownload(path: string) {
    const downloadRef = `dnl1_${this.#randomBytes(32).toString("base64url")}`;
    this.#pathsByRef.set(downloadRef, path);

    while (this.#pathsByRef.size > MAX_TRACKED_DOWNLOADS) {
      const oldest = this.#pathsByRef.keys().next();
      if (oldest.done) break;
      this.#pathsByRef.delete(oldest.value);
    }

    return downloadRef;
  }
}
