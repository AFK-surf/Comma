import { useCommaMessages } from "@comma/i18n/react";
import type { ReactNode } from "react";
import type { RangedFile } from "./PdfFilePreview";
import { RenderedFilePreview, type DrawFile } from "./RenderedFilePreview";
import { opensInBrowser, zipWithinLimits } from "./wholeFile";

/** The largest Word document the preview reads: it is a ZIP archive, read whole before a page shows. */
export const docxPreviewMaxBytes = 64 * 1024 * 1024;

// Each drawing has a class of its own: the renderer scopes a document's styles by its class, and two documents on
// one screen (a card and the sidebar) must not take each other's.
let drawings = 0;

/**
 * A Word document's pages, as HTML from the document's own parts, with the styles they are drawn with, each page as
 * wide as Word set it. Pages break where Word last laid them out; a document saved by a tool that does not lay it out
 * is one long page. Only pictures inside the document are shown, embedded HTML (an "altChunk", which would run in a
 * frame) is not drawn, and a link keeps its address only when it opens in the browser or goes to a place in the
 * document. `firstPage` keeps the first page alone.
 */
export async function renderDocx(
  bytes: Uint8Array<ArrayBuffer>,
  ownerDocument: Document,
  { firstPage = false }: { firstPage?: boolean } = {}
) {
  if (!zipWithinLimits(bytes)) throw new Error("archive out of bounds");
  const { renderAsync } = await import("docx-preview");
  drawings += 1;
  const className = `comma-docx-${drawings}`;
  const styles = ownerDocument.createElement("div");
  const pages = ownerDocument.createElement("div");
  pages.className = "comma-docx-pages";
  await renderAsync(bytes, pages, styles, {
    className,
    inWrapper: false,
    breakPages: true,
    ignoreLastRenderedPageBreak: false,
    renderAltChunks: false,
    renderChanges: false,
    renderComments: false,
    experimental: false,
    // Data URLs: the renderer never revokes the object URLs it would make, and fonts load only from data URLs here.
    useBase64URL: true,
  });
  const sections = [...pages.children].filter((child) => child.tagName === "SECTION");
  if (sections.length === 0) throw new Error("no pages");
  if (firstPage) for (const later of sections.slice(1)) later.remove();
  for (const link of pages.querySelectorAll("a[href]")) {
    const href = link.getAttribute("href")!;
    if (!href.startsWith("#") && !opensInBrowser(href)) link.removeAttribute("href");
  }
  const drawn = ownerDocument.createElement("div");
  drawn.append(styles, pages);
  return drawn;
}

/** The width of a drawn document's widest page, at full size. */
export const docxPageWidth = (drawn: HTMLElement) =>
  Math.max(
    ...[...drawn.querySelectorAll<HTMLElement>(".comma-docx-pages > section")].map(
      (section) => section.offsetWidth
    )
  );

/** A Word document's pages in `element`, each fitted to its width (never larger than its own). */
const drawPages: DrawFile = async (bytes, element) => {
  const drawn = await renderDocx(bytes, element.ownerDocument);
  element.replaceChildren(drawn);
  // Pages are as wide as Word set them; their width is read once, at full size.
  const natural = docxPageWidth(drawn);
  const pages = drawn.querySelector<HTMLElement>(".comma-docx-pages")!;
  const fit = () => {
    pages.style.zoom = String(Math.min(1, element.clientWidth / natural));
  };
  fit();
  const resize = new ResizeObserver(fit);
  resize.observe(element);
  return {
    destroy: () => {
      resize.disconnect();
      element.replaceChildren();
    },
  };
};

/** A Word document (.docx): its pages in one scrolling column, fitted to the panel's width. */
export function DocxFilePreview({
  blob,
  ranged,
  onOpenBrowser,
  children,
}: {
  blob?: Blob | undefined;
  ranged?: RangedFile | undefined;
  onOpenBrowser: (url: string) => void;
  /** Content after the last page, in the same scroll. */
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  return (
    <RenderedFilePreview
      blob={blob}
      draw={drawPages}
      maxBytes={docxPreviewMaxBytes}
      onOpenBrowser={onOpenBrowser}
      ranged={ranged}
      testId="file-preview-docx"
      tooLarge={messages.file_preview_office_too_large({ limit: 64 })}
    >
      {children}
    </RenderedFilePreview>
  );
}
