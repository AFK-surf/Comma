import { useCall, useTopic } from "@comma/core-client";
import { useCommaLocale } from "@comma/i18n/react";
import { ChatPanelVideo } from "@comma/ui/components/chat-panel";
import {
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type SyntheticEvent,
} from "react";
import { createFileDownloadCapability } from "../../../../runtime-files/fileDownloads";
import {
  conversationFileSource,
  conversationFileSourceKey,
  resolveConversationFile,
  conversationFileLink,
  readConversationFileParts,
  saveConversationFile,
  type ConversationFileSource,
} from "../../../../runtime-files/fileSources";
import type { InlineMediaType } from "../../../../runtime-files/inlineMedia";
import { MediaMenuContext } from "../../../file-preview/useMediaContextMenu";
import { useDriveObjectUrl } from "../../../drive/useDriveObjectUrl";
import type { ChatRegistryAttempt } from "../../ChatProvider";

/**
 * Plays an agent's video attachment in the message, from the same conversation
 * attachment source the file card downloads and previews, so authorization
 * stays with that one owner. Where the host streams (the desktop app), the
 * player reads the ranges it needs from the core's `fileStream` URL, so a video
 * of any size plays; on the web it reads them from the server's media URL. A
 * renewed URL (a new session generation, a media URL minted again) keeps the
 * player's position. Where the host can only read whole, the core reads the
 * bytes up to its 10 MB bound. Anything short of a playable video reports
 * `onUnavailable`, and the message paints the file card instead.
 */
export function MessageInlineVideo({
  active,
  beginAttempt,
  mediaType,
  onUnavailable,
  position,
  source,
  testId,
}: {
  /** Bytes are requested only once the message has come near the viewport. */
  active: boolean;
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
  const call = useCall();
  const openMediaMenu = useContext(MediaMenuContext);
  const key = conversationFileSourceKey(source);
  const { value: stream } = useTopic(
    active
      ? {
          topic: "fileStream",
          source: JSON.stringify(conversationFileSource(source)),
          type: mediaType,
        }
      : null
  );
  // Read a part at a time, at any size, only where the host cannot stream (a Task's on a machine, on the web).
  const wholeRead = stream?.status === "unsupported";
  const streamFailed = stream?.status === "failed";
  const streamUrl = stream?.status === "ready" ? (stream.url ?? undefined) : undefined;
  const [loaded, setLoaded] = useState<{ blob: Blob; key: string }>();
  const blob = loaded?.key === key ? loaded.blob : undefined;
  const blobUrl = useDriveObjectUrl(blob);
  const url = streamUrl ?? blobUrl;

  useEffect(() => {
    if (active && streamFailed) onUnavailable(position);
  }, [active, onUnavailable, position, streamFailed]);

  useEffect(() => {
    if (!active || !wholeRead) return undefined;
    const controller = new AbortController();
    const attempt = beginAttempt?.();
    const signal = attempt
      ? AbortSignal.any([controller.signal, attempt.signal])
      : controller.signal;
    let current = true;
    void readConversationFileParts(
      call,
      source
    )(signal).then(
      (bytes) => {
        if (!current || signal.aborted || (attempt && !attempt.isCurrent())) return;
        if (bytes.size === 0) {
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
  }, [
    active,
    call,
    beginAttempt,
    key,
    mediaType,
    onUnavailable,
    position,
    source,
    wholeRead,
  ]);

  // Bytes already read are reused; a streamed video is read for the action.
  const resolveBytes = useMemo(
    () =>
      blob
        ? async () => blob
        : streamUrl
          ? (signal?: AbortSignal) => resolveConversationFile(call, source, signal)
          : undefined,
    [blob, call, source, streamUrl]
  );
  // The desktop saves it into Downloads as it arrives, and a browser downloads
  // it from its media URL: either at any size.
  const save = useMemo(() => saveConversationFile(call, source), [call, source]);
  const link = useMemo(() => conversationFileLink(call, source), [call, source]);
  const parts = useMemo(() => readConversationFileParts(call, source), [call, source]);
  const download = useMemo(
    () =>
      resolveBytes
        ? {
            capability: createFileDownloadCapability(
              resolveBytes,
              { locale },
              { save, link, parts }
            ),
            fileName: source.fileName,
            ...(source.size === undefined ? {} : { fileSize: source.size }),
          }
        : undefined,
    [resolveBytes, locale, save, link, parts, source.fileName, source.size]
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
          // The stream answers CORS, so a frame can be copied from it.
          {...(streamUrl ? { crossOrigin: "anonymous" as const } : {})}
          poster=""
          previewTitle={source.fileName}
          sourceKey={key}
          src={url}
          {...(openMediaMenu && resolveBytes
            ? {
                onContextMenu: (event) => {
                  if (!(event.currentTarget instanceof HTMLVideoElement)) return;
                  openMediaMenu(event, {
                    fileName: source.fileName,
                    video: event.currentTarget,
                    // The opaque-origin desktop CSP forbids fetching blob:null URLs.
                    // Bytes come from the conversation file owner instead.
                    resolve: resolveBytes,
                    save,
                    link,
                    parts,
                    attachment: source,
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
