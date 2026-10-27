import type { ChatConversationFile } from "@comma/chat-contract";
import type { AttachmentUploadInput } from "@comma/core/chat";
import { CoreError, useCall, useTopic } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { useEffect, useMemo, useState } from "react";
import { createFileDownloadCapability } from "../../runtime-files/fileDownloads";
import { createFileOpenInAction } from "../../runtime-files/fileOpenActions";
import {
  conversationFileSource,
  conversationFileSourceKey,
  readConversationFileRange,
  resolveConversationFile,
  conversationFileLink,
  readConversationFileParts,
  saveConversationFile,
  type ConversationFileSource,
} from "../../runtime-files/fileSources";
import { useChatRegistry } from "../chat/ChatProvider";
import { driveStreamMediaType } from "../drive/driveStore";
import { filePreviewKind, textPreviewLimit } from "../file-preview/FilePreviewContent";
import type { RangedFile } from "../file-preview/PdfFilePreview";
import { FilePreviewPanel as SharedFilePreviewPanel } from "../file-preview/FilePreviewPanel";

const imageTypeByExtension: Record<string, string> = {
  avif: "image/avif",
  gif: "image/gif",
  jpeg: "image/jpeg",
  jpg: "image/jpeg",
  png: "image/png",
  svg: "image/svg+xml",
  webp: "image/webp",
};

/** The type an audio, video or image attachment is read as: the one it declares, else its name's. */
function streamMediaType(
  source: ConversationFileSource,
  kind: "audio" | "video" | "image"
) {
  const declared = source.mimeType?.split(";")[0]?.trim().toLowerCase();
  if (declared?.startsWith(`${kind}/`)) return declared;
  if (kind !== "image") return driveStreamMediaType(source.fileName);
  const extension = source.fileName.split(".").at(-1)?.toLowerCase() ?? "";
  return imageTypeByExtension[extension] ?? "image/png";
}

export function FilePreviewPanel({
  source,
  panelId,
  onOpenBrowser,
  onAttachFiles,
  onAttachConversationFiles,
}: {
  source: ConversationFileSource;
  panelId: string;
  onOpenBrowser: (url: string) => void;
  onAttachFiles?: ((files: AttachmentUploadInput[]) => unknown) | undefined;
  onAttachConversationFiles?: ((files: ChatConversationFile[]) => unknown) | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const { beginAttempt } = useChatRegistry();
  const key = conversationFileSourceKey(source);
  const kind = filePreviewKind(source.fileName, source.mimeType);
  // Audio, video and images load from a ranged URL, so a file of any size
  // shows without the window holding it.
  const streamed = kind === "audio" || kind === "video" || kind === "image";
  const { value: stream } = useTopic(
    streamed
      ? {
          topic: "fileStream",
          source: JSON.stringify(conversationFileSource(source)),
          type: streamMediaType(source, kind),
        }
      : null
  );
  const mediaUrl = stream?.status === "ready" ? (stream.url ?? undefined) : undefined;
  // What the preview reads of the file: a stream (audio, video, an image), spans
  // as pages ask (a PDF), the head it shows (text), or nothing (a type it
  // cannot show). The file is read whole only where the host cannot stream it.
  const reads = streamed
    ? stream?.status === "unsupported"
      ? "whole"
      : "stream"
    : kind === "pdf"
      ? "spans"
      : kind === "text" || kind === "markdown" || kind === "html"
        ? "head"
        : "none";
  const ranged = useMemo<RangedFile | undefined>(
    () =>
      reads === "spans"
        ? {
            read: (offset, length, signal) =>
              readConversationFileRange(call, source, offset, length, signal),
          }
        : undefined,
    [call, reads, source]
  );
  const [loaded, setState] = useState<{
    owner?: object;
    key?: string;
    blob?: Blob;
    error?: string;
  }>({});
  const state = loaded.owner === beginAttempt && loaded.key === key ? loaded : {};
  // Each mounted selection owns its request. Switch/close unmounts it; a late
  // response cannot publish another selection.
  useEffect(() => {
    if (reads !== "whole" && reads !== "head") return undefined;
    const controller = new AbortController();
    const attempt = beginAttempt();
    const signal = AbortSignal.any([controller.signal, attempt.signal]);
    let current = true;
    setState({ owner: beginAttempt, key });
    const clearRevoked = () => {
      if (current)
        setState({ owner: beginAttempt, key, error: messages.file_preview_failed() });
    };
    signal.addEventListener("abort", clearRevoked, { once: true });
    // One byte past what a text preview shows tells it whether the file goes on.
    const bytes =
      reads === "head"
        ? readConversationFileRange(call, source, 0, textPreviewLimit + 1, signal).then(
            (span) =>
              new Blob([span.bytes as Uint8Array<ArrayBuffer>], {
                type: source.mimeType ?? span.type,
              })
          )
        : resolveConversationFile(call, source, signal);
    void bytes.then(
      (blob) => {
        if (!current || signal.aborted || !attempt.isCurrent()) return;
        setState({ owner: beginAttempt, key, blob });
      },
      (error: unknown) => {
        if (current)
          setState({
            owner: beginAttempt,
            key,
            error:
              error instanceof CoreError && error.code === "too_large"
                ? messages.file_preview_too_large()
                : messages.file_preview_failed(),
          });
      }
    );
    return () => {
      current = false;
      signal.removeEventListener("abort", clearRevoked);
      controller.abort();
      attempt.release();
    };
  }, [call, key, source, beginAttempt, messages, reads]);
  // The desktop saves it into Downloads as it arrives, and a browser downloads
  // it from its media URL: either at any size.
  const save = useMemo(() => saveConversationFile(call, source), [call, source]);
  const link = useMemo(() => conversationFileLink(call, source), [call, source]);
  const parts = useMemo(() => readConversationFileParts(call, source), [call, source]);
  const download = useMemo(
    () => ({
      fileName: source.fileName,
      capability: createFileDownloadCapability(
        (signal) => resolveConversationFile(call, source, signal),
        { locale },
        { save, link, parts }
      ),
    }),
    [call, source, locale, save, link, parts]
  );
  const openIn = useMemo(
    () =>
      createFileOpenInAction({
        call,
        source,
        bridge: getNativeBridge(),
        locale,
        beginAttempt,
      }),
    [call, source, locale, beginAttempt]
  );
  return (
    <SharedFilePreviewPanel
      fileName={source.fileName}
      mimeType={source.mimeType}
      blob={state.blob}
      mediaUrl={mediaUrl}
      mediaKey={key}
      ranged={ranged}
      error={stream?.status === "failed" ? messages.file_preview_failed() : state.error}
      {...(reads === "none"
        ? { placeholder: messages.file_preview_unavailable() }
        : {})}
      panelId={panelId}
      testId="file-preview-panel"
      download={download}
      save={save}
      link={link}
      parts={parts}
      openIn={openIn}
      onOpenBrowser={onOpenBrowser}
      onAttachFiles={onAttachFiles}
      attachment={source}
      onAttachConversationFiles={onAttachConversationFiles}
    />
  );
}
