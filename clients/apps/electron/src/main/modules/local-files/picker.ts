import type {
  LocalFilesPickInput,
  LocalFilesPickResult,
  LocalFilesPreviewInput,
  LocalFilesPreviewResult,
} from "@comma/native-bridge";
import {
  chatAttachmentUploadLimit,
  chatAttachmentUploadMaxBytes,
  chatImagePreviewMaxBytes,
  type ChatPickAttachmentError,
  type ChatAttachmentSource,
} from "@comma/chat-contract";
import { basename, extname } from "node:path";
import { BrowserWindow, dialog, nativeImage, webContents } from "electron";
import { getCurrentNativeCallerContext } from "../ipc";
import {
  LocalFileRouteRegistrationError,
  type LocalFileRouteRegistrar,
} from "./registration";
import {
  LocalFileSnapshotError,
  LocalFileSnapshotStore,
  readBoundedLocalFileSource,
  sanitizeLocalFileDisplayName,
  type LocalFileSnapshot,
} from "./snapshot-store";
import { getCurrentNativeSessionAdmission } from "../session/native-session-admission";

const MAX_LOCAL_FILES_PER_PICK = 50;
const MAX_LOCAL_FILES_TOTAL_BYTES = 1024 * 1024 * 1024;
const LOCAL_FILE_PREVIEW_MAX_BYTES = chatImagePreviewMaxBytes;
/**
 * Previews ship at source resolution — the render is a sanitizing
 * decode/encode pass, not a thumbnail step (the renderer's cards AND its
 * full-size preview modal consume these bytes, and a downscale reads as a
 * blurry upload). The ladder below steps the scale down when a rung's PNG
 * overflows the transport bound, or when the source itself is larger than a
 * rendered preview may be.
 */
const LOCAL_FILE_PREVIEW_ENCODE_SCALES = [1, 0.75, 0.5, 0.35, 0.25] as const;
/**
 * nativeImage decodes PNG and JPEG only; GIF and WebP bytes come back as an
 * empty image. The renderer's Chromium decodes both natively, so those
 * sources ship through as-is once their header has been bounded.
 */
const RENDERER_DECODED_MEDIA_TYPES = new Set(["image/gif", "image/webp"]);
/**
 * Decode bound: a phone camera photo. 48 megapixels covers the largest
 * current iPhone still, and decodes to about 200 MB of bitmap, briefly.
 */
const LOCAL_FILE_PREVIEW_INPUT_MAX_DIMENSION = 8_192;
const LOCAL_FILE_PREVIEW_INPUT_MAX_PIXELS = 50_331_648;
/** Render bound: what the preview modal and the cards can use. */
const LOCAL_FILE_PREVIEW_RENDER_MAX_DIMENSION = 4_096;
const LOCAL_FILE_PREVIEW_RENDER_MAX_PIXELS = 16_777_216;
const LOCAL_FILE_PREVIEW_MAX_QUEUED = 16;
export const CHAT_UPLOAD_IMAGE_EXTENSIONS = [
  ".gif",
  ".jpeg",
  ".jpg",
  ".png",
  ".webp",
] as const;
const JPEG_HEADER_SCAN_MAX_BYTES = 1024 * 1024;
const JPEG_HEADER_SCAN_MAX_SEGMENTS = 1_024;
const allowNonChatLocalFileRegistration = () => {};

type OpenDialog = (options: {
  properties: Array<"multiSelections" | "openFile">;
}) => Promise<{ canceled: boolean; filePaths: string[] }>;

/**
 * A parentless panel opens modeless at the normal window level: behind Side
 * Chat's floating panel and, because that panel does not activate Comma, behind
 * the active app. A sheet on the calling window stays in front of it.
 */
const openDialogOnCallerWindow: OpenDialog = (options) => {
  const caller = webContents.fromId(getCurrentNativeCallerContext().webContentsId);
  const owner = caller && BrowserWindow.fromWebContents(caller);
  return owner ? dialog.showOpenDialog(owner, options) : dialog.showOpenDialog(options);
};

type PreviewImage = {
  getSize(): { height: number; width: number };
  isEmpty(): boolean;
  resize(options: { height: number; quality: "best"; width: number }): PreviewImage;
  toPNG(): Buffer;
};

type CreatePreviewImage = (bytes: Buffer) => PreviewImage;

export type ChatAttachmentPickInput = Readonly<{
  sources?: ChatAttachmentSource[];
  assertLocalFileRegistrationAllowed: () => void;
  /** Invoked once the native dialog resolves, before any intake work runs. */
  onDialogClosed?: () => void;
  maxFiles: number;
  maxTotalSize: number;
  maxUploadFiles: number;
  workspaceId: string;
}>;

export type ChatAttachmentPickItem =
  | Readonly<{
      bytes: Uint8Array;
      kind: "upload";
      name: string;
      size: number;
    }>
  | Readonly<{
      file: LocalFileSnapshot;
      kind: "local_file";
    }>;

export type ChatAttachmentPickResult = Readonly<{
  cancelled: boolean;
  errors: ChatPickAttachmentError[];
  items: ChatAttachmentPickItem[];
}>;

export type ChatImagePreviewInput = Readonly<{
  bytes: Uint8Array;
  mediaType: string;
}>;

export interface LocalFilePickerProvider {
  pick(input: LocalFilesPickInput): Promise<LocalFilesPickResult>;
  pickForChat(input: ChatAttachmentPickInput): Promise<ChatAttachmentPickResult>;
  preview(input: LocalFilesPreviewInput): Promise<LocalFilesPreviewResult>;
  renderImagePreview(input: ChatImagePreviewInput): Promise<Uint8Array>;
}

/**
 * Main owns native intake and preview resolution. Host paths stay in the picker
 * stack frame; the generated bridge returns only opaque refs, bounded metadata,
 * or bounded preview bytes (a PNG re-encode, or the bounded GIF/WebP source).
 */
export class LocalFilePickerService implements LocalFilePickerProvider {
  readonly #createPreviewImage: CreatePreviewImage;
  readonly #openDialog: OpenDialog;
  readonly #previewWorkQueue = new PreviewWorkQueue(LOCAL_FILE_PREVIEW_MAX_QUEUED);
  readonly #registrar: LocalFileRouteRegistrar;
  readonly #store: LocalFileSnapshotStore;
  readonly #uploadImageExtensions: ReadonlySet<string>;

  constructor({
    createPreviewImage = (bytes) => nativeImage.createFromBuffer(bytes),
    openDialog = openDialogOnCallerWindow,
    registrar,
    store,
    uploadImageExtensions = CHAT_UPLOAD_IMAGE_EXTENSIONS,
  }: {
    createPreviewImage?: CreatePreviewImage;
    openDialog?: OpenDialog;
    registrar: LocalFileRouteRegistrar;
    store: LocalFileSnapshotStore;
    /** Extensions admitted to the upload class; the Chat channel transcodes any it cannot send as-is. */
    uploadImageExtensions?: readonly string[];
  }) {
    this.#createPreviewImage = createPreviewImage;
    this.#openDialog = openDialog;
    this.#registrar = registrar;
    this.#store = store;
    this.#uploadImageExtensions = new Set(
      uploadImageExtensions.map((extension) => extension.toLowerCase())
    );
  }

  async preview(input: LocalFilesPreviewInput): Promise<LocalFilesPreviewResult> {
    try {
      const admission = getCurrentNativeSessionAdmission();
      return await this.#previewWorkQueue.run(admission.credential.signal, async () => {
        throwIfAborted(admission.credential.signal);
        const { bytes, mediaType } = await this.#store.readPreviewSource(
          input.localFileRef,
          admission.principalUserId,
          admission.credential.signal
        );
        throwIfAborted(admission.credential.signal);
        const pngImage = await this.#renderImagePreview(
          bytes,
          mediaType,
          admission.credential.signal
        );
        return { pngImage, status: "ready" };
      });
    } catch {
      return { status: "unavailable" };
    }
  }

  async renderImagePreview(input: ChatImagePreviewInput): Promise<Uint8Array> {
    const admission = getCurrentNativeSessionAdmission();
    if (
      input.bytes.byteLength === 0 ||
      input.bytes.byteLength > chatAttachmentUploadMaxBytes
    ) {
      throw previewUnavailable();
    }
    return this.#previewWorkQueue.run(admission.credential.signal, () =>
      this.#renderImagePreview(
        Buffer.from(input.bytes),
        input.mediaType,
        admission.credential.signal
      )
    );
  }

  async #renderImagePreview(
    bytes: Buffer,
    mediaType: string,
    signal: AbortSignal
  ): Promise<Uint8Array> {
    throwIfAborted(signal);
    inspectPreviewImageHeader(bytes, mediaType);

    if (RENDERER_DECODED_MEDIA_TYPES.has(mediaType)) {
      if (bytes.byteLength > LOCAL_FILE_PREVIEW_MAX_BYTES) throw previewUnavailable();
      return bytes;
    }

    // nativeImage decode/resize/encode are synchronous. Yield once before
    // entering that bounded section so unrelated Main work can run after
    // the chunked source read and hash or bounded workspace fetch.
    await yieldToMainLoop();
    throwIfAborted(signal);
    const image = this.#createPreviewImage(bytes);
    throwIfAborted(signal);
    if (image.isEmpty()) throw previewUnavailable();

    const size = image.getSize();
    if (!validPreviewDimensions(size.width, size.height)) {
      throw previewUnavailable();
    }

    for (const scale of LOCAL_FILE_PREVIEW_ENCODE_SCALES) {
      const preview =
        scale < 1
          ? image.resize({
              height: Math.max(1, Math.round(size.height * scale)),
              quality: "best",
              width: Math.max(1, Math.round(size.width * scale)),
            })
          : image;
      throwIfAborted(signal);
      if (preview.isEmpty()) throw previewUnavailable();
      const previewSize = preview.getSize();
      // A larger source than a preview may be: the next rung down.
      if (!validRenderedPreviewDimensions(previewSize.width, previewSize.height)) {
        continue;
      }

      const pngImage = preview.toPNG();
      throwIfAborted(signal);
      if (!(pngImage instanceof Uint8Array) || pngImage.byteLength === 0) {
        throw previewUnavailable();
      }
      if (pngImage.byteLength <= LOCAL_FILE_PREVIEW_MAX_BYTES) {
        return pngImage;
      }
      // Overflow: yield before the next (smaller) synchronous encode pass.
      await yieldToMainLoop();
      throwIfAborted(signal);
    }
    throw previewUnavailable();
  }

  async pick(input: LocalFilesPickInput): Promise<LocalFilesPickResult> {
    // Start the workspace connector while the user is still inside the native
    // dialog so registration rarely has to wait for the initial connect.
    this.#registrar.prewarm?.(input.workspaceId);
    const selected = await this.#openDialog({
      properties: ["openFile", "multiSelections"],
    });
    if (selected.canceled) return { cancelled: true, errors: [], files: [] };

    const files: LocalFileSnapshot[] = [];
    const snapshots: LocalFileSnapshot[] = [];
    const errors: LocalFilesPickResult["errors"] = [];
    const maxFiles = Math.min(MAX_LOCAL_FILES_PER_PICK, input.maxFiles);
    const maxTotalSize = Math.min(MAX_LOCAL_FILES_TOTAL_BYTES, input.maxTotalSize);
    if (selected.filePaths.length > maxFiles) {
      errors.push({
        errorClass: "too_many_local_files",
        message: `Select at most ${maxFiles} more local files.`,
        retryable: true,
      });
    }

    let snapshotBytes = 0;
    for (const sourcePath of selected.filePaths.slice(0, maxFiles)) {
      try {
        const admission = getCurrentNativeSessionAdmission();
        const snapshot = await this.#store.snapshot(
          sourcePath,
          admission.principalUserId
        );
        if (snapshotBytes + snapshot.size > maxTotalSize) {
          await this.#store.releaseDraft(snapshot.localFileRef);
          await Promise.all(
            snapshots.map((candidate) =>
              this.#store.releaseDraft(candidate.localFileRef).catch(() => false)
            )
          );
          snapshots.length = 0;
          errors.push({
            errorClass: "local_file_too_large",
            message: "Selected local files exceed the remaining combined limit.",
            retryable: true,
          });
          break;
        }
        snapshotBytes += snapshot.size;
        snapshots.push(snapshot);
      } catch (error) {
        if (errors.length < MAX_LOCAL_FILES_PER_PICK) {
          errors.push(publicSnapshotError(error));
        }
      }
    }

    // Do not create any remote route until the complete selected batch has
    // passed the aggregate byte limit. This prevents a rejected batch from
    // leaving registered-but-unattachable refs behind.
    for (const snapshot of snapshots) {
      try {
        await this.#registrar.register(
          input.workspaceId,
          snapshot,
          allowNonChatLocalFileRegistration
        );
        files.push(snapshot);
      } catch (error) {
        // A dispatched idempotent registration may have committed even when
        // both responses were lost, so retain only that explicitly ambiguous
        // case for bounded reconciliation. Local preflight/4xx failures and
        // untyped provider failures are definite non-acceptance and are
        // released immediately.
        if (
          !(error instanceof LocalFileRouteRegistrationError) ||
          error.outcome === "rejected"
        ) {
          await this.#store.releaseDraft(snapshot.localFileRef).catch(() => false);
        }
        if (errors.length < MAX_LOCAL_FILES_PER_PICK) {
          errors.push(publicSnapshotError(error));
        }
      }
    }
    return { cancelled: false, errors, files };
  }

  /**
   * Main-only mixed attachment intake. Upload bytes are consumed by the
   * session-bound Chat provider and never cross the generated bridge result.
   * Regular files retain the V2 registration fence used by local-file refs.
   */
  /** Main-owned, user-approved sources such as AirDrop use the same intake path. */
  importForChat(
    filePaths: readonly string[],
    input: ChatAttachmentPickInput
  ): Promise<ChatAttachmentPickResult> {
    return this.pickForChat({
      ...input,
      sources: filePaths.map((sourcePath) => ({ kind: "path", sourcePath })),
    });
  }

  async pickForChat(input: ChatAttachmentPickInput): Promise<ChatAttachmentPickResult> {
    // Start the workspace connector while the user is still inside the native
    // dialog so regular-file registration rarely waits for the initial connect.
    this.#registrar.prewarm?.(input.workspaceId);
    const selected = input.sources
      ? { canceled: false, filePaths: [] }
      : await this.#openDialog({ properties: ["openFile", "multiSelections"] });
    input.onDialogClosed?.();
    if (selected.canceled) return { cancelled: true, errors: [], items: [] };

    const errors: ChatPickAttachmentError[] = [];
    const maxFiles = Math.min(MAX_LOCAL_FILES_PER_PICK, input.maxFiles);
    const maxTotalSize = Math.min(MAX_LOCAL_FILES_TOTAL_BYTES, input.maxTotalSize);
    const maxUploadFiles = Math.max(
      0,
      Math.min(chatAttachmentUploadLimit, input.maxUploadFiles)
    );
    let candidates: ChatAttachmentPickItem[] = [];
    let regularSnapshotBytes = 0;
    let regularBatchRejected = false;
    let uploadFiles = 0;
    let localFileCount = 0;

    // Admission is per class over the full selection: image uploads budget
    // only against the upload allowance and local refs only against the
    // local-file count and byte budgets. Slicing the selection by one
    // class's budget would silently drop the other class — with 50 local
    // refs attached and zero images, a selected PNG must still upload.
    const sources: ChatAttachmentSource[] =
      input.sources ??
      selected.filePaths.map((sourcePath) => ({ kind: "path", sourcePath }));
    for (const source of sources) {
      if (source.kind === "upload") {
        if (uploadFiles >= maxUploadFiles) {
          pushChatPickError(errors, {
            errorClass: "too_many_local_files",
            isImage: true,
            message: "No more uploads can be added to this message.",
            name: sanitizeLocalFileDisplayName(source.name),
            retryable: true,
          });
        } else {
          candidates.push(source);
          uploadFiles += 1;
        }
        continue;
      }
      const sourcePath = source.sourcePath;
      const sourceName = sanitizeLocalFileDisplayName(basename(sourcePath));
      const sourceIsImage = this.#uploadImageExtensions.has(
        extname(sourceName).toLowerCase()
      );
      if (!sourceIsImage && localFileCount >= maxFiles) {
        pushChatPickError(errors, {
          errorClass: "too_many_local_files",
          isImage: false,
          message: `Select at most ${maxFiles} more files.`,
          name: sourceName,
          retryable: true,
        });
        continue;
      }
      if (sourceIsImage && uploadFiles >= maxUploadFiles) {
        pushChatPickError(errors, {
          errorClass: "too_many_local_files",
          isImage: true,
          message: "No more image uploads can be added to this message.",
          name: sourceName,
          retryable: true,
        });
        continue;
      }
      if (!sourceIsImage && regularBatchRejected) {
        pushChatPickError(errors, {
          errorClass: "local_file_too_large",
          isImage: false,
          message: "Selected local files exceed the remaining combined limit.",
          name: sourceName,
          retryable: true,
        });
        continue;
      }

      if (sourceIsImage) {
        try {
          const image = await readBoundedLocalFileSource(
            sourcePath,
            chatAttachmentUploadMaxBytes
          );
          candidates.push({
            bytes: image.bytes,
            kind: "upload",
            name: image.name,
            size: image.size,
          });
          uploadFiles += 1;
        } catch (error) {
          pushChatPickError(errors, namedChatPickError(error, sourceName, true));
        }
        continue;
      }

      let snapshot: LocalFileSnapshot;
      try {
        const admission = getCurrentNativeSessionAdmission();
        snapshot = await this.#store.snapshot(sourcePath, admission.principalUserId);
      } catch (error) {
        pushChatPickError(errors, namedChatPickError(error, sourceName, false));
        continue;
      }

      if (regularSnapshotBytes + snapshot.size > maxTotalSize) {
        await this.#store.releaseDraft(snapshot.localFileRef).catch(() => false);
        await Promise.all(
          candidates.flatMap((candidate) =>
            candidate.kind === "local_file"
              ? [
                  this.#store
                    .releaseDraft(candidate.file.localFileRef)
                    .catch(() => false),
                ]
              : []
          )
        );
        candidates = candidates.filter((candidate) => candidate.kind === "upload");
        regularSnapshotBytes = 0;
        regularBatchRejected = true;
        pushChatPickError(errors, {
          errorClass: "local_file_too_large",
          isImage: false,
          message: "Selected local files exceed the remaining combined limit.",
          name: snapshot.name,
          retryable: true,
        });
        continue;
      }

      regularSnapshotBytes += snapshot.size;
      localFileCount += 1;
      candidates.push({ file: snapshot, kind: "local_file" });
    }

    const items: ChatAttachmentPickItem[] = [];
    for (const candidate of candidates) {
      if (candidate.kind === "upload") {
        items.push(candidate);
        continue;
      }
      try {
        input.assertLocalFileRegistrationAllowed();
        await this.#registrar.register(
          input.workspaceId,
          candidate.file,
          input.assertLocalFileRegistrationAllowed
        );
        items.push(candidate);
      } catch (error) {
        if (
          !(error instanceof LocalFileRouteRegistrationError) ||
          error.outcome === "rejected"
        ) {
          await this.#store
            .releaseDraft(candidate.file.localFileRef)
            .catch(() => false);
        }
        pushChatPickError(
          errors,
          namedChatPickError(error, candidate.file.name, false)
        );
      }
    }

    return { cancelled: false, errors, items };
  }
}

type PreviewWork<T> = {
  onAbort: () => void;
  reject: (error: Error) => void;
  resolve: (value: T | PromiseLike<T>) => void;
  signal: AbortSignal;
  task: () => Promise<T>;
};

class PreviewWorkQueue {
  #active = false;
  readonly #maxQueued: number;
  readonly #queued: PreviewWork<unknown>[] = [];

  constructor(maxQueued: number) {
    this.#maxQueued = maxQueued;
  }

  run<T>(signal: AbortSignal, task: () => Promise<T>): Promise<T> {
    if (signal.aborted) return Promise.reject(previewUnavailable());
    if (this.#active && this.#queued.length >= this.#maxQueued) {
      return Promise.reject(previewUnavailable());
    }

    return new Promise<T>((resolve, reject) => {
      const work: PreviewWork<T> = {
        onAbort: () => {
          const index = this.#queued.indexOf(work as PreviewWork<unknown>);
          if (index < 0) return;
          this.#queued.splice(index, 1);
          reject(previewUnavailable());
        },
        reject,
        resolve,
        signal,
        task,
      };
      if (this.#active) {
        signal.addEventListener("abort", work.onAbort, { once: true });
        this.#queued.push(work as PreviewWork<unknown>);
        return;
      }
      this.#start(work as PreviewWork<unknown>);
    });
  }

  #start(work: PreviewWork<unknown>) {
    this.#active = true;
    work.signal.removeEventListener("abort", work.onAbort);
    void Promise.resolve()
      .then(() => {
        throwIfAborted(work.signal);
        return work.task();
      })
      .then(work.resolve, work.reject)
      .finally(() => {
        this.#active = false;
        this.#drain();
      });
  }

  #drain() {
    while (!this.#active) {
      const next = this.#queued.shift();
      if (!next) return;
      next.signal.removeEventListener("abort", next.onAbort);
      if (next.signal.aborted) {
        next.reject(previewUnavailable());
        continue;
      }
      this.#start(next);
    }
  }
}

function inspectPreviewImageHeader(bytes: Buffer, mediaType: string) {
  const dimensions =
    mediaType === "image/png"
      ? inspectPngHeader(bytes)
      : mediaType === "image/jpeg"
        ? inspectJpegHeader(bytes)
        : mediaType === "image/gif"
          ? inspectGifHeader(bytes)
          : mediaType === "image/webp"
            ? inspectWebpHeader(bytes)
            : undefined;
  if (!dimensions || !validPreviewDimensions(dimensions.width, dimensions.height)) {
    throw previewUnavailable();
  }
}

function inspectPngHeader(bytes: Buffer) {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (
    bytes.byteLength < 33 ||
    !bytes.subarray(0, signature.byteLength).equals(signature) ||
    bytes.readUInt32BE(8) !== 13 ||
    bytes.toString("ascii", 12, 16) !== "IHDR"
  ) {
    return undefined;
  }
  const bitDepth = bytes[24];
  const colorType = bytes[25];
  const validBitDepth =
    (colorType === 0 && [1, 2, 4, 8, 16].includes(bitDepth ?? -1)) ||
    (colorType === 2 && [8, 16].includes(bitDepth ?? -1)) ||
    (colorType === 3 && [1, 2, 4, 8].includes(bitDepth ?? -1)) ||
    ((colorType === 4 || colorType === 6) && [8, 16].includes(bitDepth ?? -1));
  if (
    !validBitDepth ||
    bytes[26] !== 0 ||
    bytes[27] !== 0 ||
    (bytes[28] !== 0 && bytes[28] !== 1)
  ) {
    return undefined;
  }
  return { height: bytes.readUInt32BE(20), width: bytes.readUInt32BE(16) };
}

function inspectJpegHeader(bytes: Buffer) {
  if (bytes.byteLength < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
    return undefined;
  }
  const limit = Math.min(bytes.byteLength, JPEG_HEADER_SCAN_MAX_BYTES);
  let offset = 2;
  let segments = 0;
  while (offset < limit && segments < JPEG_HEADER_SCAN_MAX_SEGMENTS) {
    if (bytes[offset] !== 0xff) return undefined;
    while (offset < limit && bytes[offset] === 0xff) offset += 1;
    if (offset >= limit) return undefined;
    const marker = bytes[offset++]!;
    segments += 1;
    if (marker === 0x00) return undefined;
    if (marker === 0xd9 || marker === 0xda) return undefined;
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      continue;
    }
    if (offset + 2 > limit) return undefined;
    const segmentLength = bytes.readUInt16BE(offset);
    if (segmentLength < 2 || offset + segmentLength > limit) return undefined;
    if (marker === 0xc0 || marker === 0xc2) {
      if (segmentLength < 11 || bytes[offset + 2] !== 8) return undefined;
      const height = bytes.readUInt16BE(offset + 3);
      const width = bytes.readUInt16BE(offset + 5);
      const components = bytes[offset + 7];
      if (
        components === undefined ||
        components < 1 ||
        components > 4 ||
        segmentLength !== 8 + 3 * components
      ) {
        return undefined;
      }
      return { height, width };
    }
    if (
      marker === 0xc1 ||
      marker === 0xc3 ||
      (marker >= 0xc5 && marker <= 0xc7) ||
      (marker >= 0xc9 && marker <= 0xcb) ||
      (marker >= 0xcd && marker <= 0xcf)
    ) {
      return undefined;
    }
    offset += segmentLength;
  }
  return undefined;
}

function inspectGifHeader(bytes: Buffer) {
  if (bytes.byteLength < 10) return undefined;
  const signature = bytes.toString("ascii", 0, 6);
  if (signature !== "GIF87a" && signature !== "GIF89a") return undefined;
  return {
    height: bytes.readUInt16LE(8),
    width: bytes.readUInt16LE(6),
  };
}

function inspectWebpHeader(bytes: Buffer) {
  if (
    bytes.byteLength < 20 ||
    bytes.toString("ascii", 0, 4) !== "RIFF" ||
    bytes.toString("ascii", 8, 12) !== "WEBP"
  ) {
    return undefined;
  }
  const riffEnd = bytes.readUInt32LE(4) + 8;
  const chunkSize = bytes.readUInt32LE(16);
  const chunkEnd = 20 + chunkSize;
  if (
    riffEnd > bytes.byteLength ||
    riffEnd < 20 ||
    chunkEnd > riffEnd ||
    chunkEnd > bytes.byteLength
  ) {
    return undefined;
  }

  switch (bytes.toString("ascii", 12, 16)) {
    case "VP8X":
      if (chunkSize < 10 || chunkEnd < 30) return undefined;
      return {
        height: bytes.readUIntLE(27, 3) + 1,
        width: bytes.readUIntLE(24, 3) + 1,
      };
    case "VP8L": {
      if (chunkSize < 5 || chunkEnd < 25 || bytes[20] !== 0x2f) return undefined;
      const dimensions = bytes.readUInt32LE(21);
      return {
        height: ((dimensions >>> 14) & 0x3fff) + 1,
        width: (dimensions & 0x3fff) + 1,
      };
    }
    case "VP8 ":
      if (
        chunkSize < 10 ||
        chunkEnd < 30 ||
        bytes[23] !== 0x9d ||
        bytes[24] !== 0x01 ||
        bytes[25] !== 0x2a
      ) {
        return undefined;
      }
      return {
        height: bytes.readUInt16LE(28) & 0x3fff,
        width: bytes.readUInt16LE(26) & 0x3fff,
      };
    default:
      return undefined;
  }
}

function withinDimensions(
  width: number,
  height: number,
  maxDimension: number,
  maxPixels: number
) {
  return (
    Number.isSafeInteger(width) &&
    Number.isSafeInteger(height) &&
    width > 0 &&
    height > 0 &&
    width <= maxDimension &&
    height <= maxDimension &&
    width <= Math.floor(maxPixels / height)
  );
}

function validPreviewDimensions(width: number, height: number) {
  return withinDimensions(
    width,
    height,
    LOCAL_FILE_PREVIEW_INPUT_MAX_DIMENSION,
    LOCAL_FILE_PREVIEW_INPUT_MAX_PIXELS
  );
}

function validRenderedPreviewDimensions(width: number, height: number) {
  return withinDimensions(
    width,
    height,
    LOCAL_FILE_PREVIEW_RENDER_MAX_DIMENSION,
    LOCAL_FILE_PREVIEW_RENDER_MAX_PIXELS
  );
}

function throwIfAborted(signal: AbortSignal) {
  if (signal.aborted) throw previewUnavailable();
}

function previewUnavailable() {
  return new LocalFileSnapshotError(
    "local_file_unavailable",
    "Local snapshot cannot be previewed."
  );
}

function yieldToMainLoop() {
  return new Promise<void>((resolve) => setImmediate(resolve));
}

function namedChatPickError(
  error: unknown,
  name: string,
  isImage: boolean
): ChatPickAttachmentError {
  const publicError = publicSnapshotError(error);
  return {
    ...publicError,
    ...(isImage && publicError.errorClass === "local_file_too_large"
      ? { message: "The selected image is larger than 10 MB." }
      : {}),
    isImage,
    name,
  };
}

function pushChatPickError(
  errors: ChatPickAttachmentError[],
  error: ChatPickAttachmentError
) {
  if (errors.length < MAX_LOCAL_FILES_PER_PICK) errors.push(error);
}

function publicSnapshotError(error: unknown): LocalFilesPickResult["errors"][number] {
  if (error instanceof LocalFileSnapshotError) {
    const errorClass =
      error instanceof LocalFileRouteRegistrationError &&
      error.remediation === "reissue_connector_token"
        ? "connector_reconfiguration_required"
        : error.errorClass === "invalid_local_file_ref"
          ? "local_file_unavailable"
          : error.errorClass;
    return {
      errorClass,
      message:
        error instanceof LocalFileRouteRegistrationError
          ? error.message
          : errorClass === "local_file_too_large"
            ? "The selected file is too large."
            : errorClass === "local_file_unsupported"
              ? "The selected item is not a supported regular file."
              : "The selected file is unavailable.",
      retryable: errorClass !== "local_file_corrupt",
    };
  }
  return {
    errorClass: "local_file_unavailable",
    message: "The selected file is unavailable.",
    retryable: true,
  };
}
