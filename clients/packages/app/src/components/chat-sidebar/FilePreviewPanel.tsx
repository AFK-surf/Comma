import type { AttachmentUploadInput } from "@comma/core/chat";
import { CoreError, useCall } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { useEffect, useMemo, useState } from "react";
import { createFileDownloadCapability } from "../../runtime-files/fileDownloads";
import { createFileOpenInAction } from "../../runtime-files/fileOpenActions";
import {
  conversationFileSourceKey,
  resolveConversationFile,
  type ConversationFileSource,
} from "../../runtime-files/fileSources";
import { useChatRegistry } from "../chat/ChatProvider";
import { FilePreviewPanel as SharedFilePreviewPanel } from "../file-preview/FilePreviewPanel";

export function FilePreviewPanel({
  source,
  panelId,
  onOpenBrowser,
  onAttachFiles,
}: {
  source: ConversationFileSource;
  panelId: string;
  onOpenBrowser: (url: string) => void;
  onAttachFiles?: ((files: AttachmentUploadInput[]) => unknown) | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const { beginAttempt } = useChatRegistry();
  const key = conversationFileSourceKey(source);
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
    void resolveConversationFile(call, source, signal).then(
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
  }, [call, key, source, beginAttempt, messages]);
  const download = useMemo(
    () => ({
      fileName: source.fileName,
      capability: createFileDownloadCapability(
        (signal) => resolveConversationFile(call, source, signal),
        { locale }
      ),
    }),
    [call, source, locale]
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
      error={state.error}
      panelId={panelId}
      testId="file-preview-panel"
      download={download}
      openIn={openIn}
      onOpenBrowser={onOpenBrowser}
      onAttachFiles={onAttachFiles}
    />
  );
}
