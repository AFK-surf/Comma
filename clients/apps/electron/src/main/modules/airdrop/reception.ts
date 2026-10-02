import { stat } from "node:fs/promises";
import { basename, extname } from "node:path";
import { baseLocale, formatNumber, messages } from "@comma/i18n";
import type {
  AirDropFileKind,
  AirDropPreview,
  AirDropPreviewResult,
  AirDropState,
  AirDropTransfer,
  NotchAirDropTransfer,
  NotchHostEvent,
  NotchHostScenePayload,
} from "@comma/native-bridge";
import type { AirDropTransferProgress } from ".";
import { readMainLocale, type MainLocaleSource } from "../../main-locale";

export type AirDropAction =
  | "accept"
  | "decline"
  | "dismiss"
  | "hold"
  | "release"
  | "reveal";
type AirDropFailure = NonNullable<AirDropTransfer["failure"]>;

export interface AirDropReceptionProvider {
  state(input?: void): AirDropState;
  act(input: { action: AirDropAction; requestId: string }): AirDropState;
  preview(input: { index: number; requestId: string }): AirDropPreviewResult;
}

/** A rendered preview: its layout is public state, its bytes are served on request. */
export type AirDropPreviewImage = AirDropPreview & { bytes: Uint8Array };

/** Main's own NotchHost writer, which carries the AirDrop scene. */
export interface AirDropNotch {
  update(payload: NotchHostScenePayload): unknown;
}

/** Electron window, QuickLook and Finder seams; index.ts owns the real ones. */
export interface AirDropPresentationPlatform {
  /** Registration id of the focused Comma window that can show toasts. */
  focusedToastSurfaceId(): string | undefined;
  onFocusChanged(listener: () => void): () => void;
  onNotchEvent(listener: (event: NotchHostEvent) => void): () => void;
  renderPreview(
    path: string,
    size: { height: number; width: number }
  ): Promise<AirDropPreviewImage | undefined>;
  reveal(path: string): void;
}

export interface AirDropOfferPresentation {
  chatTitle?: string | undefined;
  files: readonly { isDirectory: boolean; name: string; size?: number | undefined }[];
  linkCount: number;
  requestId: string;
  senderName?: string | undefined;
  surfaceId?: string | undefined;
}

interface Entry {
  decide?: ((accept: boolean) => void) | undefined;
  /** The pointer or focus is on the toast: a result stays until it leaves. */
  held?: boolean | undefined;
  paths: string[];
  previews: (AirDropPreviewImage | undefined)[];
  /** Preview rendering starts when files land, before chat intake finishes. */
  received?:
    | Promise<{ files: AirDropTransfer["files"]; previews: Entry["previews"] }>
    | undefined;
  settledAt?: number | undefined;
  timer?: ReturnType<typeof setTimeout> | undefined;
  transfer: AirDropTransfer;
}

const MAX_TRANSFERS = 4;
/** A single file gets the toast's larger preview; several get tiles. */
const SINGLE_PREVIEW = { height: 110, width: 174 };
const TILE_PREVIEW = { height: 96, width: 96 };
const COMPLETED_LINGER_MS = 6_000;
const FAILED_LINGER_MS = 10_000;
const NOTCH_RESULT_MS = 4_000;

/**
 * Main-owned presentation of AirDrop reception. The toast in the window that
 * owns the destination chat and the Notch both render this state; a decision
 * from either answers the same pending offer. The Notch shows a transfer only
 * while that window is not focused, ahead of in-progress tasks.
 */
export class AirDropReception implements AirDropReceptionProvider {
  readonly #entries = new Map<string, Entry>();
  readonly #locale: MainLocaleSource;
  readonly #log: { warn(message: string): void } | undefined;
  readonly #notch: AirDropNotch;
  readonly #platform: AirDropPresentationPlatform;
  readonly #publish: (state: AirDropState) => void;
  readonly #unsubscribe: (() => void)[];
  #notchKey = "";
  #notchTimer: ReturnType<typeof setTimeout> | undefined;
  #revision = 0;

  constructor(options: {
    locale?: MainLocaleSource | undefined;
    log?: { warn(message: string): void } | undefined;
    notch: AirDropNotch;
    platform: AirDropPresentationPlatform;
    publish: (state: AirDropState) => void;
  }) {
    this.#locale = options.locale ?? baseLocale;
    this.#log = options.log;
    this.#notch = options.notch;
    this.#platform = options.platform;
    this.#publish = options.publish;
    this.#unsubscribe = [
      options.platform.onFocusChanged(() => this.#syncNotch()),
      options.platform.onNotchEvent((event) => {
        if (event.type !== "action" || !event.payload?.value) return;
        const action = event.payload.action;
        if (action === "airdrop:accept" || action === "airdrop:decline") {
          this.act({
            action: action === "airdrop:accept" ? "accept" : "decline",
            requestId: event.payload.value,
          });
        }
      }),
    ];
  }

  state(): AirDropState {
    return {
      revision: this.#revision,
      transfers: [...this.#entries.values()].map((entry) => entry.transfer),
    };
  }

  preview({
    index,
    requestId,
  }: {
    index: number;
    requestId: string;
  }): AirDropPreviewResult {
    const image = this.#entries.get(requestId)?.previews[index];
    return image
      ? { image: image.bytes, mediaType: image.mediaType, status: "ready" }
      : { status: "unavailable" };
  }

  act({ action, requestId }: { action: AirDropAction; requestId: string }) {
    const entry = this.#entries.get(requestId);
    if (entry && (action === "hold" || action === "release"))
      this.#hold(entry, action === "hold");
    else if (entry?.decide && action !== "reveal") entry.decide(action === "accept");
    else if (entry?.settledAt !== undefined && action === "dismiss")
      this.#remove(entry);
    else if (entry?.transfer.canReveal && action === "reveal" && entry.paths[0])
      this.#platform.reveal(entry.paths[0]);
    return this.state();
  }

  /** Shows the offer and resolves with the user's decision, or false on abort. */
  confirm(offer: AirDropOfferPresentation, signal: AbortSignal): Promise<boolean> {
    if (signal.aborted) return Promise.resolve(false);
    const entry = this.#add(offer, { phase: "offer" });
    this.#changed();
    return new Promise<boolean>((resolve) => {
      const decide = (accept: boolean) => {
        if (entry.decide !== decide) return;
        entry.decide = undefined;
        signal.removeEventListener("abort", abort);
        if (accept) this.#change(entry, { phase: "receiving" });
        else this.#remove(entry);
        resolve(accept);
      };
      const abort = () => decide(false);
      entry.decide = decide;
      signal.addEventListener("abort", abort, { once: true });
    });
  }

  /** An offer Comma cannot attach is declined at once; both surfaces say why. */
  refuse(offer: AirDropOfferPresentation, failure: "no_chat" | "directory") {
    this.#settle(this.#add(offer, { failure, phase: "failed" }), {});
  }

  /** The helper's byte count for an accepted upload, about once per second. */
  progress(requestId: string, { fraction }: AirDropTransferProgress) {
    const entry = this.#entries.get(requestId);
    if (entry?.transfer.phase === "receiving" && fraction !== undefined)
      this.#change(entry, { progress: fraction });
  }

  /** Files landed on disk: previews render while chat intake runs. */
  received(requestId: string, paths: readonly string[]) {
    const entry = this.#entries.get(requestId);
    if (!entry || entry.settledAt !== undefined) return;
    entry.paths = [...paths];
    entry.received = this.#describe(entry.paths);
  }

  async complete(requestId: string, unattachedCount: number) {
    const entry = this.#entries.get(requestId);
    if (!entry?.received || entry.settledAt !== undefined) return;
    const { files, previews } = await entry.received;
    if (this.#entries.get(requestId) !== entry || entry.settledAt !== undefined) return;
    if (unattachedCount >= files.length) {
      this.fail(requestId, "attach");
      return;
    }
    entry.previews = previews;
    this.#settle(entry, {
      canReveal: unattachedCount > 0,
      files,
      phase: "completed",
      unattachedCount,
    });
  }

  fail(requestId: string, failure: Exclude<AirDropFailure, "directory">) {
    const entry = this.#entries.get(requestId);
    if (!entry || entry.settledAt !== undefined) return;
    this.#settle(entry, {
      canReveal: entry.paths.length > 0,
      failure,
      phase: "failed",
    });
  }

  /** A session change ends every transfer without showing a failure. */
  reset() {
    if (!this.#entries.size) return;
    const entries = [...this.#entries.values()];
    this.#entries.clear();
    for (const entry of entries) {
      clearTimeout(entry.timer);
      entry.decide?.(false);
    }
    this.#changed();
  }

  close() {
    for (const unsubscribe of this.#unsubscribe) unsubscribe();
    clearTimeout(this.#notchTimer);
    this.reset();
  }

  #add(
    offer: AirDropOfferPresentation,
    initial: Pick<AirDropTransfer, "failure" | "phase">
  ) {
    // The receiver admits at most four offers; settled results make room.
    for (const entry of this.#entries.values()) {
      if (this.#entries.size < MAX_TRANSFERS) break;
      if (entry.settledAt !== undefined) {
        clearTimeout(entry.timer);
        this.#entries.delete(entry.transfer.requestId);
      }
    }
    const entry: Entry = {
      paths: [],
      previews: [],
      transfer: {
        canReveal: false,
        ...(offer.chatTitle ? { chatTitle: offer.chatTitle.slice(0, 512) } : {}),
        files: offer.files.map((file) => ({
          kind: file.isDirectory ? "folder" : fileKind(file.name),
          name: displayName(file.name),
          ...(file.size === undefined ? {} : { size: file.size }),
        })),
        linkCount: offer.linkCount,
        ...initial,
        requestId: offer.requestId,
        ...(offer.senderName ? { senderName: displayName(offer.senderName, 160) } : {}),
        ...(offer.surfaceId ? { surfaceId: offer.surfaceId } : {}),
        unattachedCount: 0,
      },
    };
    this.#entries.set(offer.requestId, entry);
    return entry;
  }

  #change(entry: Entry, patch: Partial<AirDropTransfer>) {
    entry.transfer = { ...entry.transfer, ...patch };
    this.#changed();
  }

  #settle(entry: Entry, patch: Partial<AirDropTransfer>) {
    entry.settledAt = Date.now();
    this.#change(entry, patch);
    this.#linger(entry);
  }

  /**
   * A settled result leaves on its own after a while. Files still on this Mac
   * wait for the user to reveal or dismiss them, and a result the user is
   * looking at, such as a strip they are scrolling, waits until they look away.
   */
  #linger(entry: Entry) {
    clearTimeout(entry.timer);
    entry.timer =
      entry.settledAt === undefined || entry.transfer.canReveal || entry.held
        ? undefined
        : setTimeout(
            () => this.#remove(entry),
            entry.transfer.phase === "completed"
              ? COMPLETED_LINGER_MS
              : FAILED_LINGER_MS
          );
  }

  #hold(entry: Entry, held: boolean) {
    if (entry.held === held) return;
    entry.held = held;
    this.#linger(entry);
  }

  #remove(entry: Entry) {
    if (this.#entries.get(entry.transfer.requestId) !== entry) return;
    clearTimeout(entry.timer);
    this.#entries.delete(entry.transfer.requestId);
    this.#changed();
  }

  #changed() {
    this.#revision += 1;
    this.#publish(this.state());
    this.#syncNotch();
  }

  async #describe(paths: readonly string[]) {
    const size = paths.length === 1 ? SINGLE_PREVIEW : TILE_PREVIEW;
    const described = await Promise.all(
      paths.slice(0, 50).map(async (path) => {
        const [info, image] = await Promise.all([
          stat(path).catch(() => undefined),
          this.#platform.renderPreview(path, size).catch(() => undefined),
        ]);
        const file: AirDropTransfer["files"][number] = {
          kind: info?.isDirectory() ? "folder" : fileKind(path),
          name: displayName(basename(path)),
          ...(image
            ? {
                preview: {
                  height: image.height,
                  mediaType: image.mediaType,
                  width: image.width,
                },
              }
            : {}),
          ...(info?.isFile() ? { size: info.size } : {}),
        };
        return { file, image };
      })
    );
    return {
      files: described.map(({ file }) => file),
      previews: described.map(({ image }) => image),
    };
  }

  #syncNotch() {
    clearTimeout(this.#notchTimer);
    const focused = this.#platform.focusedToastSurfaceId();
    const now = Date.now();
    const visible = [...this.#entries.values()].filter(
      (entry) =>
        (focused === undefined || entry.transfer.surfaceId !== focused) &&
        (entry.settledAt === undefined || now - entry.settledAt < NOTCH_RESULT_MS)
    );
    const shown =
      visible.findLast((entry) => entry.transfer.phase === "offer") ??
      visible.findLast((entry) => entry.transfer.phase === "receiving") ??
      visible.at(-1);
    const nextExpiry = Math.min(
      ...visible.map((entry) =>
        entry.settledAt === undefined
          ? Infinity
          : entry.settledAt + NOTCH_RESULT_MS - now
      )
    );
    if (Number.isFinite(nextExpiry))
      this.#notchTimer = setTimeout(() => this.#syncNotch(), Math.max(0, nextExpiry));

    const transfer = shown ? this.#notchTransfer(shown) : undefined;
    // Previews and labels change only with a transfer's phase or outcome; the
    // ring moves in whole percents.
    const key = transfer
      ? `${transfer.requestId}:${transfer.phase}:${transfer.title}:${Math.floor((transfer.progress ?? -1) * 100)}`
      : "";
    if (key === this.#notchKey) return;
    this.#notchKey = key;
    Promise.resolve(
      this.#notch.update({ airDrop: transfer ? { transfer } : {} })
    ).catch((error: unknown) =>
      this.#log?.warn(
        `AirDrop Notch update failed: ${error instanceof Error ? error.message : String(error)}`
      )
    );
  }

  #notchTransfer(entry: Entry): NotchAirDropTransfer {
    const { transfer } = entry;
    const current = readMainLocale(this.#locale);
    const locale = { locale: current };
    const sender = transfer.senderName ?? messages.airdrop_unknown_sender({}, locale);
    const chat = transfer.chatTitle ?? "";
    const counted = (count: number) => ({
      count,
      formattedCount: formatNumber(count, current),
    });
    // The Notch speaks with the toast's status copy. It has no room for the
    // toast's strip of files, so several files are a count in the title.
    const several = transfer.files.length > 1;
    const copy =
      transfer.phase === "offer"
        ? {
            subtitle: messages.airdrop_chat_destination({ chat }, locale),
            title: several
              ? messages.airdrop_offer_files_title(
                  { ...counted(transfer.files.length), sender },
                  locale
                )
              : messages.airdrop_offer_title({ sender }, locale),
          }
        : transfer.phase === "receiving"
          ? {
              subtitle: messages.airdrop_chat_destination({ chat }, locale),
              title: several
                ? messages.airdrop_receiving_files_title(
                    { ...counted(transfer.files.length), sender },
                    locale
                  )
                : messages.airdrop_receiving_title({ sender }, locale),
            }
          : transfer.phase === "completed"
            ? {
                ...(transfer.unattachedCount
                  ? {
                      subtitle: messages.airdrop_completed_unattached(
                        counted(transfer.unattachedCount),
                        locale
                      ),
                    }
                  : {}),
                // Counts only what reached the chat; the subtitle names the rest.
                title: several
                  ? messages.airdrop_completed_files_title(
                      {
                        ...counted(transfer.files.length - transfer.unattachedCount),
                        chat,
                      },
                      locale
                    )
                  : messages.airdrop_completed_title({ chat }, locale),
              }
            : {
                subtitle:
                  transfer.failure === "no_chat"
                    ? messages.airdrop_failed_no_chat({}, locale)
                    : transfer.failure === "directory"
                      ? messages.airdrop_failed_directory({}, locale)
                      : transfer.failure === "attach"
                        ? messages.airdrop_failed_attach({}, locale)
                        : messages.airdrop_failed_transfer({}, locale),
                title: messages.airdrop_failed_title({}, locale),
              };
    return {
      ...(transfer.phase === "offer"
        ? {
            acceptLabel: messages.airdrop_accept({}, locale),
            declineLabel: messages.airdrop_decline({}, locale),
          }
        : {}),
      phase: transfer.phase,
      ...(transfer.phase === "completed" && !several && entry.previews[0]
        ? { preview: Buffer.from(entry.previews[0].bytes).toString("base64") }
        : {}),
      ...(transfer.phase === "receiving" && transfer.progress !== undefined
        ? { progress: transfer.progress }
        : {}),
      requestId: transfer.requestId,
      ...copy,
    };
  }
}

const imageExtensions = new Set([
  ".avif",
  ".bmp",
  ".dng",
  ".gif",
  ".heic",
  ".heif",
  ".jpeg",
  ".jpg",
  ".png",
  ".svg",
  ".tif",
  ".tiff",
  ".webp",
]);
const videoExtensions = new Set([".avi", ".m4v", ".mkv", ".mov", ".mp4", ".webm"]);
const documentExtensions = new Set([
  ".csv",
  ".doc",
  ".docx",
  ".json",
  ".key",
  ".md",
  ".numbers",
  ".pages",
  ".pdf",
  ".ppt",
  ".pptx",
  ".rtf",
  ".txt",
  ".xls",
  ".xlsx",
]);
const archiveExtensions = new Set([
  ".7z",
  ".dmg",
  ".gz",
  ".rar",
  ".tar",
  ".tgz",
  ".zip",
]);

export function fileKind(name: string): AirDropFileKind {
  const extension = extname(name).toLowerCase();
  if (imageExtensions.has(extension)) return "image";
  if (videoExtensions.has(extension)) return "video";
  if (documentExtensions.has(extension)) return "document";
  if (archiveExtensions.has(extension)) return "archive";
  return "file";
}

/** Sender-provided names are display text: one line, bounded. */
function displayName(name: string, maxLength = 512) {
  return name.replace(/[\r\n\t]/g, " ").slice(0, maxLength);
}
