import { useCommaMessages } from "@comma/i18n/react";
import { ChatPanelAudio, ChatPanelVideo } from "@comma/ui/components/chat-panel";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import { SkillFileSource } from "@comma/ui/components/plugins";
import { useEffect, useMemo, useState } from "react";
import DOMPurify from "dompurify";
import { ArchiveFilePreview } from "./ArchiveFilePreview";
import { CsvFilePreview } from "./CsvFilePreview";
import { FilePreviewLoading } from "./FilePreviewLoading";
import { JsonFilePreview } from "./JsonFilePreview";
import { NotebookFilePreview } from "./NotebookFilePreview";
import { TiffFilePreview } from "./TiffFilePreview";
import { useDriveObjectUrl } from "../drive/useDriveObjectUrl";
import { useCommaUiThemeName } from "../commaUiTheme";

type PreviewKind =
  | "image"
  | "tiff"
  | "audio"
  | "video"
  | "pdf"
  | "slides"
  | "docx"
  | "xlsx"
  | "csv"
  | "notebook"
  | "json"
  | "jsonl"
  | "archive"
  | "markdown"
  | "html"
  | "text"
  | "unknown";
/** How much of a text file a preview shows; a longer one says it was cut. */
export const textPreviewLimit = 256 * 1024;
const textLimit = textPreviewLimit;

function previewKindByExtension(
  baseName: string,
  extension: string
): PreviewKind | undefined {
  if (extension === "pdf") return "pdf";
  // A PowerPoint deck of the Open XML kind; an older binary .ppt has no preview.
  if (extension === "pptx") return "slides";
  // A Word document of the Open XML kind; an older binary .doc has no preview.
  if (extension === "docx") return "docx";
  // Spreadsheets SheetJS reads directly: .xlsx, .xls, .xlsm, .xlsb, and OpenDocument .ods.
  if (
    extension === "xlsx" ||
    extension === "xls" ||
    extension === "xlsm" ||
    extension === "xlsb" ||
    extension === "ods"
  )
    return "xlsx";
  if (extension === "csv" || extension === "tsv") return "csv";
  if (extension === "ipynb") return "notebook";
  if (extension === "jsonl" || extension === "ndjson") return "jsonl";
  if (extension === "json") return "json";
  if (
    extension === "zip" ||
    extension === "tar" ||
    extension === "tgz" ||
    extension === "gz"
  )
    return "archive";
  if (extension === "md" || extension === "markdown") return "markdown";
  if (extension === "html" || extension === "htm") return "html";
  if (extension === "tif" || extension === "tiff") return "tiff";
  if (/^(png|jpe?g|gif|webp|avif|svg|bmp|ico)$/.test(extension)) return "image";
  if (/^(mp3|wav|ogg|aac|m4a|flac)$/.test(extension)) return "audio";
  if (/^(mp4|webm|mov|m4v)$/.test(extension)) return "video";
  if (textFileNames.has(baseName) || textExtensions.has(extension)) return "text";
  return undefined;
}

export function filePreviewKind(name: string, mime = ""): PreviewKind {
  const baseName = name.split("/").at(-1)?.toLowerCase() ?? "";
  const dotIndex = baseName.lastIndexOf(".");
  const extension =
    dotIndex > 0 && dotIndex < baseName.length - 1 ? baseName.slice(dotIndex + 1) : "";
  // Prefer a known filename extension over the declared MIME type: Windows browsers
  // with Excel installed tag `.csv` as `application/vnd.ms-excel`, MIME.from_path tags
  // `.ts` as `video/mp2t`, and `.ipynb`/`.jsonl` often arrive as `application/json`.
  const byExtension = previewKindByExtension(baseName, extension);
  if (byExtension) return byExtension;
  const mediaType = mime.split(";")[0]?.trim().toLowerCase() ?? "";
  if (mediaType === "application/pdf") return "pdf";
  if (
    mediaType ===
    "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  )
    return "slides";
  if (
    mediaType ===
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  )
    return "docx";
  if (
    mediaType === "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" ||
    mediaType === "application/vnd.ms-excel" ||
    mediaType === "application/vnd.ms-excel.sheet.macroenabled.12" ||
    mediaType === "application/vnd.ms-excel.sheet.binary.macroenabled.12" ||
    mediaType === "application/vnd.oasis.opendocument.spreadsheet"
  )
    return "xlsx";
  if (
    mediaType === "text/csv" ||
    mediaType === "application/csv" ||
    mediaType === "text/tab-separated-values"
  )
    return "csv";
  if (mediaType === "application/x-ipynb+json") return "notebook";
  if (mediaType === "application/x-ndjson" || mediaType === "application/jsonl")
    return "jsonl";
  if (mediaType === "application/json") return "json";
  if (
    mediaType === "application/zip" ||
    mediaType === "application/x-tar" ||
    mediaType === "application/gzip" ||
    mediaType === "application/x-gzip"
  )
    return "archive";
  if (mediaType === "text/markdown") return "markdown";
  if (mediaType === "text/html") return "html";
  if (mediaType === "image/tiff") return "tiff";
  if (mediaType.startsWith("image/")) return "image";
  if (mediaType.startsWith("audio/")) return "audio";
  if (mediaType.startsWith("video/")) return "video";
  if (mediaType.startsWith("text/") || textMediaTypes.has(mediaType)) return "text";
  return "unknown";
}

// Source code and configuration show as text: by the ending after the last dot,
// or, for a file known by its whole name, by that name.
const textExtensions = new Set(
  (
    "txt json jsonc json5 jsonl ndjson yaml yml xml log toml ini cfg conf env properties lock diff patch " +
    "py pyi rb php pl pm lua r jl sh bash zsh fish ps1 bat cmd " +
    "js mjs cjs jsx ts mts cts tsx vue svelte astro css scss sass less " +
    "c h cc cpp cxx hpp hh m mm cs java kt kts scala groovy gradle swift go rs zig dart " +
    "ex exs erl hs ml clj cljs lisp el vim sql graphql gql proto tf hcl nix cmake " +
    "tex bib rst adoc org srt vtt glsl vert frag wgsl tla"
  ).split(" ")
);
const textFileNames = new Set([
  "makefile",
  "dockerfile",
  ".gitignore",
  ".gitattributes",
  ".editorconfig",
  ".npmrc",
  ".env",
]);
/** Text read as prose, shown as it is; every other text file shows as numbered, colored source. */
const proseTextFile = /\.(txt|log)$/i;
/** Prose files, and a text file with no ending (README, LICENSE) unless its name says it is source. */
function isProseTextFile(fileName: string): boolean {
  const baseName = fileName.split("/").at(-1)?.toLowerCase() ?? "";
  if (proseTextFile.test(baseName)) return true;
  const dotIndex = baseName.lastIndexOf(".");
  const hasExtension = dotIndex > 0 && dotIndex < baseName.length - 1;
  return !hasExtension && !textFileNames.has(baseName);
}
const textMediaTypes = new Set([
  "application/json",
  "application/xml",
  "application/javascript",
  "application/typescript",
  "application/x-python",
  "application/x-python-code",
  "application/x-sh",
  "application/x-shellscript",
  "application/x-yaml",
  "application/yaml",
  "application/toml",
  "application/sql",
]);

// An HTML attachment is an opaque document, not another Comma page. Its text
// cannot request remote/relative resources, execute scripts, or navigate Comma.
const htmlPreviewCsp =
  "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'";

export const isolatedHtmlDocument = (html: string) => {
  // Fragment sanitization drops leading/head styles and the html/body attributes.
  // Keep the document, then put our CSP before any user-authored styles.
  // SAFE_FOR_XML drops a whole <style> whose CSS holds "<svg" or "<!--"; this
  // output only reaches the opaque sandbox and CSP, which are the isolation.
  const document = DOMPurify.sanitize(html, {
    WHOLE_DOCUMENT: true,
    RETURN_DOM: true,
    SAFE_FOR_XML: false,
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
  }) as HTMLElement;
  const policy = document.ownerDocument.createElement("meta");
  policy.httpEquiv = "Content-Security-Policy";
  policy.content = htmlPreviewCsp;
  document.querySelector("head")!.prepend(policy);
  return `<!doctype html>${document.outerHTML}`;
};

function TextPreview({
  blob,
  fileName,
  kind,
  onOpenBrowser,
}: {
  blob: Blob;
  fileName: string;
  kind: "markdown" | "html" | "text";
  onOpenBrowser: (url: string) => void;
}) {
  const messages = useCommaMessages();
  const isDark = useCommaUiThemeName() === "Dark mode";
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
      ) : isProseTextFile(fileName) ? (
        <pre className="m-0 whitespace-pre-wrap break-words text-sm">{text}</pre>
      ) : (
        <div className="w-full self-start">
          <SkillFileSource isDark={isDark} path={fileName} text={text} />
        </div>
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
// Select/Close retire the old decoder.
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
  mediaUrl,
  mediaKey,
  error,
  placeholder,
  onOpenBrowser,
}: {
  fileName: string;
  mimeType?: string | undefined;
  blob?: Blob | undefined;
  /** A CORS-enabled URL serving audio, video or an image in ranges; shows without the whole file. */
  mediaUrl?: string | undefined;
  /** The file `mediaUrl` reads, when that URL can be renewed: a new URL of it keeps the playback position. */
  mediaKey?: string | undefined;
  error?: string | undefined;
  placeholder?: string | undefined;
  onOpenBrowser: (url: string) => void;
}) {
  if (error) return <p role="alert">{error}</p>;
  const kind = filePreviewKind(fileName, mimeType || blob?.type);
  if (mediaUrl && (kind === "audio" || kind === "video"))
    return (
      <MediaPreview
        crossOrigin
        fileName={fileName}
        kind={kind}
        sourceKey={mediaKey}
        url={mediaUrl}
      />
    );
  // The browser decodes the image as it arrives, at any size.
  if (mediaUrl && kind === "image")
    return (
      <img
        alt={fileName}
        className="max-h-full max-w-full rounded-lg object-contain"
        crossOrigin="anonymous"
        src={mediaUrl}
      />
    );
  if (!blob)
    return placeholder === undefined ? (
      <FilePreviewLoading />
    ) : (
      <p className="text-sm text-secondary">{placeholder}</p>
    );
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
  if (kind === "csv")
    return (
      <CsvFilePreview
        blob={blob}
        fileName={fileName}
        mimeType={mimeType}
        onOpenBrowser={onOpenBrowser}
      />
    );
  if (kind === "notebook")
    return <NotebookFilePreview blob={blob} onOpenBrowser={onOpenBrowser} />;
  if (kind === "json" || kind === "jsonl")
    return (
      <JsonFilePreview
        blob={blob}
        fileName={fileName}
        lines={kind === "jsonl"}
        onOpenBrowser={onOpenBrowser}
      />
    );
  if (kind === "archive")
    return <ArchiveFilePreview blob={blob} fileName={fileName} mimeType={mimeType} />;
  if (kind === "tiff") return <TiffFilePreview blob={blob} fileName={fileName} />;
  if (kind === "text" || kind === "markdown" || kind === "html")
    return (
      <TextPreview
        blob={blob}
        fileName={fileName}
        kind={kind}
        onOpenBrowser={onOpenBrowser}
      />
    );
  if (!url) return <FilePreviewLoading />;
  if (kind === "image")
    return (
      <img
        alt={fileName}
        className="max-h-full max-w-full rounded-lg object-contain"
        src={url}
      />
    );
  if (kind === "audio" || kind === "video")
    return <MediaPreview fileName={fileName} kind={kind} url={url} />;
  return (
    <p className="text-sm text-secondary">{messages.file_preview_unavailable()}</p>
  );
}

function MediaPreview({
  crossOrigin = false,
  fileName,
  kind,
  sourceKey,
  url,
}: {
  crossOrigin?: boolean;
  fileName: string;
  kind: "audio" | "video";
  sourceKey?: string | undefined;
  url: string;
}) {
  if (kind === "audio")
    return (
      <ChatPanelAudio
        className="w-full"
        src={url}
        {...(sourceKey ? { sourceKey } : {})}
      />
    );
  return (
    <ChatPanelVideo
      className="w-full max-w-full"
      crossOrigin={crossOrigin ? "anonymous" : undefined}
      {...(sourceKey ? { sourceKey } : {})}
      src={url}
      poster=""
      alt={fileName}
      previewTitle={fileName}
    />
  );
}
