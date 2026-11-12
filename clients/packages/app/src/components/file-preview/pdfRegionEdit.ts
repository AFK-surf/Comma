import type { PDFDocumentProxy } from "pdfjs-dist";

/** A rectangle on a page in PDF points, from the page's top-left corner as it shows. */
export interface PdfRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** What a person asked about one area of a PDF page, and what the page holds there. */
export interface PdfRegionEdit {
  prompt: string;
  page: number;
  pageCount: number;
  pageSize: { width: number; height: number };
  region: PdfRect;
  /** The PDF's own text inside the area: what the agent searches the source for. */
  text: string;
  screenshot: { bytes: Uint8Array; name: string; size: number } | undefined;
}

/** The longest edge of an area's screenshot, as for an inspected browser element. */
const screenshotMaxEdge = 1568;
/** Past this a small area only grows blurrier glyph edges, not more detail. */
const screenshotMaxScale = 4;
const maxPromptLength = 4_000;
const maxTextLength = 2_000;

/** Renders `region` of `page` straight from the PDF, sharper than the canvas on screen, as a PNG. */
async function regionScreenshot(
  pdf: PDFDocumentProxy,
  page: number,
  region: PdfRect,
  ownerDocument: Document
) {
  const pdfPage = await pdf.getPage(page);
  const scale = Math.min(
    screenshotMaxScale,
    screenshotMaxEdge / Math.max(region.width, region.height)
  );
  const canvas = ownerDocument.createElement("canvas");
  canvas.width = Math.max(1, Math.round(region.width * scale));
  canvas.height = Math.max(1, Math.round(region.height * scale));
  const viewport = pdfPage.getViewport({
    scale,
    offsetX: -region.x * scale,
    offsetY: -region.y * scale,
  });
  await pdfPage.render({ canvas, viewport }).promise;
  const blob = await new Promise<Blob | null>((resolve) =>
    canvas.toBlob(resolve, "image/png")
  );
  canvas.width = 0;
  canvas.height = 0;
  if (!blob) return;
  const bytes = new Uint8Array(await blob.arrayBuffer());
  return { bytes, name: `pdf-page-${page}-area.png`, size: bytes.byteLength };
}

/** The PDF text whose glyph boxes meet `region`, in the order the page lists it. */
async function regionText(pdf: PDFDocumentProxy, page: number, region: PdfRect) {
  const pdfPage = await pdf.getPage(page);
  const viewport = pdfPage.getViewport({ scale: 1 });
  const content = await pdfPage.getTextContent();
  let text = "";
  for (const item of content.items) {
    if (!("str" in item) || !item.str) continue;
    // The run's box on the page: `width` along its baseline and `height` up from it, in the directions its matrix
    // gives, so text the page or the run itself turns is found where it shows.
    const [a, b, c, d, e, f] = item.transform as number[];
    const along = Math.hypot(a!, b!) || 1;
    const up = Math.hypot(c!, d!) || 1;
    const height = item.height || up;
    const across = [(a! / along) * item.width, (b! / along) * item.width];
    const rise = [(c! / up) * height, (d! / up) * height];
    const corners = [
      [e!, f!],
      [e! + across[0]!, f! + across[1]!],
      [e! + rise[0]!, f! + rise[1]!],
      [e! + across[0]! + rise[0]!, f! + across[1]! + rise[1]!],
    ].map(([x, y]) => viewport.convertToViewportPoint(x!, y!) as [number, number]);
    const xs = corners.map(([x]) => x);
    const ys = corners.map(([, y]) => y);
    if (
      Math.min(...xs) > region.x + region.width ||
      Math.max(...xs) < region.x ||
      Math.min(...ys) > region.y + region.height ||
      Math.max(...ys) < region.y
    )
      continue;
    text += item.str + (item.hasEOL ? "\n" : " ");
  }
  return text.replace(/[ \t]+\n/g, "\n").trim();
}

export async function capturePdfRegion(
  pdf: PDFDocumentProxy,
  {
    prompt,
    page,
    region,
    ownerDocument,
  }: { prompt: string; page: number; region: PdfRect; ownerDocument: Document }
): Promise<PdfRegionEdit> {
  const pdfPage = await pdf.getPage(page);
  const { width, height } = pdfPage.getViewport({ scale: 1 });
  const [screenshot, text] = await Promise.all([
    regionScreenshot(pdf, page, region, ownerDocument),
    regionText(pdf, page, region),
  ]);
  return {
    prompt,
    page,
    pageCount: pdf.numPages,
    pageSize: { width, height },
    region,
    text,
    screenshot,
  };
}

/** The message a region edit sends: the person's words, then the area's context for the agent. */
export function pdfRegionEditMessage(
  edit: PdfRegionEdit,
  file: { fileName: string; reference?: string | undefined }
) {
  const lines = [
    clipped(edit.prompt.trim(), maxPromptLength) || "Edit this area of the PDF.",
    "",
    "<user-reminder>",
    "<pdf_region_context>",
    `File: ${file.fileName}`,
  ];
  if (file.reference) lines.push(`Attachment: ${file.reference}`);
  lines.push(
    `Page: ${edit.page} of ${edit.pageCount}`,
    `Page size: ${point(edit.pageSize.width)} x ${point(edit.pageSize.height)} pt`,
    `Selected area (pt, from the page's top-left corner): x=${point(edit.region.x)}, y=${point(edit.region.y)}, width=${point(edit.region.width)}, height=${point(edit.region.height)}`
  );
  if (edit.screenshot) lines.push(`Screenshot: attached as ${edit.screenshot.name}`);
  lines.push(
    "",
    edit.text
      ? `Text in the area:\n${clipped(edit.text, maxTextLength)}`
      : "Text in the area: none (the area holds only images or drawings)."
  );
  lines.push("</pdf_region_context>", "</user-reminder>");
  return {
    text: lines.join("\n"),
    files: edit.screenshot ? [edit.screenshot] : [],
  };
}

function point(value: number) {
  return String(Math.round(value * 10) / 10);
}

function clipped(value: string, maxLength: number) {
  return value.length <= maxLength
    ? value
    : `${value.slice(0, maxLength)}\n...[truncated]`;
}
