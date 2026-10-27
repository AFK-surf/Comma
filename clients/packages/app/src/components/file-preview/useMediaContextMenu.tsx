import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import {
  MediaContextMenu,
  type MediaContextMenuAction,
} from "@comma/ui/components/menu/MediaContextMenu";
import { toast } from "@comma/ui/components/toast";
import { useTextEditContextMenuState } from "@comma/ui/components/menu";
import {
  createContext,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type MouseEvent,
} from "react";
import type { ChatConversationFile } from "@comma/chat-contract";
import type { AttachmentUploadInput } from "@comma/core/chat";
import {
  canCopyFile,
  copyFile,
  copySavedFile,
} from "../../runtime-files/fileClipboard";
import type { ConversationFileSource } from "../../runtime-files/fileSources";
import { captureVideoFrame } from "../../runtime-files/videoFrame";
import { copyImageBlob } from "../../runtime-files/imageClipboard";
import {
  downloadFile,
  type DownloadLink,
  type ResolveFileBytes,
  type SaveToDownloads,
} from "../../runtime-files/fileDownloads";

export type MediaMenuSource = {
  fileName: string;
  resolve: ResolveFileBytes;
  /** How the desktop saves the file without reading it whole (a chat file of any size). */
  save?: SaveToDownloads | undefined;
  /** How a browser downloads the file itself, at any size (a chat file on the web). */
  link?: DownloadLink | undefined;
  /** How the file is read a part at a time for a browser to save, when it has no link (a Task's on a machine). */
  parts?: ResolveFileBytes | undefined;
  /** The message attachment this is, which Add to Context attaches by reference instead of its bytes. */
  attachment?: ConversationFileSource | undefined;
  video?: HTMLVideoElement;
};
export type OpenMediaMenu = (
  event: MouseEvent<HTMLElement>,
  source: MediaMenuSource
) => void;
export const MediaMenuContext = createContext<OpenMediaMenu | undefined>(undefined);

/** Captures the displayed resource, including SVG, without rasterizing attachments or saves. */
export function mediaElementSource(
  media: HTMLImageElement | HTMLVideoElement
): MediaMenuSource {
  const video = media instanceof HTMLVideoElement ? media : undefined;
  const src = media.currentSrc || media.src;
  const pathName = new URL(src, document.baseURI).pathname;
  let name = pathName.split("/").at(-1) || "";
  try {
    name = decodeURIComponent(name);
  } catch {
    /* Keep a literal filename. */
  }
  const extension = /\.(png|jpe?g|gif|webp|avif|svg|bmp|ico|tiff?|mp4|webm|mov|m4v)$/i;
  const label =
    media instanceof HTMLImageElement
      ? media.alt
      : (media.getAttribute("aria-label") ?? "");
  const fileName = extension.test(name)
    ? name
    : extension.test(label)
      ? label
      : video
        ? "video"
        : "image";
  return {
    fileName,
    ...(video ? { video } : {}),
    resolve: async (signal) => {
      const response = await fetch(src, {
        signal: signal
          ? AbortSignal.any([signal, AbortSignal.timeout(30_000)])
          : AbortSignal.timeout(30_000),
      });
      if (!response.ok) throw new Error("Image could not be read.");
      return response.blob();
    },
  };
}

function mediaFileName(fileName: string, blob: Blob) {
  if (/\.[a-z0-9]+$/i.test(fileName)) return fileName;
  const extensions: Record<string, string> = {
    "image/svg+xml": "svg",
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/gif": "gif",
    "image/webp": "webp",
    "image/avif": "avif",
    "image/bmp": "bmp",
    "image/tiff": "tiff",
    "image/x-icon": "ico",
    "video/mp4": "mp4",
    "video/webm": "webm",
    "video/quicktime": "mov",
    "video/x-m4v": "m4v",
  };
  return `${fileName}.${extensions[blob.type] ?? "png"}`;
}

export function useMediaContextMenu(
  onAttachFiles?: ((files: AttachmentUploadInput[]) => unknown) | undefined,
  onAttachConversationFiles?: ((files: ChatConversationFile[]) => unknown) | undefined
) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const triggerRef = useRef<Element | null>(null);
  const sourceRef = useRef<
    (MediaMenuSource & { copyFrame?: () => Promise<Blob> }) | null
  >(null);
  const [menuKind, setMenuKind] = useState<"image" | "video">("image");
  const [canCopy, setCanCopy] = useState(true);
  const lifetimeRef = useRef<AbortController | null>(null);
  useEffect(() => {
    const controller = new AbortController();
    lifetimeRef.current = controller;
    return () => controller.abort();
  }, []);
  const state = useTextEditContextMenuState({ isEnabled: true });
  const { openAtPointer } = state;
  const open = useCallback<OpenMediaMenu>(
    (event, source) => {
      event.preventDefault();
      event.stopPropagation();
      triggerRef.current = event.currentTarget;
      const copyFrame = source.video ? captureVideoFrame(source.video) : undefined;
      sourceRef.current = { ...source, ...(copyFrame ? { copyFrame } : {}) };
      setMenuKind(source.video ? "video" : "image");
      setCanCopy(!source.video || Boolean(copyFrame));
      openAtPointer(
        event.currentTarget,
        event.clientX,
        event.clientY,
        event.target instanceof Element ? event.target : event.currentTarget
      );
    },
    [openAtPointer]
  );
  const act = async (action: MediaContextMenuAction) => {
    const source = sourceRef.current;
    const signal = lifetimeRef.current?.signal;
    if (!source || !signal || signal.aborted) return;
    const resolve = async () => {
      const blob = await source.resolve(signal);
      signal.throwIfAborted();
      return blob;
    };

    try {
      if (action === "copy-frame" || (action === "copy" && !source.video)) {
        const blob = source.video ? await source.copyFrame?.() : await resolve();
        if (!blob) return;
        signal.throwIfAborted();
        await copyImageBlob(blob);
        toast.success(
          source.video
            ? messages.video_context_copied()
            : messages.drive_preview_copied_title(),
          {
            description: messages.drive_preview_copied_description({
              name: source.fileName,
            }),
            id: source.video ? "video-frame-copy" : "image-copy",
            testId: source.video ? "video-frame-copy" : "image-copy",
          }
        );
        return;
      }
      if (
        action === "add-to-context" &&
        source.attachment &&
        onAttachConversationFiles
      ) {
        const { attachment } = source;
        await onAttachConversationFiles([
          {
            conversationId: attachment.conversationId,
            messageId: attachment.messageId,
            index: attachment.attachmentIndex,
            name: attachment.fileName,
            size: attachment.size ?? 0,
          },
        ]);
        return;
      }
      if (action === "copy" && source.save) {
        await copySavedFile(source.save, locale, signal);
        return;
      }
      if (action === "save" && (source.save || source.link)) {
        await downloadFile(
          {
            fileName: source.fileName,
            resolve,
            save: source.save,
            link: source.link,
            parts: source.parts,
          },
          { locale }
        );
        return;
      }
      const blob = await resolve();
      if (action === "copy") {
        await copyFile(blob, mediaFileName(source.fileName, blob), locale, signal);
      } else if (action === "save") {
        await downloadFile(
          { fileName: mediaFileName(source.fileName, blob), resolve: async () => blob },
          { locale }
        );
      } else if (action === "add-to-context") {
        await onAttachFiles?.([
          { data: blob, name: mediaFileName(source.fileName, blob), size: blob.size },
        ]);
      }
    } catch (error) {
      if (signal.aborted) return;
      if (action === "save") {
        await downloadFile(
          {
            fileName: source.fileName,
            resolve: async () => {
              throw error;
            },
          },
          { locale }
        );
        return;
      }
      toast.error(
        action === "copy-frame"
          ? messages.video_context_copy_failed()
          : action === "copy"
            ? source.video
              ? messages.video_context_file_copy_failed()
              : messages.drive_preview_copy_failed_title()
            : source.video
              ? messages.video_context_attach_failed()
              : messages.image_context_attach_failed(),
        {
          id: "image-action-failed",
          testId: "image-action-failed",
        }
      );
    }
  };
  // The menu stays mounted in its conversation, which renders with each
  // streamed chunk: its props keep their identity so the memoized menu does
  // not render with it.
  const actRef = useRef(act);
  actRef.current = act;
  const onAction = useCallback(
    (action: MediaContextMenuAction) => void actRef.current(action),
    []
  );
  const { handleOpenChange } = state;
  const onOpenChange = useCallback(
    (isOpen: boolean) => {
      if (handleOpenChange(isOpen) && !isOpen) sourceRef.current = null;
    },
    [handleOpenChange]
  );
  const labels = useMemo(
    () => ({
      ariaLabel:
        menuKind === "video"
          ? messages.video_context_menu()
          : messages.image_context_menu(),
      addToContext: messages.image_context_add(),
      copy:
        menuKind === "video"
          ? messages.common_copy()
          : messages.drive_preview_copy_image(),
      ...(menuKind === "video"
        ? {
            copyFrame: messages.video_context_copy_frame(),
            // The web points to the desktop app, which copies files on
            // macOS and Windows; another desktop app (Linux) cannot yet.
            copyUnavailable:
              getNativeBridge().platform === "electron"
                ? messages.video_context_copy_unavailable()
                : messages.video_context_copy_desktop(),
          }
        : {}),
      save:
        menuKind === "video"
          ? messages.video_context_save()
          : messages.image_context_save(),
    }),
    [menuKind, messages]
  );
  return {
    open,
    menu: (
      <MediaContextMenu
        triggerRef={triggerRef}
        isOpen={state.isOpen}
        onOpenChange={onOpenChange}
        pointerOffsets={state.pointerOffsets}
        labels={labels}
        canAttach={Boolean(onAttachFiles)}
        canCopy={menuKind === "video" ? canCopyFile() : canCopy}
        canCopyFrame={canCopy}
        onAction={onAction}
      />
    ),
  };
}
