import { expect, it, vi } from "vitest";
import type { PDFDocumentProxy } from "pdfjs-dist";
import {
  capturePdfRegion,
  pdfRegionEditMessage,
} from "../components/file-preview/pdfRegionEdit";

/** A 600 x 800 pt page; PDF space has its origin bottom-left, the page as shown top-left. */
const pdfWith = (
  items: Array<{ str: string; x: number; y: number; hasEOL?: boolean }>,
  convertToViewportPoint = (x: number, y: number) => [x, 800 - y]
) => {
  const render = vi.fn(() => ({ promise: Promise.resolve() }));
  const page = {
    getViewport: vi.fn(() => ({
      width: 600,
      height: 800,
      convertToViewportPoint,
    })),
    getTextContent: () =>
      Promise.resolve({
        items: items.map(({ str, x, y, hasEOL = false }) => ({
          str,
          transform: [10, 0, 0, 10, x, y],
          width: str.length * 5,
          height: 10,
          hasEOL,
        })),
      }),
    render,
  };
  return {
    pdf: {
      numPages: 3,
      getPage: () => Promise.resolve(page),
    } as unknown as PDFDocumentProxy,
    page,
  };
};
const ownerDocument = () => {
  const canvases: Array<{ width: number; height: number }> = [];
  const document = {
    createElement: () => {
      const canvas = {
        width: 0,
        height: 0,
        toBlob: (done: (blob: Blob) => void) =>
          done(new Blob([new Uint8Array([137, 80, 78, 71])], { type: "image/png" })),
      };
      canvases.push(canvas);
      return canvas;
    },
  } as unknown as Document;
  return { document, canvases };
};

it("finds text on a turned page where the page shows it", async () => {
  // A page turned a quarter (/Rotate 90): a run along PDF x reads downward on screen.
  const { pdf } = pdfWith([{ str: "Turned title", x: 100, y: 700 }], (x, y) => [y, x]);
  const edit = await capturePdfRegion(pdf, {
    prompt: "Fix this",
    page: 1,
    // Across the middle of the run as it shows: x 700-710, y 100-160.
    region: { x: 690, y: 140, width: 40, height: 10 },
    ownerDocument: ownerDocument().document,
  });
  expect(edit.text).toBe("Turned title");
});

it("captures the area's own PDF text and a sharp screenshot of just that area", async () => {
  const { pdf, page } = pdfWith([
    { str: "Q3 Revenue", x: 100, y: 700, hasEOL: true },
    { str: "Highlights", x: 100, y: 660 },
    { str: "Footer note", x: 100, y: 40 },
    { str: "Side margin", x: 520, y: 660 },
  ]);
  const { document, canvases } = ownerDocument();
  const edit = await capturePdfRegion(pdf, {
    prompt: "Make the title bigger",
    page: 2,
    region: { x: 80, y: 80, width: 300, height: 80 },
    ownerDocument: document,
  });

  expect(edit.text).toBe("Q3 Revenue\nHighlights");
  expect(edit).toMatchObject({
    page: 2,
    pageCount: 3,
    pageSize: { width: 600, height: 800 },
  });
  expect(edit.screenshot).toMatchObject({ name: "pdf-page-2-area.png", size: 4 });
  // A 300 pt area would reach the 1568 px edge at 5.2x; it stops at 4x, past which only blur grows.
  expect(page.render).toHaveBeenCalledOnce();
  expect(page.getViewport).toHaveBeenCalledWith({
    scale: 4,
    offsetX: -320,
    offsetY: -320,
  });
  expect(canvases).toHaveLength(1);
  // The capture canvas gives its pixels back once encoded.
  expect(canvases[0]).toMatchObject({ width: 0, height: 0 });
});

it("tells the agent where the area is and what it holds, after the person's words", () => {
  const message = pdfRegionEditMessage(
    {
      prompt: "  Make the title bigger ",
      page: 2,
      pageCount: 3,
      pageSize: { width: 612, height: 792 },
      region: { x: 72.04, y: 100, width: 200.55, height: 80 },
      text: "",
      screenshot: { bytes: new Uint8Array([1]), name: "pdf-page-2-area.png", size: 1 },
    },
    { fileName: "Q3 review.pdf", reference: "group/conversation/message/0" }
  );
  expect(message.text).toBe(
    [
      "Make the title bigger",
      "",
      "<user-reminder>",
      "<pdf_region_context>",
      "File: Q3 review.pdf",
      "Attachment: group/conversation/message/0",
      "Page: 2 of 3",
      "Page size: 612 x 792 pt",
      "Selected area (pt, from the page's top-left corner): x=72, y=100, width=200.6, height=80",
      "Screenshot: attached as pdf-page-2-area.png",
      "",
      "Text in the area: none (the area holds only images or drawings).",
      "</pdf_region_context>",
      "</user-reminder>",
    ].join("\n")
  );
  expect(message.files).toEqual([
    { bytes: new Uint8Array([1]), name: "pdf-page-2-area.png", size: 1 },
  ]);
});
