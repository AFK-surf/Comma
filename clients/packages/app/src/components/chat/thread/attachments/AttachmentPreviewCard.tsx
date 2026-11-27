import { useCall } from "@comma/core-client";
import { useCommaLocale } from "@comma/i18n/react";
import {
  ChatPanelPreviewCard,
  type ChatPanelFileOpenInAction,
} from "@comma/ui/components/chat-panel";
import { FileTypeIcon, resolveFileType } from "@comma/ui/components/file-type-icon";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import { useEffect, useMemo, useRef, useState } from "react";
import {
  conversationFileSourceKey,
  readConversationFileRange,
  type ConversationFileSource,
} from "../../../../runtime-files/fileSources";
import { documentParts } from "../../../file-preview/documentExport";
import { filePreviewKind } from "../../../file-preview/FilePreviewContent";
import { officeThumbnail, pdfFirstPage } from "../../../file-preview/filePictures";
import { OfficeCover } from "../../../file-preview/OfficeCover";
import { formatAttachmentSize } from "./attachmentLabels";

const office = /\.(?:pptx?|key|docx?|pages|xlsx?|xlsm|xlsb|ods|numbers)$/iu;

/** Whether a file shows in the chat as a card with a picture: one the sidebar reads as a page, or a deck or office file. */
export function opensAsPreviewCard(fileName: string, mimeType: string | undefined) {
  const kind = filePreviewKind(fileName, mimeType);
  return (
    kind === "markdown" || kind === "pdf" || kind === "html" || office.test(fileName)
  );
}

// What a document's picture reads of it: enough for the sheet's few lines.
const headBytes = 1536;
const heads = new Map<string, string>();
const maxHeads = 64;

// A picture as a document writes it: Markdown's own, or the line of HTML of one set to a side or given a width.
const writtenPicture =
  /!\[[^\]]*\]\([^)]*\)|<p(?: align="[a-z]+")?>\s*<(?:img|video)\b[^>]*>(?:<\/video>)?\s*<\/p>/gu;

/** The start of a document's text, whole lines only, without its front matter and its pictures. */
export function documentHead(bytes: Uint8Array, whole: boolean) {
  const text = new TextDecoder().decode(bytes);
  const cut = whole ? text : text.slice(0, Math.max(0, text.lastIndexOf("\n")));
  return documentParts(cut).page.replace(writtenPicture, "");
}

/** The picture of a Markdown document: the top of its page, read once for each file. */
function DocumentPicture({ source }: { source: ConversationFileSource }) {
  const call = useCall();
  const key = conversationFileSourceKey(source);
  const [head, setHead] = useState(() => heads.get(key));
  // Lines read after the card was drawn come in; lines the card is drawn with are there at once.
  const [arrived, setArrived] = useState(false);
  useEffect(() => {
    if (heads.has(key)) return undefined;
    const controller = new AbortController();
    void readConversationFileRange(call, source, 0, headBytes, controller.signal).then(
      (range) => {
        const text = documentHead(range.bytes, range.bytes.length >= range.size);
        if (heads.size >= maxHeads) heads.delete(heads.keys().next().value!);
        heads.set(key, text);
        setHead(text);
        setArrived(true);
      },
      // A file that cannot be read keeps a blank sheet; opening it says why.
      () => undefined
    );
    return () => controller.abort();
  }, [call, key, source]);
  return head ? (
    <div
      className="comma-document comma-document-thumbnail"
      data-arrived={arrived ? "true" : undefined}
    >
      <MarkdownStream animation="none" content={head} final htmlPolicy="escape" />
    </div>
  ) : null;
}

// The pictures drawn of PDFs and office files, by file, as object URLs: a card that mounts again (a row scrolled
// back, a tab reopened) shows its picture at once. `null`: the file has none. `drawn`: a deck, a Word document or a
// workbook, whose first page the card draws itself (OfficeCover).
type Picture = string | null | "drawn";
const pictures = new Map<string, Picture>();
const maxPictures = 32;

function keepPicture(key: string, picture: Picture) {
  if (pictures.size >= maxPictures) {
    const [oldest, old] = pictures.entries().next().value!;
    pictures.delete(oldest);
    if (old && old !== "drawn") URL.revokeObjectURL(old);
  }
  pictures.set(key, picture);
}

/**
 * The picture of a PDF (its first page) or of an office file (the thumbnail saved in it), made once `seenRef`'s
 * element (the card) comes into view. Until then, and for a file with no picture, there is none. A .pptx, .docx or
 * .xlsx file is `drawn`: its first page is drawn, as the thumbnail saved in one may be a blank one its maker puts in
 * every file, or there may be none.
 */
function useFilePicture(
  fileName: string,
  mimeType: string | undefined,
  source: ConversationFileSource | undefined,
  enabled: boolean
) {
  const call = useCall();
  const key = source ? conversationFileSourceKey(source) : "";
  const kind = filePreviewKind(fileName, mimeType);
  const pdf = kind === "pdf";
  const drawn = kind === "slides" || kind === "docx" || kind === "xlsx";
  const [picture, setPicture] = useState(() => pictures.get(key));
  // A picture made after the card was drawn comes in; one kept from before is there at once.
  const [arrived, setArrived] = useState(false);
  const seenRef = useRef<HTMLElement>(null);
  useEffect(() => {
    const element = seenRef.current;
    if (!enabled || !source || !element || pictures.has(key)) return undefined;
    const controller = new AbortController();
    const file = {
      read: (offset: number, length: number, signal?: AbortSignal) =>
        readConversationFileRange(
          call,
          source,
          offset,
          length,
          signal ? AbortSignal.any([signal, controller.signal]) : controller.signal
        ),
    };
    // A card far up a long transcript draws nothing until the reader comes to it.
    const seen = new IntersectionObserver(([entry]) => {
      if (!entry?.isIntersecting) return;
      seen.disconnect();
      void (async () => {
        const blob = drawn
          ? undefined
          : await (pdf
              ? pdfFirstPage(file, element.ownerDocument)
              : officeThumbnail(file, controller.signal));
        const made: Picture = drawn ? "drawn" : blob ? URL.createObjectURL(blob) : null;
        if (controller.signal.aborted) {
          if (made && made !== "drawn") URL.revokeObjectURL(made);
          return;
        }
        keepPicture(key, made);
        setPicture(made);
        setArrived(true);
      })().catch(
        // A file that cannot be read keeps its mark; opening it says why.
        () => undefined
      );
    });
    seen.observe(element);
    return () => {
      seen.disconnect();
      controller.abort();
    };
  }, [call, enabled, key, pdf, drawn, source]);
  return { picture: picture ?? undefined, arrived, pdf, seenRef };
}

/**
 * A file an Agent sent that opens beside the chat as a page, shown as a card: its type, name and Open, then its
 * picture across the card. The picture is a document's own first lines, a PDF's first page, or an office file's
 * own thumbnail; a PowerPoint deck, a Word document or an Excel workbook shows its first page. An office file with no
 * picture is its header alone.
 */
export function AttachmentPreviewCard({
  fileName,
  mimeType,
  size,
  source,
  onOpen,
  openIn,
  testId,
}: {
  fileName: string;
  mimeType?: string | undefined;
  size?: number | undefined;
  /** Where the file's bytes are read, for its picture. */
  source?: ConversationFileSource | undefined;
  onOpen: () => void;
  openIn?: ChatPanelFileOpenInAction | undefined;
  testId: string;
}) {
  const locale = useCommaLocale();
  const type = resolveFileType({ fileName, mimeType });
  const kind = filePreviewKind(fileName, mimeType);
  const document = kind === "markdown";
  const { picture, arrived, pdf, seenRef } = useFilePicture(
    fileName,
    mimeType,
    source,
    !document
  );
  const call = useCall();
  const rangedSource = useMemo(
    () => ({
      read: (offset: number, length: number, signal?: AbortSignal) =>
        source
          ? readConversationFileRange(call, source, offset, length, signal)
          : Promise.reject(new Error("no source")),
    }),
    [call, source]
  );
  return (
    <ChatPanelPreviewCard
      cardRef={seenRef}
      fades={document}
      icon={
        <FileTypeIcon className="size-3xl" fileName={fileName} mimeType={mimeType} />
      }
      onOpen={onOpen}
      openIn={openIn}
      subtitle={
        size === undefined ? type : `${type} · ${formatAttachmentSize(size, locale)}`
      }
      testId={testId}
      title={fileName}
    >
      {document && source ? (
        <DocumentPicture source={source} />
      ) : picture === "drawn" &&
        source &&
        (kind === "slides" || kind === "docx" || kind === "xlsx") ? (
        <OfficeCover
          file={rangedSource}
          fileKey={conversationFileSourceKey(source)}
          kind={kind}
        />
      ) : picture ? (
        <img
          alt=""
          className="comma-attachment-preview-image"
          data-arrived={arrived ? "true" : undefined}
          draggable={false}
          src={picture}
        />
      ) : pdf ? (
        // A PDF always has a first page: its place is kept while the page is drawn.
        <div className="comma-attachment-preview-wait" />
      ) : // An office file may carry no thumbnail: until one is read, the card is its header alone.
      undefined}
    </ChatPanelPreviewCard>
  );
}
