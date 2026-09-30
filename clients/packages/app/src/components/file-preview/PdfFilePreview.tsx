import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui";
import { useEffect, useRef, useState } from "react";
// Vite turns this local package asset into a bundled URL.
// oxlint-disable-next-line import/default
import pdfWorkerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";
import type { PDFDocumentProxy } from "pdfjs-dist";
import { FilePreviewLoading } from "./FilePreviewLoading";

export function PdfFilePreview({ blob }: { blob: Blob }) {
  const messages = useCommaMessages();
  const [document, setDocument] = useState<PDFDocumentProxy>();
  const [page, setPage] = useState(1);
  const [failed, setFailed] = useState(false);
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    let current = true;
    let loading: ReturnType<(typeof import("pdfjs-dist"))["getDocument"]> | undefined;
    void (async () => {
      const pdfjs = await import("pdfjs-dist");
      const data = new Uint8Array(await blob.arrayBuffer());
      if (!current) return;
      pdfjs.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;
      loading = pdfjs.getDocument({ data, enableXfa: false, maxImageSize: 16_777_216 });
      const loaded = await loading.promise;
      if (current) setDocument(loaded);
    })().catch(() => {
      if (current) setFailed(true);
    });
    return () => {
      current = false;
      void loading?.destroy();
    };
  }, [blob]);
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
