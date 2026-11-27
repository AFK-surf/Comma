import { useCommaMessages } from "@comma/i18n/react";
import type { ReactNode } from "react";
import type { RangedFile } from "./PdfFilePreview";
import { RenderedFilePreview, type DrawFile } from "./RenderedFilePreview";

/** The largest deck the preview reads: a deck is a ZIP archive, so it is read whole before a slide shows. */
export const slidesPreviewMaxBytes = 64 * 1024 * 1024;

/** A deck's slides in one column, fitted to its width; pictures linked from the web are not fetched. */
const drawSlides: DrawFile = async (bytes, element, signal) => {
  const { PptxViewer, RECOMMENDED_ZIP_LIMITS } = await import("@aiden0z/pptx-renderer");
  return PptxViewer.open(bytes, element, {
    externalMedia: "block",
    zipLimits: RECOMMENDED_ZIP_LIMITS,
    fitMode: "contain",
    lazySlides: true,
    lazyMedia: true,
    // Its PDF fallback for pasted vector art starts a worker from a blob, which the app's pages do not run.
    pdfjs: false,
    renderMode: "list",
    listOptions: { windowed: true, initialSlides: 3, batchSize: 3 },
    signal,
  });
};

/**
 * A PowerPoint deck (.pptx): every slide in one scrolling column, fitted to the panel's width. Slides are drawn in
 * the page as HTML and SVG from the deck's own parts.
 */
export function SlidesFilePreview({
  blob,
  ranged,
  onOpenBrowser,
  children,
}: {
  blob?: Blob | undefined;
  ranged?: RangedFile | undefined;
  onOpenBrowser: (url: string) => void;
  /** Content after the last slide, in the same scroll. */
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  return (
    <RenderedFilePreview
      blob={blob}
      draw={drawSlides}
      maxBytes={slidesPreviewMaxBytes}
      onOpenBrowser={onOpenBrowser}
      ranged={ranged}
      testId="file-preview-slides"
      tooLarge={messages.file_preview_slides_too_large()}
    >
      {children}
    </RenderedFilePreview>
  );
}
