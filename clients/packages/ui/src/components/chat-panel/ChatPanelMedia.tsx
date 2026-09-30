import {
  type CSSProperties,
  type MouseEvent as ReactMouseEvent,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { createPortal } from "react-dom";
import { useCommaMessages } from "@comma/i18n/react";
import { isReducedMotionEnabled, spacing } from "../../tokens";
import {
  CheckIcon,
  CopyIcon,
  DownloadIcon,
  FileTextIcon,
  PictureInPictureIcon,
} from "../icons";
import { cx } from "../utils";
import {
  ChatPanelMediaPlayer,
  resolveMediaFullWindowShortcut,
  useMediaPlaybackController,
} from "./ChatPanelMediaPlayer";
import {
  type ChatPanelMediaDownloadAction,
  formatMediaFileSize,
} from "./ChatPanelMediaDownload";
import {
  ChatPanelFileOpenInMenu,
  type ChatPanelFileOpenInAction,
} from "./ChatPanelFileOpenInMenu";
import {
  ChatPanelMediaDownloadControl,
  useChatPanelMediaDownloadController,
} from "./ChatPanelMediaDownloadControl";
import { ChatPanelMediaPreview } from "./ChatPanelMediaPreview";
import { useChatPanelVideoSurface } from "./ChatPanelVideoPictureInPicture";
import { useKeyboardFocusMotion } from "./useKeyboardFocusMotion";
import { usePointerPressFeedback } from "./usePointerPressFeedback";

export type {
  ChatPanelFileApplication,
  ChatPanelFileOpenInAction,
} from "./ChatPanelFileOpenInMenu";

export { downloadMediaSource } from "./ChatPanelMediaDownload";
export type {
  ChatPanelMediaDownloadAction,
  ChatPanelMediaDownloadCapability,
  ChatPanelMediaDownloadErrorCode,
  ChatPanelMediaDownloadKind,
  ChatPanelMediaDownloadRequest,
  ChatPanelMediaDownloadResult,
  DownloadMediaSourceOptions,
} from "./ChatPanelMediaDownload";

export interface ChatPanelAudioProps {
  className?: string;
  defaultCurrentTime?: number;
  defaultPlaying?: boolean;
  download?: ChatPanelMediaDownloadAction;
  duration?: number;
  src: string;
}

export interface ChatPanelImageProps {
  alt: string;
  className?: string;
  download?: ChatPanelMediaDownloadAction;
  onCopy?: () => Promise<void> | void;
  onContextMenu?: (event: ReactMouseEvent<HTMLElement>) => void;
  previewTitle?: string;
  src: string;
}

export interface ChatPanelFileProps {
  className?: string;
  fileName: string;
  fileSize?: number | string;
  mimeType?: string;
  /** Opens this file in the application's preview surface. */
  onPreview?: () => void;
  openIn?: ChatPanelFileOpenInAction;
  /** Stable hook for tests; rendered as `data-testid` on the card. */
  testId?: string;
  typeLabel?: string;
}

export interface ChatPanelVideoProps {
  alt: string;
  aspectRatio?: number;
  className?: string;
  defaultCurrentTime?: number;
  defaultPlaying?: boolean;
  download?: ChatPanelMediaDownloadAction;
  duration?: number;
  poster: string;
  previewTitle?: string;
  src: string;
  onContextMenu?: (event: ReactMouseEvent<HTMLElement>) => void;
}

const defaultVideoAspectRatio = 16 / 9;

/**
 * A floating video goes back to its frame this far before the frame scrolls
 * into view, so the reader never sees the frame empty.
 */
const pictureInPictureReturnMargin = spacing["6xl"];

const scrollPlayerIntoView = (player: HTMLElement) =>
  player.scrollIntoView({
    behavior: isReducedMotionEnabled() ? "instant" : "smooth",
    block: "center",
  });

const normalizeVideoAspectRatio = (value: number | undefined) =>
  value !== undefined && Number.isFinite(value) && value > 0 ? value : undefined;

const mimeTypeLabels: Record<string, string> = {
  "application/epub+zip": "EPUB",
  "application/json": "JSON",
  "application/msword": "DOC",
  "application/pdf": "PDF",
  "application/rtf": "RTF",
  "application/vnd.ms-excel": "XLS",
  "application/vnd.ms-powerpoint": "PPT",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation": "PPTX",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "XLSX",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "DOCX",
  "application/zip": "ZIP",
  "audio/mpeg": "MP3",
  "image/jpeg": "JPG",
  "text/csv": "CSV",
  "text/plain": "TXT",
  "video/mp4": "MP4",
};

const resolveFileType = ({
  fileName,
  mimeType,
  typeLabel,
}: {
  fileName: string;
  mimeType: string | undefined;
  typeLabel: string | undefined;
}) => {
  if (typeLabel?.trim()) return typeLabel.trim().toUpperCase();

  const normalizedMimeType = mimeType?.split(";")[0]?.trim().toLowerCase();
  if (normalizedMimeType) {
    const knownType = mimeTypeLabels[normalizedMimeType];
    if (knownType) return knownType;

    const subtype = normalizedMimeType.split("/")[1];
    if (subtype) {
      return subtype.replace(/^x-/, "").split(/[.+-]/).at(-1)!.toUpperCase();
    }
  }

  const cleanFileName = fileName.split(/[?#]/)[0] ?? fileName;
  const extension = cleanFileName.includes(".")
    ? cleanFileName.split(".").at(-1)
    : undefined;
  return extension?.trim() ? extension.toUpperCase() : "FILE";
};

const convertImageBlobToPng = async (blob: Blob) => {
  const objectUrl = URL.createObjectURL(blob);

  try {
    const image = await new Promise<HTMLImageElement>((resolve, reject) => {
      const element = new Image();
      element.addEventListener("load", () => resolve(element), { once: true });
      element.addEventListener(
        "error",
        () => reject(new Error("The generated image could not load.")),
        { once: true }
      );
      element.src = objectUrl;
    });
    if (!image.naturalWidth || !image.naturalHeight) {
      throw new Error("The generated image has no drawable dimensions.");
    }

    const canvas = document.createElement("canvas");
    canvas.width = image.naturalWidth;
    canvas.height = image.naturalHeight;
    const context = canvas.getContext("2d");
    if (!context) throw new Error("Image conversion is unavailable.");
    context.drawImage(image, 0, 0);

    return await new Promise<Blob>((resolve, reject) => {
      canvas.toBlob((pngBlob) => {
        if (pngBlob) resolve(pngBlob);
        else reject(new Error("The generated image could not be converted."));
      }, "image/png");
    });
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
};

const copyImageSource = async (src: string) => {
  if (!navigator.clipboard?.write || typeof ClipboardItem === "undefined") {
    throw new Error("Image clipboard writes are unavailable.");
  }

  const response = await fetch(src);
  if (!response.ok) throw new Error("The generated image could not be read.");

  const blob = await response.blob();
  if (!blob.type.startsWith("image/")) {
    throw new Error("The generated asset is not an image.");
  }

  const clipboardSupportsSourceType =
    typeof ClipboardItem.supports === "function" && ClipboardItem.supports(blob.type);
  const clipboardBlob =
    blob.type === "image/png" || clipboardSupportsSourceType
      ? blob
      : await convertImageBlobToPng(blob);
  await navigator.clipboard.write([
    new ClipboardItem({ [clipboardBlob.type]: clipboardBlob }),
  ]);
};

const CopyStateIcon = ({ copied }: { copied: boolean }) => (
  <span
    aria-hidden="true"
    className="t-icon-swap size-2xl"
    data-state={copied ? "b" : "a"}
    data-swap-blur="none"
  >
    <span className="t-icon inline-flex size-2xl" data-icon="a">
      <CopyIcon className="size-2xl" />
    </span>
    <span className="t-icon inline-flex size-2xl" data-icon="b">
      <CheckIcon className="size-2xl text-fg-success-primary" />
    </span>
  </span>
);

export const ChatPanelAudio = ({
  className,
  defaultCurrentTime,
  defaultPlaying,
  download,
  duration = 19,
  src,
}: ChatPanelAudioProps) => {
  const controller = useMediaPlaybackController({
    defaultCurrentTime,
    defaultPlaying,
    duration,
    sourceKey: src,
  });
  const downloadController = useChatPanelMediaDownloadController({
    action: download,
    kind: "audio",
    source: src,
  });

  return (
    <div className={cx("chat-panel-audio", className)}>
      {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- Captions are intentionally outside the generated-media component contract. */}
      <audio
        hidden
        onCanPlay={controller.handleCanPlay}
        onDurationChange={controller.handleDurationChange}
        onEmptied={controller.handleEmptied}
        onEnded={controller.handleEnded}
        onLoadedMetadata={controller.handleLoadedMetadata}
        onPause={controller.handlePause}
        onPlay={controller.handlePlay}
        onRateChange={controller.handleRateChange}
        onTimeUpdate={controller.handleTimeUpdate}
        preload="metadata"
        ref={controller.bindMediaElement}
        src={src}
      />
      <ChatPanelMediaPlayer
        controller={controller}
        {...(download ? { downloadController } : {})}
        kind="audio"
      />
    </div>
  );
};

export const ChatPanelImage = ({
  alt,
  className,
  download,
  onCopy,
  onContextMenu,
  previewTitle = "Generated image preview",
  src,
}: ChatPanelImageProps) => {
  const [copyState, setCopyState] = useState<"idle" | "copied" | "error">("idle");
  const [previewOpen, setPreviewOpen] = useState(false);
  const [previewInstantMotion, setPreviewInstantMotion] = useState(false);
  const previewTriggerRef = useRef<HTMLButtonElement | null>(null);
  const resetTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const keyboardFocusMotion = useKeyboardFocusMotion();
  const buttonPressFeedback = usePointerPressFeedback<HTMLButtonElement>();
  const downloadController = useChatPanelMediaDownloadController({
    action: download,
    kind: "image",
    source: src,
  });

  useEffect(
    () => () => {
      if (resetTimerRef.current) clearTimeout(resetTimerRef.current);
    },
    []
  );

  const copyImage = async () => {
    try {
      if (onCopy) {
        await onCopy();
      } else {
        await copyImageSource(src);
      }
      setCopyState("copied");
      if (resetTimerRef.current) clearTimeout(resetTimerRef.current);
      resetTimerRef.current = setTimeout(() => setCopyState("idle"), 1400);
    } catch {
      setCopyState("error");
      if (resetTimerRef.current) clearTimeout(resetTimerRef.current);
      resetTimerRef.current = setTimeout(() => setCopyState("idle"), 2000);
    }
  };

  const openPreview = (event: ReactMouseEvent<HTMLButtonElement>) => {
    setPreviewInstantMotion(event.detail === 0);
    setPreviewOpen(true);
  };

  return (
    <>
      <figure className={cx("chat-panel-image", className)} {...keyboardFocusMotion}>
        <button
          aria-label="Preview generated image"
          className="chat-panel-image-preview-trigger"
          {...buttonPressFeedback}
          onClick={openPreview}
          ref={previewTriggerRef}
          type="button"
        >
          {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- The displayed image owns its context menu. */}
          <img
            alt={alt}
            className="chat-panel-image-content"
            src={src}
            data-media-context-menu={onContextMenu ? "true" : undefined}
            onContextMenu={onContextMenu}
          />
        </button>
        <div className="chat-panel-image-toolbar">
          <button
            aria-label={
              copyState === "copied"
                ? "Image copied"
                : copyState === "error"
                  ? "Copy image failed. Try again"
                  : "Copy image"
            }
            className="chat-panel-image-action"
            {...buttonPressFeedback}
            onClick={() => void copyImage()}
            title={
              copyState === "copied"
                ? "Copied"
                : copyState === "error"
                  ? "Copy failed"
                  : "Copy image"
            }
            type="button"
          >
            <CopyStateIcon copied={copyState === "copied"} />
          </button>
          {download ? (
            <ChatPanelMediaDownloadControl
              buttonClassName="chat-panel-image-action"
              controller={downloadController}
              feedbackPlacement="below"
              icon={<DownloadIcon className="size-2xl" />}
              kind="image"
            />
          ) : null}
          <span aria-live="polite" className="sr-only">
            {copyState === "copied"
              ? "Image copied."
              : copyState === "error"
                ? "Could not copy the image."
                : ""}
          </span>
        </div>
      </figure>
      <ChatPanelMediaPreview
        instantMotion={previewInstantMotion}
        isOpen={previewOpen}
        onOpenChange={setPreviewOpen}
        returnFocusRef={previewTriggerRef}
        title={previewTitle}
      >
        <div className="chat-panel-media-preview-stage" data-media-kind="image">
          {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- The displayed image owns its context menu. */}
          <img
            alt={alt}
            src={src}
            data-media-context-menu={onContextMenu ? "true" : undefined}
            onContextMenu={onContextMenu}
          />
        </div>
      </ChatPanelMediaPreview>
    </>
  );
};

export const ChatPanelFile = ({
  className,
  fileName,
  fileSize,
  mimeType,
  onPreview,
  openIn,
  testId,
  typeLabel,
}: ChatPanelFileProps) => {
  const messages = useCommaMessages();
  const resolvedType = resolveFileType({ fileName, mimeType, typeLabel });

  return (
    <article className={cx("chat-panel-file", className)} data-testid={testId}>
      {onPreview ? (
        <button
          aria-label={messages.ui_file_preview({ fileName })}
          className="chat-panel-file-preview-trigger"
          onClick={onPreview}
          type="button"
        />
      ) : null}
      <span aria-hidden className="chat-panel-file-icon">
        <FileTextIcon className="size-3xl" />
      </span>
      <div className="chat-panel-file-details">
        <p className="chat-panel-file-name" title={fileName}>
          {fileName}
        </p>
        <p className="chat-panel-file-meta">
          {fileSize === undefined
            ? resolvedType
            : `${resolvedType} · ${formatMediaFileSize(fileSize)}`}
        </p>
      </div>
      {openIn ? (
        <div className="chat-panel-file-actions">
          <ChatPanelFileOpenInMenu action={openIn} />
        </div>
      ) : null}
    </article>
  );
};

export const ChatPanelVideo = ({
  alt,
  aspectRatio,
  className,
  defaultCurrentTime,
  defaultPlaying,
  download,
  duration = 19,
  poster,
  previewTitle = "Generated video preview",
  src,
  onContextMenu,
}: ChatPanelVideoProps) => {
  const messages = useCommaMessages();
  const [previewOpen, setPreviewOpen] = useState(false);
  const [previewInstantMotion, setPreviewInstantMotion] = useState(false);
  const suppliedAspectRatio = normalizeVideoAspectRatio(aspectRatio);
  const [resolvedAspectRatio, setResolvedAspectRatio] = useState(
    suppliedAspectRatio ?? defaultVideoAspectRatio
  );
  const previewTriggerRef = useRef<HTMLButtonElement | null>(null);
  const ratioSourceRef = useRef<"fallback" | "metadata" | "poster" | "supplied">(
    suppliedAspectRatio ? "supplied" : "fallback"
  );
  const controller = useMediaPlaybackController({
    defaultCurrentTime,
    defaultPlaying,
    duration,
    sourceKey: src,
  });
  const downloadController = useChatPanelMediaDownloadController({
    action: download,
    kind: "video",
    source: src,
  });
  const videoLayoutStyle = {
    "--chat-panel-video-aspect-ratio": resolvedAspectRatio,
  } as CSSProperties;
  const {
    pictureInPicture: pictureInPictureStore,
    reveal: revealSurface,
    revealPlayer,
    returnLabel,
    visible: surfaceVisible,
  } = useChatPanelVideoSurface();
  const pictureInPictureOwner = useId();
  const figureRef = useRef<HTMLElement | null>(null);
  const frameSlotRef = useRef<HTMLDivElement | null>(null);
  // The live `<video>` renders into this node, so a floating window can borrow
  // the playing element itself instead of restarting the source elsewhere.
  const [videoHost] = useState(() => {
    const host = document.createElement("div");
    host.className = "chat-panel-video-host";
    return host;
  });
  const [inView, setInView] = useState(true);
  const [pictureInPicture, setPictureInPicture] = useState(false);
  // A video the reader brought back stays in its frame until they have seen it
  // there; only leaving the view after that floats it again.
  const [returning, setReturning] = useState(false);
  const [returnRequested, setReturnRequested] = useState(false);
  const seen = inView && surfaceVisible !== false;
  if (returning && seen) setReturning(false);
  // Playing out of view opens the window. Only the reader ends it (Close, Jump
  // to message, Play here, Full window), even once the frame is back in view.
  const floating = pictureInPicture
    ? !previewOpen
    : pictureInPictureStore !== undefined &&
      controller.isPlaying &&
      !seen &&
      !previewOpen &&
      !returning;
  if (floating !== pictureInPicture) setPictureInPicture(floating);

  useLayoutEffect(() => {
    frameSlotRef.current!.append(videoHost);
  }, [videoHost]);

  useEffect(() => {
    if (!pictureInPictureStore) return undefined;
    const figure = figureRef.current!;
    const observer = new IntersectionObserver(
      (entries) => {
        const entry = entries.at(-1);
        if (entry) setInView(entry.isIntersecting);
      },
      {
        // A nested scrollport clips before a document-root margin applies.
        root: figure.closest('[data-slot="scroll-area-viewport"]'),
        rootMargin: `${pictureInPictureReturnMargin}px 0px`,
      }
    );
    observer.observe(figure);
    return () => observer.disconnect();
  }, [pictureInPictureStore]);

  // Brings the player back into view, first putting a hidden surface on screen.
  // Passive: the surface's own scroller finishes attaching in that same commit.
  useEffect(() => {
    if (!returnRequested || surfaceVisible === false) return;
    setReturnRequested(false);
    (revealPlayer ?? scrollPlayerIntoView)(figureRef.current!);
  }, [returnRequested, revealPlayer, surfaceVisible]);

  const playHere = () => {
    setPictureInPicture(false);
    setReturning(true);
  };

  const returnToPlayer = () => {
    playHere();
    if (surfaceVisible === false) revealSurface?.();
    setReturnRequested(true);
  };

  // Every commit while floating, so the window's controls follow playback.
  useLayoutEffect(() => {
    if (!pictureInPicture || !pictureInPictureStore) return;
    pictureInPictureStore.show(pictureInPictureOwner, {
      aspectRatio: resolvedAspectRatio,
      controller,
      onClose: () => {
        controller.pause();
        setPictureInPicture(false);
      },
      onExpand: () => {
        previewTriggerRef.current =
          figureRef.current?.querySelector<HTMLButtonElement>(
            '[data-slot="chat-panel-video-expand"]'
          ) ?? null;
        setPreviewInstantMotion(false);
        setPreviewOpen(true);
        returnToPlayer();
      },
      onReturn: returnToPlayer,
      returnLabel,
      title: previewTitle,
      video: videoHost,
    });
  });

  useLayoutEffect(() => {
    if (!pictureInPicture || !pictureInPictureStore) return undefined;
    return () => pictureInPictureStore.hide(pictureInPictureOwner);
  }, [pictureInPicture, pictureInPictureOwner, pictureInPictureStore]);

  useEffect(() => {
    const nextSuppliedAspectRatio = normalizeVideoAspectRatio(aspectRatio);
    if (!nextSuppliedAspectRatio) return;
    ratioSourceRef.current = "supplied";
    setResolvedAspectRatio(nextSuppliedAspectRatio);
  }, [aspectRatio]);

  useEffect(() => {
    if (suppliedAspectRatio || typeof Image === "undefined") return;

    const posterImage = new Image();
    posterImage.addEventListener(
      "load",
      () => {
        if (
          ratioSourceRef.current !== "fallback" ||
          !posterImage.naturalWidth ||
          !posterImage.naturalHeight
        ) {
          return;
        }
        ratioSourceRef.current = "poster";
        setResolvedAspectRatio(posterImage.naturalWidth / posterImage.naturalHeight);
      },
      { once: true }
    );
    posterImage.src = poster;

    return () => {
      posterImage.src = "";
    };
  }, [poster, suppliedAspectRatio]);

  const resolveMetadataAspectRatio = (
    event: React.SyntheticEvent<HTMLVideoElement>
  ) => {
    controller.handleLoadedMetadata(event);
    if (suppliedAspectRatio) return;
    const video = event.currentTarget;
    const metadataAspectRatio = normalizeVideoAspectRatio(
      video.videoHeight > 0 ? video.videoWidth / video.videoHeight : undefined
    );
    if (!metadataAspectRatio) return;
    ratioSourceRef.current = "metadata";
    setResolvedAspectRatio(metadataAspectRatio);
  };

  const mediaElement = (
    // oxlint-disable-next-line jsx-a11y/media-has-caption -- Captions are intentionally outside the generated-media component contract.
    <video
      aria-label={alt}
      className="chat-panel-video-content"
      data-media-context-menu={onContextMenu ? "true" : undefined}
      onContextMenu={onContextMenu}
      onCanPlay={controller.handleCanPlay}
      onDurationChange={controller.handleDurationChange}
      onEmptied={controller.handleEmptied}
      onEnded={controller.handleEnded}
      onLoadedMetadata={resolveMetadataAspectRatio}
      onPause={controller.handlePause}
      onPlay={controller.handlePlay}
      onRateChange={controller.handleRateChange}
      onTimeUpdate={controller.handleTimeUpdate}
      playsInline
      poster={poster}
      preload="metadata"
      ref={controller.bindMediaElement}
      src={src}
    />
  );

  const openPreview = (event: ReactMouseEvent<HTMLButtonElement>) => {
    previewTriggerRef.current = event.currentTarget;
    setPreviewInstantMotion(event.detail === 0);
    setPreviewOpen(true);
  };

  const handleVideoSurfaceClick = (event: ReactMouseEvent<HTMLDivElement>) => {
    const { eventModifier } = resolveMediaFullWindowShortcut();
    if (!event[eventModifier]) return;

    event.preventDefault();
    previewTriggerRef.current =
      event.currentTarget
        .closest(".chat-panel-video-stage")
        ?.querySelector<HTMLButtonElement>('[data-slot="chat-panel-video-expand"]') ??
      null;
    setPreviewInstantMotion(false);
    setPreviewOpen(true);
  };

  return (
    <>
      <figure
        className={cx("chat-panel-video", className)}
        ref={figureRef}
        style={videoLayoutStyle}
      >
        <div
          className="chat-panel-video-stage"
          data-picture-in-picture={pictureInPicture ? "true" : undefined}
        >
          {/* oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions -- Primary-modifier click is a pointer gesture; keyboard users open Full window from the expand control. */}
          <div className="chat-panel-video-surface" onClick={handleVideoSurfaceClick}>
            {previewOpen ? (
              <img alt={alt} className="chat-panel-video-content" src={poster} />
            ) : null}
            <div className="chat-panel-video-frame-slot" ref={frameSlotRef} />
            {createPortal(previewOpen ? null : mediaElement, videoHost)}
          </div>
          {pictureInPicture ? (
            <div className="chat-panel-video-pip-placeholder">
              <PictureInPictureIcon className="size-3xl" />
              <p className="chat-panel-video-pip-placeholder-label">
                {messages.ui_video_picture_in_picture_playing()}
              </p>
              <button
                className="chat-panel-video-pip-placeholder-action"
                onClick={playHere}
                type="button"
              >
                {messages.ui_video_picture_in_picture_play_here()}
              </button>
            </div>
          ) : null}
          <ChatPanelMediaPlayer
            controller={controller}
            {...(download ? { downloadController } : {})}
            kind="video"
            onExpand={openPreview}
            tone="dark"
          />
        </div>
      </figure>
      <ChatPanelMediaPreview
        instantMotion={previewInstantMotion}
        isOpen={previewOpen}
        onOpenChange={setPreviewOpen}
        returnFocusRef={previewTriggerRef}
        title={previewTitle}
      >
        <div
          className="chat-panel-media-preview-stage"
          data-media-kind="video"
          style={videoLayoutStyle}
        >
          {mediaElement}
          <ChatPanelMediaPlayer
            controller={controller}
            {...(download ? { downloadController } : {})}
            kind="video"
            tone="dark"
          />
        </div>
      </ChatPanelMediaPreview>
    </>
  );
};
