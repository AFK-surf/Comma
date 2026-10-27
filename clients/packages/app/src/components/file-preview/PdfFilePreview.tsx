import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { useEffect, useRef, useState } from "react";
// Vite turns this local package asset into a bundled URL.
// oxlint-disable-next-line import/default
import pdfWorkerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";
import type { PDFDocumentProxy } from "pdfjs-dist";
import { FilePreviewLoading } from "./FilePreviewLoading";

/** A file read in spans: up to `length` bytes from `offset`, and the whole file's size. */
export interface RangedFile {
  read(
    offset: number,
    length: number,
    signal?: AbortSignal
  ): Promise<{ bytes: Uint8Array; size: number }>;
}

/** pdf.js asks for spans of this size: a page reads only the spans it needs. */
const PDF_RANGE_CHUNK = 256 * 1024;
/** The most one read asks for (`files.readRange` takes at most 10 MB): a whole number of chunks. */
const PDF_READ_MAX = 32 * PDF_RANGE_CHUNK;

/** Renders a PDF from its bytes, or from spans of a file of any size (`ranged`), a page at a time. */
export function PdfFilePreview(source: { blob: Blob } | { ranged: RangedFile }) {
  const messages = useCommaMessages();
  const [document, setDocument] = useState<PDFDocumentProxy>();
  const [page, setPage] = useState(1);
  const [failed, setFailed] = useState(false);
  const canvas = useRef<HTMLCanvasElement>(null);
  const blob = "blob" in source ? source.blob : undefined;
  const ranged = "ranged" in source ? source.ranged : undefined;
  useEffect(() => {
    let current = true;
    const reads = new AbortController();
    let loading: ReturnType<(typeof import("pdfjs-dist"))["getDocument"]> | undefined;
    void (async () => {
      const pdfjs = await import("pdfjs-dist");
      pdfjs.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;
      const options = { enableXfa: false, maxImageSize: 16_777_216 };
      if (ranged) {
        // The first span carries the file's size; the rest are read as pdf.js asks.
        const first = await ranged.read(0, PDF_RANGE_CHUNK, reads.signal);
        if (!current) return;
        const transport = new pdfjs.PDFDataRangeTransport(first.size, first.bytes);
        // pdf.js may join adjacent chunks into one span larger than a read takes: it is read, and handed on, in
        // chunk-aligned parts.
        transport.requestDataRange = (begin: number, end: number) => {
          for (let from = begin; from < end; from += PDF_READ_MAX) {
            ranged.read(from, Math.min(PDF_READ_MAX, end - from), reads.signal).then(
              (span) => {
                if (current) transport.onDataRange(from, span.bytes);
              },
              () => {
                if (current) setFailed(true);
              }
            );
          }
        };
        loading = pdfjs.getDocument({
          ...options,
          range: transport,
          rangeChunkSize: PDF_RANGE_CHUNK,
          disableAutoFetch: true,
          disableStream: true,
        });
      } else {
        const data = new Uint8Array(await blob!.arrayBuffer());
        if (!current) return;
        loading = pdfjs.getDocument({ ...options, data });
      }
      const loaded = await loading.promise;
      if (current) setDocument(loaded);
    })().catch(() => {
      if (current) setFailed(true);
    });
    return () => {
      current = false;
      reads.abort();
      void loading?.destroy();
    };
  }, [blob, ranged]);
  useEffect(() => {
    if (!document || !canvas.current) return;
    let current = true;
    let render:
      | ReturnType<Awaited<ReturnType<PDFDocumentProxy["getPage"]>>["render"]>
      | undefined;
    const target = canvas.current;
    void (async () => {
      const pdfPage = await document.getPage(page);
      if (!current) return;
      const natural = pdfPage.getViewport({ scale: 1 });
      if (
        !Number.isFinite(natural.width) ||
        !Number.isFinite(natural.height) ||
        natural.width <= 0 ||
        natural.height <= 0
      )
        throw new Error("Invalid PDF page dimensions");
      const viewport = pdfPage.getViewport({
        scale: Math.min(1.5, 1200 / Math.max(natural.width, natural.height)),
      });
      target.width = Math.ceil(viewport.width);
      target.height = Math.ceil(viewport.height);
      render = pdfPage.render({ canvas: target, viewport });
      await render.promise;
    })().catch(() => {
      if (current) setFailed(true);
    });
    return () => {
      current = false;
      render?.cancel();
    };
  }, [document, page]);
  if (failed) return <p role="alert">{messages.file_preview_failed()}</p>;
  if (!document) return <FilePreviewLoading />;
  return (
    <div className="flex min-w-0 flex-col gap-lg">
      <div className="flex items-center justify-center gap-sm">
        <Button isDisabled={page <= 1} onPress={() => setPage((value) => value - 1)}>
          {messages.file_preview_previous_page()}
        </Button>
        <span>{messages.file_preview_page({ page, total: document.numPages })}</span>
        <Button
          isDisabled={page >= document.numPages}
          onPress={() => setPage((value) => value + 1)}
        >
          {messages.file_preview_next_page()}
        </Button>
      </div>
      {/* Canvas pixels need an accessible image name; an img cannot host the PDF renderer. */}
      <canvas
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="img"
        aria-label={messages.file_preview_pdf_page({ page })}
        className="h-auto w-full"
        data-testid="file-preview-pdf"
        key={page}
        ref={canvas}
      />
    </div>
  );
}
