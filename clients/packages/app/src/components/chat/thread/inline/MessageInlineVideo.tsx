import { chatAttachmentDownloadMaxBytes } from "@comma/chat-contract";
import { useCommaLocale } from "@comma/i18n/react";
import { ChatPanelVideo } from "@comma/ui";
import {
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type SyntheticEvent,
} from "react";
import type { CommaApiClient } from "../../../../api";
import { createFileDownloadCapability } from "../../../../runtime-files/fileDownloads";
import {
  conversationFileSourceKey,
  resolveConversationFile,
  type ConversationFileSource,
} from "../../../../runtime-files/fileSources";
import type { InlineMediaType } from "../../../../runtime-files/inlineMedia";
import { MediaMenuContext } from "../../../file-preview/useMediaContextMenu";
import { useDriveObjectUrl } from "../../../drive/useDriveObjectUrl";
import type { ChatRegistryAttempt } from "../../ChatProvider";

/**
 * Plays an agent's video attachment in the message. The bytes come from the
 * same conversation attachment source the file card downloads and previews, so
 * authorization and the size limit stay with that one owner. Anything short of
 * a playable video reports `onUnavailable`, and the message paints the file
 * card instead.
 */
export function MessageInlineVideo({
  active,
  api,
  beginAttempt,
  mediaType,
  onUnavailable,
  position,
  source,
  testId,
}: {
  /** Bytes are requested only once the message has come near the viewport. */
  active: boolean;
  api: CommaApiClient;
  beginAttempt?:
    | (() => Pick<ChatRegistryAttempt, "signal" | "isCurrent" | "release">)
    | undefined;
  mediaType: Extract<InlineMediaType, `video/${string}`>;
  onUnavailable: (position: number) => void;
  /** The attachment's position in its message; identifies it to the owner. */
  position: number;
  /** Identity-stable per attachment: a new object restarts the request. */
  source: ConversationFileSource;
  testId: string;
}) {
  const locale = useCommaLocale();
  const openMediaMenu = useContext(MediaMenuContext);
  const key = conversationFileSourceKey(source);
  const [loaded, setLoaded] = useState<{ blob: Blob; key: string }>();
  const blob = loaded?.key === key ? loaded.blob : undefined;
  const url = useDriveObjectUrl(blob);

  useEffect(() => {
    if (!active) return undefined;
    const controller = new AbortController();
    const attempt = beginAttempt?.();
    const signal = attempt
      ? AbortSignal.any([controller.signal, attempt.signal])
      : controller.signal;
    let current = true;
    void resolveConversationFile(api, source, signal).then(
      (bytes) => {
        if (!current || signal.aborted || (attempt && !attempt.isCurrent())) return;
        if (bytes.size === 0 || bytes.size > chatAttachmentDownloadMaxBytes) {
          onUnavailable(position);
          return;
        }
        // The endpoint may answer with a generic content type; the decoder is
        // handed the allowlisted type the attachment was admitted under.
        setLoaded({ blob: new Blob([bytes], { type: mediaType }), key });
      },
      () => {
        if (current && !signal.aborted) onUnavailable(position);
      }
    );
    return () => {
      current = false;
      controller.abort();
      attempt?.release();
    };
  }, [active, api, beginAttempt, key, mediaType, onUnavailable, position, source]);

  const download = useMemo(
    () =>
      blob
        ? {
            capability: createFileDownloadCapability(async () => blob, { locale }),
            fileName: source.fileName,
            ...(source.size === undefined ? {} : { fileSize: source.size }),
          }
        : undefined,
    [blob, locale, source.fileName, source.size]
  );

  // The player swaps in a poster `<img>` while its full-window preview is open;
  // only the decoder's own failure turns the attachment back into a file card.
  const handleMediaError = useCallback(
    (event: SyntheticEvent<HTMLDivElement>) => {
      if (event.target instanceof HTMLVideoElement) onUnavailable(position);
    },
    [onUnavailable, position]
  );

  return (
    <div
      className="comma-chat-inline-video-frame"
      data-testid={testId}
      onErrorCapture={handleMediaError}
    >
      {url ? (
        <ChatPanelVideo
          alt={source.fileName}
          className="comma-chat-inline-video"
          poster=""
          previewTitle={source.fileName}
          src={url}
          {...(openMediaMenu && blob
            ? {
                onContextMenu: (event) => {
                  if (!(event.currentTarget instanceof HTMLVideoElement)) return;
                  openMediaMenu(event, {
                    fileName: source.fileName,
                    video: event.currentTarget,
                    // The opaque-origin desktop CSP forbids fetching blob:null URLs.
                    // Reuse bytes already admitted by the conversation file owner.
                    resolve: async () => blob,
                  });
                },
              }
            : {})}
          {...(download ? { download } : {})}
        />
      ) : (
        // Same box as the player's initial 16:9 frame, so the swap moves nothing.
        <div
          aria-hidden
          className="chat-panel-video comma-chat-inline-video"
          data-comma-inline-video-placeholder=""
        >
          <div className="chat-panel-video-stage" />
        </div>
      )}
    </div>
  );
}
