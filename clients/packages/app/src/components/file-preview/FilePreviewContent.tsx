import { useCommaMessages } from "@comma/i18n/react";
import { ChatPanelAudio, ChatPanelVideo, MarkdownStream } from "@comma/ui";
import { useEffect, useMemo, useState } from "react";
import DOMPurify from "dompurify";
import { FilePreviewLoading } from "./FilePreviewLoading";
import { PdfFilePreview } from "./PdfFilePreview";
import { useDriveObjectUrl } from "../drive/useDriveObjectUrl";

type PreviewKind =
  | "image"
  | "audio"
  | "video"
  | "pdf"
  | "markdown"
  | "html"
  | "text"
  | "unknown";
const textLimit = 256 * 1024;

export function filePreviewKind(name: string, mime = ""): PreviewKind {
  const extension = name.split(".").at(-1)?.toLowerCase();
  const mediaType = mime.split(";")[0]?.trim().toLowerCase() ?? "";
  if (mediaType === "application/pdf" || extension === "pdf") return "pdf";
  if (mediaType === "text/markdown" || extension === "md" || extension === "markdown")
    return "markdown";
  if (mediaType === "text/html" || extension === "html" || extension === "htm")
    return "html";
  if (
    mediaType.startsWith("image/") ||
    /^(png|jpe?g|gif|webp|avif|svg)$/.test(extension ?? "")
  )
    return "image";
  if (
    mediaType.startsWith("audio/") ||
    /^(mp3|wav|ogg|aac|m4a|flac)$/.test(extension ?? "")
  )
    return "audio";
  if (mediaType.startsWith("video/") || /^(mp4|webm|mov|m4v)$/.test(extension ?? ""))
    return "video";
  if (
    mediaType.startsWith("text/") ||
    /^(txt|csv|json|yaml|yml|xml|log|toml)$/.test(extension ?? "")
  )
    return "text";
  return "unknown";
}

// An HTML attachment is an opaque document, not another Comma page. Its text
// cannot request remote/relative resources, execute scripts, or navigate Comma.
const htmlPreviewCsp =
  "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'";

export const isolatedHtmlDocument = (html: string) => {
  const body = DOMPurify.sanitize(html, {
    FORBID_TAGS: [
      "script",
      "meta",
      "base",
      "link",
      "iframe",
      "frame",
      "object",
      "embed",
      "form",
      "svg",
      "math",
    ],
    FORBID_ATTR: [
      "srcset",
      "srcdoc",
      "action",
      "formaction",
      "ping",
      "target",
      "download",
    ],
    ALLOWED_URI_REGEXP: /^(?:#|data:image\/(?:png|gif|jpe?g|webp);)/i,
  });
  return `<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="${htmlPreviewCsp}"><meta charset="utf-8"></head><body>${body}</body></html>`;
};

function TextPreview({
  blob,
  kind,
  onOpenBrowser,
}: {
  blob: Blob;
  kind: "markdown" | "html" | "text";
  onOpenBrowser: (url: string) => void;
}) {
  const messages = useCommaMessages();
  const [text, setText] = useState<string>();
  useEffect(() => {
    let current = true;
    void blob
      .slice(0, textLimit)
      .text()
      .then((value) => {
        if (current) setText(value);
      });
    return () => {
      current = false;
    };
  }, [blob]);
  const policy = useMemo(() => ({ onOpenLink: onOpenBrowser }), [onOpenBrowser]);
  if (text === undefined) return <FilePreviewLoading />;
  return (
    <>
      {kind === "html" ? (
        <iframe
          className="min-h-[480px] w-full flex-1 border-0 bg-white"
          data-testid="file-preview-html"
          referrerPolicy="no-referrer"
          sandbox=""
          srcDoc={isolatedHtmlDocument(text)}
          title={messages.file_preview_html_title()}
        />
      ) : kind === "markdown" ? (
        <MarkdownStream
          content={text}
          final
          animation="none"
          htmlPolicy="escape"
          documentResourcePolicy={policy}
        />
      ) : (
        <pre className="m-0 whitespace-pre-wrap break-words text-sm">{text}</pre>
      )}
      {blob.size > textLimit ? (
        <p className="text-sm text-secondary">
          {messages.file_preview_text_truncated()}
        </p>
      ) : null}
    </>
  );
}

// Blob identity owns decoder lifetime; Drive can replace bytes under one file id.
// tla/file-actions/FilePreviewSelection.tla: Select/Close retire the old decoder.
const blobKeys = new WeakMap<Blob, number>();
let nextBlobKey = 0;
function blobKey(blob: Blob) {
  let key = blobKeys.get(blob);
  if (key === undefined) {
    key = ++nextBlobKey;
    blobKeys.set(blob, key);
  }
  return key;
}

/** Already-authorized bytes only; adapters retain fetch, storage and transfer ownership. */
export function FilePreviewContent({
  fileName,
  mimeType,
  blob,
  error,
  placeholder,
  onOpenBrowser,
}: {
  fileName: string;
  mimeType?: string | undefined;
  blob?: Blob | undefined;
  error?: string | undefined;
  placeholder?: string | undefined;
  onOpenBrowser: (url: string) => void;
}) {
  if (error) return <p role="alert">{error}</p>;
  if (!blob)
    return placeholder === undefined ? <FilePreviewLoading /> : <p>{placeholder}</p>;
  return (
    <LoadedFilePreview
      key={blobKey(blob)}
      fileName={fileName}
      mimeType={mimeType}
      blob={blob}
      onOpenBrowser={onOpenBrowser}
    />
  );
}

function LoadedFilePreview({
  fileName,
  mimeType,
  blob,
  onOpenBrowser,
}: {
  fileName: string;
  mimeType?: string | undefined;
  blob: Blob;
  onOpenBrowser: (url: string) => void;
}) {
  const messages = useCommaMessages();
  const url = useDriveObjectUrl(blob);
  const kind = filePreviewKind(fileName, mimeType || blob.type);
  if (kind === "pdf") return <PdfFilePreview blob={blob} />;
  if (kind === "text" || kind === "markdown" || kind === "html")
    return <TextPreview blob={blob} kind={kind} onOpenBrowser={onOpenBrowser} />;
  if (!url) return <FilePreviewLoading />;
  if (kind === "image")
    return (
      <img
        alt={fileName}
        className="max-h-full max-w-full rounded-lg object-contain"
        src={url}
      />
    );
  if (kind === "audio") return <ChatPanelAudio className="w-full" src={url} />;
  if (kind === "video")
    return (
      <ChatPanelVideo
        className="w-full max-w-full"
        src={url}
        poster=""
        alt={fileName}
        previewTitle={fileName}
      />
    );
  return <p>{messages.file_preview_unavailable()}</p>;
}
