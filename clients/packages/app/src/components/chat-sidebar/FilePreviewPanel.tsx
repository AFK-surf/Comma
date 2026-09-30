import type { AttachmentUploadInput } from "../chat/model/conversationChannel";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { fileDownloadMaxBytes, getNativeBridge } from "@comma/native-bridge";
import { useEffect, useMemo, useState } from "react";
import type { CommaApiClient } from "../../api";
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
  api,
  source,
  panelId,
  onOpenBrowser,
  onAttachFiles,
}: {
  api: CommaApiClient;
  source: ConversationFileSource;
  panelId: string;
  onOpenBrowser: (url: string) => void;
  onAttachFiles?: ((files: AttachmentUploadInput[]) => unknown) | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const { beginAttempt } = useChatRegistry();
  const key = conversationFileSourceKey(source);
  const [loaded, setState] = useState<{
    owner?: CommaApiClient;
    key?: string;
    blob?: Blob;
    error?: string;
  }>({});
  const state = loaded.owner === api && loaded.key === key ? loaded : {};
  // Each mounted selection owns its request. Switch/close unmounts it; a late
  // response cannot publish another selection (FilePreviewSelection.tla).
  useEffect(() => {
    const controller = new AbortController();
    const attempt = beginAttempt();
    const signal = AbortSignal.any([controller.signal, attempt.signal]);
    let current = true;
    setState({ owner: api, key });
    const clearRevoked = () => {
      if (current) setState({ owner: api, key, error: messages.file_preview_failed() });
    };
    signal.addEventListener("abort", clearRevoked, { once: true });
    void resolveConversationFile(api, source, signal).then(
      (blob) => {
        if (!current || signal.aborted || !attempt.isCurrent()) return;
        setState(
          blob.size > fileDownloadMaxBytes
            ? { owner: api, key, error: messages.file_preview_too_large() }
            : { owner: api, key, blob }
        );
      },
      () => {
        if (current)
          setState({ owner: api, key, error: messages.file_preview_failed() });
      }
    );
    return () => {
      current = false;
      signal.removeEventListener("abort", clearRevoked);
      controller.abort();
      attempt.release();
    };
  }, [api, key, source, beginAttempt, messages]);
  const download = useMemo(
    () => ({
      fileName: source.fileName,
      capability: createFileDownloadCapability(
        (signal) => resolveConversationFile(api, source, signal),
        { locale }
      ),
    }),
    [api, source, locale]
  );
  const openIn = useMemo(
    () =>
      createFileOpenInAction({
        api,
        source,
        bridge: getNativeBridge(),
        locale,
        beginAttempt,
      }),
    [api, source, locale, beginAttempt]
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
