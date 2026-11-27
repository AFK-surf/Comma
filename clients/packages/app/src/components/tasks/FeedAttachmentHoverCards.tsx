import { useCall, useTopic, type TaskFile } from "@comma/core-client";
import { ChatPanelImage } from "@comma/ui/components/chat-panel";
import { FileTypeIcon } from "@comma/ui/components/file-type-icon";
import { HoverCard } from "@comma/ui/components/hover-card";
import { PlayIcon } from "@comma/ui/components/icons";
import {
  useHorizontalDragScroll,
  type TaskFeedEntry,
  type TaskFeedFile,
  type TaskFeedMedia,
  type TaskFeedPullRequest,
} from "@comma/ui/components/task-workspace";
import { cx } from "@comma/ui/components/utils";
import { useEffect, useMemo, useRef, useState, type ReactElement } from "react";
import {
  conversationFileSource,
  conversationFileSourceKey,
  readConversationFileParts,
  type ConversationFileSource,
} from "../../runtime-files/fileSources";
import { streamMediaType } from "../chat-sidebar/FilePreviewPanel";
import {
  TaskFilePreviewCard,
  taskFileSource,
  type TaskFilePreviewCache,
} from "../chat/tasks/TaskFilePreviewCard";
import { ChatLinkHoverCard } from "../chat/thread/inline/ChatLinkHoverCard";
import { useDriveObjectUrl } from "../drive/useDriveObjectUrl";

export type TaskFileListCache = Map<string, Promise<readonly TaskFile[] | null>>;

function loadTaskFilesForEntry(
  call: ReturnType<typeof useCall>,
  cache: TaskFileListCache,
  groupId: string,
  conversationId: string
): Promise<readonly TaskFile[] | null> {
  const key = `${groupId}:${conversationId}`;
  const existing = cache.get(key);
  if (existing) return existing;

  const request = call("taskFiles.list", {
    group: groupId,
    conversation: conversationId,
  })
    .then((value) => {
      if (value.status === "ready") return value.files;
      cache.delete(key);
      return null;
    })
    .catch(() => {
      cache.delete(key);
      return null;
    });

  cache.set(key, request);
  return request;
}

function matchTaskFile(
  files: readonly TaskFile[],
  feedFile: TaskFeedFile
): TaskFile | undefined {
  const target = feedFile.name.trim();
  return files.find((file) => file.file_name.trim() === target);
}

const ATTACHMENT_ID_RE = /^(.+):(\d+)$/;

function isVideoMedia(media: TaskFeedMedia): boolean {
  if (media.mimeType?.toLowerCase().startsWith("video/")) return true;
  const name = (media.filename ?? media.attachmentId).toLowerCase();
  return /\.(mp4|mov|webm|m4v|mkv)$/.test(name);
}

function directMediaSource(
  entry: TaskFeedEntry,
  media: TaskFeedMedia
): ConversationFileSource | null {
  const match = ATTACHMENT_ID_RE.exec(media.attachmentId);
  if (!match) return null;
  return {
    groupId: entry.groupId,
    conversationId: entry.conversationId,
    messageId: match[1]!,
    attachmentIndex: Number(match[2]),
    fileName: media.filename ?? media.attachmentId,
    ...(media.mimeType ? { mimeType: media.mimeType } : {}),
  };
}

function matchMediaTaskFile(
  files: readonly TaskFile[],
  entry: TaskFeedEntry,
  media: TaskFeedMedia,
  mediaIndex: number
): TaskFile | undefined {
  const targetName = media.filename?.trim();
  if (entry.outcomeMessageId && targetName) {
    const exact = files.find(
      (f) =>
        f.message_id === entry.outcomeMessageId && f.file_name.trim() === targetName
    );
    if (exact) return exact;
  }
  if (targetName) {
    const byName = files.find((f) => f.file_name.trim() === targetName);
    if (byName) return byName;
  }
  if (entry.outcomeMessageId) {
    const sameMsgMedia = files.filter(
      (f) =>
        f.message_id === entry.outcomeMessageId &&
        (f.type === "image" ||
          f.mime_type?.startsWith("image/") ||
          f.mime_type?.startsWith("video/"))
    );
    if (sameMsgMedia[mediaIndex]) return sameMsgMedia[mediaIndex];
  }
  return undefined;
}

function FeedMediaPlaceholder({
  label,
  mimeType,
  single,
}: {
  label: string;
  mimeType?: string | undefined;
  single: boolean;
}) {
  return (
    <div
      className={
        single
          ? "flex h-28 w-full items-center justify-center gap-2 rounded-2xl border border-secondary bg-secondary/20 px-4 text-xs text-tertiary"
          : "flex size-full items-center justify-center gap-1.5 px-3 text-xs text-tertiary"
      }
      data-slot="task-feed-media-fallback"
    >
      <FileTypeIcon className="size-4 shrink-0" fileName={label} mimeType={mimeType} />
      <span className="max-w-[180px] truncate">{label}</span>
    </div>
  );
}

function FeedMediaStreamItem({
  item,
  single,
  source,
}: {
  item: TaskFeedMedia;
  single: boolean;
  source: ConversationFileSource;
}) {
  const call = useCall();
  const video = isVideoMedia(item);
  const label = item.filename ?? item.attachmentId;
  const sourceKey = conversationFileSourceKey(source);
  const { value: stream } = useTopic({
    topic: "fileStream",
    source: JSON.stringify(conversationFileSource(source)),
    type: streamMediaType(source, video ? "video" : "image"),
  });
  const wholeRead = stream?.status === "unsupported";
  const streamUrl = stream?.status === "ready" ? (stream.url ?? undefined) : undefined;
  const [loaded, setLoaded] = useState<{ blob: Blob; key: string }>();
  const blob = loaded?.key === sourceKey ? loaded.blob : undefined;
  const blobUrl = useDriveObjectUrl(blob);
  const url = streamUrl ?? blobUrl;

  useEffect(() => {
    if (!wholeRead) return undefined;
    const controller = new AbortController();
    let active = true;
    void readConversationFileParts(
      call,
      source
    )(controller.signal).then(
      (bytes) => {
        if (!active || controller.signal.aborted || bytes.size === 0) return;
        setLoaded({ blob: bytes, key: sourceKey });
      },
      () => undefined
    );
    return () => {
      active = false;
      controller.abort();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [call, sourceKey, wholeRead]);

  if (!url) {
    return (
      <FeedMediaPlaceholder label={label} mimeType={item.mimeType} single={single} />
    );
  }

  if (video) {
    return (
      <div className="relative size-full">
        <video
          className={
            single ? "aspect-[16/9] w-full object-cover" : "size-full object-cover"
          }
          muted
          playsInline
          preload="metadata"
          src={url}
        />
        <span
          aria-hidden
          className="pointer-events-none absolute right-2 bottom-2 inline-flex size-6 items-center justify-center rounded-full bg-black/55 text-white backdrop-blur-xs"
        >
          <PlayIcon className="size-3" />
        </span>
      </div>
    );
  }

  return (
    <ChatPanelImage
      alt={label}
      className="max-w-full! aspect-auto! size-full! rounded-none! [&_.chat-panel-image-preview-trigger]:rounded-none! [&_img]:size-full [&_img]:object-cover"
      previewTitle={label}
      src={url}
    />
  );
}

export function FeedMediaStrip({
  entry,
  fileListCache,
  media,
}: {
  entry: TaskFeedEntry;
  fileListCache: TaskFileListCache;
  media: readonly TaskFeedMedia[];
}) {
  const call = useCall();
  const visibleItems = media;
  const directSources = useMemo(
    () => visibleItems.map((item) => directMediaSource(entry, item)),
    [entry, visibleItems]
  );
  const needsLookup = useMemo(
    () => directSources.some((src) => src === null),
    [directSources]
  );

  const containerRef = useRef<HTMLDivElement | null>(null);
  const { canScroll, dragging, handlers, scrolledLeft } =
    useHorizontalDragScroll(containerRef);
  const [inView, setInView] = useState(!needsLookup);
  const [listedFiles, setListedFiles] = useState<readonly TaskFile[] | null>(null);

  useEffect(() => {
    if (!needsLookup || inView) return;
    const node = containerRef.current;
    if (!node) return;
    if (typeof IntersectionObserver === "undefined") {
      setInView(true);
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          setInView(true);
          observer.disconnect();
        }
      },
      { rootMargin: "120px" }
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [inView, needsLookup]);

  useEffect(() => {
    if (!needsLookup || !inView) return;
    let active = true;
    void loadTaskFilesForEntry(
      call,
      fileListCache,
      entry.groupId,
      entry.conversationId
    ).then((files) => {
      if (active) setListedFiles(files);
    });
    return () => {
      active = false;
    };
  }, [call, entry.conversationId, entry.groupId, fileListCache, inView, needsLookup]);

  const single = visibleItems.length === 1;

  if (single) {
    const item = visibleItems[0]!;
    const label = item.filename ?? item.attachmentId;
    const matched =
      directSources[0] ??
      (listedFiles
        ? (() => {
            const found = matchMediaTaskFile(listedFiles, entry, item, 0);
            return found ? taskFileSource(entry.groupId, found) : null;
          })()
        : null);

    return (
      <div
        className="aspect-video w-full max-w-[340px] overflow-hidden rounded-xl border border-secondary bg-secondary/20"
        data-slot="task-feed-media-single"
        ref={containerRef}
      >
        {matched ? (
          <FeedMediaStreamItem item={item} single source={matched} />
        ) : (
          <FeedMediaPlaceholder label={label} mimeType={item.mimeType} single />
        )}
      </div>
    );
  }

  return (
    <div
      className={cx(
        "relative -mr-5 pr-5 flex flex-nowrap gap-2 overflow-x-auto overscroll-x-contain [scrollbar-width:none] [&::-webkit-scrollbar]:hidden",
        scrolledLeft
          ? "[mask-image:linear-gradient(to_right,transparent,black_18px,black_100%)]"
          : "",
        canScroll ? (dragging ? "cursor-grabbing select-none" : "cursor-grab") : ""
      )}
      data-slot="task-feed-media-carousel"
      ref={containerRef}
      {...handlers}
    >
      {visibleItems.map((item, idx) => {
        const label = item.filename ?? item.attachmentId;
        const matched =
          directSources[idx] ??
          (listedFiles
            ? (() => {
                const found = matchMediaTaskFile(listedFiles, entry, item, idx);
                return found ? taskFileSource(entry.groupId, found) : null;
              })()
            : null);

        return (
          <div
            className="h-[144px] w-[192px] shrink-0 overflow-hidden rounded-xl border border-secondary bg-secondary/20"
            data-slot="task-feed-media-cell"
            key={`${item.attachmentId}-${idx}`}
          >
            {matched ? (
              <FeedMediaStreamItem item={item} single={false} source={matched} />
            ) : (
              <FeedMediaPlaceholder
                label={label}
                mimeType={item.mimeType}
                single={false}
              />
            )}
          </div>
        );
      })}
    </div>
  );
}

/**
 * Mounted lazily only when the HoverCard actually opens, so zero `taskFiles.list`
 * requests fire until the reader hovers a file chip.
 */
function FeedTaskFileHoverContent({
  entry,
  file,
  fileListCache,
  previewCache,
}: {
  entry: TaskFeedEntry;
  file: TaskFeedFile;
  fileListCache: TaskFileListCache;
  previewCache: TaskFilePreviewCache;
}) {
  const call = useCall();
  const [state, setState] = useState<
    { status: "loading" } | { status: "ready"; matched?: TaskFile | undefined }
  >({ status: "loading" });

  useEffect(() => {
    let active = true;
    void loadTaskFilesForEntry(
      call,
      fileListCache,
      entry.groupId,
      entry.conversationId
    ).then((files) => {
      if (!active) return;
      setState({
        status: "ready",
        matched: files ? matchTaskFile(files, file) : undefined,
      });
    });
    return () => {
      active = false;
    };
  }, [call, entry.conversationId, entry.groupId, file, fileListCache]);

  if (state.status === "loading") {
    return (
      <div
        className="flex w-full flex-col gap-sm p-xxs"
        data-testid="feed-file-hover-loading"
      >
        <div className="h-3.5 w-40 animate-pulse rounded bg-secondary" />
        <div className="h-3 w-28 animate-pulse rounded bg-secondary" />
      </div>
    );
  }

  if (state.matched) {
    return (
      <TaskFilePreviewCard
        cache={previewCache}
        file={state.matched}
        groupId={entry.groupId}
      />
    );
  }

  return (
    <div
      className="flex w-full min-w-0 items-center gap-sm p-xxs"
      data-testid="feed-file-hover-fallback"
    >
      <FileTypeIcon
        className="size-8 shrink-0"
        fileName={file.name}
        mimeType={file.mimeType}
      />
      <div className="flex min-w-0 flex-col">
        <span className="truncate text-sm font-medium text-primary">{file.name}</span>
        {file.mimeType ? (
          <span className="truncate text-xs text-tertiary">{file.mimeType}</span>
        ) : null}
      </div>
    </div>
  );
}

export function FeedPullRequestHoverCard({
  anchor,
  pullRequest,
  workspaceId,
}: {
  anchor: ReactElement;
  pullRequest: TaskFeedPullRequest;
  workspaceId: string;
}) {
  return (
    <ChatLinkHoverCard
      anchor={anchor}
      href={pullRequest.url}
      label={`#${pullRequest.number}`}
      workspaceId={workspaceId}
    />
  );
}

export function FeedFileHoverCard({
  anchor,
  entry,
  file,
  fileListCache,
  previewCache,
}: {
  anchor: ReactElement;
  entry: TaskFeedEntry;
  file: TaskFeedFile;
  fileListCache: TaskFileListCache;
  previewCache: TaskFilePreviewCache;
}) {
  return (
    <HoverCard
      className="max-w-[calc(100vw-var(--spacing-xl)*2)]"
      content={
        <FeedTaskFileHoverContent
          entry={entry}
          file={file}
          fileListCache={fileListCache}
          previewCache={previewCache}
        />
      }
      placement="bottom start"
      pointerOnly
    >
      {anchor}
    </HoverCard>
  );
}
