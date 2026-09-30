import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { expect, it, vi } from "vitest";
import { PdfFilePreview } from "../components/file-preview/PdfFilePreview";

const pdfjs = vi.hoisted(() => ({ getDocument: vi.fn(), GlobalWorkerOptions: {} }));
vi.mock("pdfjs-dist", () => pdfjs);

it("reports PDF loading without an empty canvas until the document is ready", async () => {
  const page = {
    getViewport: () => ({ width: 360, height: 504 }),
    render: vi.fn(() => ({ promise: Promise.resolve(), cancel: vi.fn() })),
  };
  const document = { numPages: 2, getPage: vi.fn().mockResolvedValue(page) };
  let resolveDocument!: (value: typeof document) => void;
  const promise = new Promise<typeof document>((resolve) => {
    resolveDocument = resolve;
  });
  pdfjs.getDocument.mockReturnValue({ promise, destroy: vi.fn() });
  render(<PdfFilePreview blob={new Blob(["PDF document bytes"])} />);

  await waitFor(() => expect(pdfjs.getDocument).toHaveBeenCalledOnce());
  expect(screen.getByRole("status", { name: "Loading preview…" })).toHaveAttribute(
    "aria-busy",
    "true"
  );
  expect(screen.queryByTestId("file-preview-pdf")).not.toBeInTheDocument();

  await act(async () => resolveDocument(document));
  await waitFor(() => expect(page.render).toHaveBeenCalledOnce());
  expect(screen.getByTestId("file-preview-pdf")).toBeVisible();
  expect(screen.queryByTestId("file-preview-loading")).not.toBeInTheDocument();
});
