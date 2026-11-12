// What a Task file's hover card shows: an image or a video's first frame from the file's stream URL (`fileStream`),
// a PDF's first page, the first lines of a text file, and for every file its name, type, size and time. The card
// mounts only once it opens, so a pointer that crosses the list reads nothing. A preview that arrives after the card
// opened fades in; one ready as it opens shows at once.
//
// Bounds: a text file is read once per Task panel, at most `headBytes` of it. A PDF's first page is drawn once per
// Task panel from the spans of the file it needs, in one shared pdf.js worker, and kept as a small JPEG; the panel
// keeps its `coversKept` latest, each behind one object URL that is revoked when the cover is dropped or the panel
// closes. Either read stops when the card closes first. An image or a video reads only what its element asks of the
// stream URL. Audio or any other file shows its details alone.
import { formatDate } from "@comma/i18n";
import { useCommaLocale } from "@comma/i18n/react";
import { useCall, useTopic, type TaskFile } from "@comma/core-client";
import { FileTypeIcon } from "@comma/ui/components/file-type-icon";
import { useCallback, useEffect, useState } from "react";
import type { RenderTask } from "pdfjs-dist";
import {
  conversationFileSource,
  conversationFileSourceKey,
  readConversationFileRange,
  type ConversationFileSource,
} from "../../../runtime-files/fileSources";
import { streamMediaType } from "../../chat-sidebar/FilePreviewPanel";
import { filePreviewKind } from "../../file-preview/FilePreviewContent";
import { openPdfDocument } from "../../file-preview/PdfFilePreview";
import { formatAttachmentSize } from "../thread/attachments/attachmentLabels";

/** Enough of a text file for the lines the card shows. */
const headBytes = 2048;
/** The longest side a PDF's cover is drawn at, in CSS pixels: the card's width. */
const coverEdge = 320;
/** The covers a Task panel keeps, the oldest dropped first: tens of KB each. */
const coversKept = 16;

/** What a Task panel's cards have read, by file, so a second hover reads nothing. */
export interface TaskFilePreviewCache {
  heads: Map<string, string>;
  /** Object URLs of the drawn covers: a second hover shows the same image in its first frame. */
  covers: Map<string, string>;
}

export const createTaskFilePreviewCache = (): TaskFilePreviewCache => ({
  heads: new Map(),
  covers: new Map(),
});

/** Drops the covers when their Task panel closes. */
export function releaseTaskFilePreviewCache(cache: TaskFilePreviewCache) {
  for (const url of cache.covers.values()) URL.revokeObjectURL(url);
  cache.covers.clear();
}

export function taskFileSource(
  groupId: string,
  file: TaskFile
): ConversationFileSource {
  return {
    groupId,
    conversationId: file.conversation_id,
    messageId: file.message_id,
    attachmentIndex: file.index,
    fileName: file.file_name,
    ...(file.mime_type ? { mimeType: file.mime_type } : {}),
    size: file.size,
  };
}

export function TaskFilePreviewCard({
  cache,
  file,
  groupId,
}: {
  cache: TaskFilePreviewCache;
  file: TaskFile;
  groupId: string;
}) {
  const locale = useCommaLocale();
  const kind = filePreviewKind(file.file_name, file.mime_type ?? "");
  const extension = file.file_name.includes(".")
    ? file.file_name.split(".").at(-1)?.toUpperCase()
    : undefined;
  const details = [
    extension,
    formatAttachmentSize(file.size, locale),
    formatDate(file.created_at, locale, { dateStyle: "medium", timeStyle: "short" }),
  ]
    .filter(Boolean)
    .join(" · ");
  const source = taskFileSource(groupId, file);
  const media =
    kind === "image" || kind === "video" ? (
      <TaskFileMedia kind={kind} source={source} />
    ) : kind === "pdf" ? (
      <TaskFileCover cache={cache} source={source} />
    ) : kind === "text" || kind === "markdown" ? (
      <TaskFileHead heads={cache.heads} source={source} />
    ) : null;
  return (
    <div className="flex min-w-0 flex-col gap-sm" data-testid="task-file-preview">
      {media}
      <div className="flex min-w-0 items-center gap-sm p-xxs">
        {media ? null : (
          <FileTypeIcon
            className="size-8"
            fileName={file.file_name}
            mimeType={file.mime_type ?? undefined}
          />
        )}
        <div className="flex min-w-0 flex-col">
          <span className="truncate text-sm font-medium text-primary">
            {file.file_name}
          </span>
          <span className="truncate text-xs text-tertiary">{details}</span>
        </div>
      </div>
    </div>
  );
}

/** An image, or a video's first frame, read from the file's stream URL; a host that cannot stream it shows none. */
function TaskFileMedia({
  kind,
  source,
}: {
  kind: "image" | "video";
  source: ConversationFileSource;
}) {
  const { value: stream } = useTopic({
    topic: "fileStream",
    source: JSON.stringify(conversationFileSource(source)),
    type: streamMediaType(source, kind),
  });
  const url = stream?.status === "ready" ? (stream.url ?? undefined) : undefined;
  const arrival = useArrival(url !== undefined);
  if (stream?.status === "unsupported" || stream?.status === "failed") return null;
  return (
    <div
      className="flex aspect-video w-full items-center justify-center overflow-hidden rounded-lg bg-secondary"
      data-testid="task-file-preview-media"
    >
      {url ? (
        kind === "image" ? (
          <img
            alt=""
            className="comma-task-file-arrival size-full object-contain"
            data-arrival={arrival.state}
            draggable={false}
            onLoad={arrival.loaded}
            src={url}
          />
        ) : (
          <video
            className="comma-task-file-arrival size-full object-contain"
            data-arrival={arrival.state}
            muted
            onLoadedData={arrival.loaded}
            playsInline
            preload="metadata"
            src={url}
          />
        )
      ) : null}
    </div>
  );
}

/** The first lines of a text file. */
function TaskFileHead({
  heads,
  source,
}: {
  heads: Map<string, string>;
  source: ConversationFileSource;
}) {
  const call = useCall();
  const key = conversationFileSourceKey(source);
  const [head, setHead] = useState(() => heads.get(key));
  const [late] = useState(() => !heads.has(key));
  useEffect(() => {
    if (heads.has(key)) return undefined;
    const controller = new AbortController();
    readConversationFileRange(call, source, 0, headBytes, controller.signal).then(
      (span) => {
        // A character cut at the end of the span decodes as U+FFFD; it is not the file's.
        const text = new TextDecoder()
          .decode(span.bytes)
          .replace(/\uFFFD+$/, "")
          .trimEnd();
        heads.set(key, text);
        if (!controller.signal.aborted) setHead(text);
      },
      () => undefined
    );
    return () => controller.abort();
    // The source is fresh each render; the file is what decides a read.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [call, heads, key]);
  if (!head) return null;
  return (
    <pre
      className="comma-task-file-arrival m-0 line-clamp-8 rounded-lg bg-secondary p-sm font-mono text-xs whitespace-pre-wrap text-secondary [overflow-wrap:anywhere]"
      data-arrival={late ? "late" : undefined}
      data-testid="task-file-preview-text"
    >
      {head}
    </pre>
  );
}

/** A PDF's first page, drawn once and kept as a JPEG; a PDF that cannot be drawn shows none. */
function TaskFileCover({
  cache,
  source,
}: {
  cache: TaskFilePreviewCache;
  source: ConversationFileSource;
}) {
  const call = useCall();
  const key = conversationFileSourceKey(source);
  const [url, setUrl] = useState(() => cache.covers.get(key));
  const [failed, setFailed] = useState(false);
  const arrival = useArrival(url !== undefined);
  useEffect(() => {
    if (cache.covers.has(key)) return undefined;
    let open = true;
    let render: RenderTask | undefined;
    const pdf = openPdfDocument(
      {
        ranged: {
          read: (offset, length, signal) =>
            readConversationFileRange(call, source, offset, length, signal),
        },
      },
      {
        onReadFailed: () => {
          if (open) setFailed(true);
        },
        shareWorker: true,
      }
    );
    void (async () => {
      const page = await (await pdf.document).getPage(1);
      const natural = page.getViewport({ scale: 1 });
      if (!(natural.width > 0 && natural.height > 0))
        throw new Error("Invalid PDF page dimensions");
      const pixels = coverEdge * Math.min(window.devicePixelRatio || 1, 2);
      const viewport = page.getViewport({
        scale: pixels / Math.max(natural.width, natural.height),
      });
      const canvas = window.document.createElement("canvas");
      canvas.width = Math.ceil(viewport.width);
      canvas.height = Math.ceil(viewport.height);
      render = page.render({ canvas, viewport });
      await render.promise;
      const drawn = await new Promise<Blob | null>((resolve) =>
        canvas.toBlob(resolve, "image/jpeg", 0.9)
      );
      if (!drawn) throw new Error("The cover could not be encoded");
      const made = URL.createObjectURL(drawn);
      cache.covers.set(key, made);
      for (const [oldest, oldestUrl] of cache.covers) {
        if (cache.covers.size <= coversKept) break;
        cache.covers.delete(oldest);
        URL.revokeObjectURL(oldestUrl);
      }
      if (open) setUrl(made);
    })().then(
      // The page is drawn: the document is not needed any more.
      () => pdf.close(),
      () => {
        pdf.close();
        if (open) setFailed(true);
      }
    );
    return () => {
      open = false;
      render?.cancel();
      pdf.close();
    };
    // The source is fresh each render; the file is what decides a read.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cache, call, key]);
  if (failed) return null;
  return (
    <div
      className="flex aspect-square w-full items-center justify-center overflow-hidden rounded-lg bg-secondary p-md"
      data-testid="task-file-preview-cover"
    >
      {url ? (
        <img
          alt=""
          className="comma-task-file-arrival max-h-full max-w-full rounded-xs border-[0.5px] border-primary shadow-sm"
          data-arrival={arrival.state}
          draggable={false}
          onLoad={arrival.loaded}
          src={url}
        />
      ) : null}
    </div>
  );
}

type Arrival = "pending" | "now" | "late";

/**
 * When an image or a video shows: "now" when its URL is at hand as the card opens, "late" once it loads after,
 * "pending" until then.
 */
function useArrival(atOpen: boolean) {
  const [state, setState] = useState<Arrival>(atOpen ? "now" : "pending");
  const loaded = useCallback(() => {
    setState((current) => (current === "pending" ? "late" : current));
  }, []);
  return { loaded, state };
}
