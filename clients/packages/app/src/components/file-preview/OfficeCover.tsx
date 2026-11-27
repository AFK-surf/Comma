import { useEffect, useRef, useState } from "react";
import { docxPageWidth, renderDocx } from "./DocxFilePreview";
import { officeThumbnail } from "./filePictures";
import type { RangedFile } from "./PdfFilePreview";
import { drawSheet, readWorkbook } from "./SheetFilePreview";
import { readWholeFile } from "./wholeFile";

/** The office files a chat card draws the first page of: a deck, a Word document, a workbook. */
export type OfficeCoverKind = "slides" | "docx" | "xlsx";

/**
 * The largest file a chat card draws the first page of, by kind. A file is read whole to draw any of it, and a card
 * is drawn without being asked for, so it reads less than the sidebar does.
 */
export const officeCoverMaxBytes: Record<OfficeCoverKind, number> = {
  slides: 16 * 1024 * 1024,
  docx: 16 * 1024 * 1024,
  xlsx: 8 * 1024 * 1024,
};

/** What a card draws of a workbook's first sheet. */
const coverRows = 30;
const coverColumns = 12;

/** A first page drawn for a card: its element, and its width at full size once it is in the card. */
type Drawing = { element: HTMLElement; width: () => number; dispose?: () => void };
/** What a card's first page is drawn from, made once for each file. */
type Cover = { draw: (ownerDocument: Document) => Promise<Drawing> };

// Files read for their cards, by file: a card that mounts again (a row scrolled back, a tab reopened) draws its page
// without reading the file again. Few are kept, as each holds what its page is drawn from.
const covers = new Map<string, Promise<Cover | undefined>>();
const maxCovers = 4;

async function readCover(
  kind: OfficeCoverKind,
  file: RangedFile
): Promise<Cover | undefined> {
  // A card leaving the screen does not stop the read: what it reads is kept for when it comes back.
  const signal = new AbortController().signal;
  const maxBytes = officeCoverMaxBytes[kind];
  const { size } = await file.read(0, 4, signal);
  if (size > maxBytes) return undefined;
  const read = await readWholeFile(file, signal, maxBytes);
  if ("error" in read) return undefined;
  if (kind === "slides") {
    const { buildPresentation, parseZip, renderSlide, RECOMMENDED_ZIP_LIMITS } =
      await import("@aiden0z/pptx-renderer");
    const presentation = buildPresentation(
      await parseZip(read.bytes.buffer, RECOMMENDED_ZIP_LIMITS)
    );
    const first = presentation.slides[0];
    if (!first) return undefined;
    return {
      draw: async () => {
        const handle = renderSlide(presentation, first, { externalMedia: "block" });
        return {
          element: handle.element,
          width: () => presentation.width,
          dispose: () => handle.dispose(),
        };
      },
    };
  }
  // A document's first page and a sheet's first cells are drawn once; each card shows a copy.
  const drawn =
    kind === "docx"
      ? await renderDocx(read.bytes, document, { firstPage: true })
      : drawSheet(
          (await readWorkbook(read.bytes, coverRows))[0]!.sheet,
          document,
          coverRows,
          coverColumns
        ).table;
  return {
    draw: async (ownerDocument) => {
      const element = ownerDocument.importNode(drawn, true);
      return {
        element,
        // A sheet's cells are shown at their own size, cut at the card's edges; a page is fitted to the card.
        width: () => (kind === "docx" ? docxPageWidth(element) : 0),
      };
    },
  };
}

/** What a file's card draws, read once for each file while it is kept; none for a file too large or unreadable. */
function coverOf(key: string, kind: OfficeCoverKind, file: RangedFile) {
  const kept = covers.get(key);
  if (kept) {
    covers.delete(key);
    covers.set(key, kept);
    return kept;
  }
  const cover = readCover(kind, file).catch(() => undefined);
  if (covers.size >= maxCovers) covers.delete(covers.keys().next().value!);
  covers.set(key, cover);
  return cover;
}

/**
 * An office file's first page across a chat card, from the card's top: a deck's first slide or a Word document's
 * first page fitted to the card's width, or the top left cells of a workbook's first sheet at their own size. It is
 * drawn in the page from the file's own parts, as the sidebar draws it: pictures linked from the web are not fetched,
 * and the page takes no clicks (the card opens the file). The thumbnail saved in a file is not used first: the tools
 * that make office files without Office save a blank one, or none. A file too large to read for its card, or one that
 * cannot be drawn, shows that thumbnail if it has one; with none, the card is its header alone.
 */
export function OfficeCover({
  fileKey,
  kind,
  file,
}: {
  fileKey: string;
  kind: OfficeCoverKind;
  file: RangedFile;
}) {
  const frame = useRef<HTMLDivElement>(null);
  const [drawn, setDrawn] = useState(false);
  const [thumbnail, setThumbnail] = useState<string>();
  useEffect(() => {
    const element = frame.current;
    if (!element) return undefined;
    let stopped = false;
    let dispose: (() => void) | undefined;
    let resize: ResizeObserver | undefined;
    let picture: string | undefined;
    void (async () => {
      const cover = await coverOf(fileKey, kind, file);
      if (stopped) return;
      if (!cover) {
        const saved = await officeThumbnail(file);
        if (stopped || !saved) return;
        picture = URL.createObjectURL(saved);
        setThumbnail(picture);
        setDrawn(true);
        return;
      }
      const drawing = await cover.draw(element.ownerDocument);
      if (stopped) return drawing.dispose?.();
      dispose = drawing.dispose;
      const page = drawing.element;
      // Out of the card's flow: the page is drawn at its own size and scaled down, and its size must not widen the card.
      page.style.position = "absolute";
      page.style.inset = "0 auto auto 0";
      page.style.transformOrigin = "0 0";
      element.replaceChildren(page);
      const width = drawing.width();
      if (width > 0) {
        const fit = () => {
          page.style.transform = `scale(${element.clientWidth / width})`;
        };
        fit();
        resize = new ResizeObserver(fit);
        resize.observe(element);
      }
      setDrawn(true);
    })().catch(() => undefined);
    return () => {
      stopped = true;
      resize?.disconnect();
      dispose?.();
      if (picture) URL.revokeObjectURL(picture);
      element.replaceChildren();
    };
  }, [file, fileKey, kind]);
  return (
    <div
      aria-hidden
      className="comma-office-cover"
      data-arrived={drawn ? "true" : undefined}
      data-kind={kind}
      data-testid="attachment-office-cover"
    >
      {thumbnail ? (
        <img
          alt=""
          className="comma-attachment-preview-image"
          draggable={false}
          src={thumbnail}
        />
      ) : null}
      <div className="comma-office-cover-page" ref={frame} />
    </div>
  );
}
