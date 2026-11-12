import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { fireEvent } from "@testing-library/react";
import { stubProperty } from "@comma/test-utils/stub-property";
import { expect, it, vi } from "vitest";
import { PdfFilePreview } from "../components/file-preview/PdfFilePreview";

const pdfjs = vi.hoisted(() => ({ getDocument: vi.fn(), GlobalWorkerOptions: {} }));
vi.mock("pdfjs-dist", () => pdfjs);

const pdfPage = () => ({
  getViewport: () => ({ width: 360, height: 504 }),
  render: vi.fn(() => ({ promise: Promise.resolve(), cancel: vi.fn() })),
});
const loadDocument = (numPages: number, page = pdfPage()) => {
  const document = { numPages, getPage: vi.fn().mockResolvedValue(page) };
  pdfjs.getDocument.mockReturnValue({
    promise: Promise.resolve(document),
    destroy: vi.fn(),
  });
  return { document, page };
};

it("reports PDF loading without an empty canvas until the document is ready", async () => {
  const page = pdfPage();
  const document = { numPages: 2, getPage: vi.fn().mockResolvedValue(page) };
  let resolveDocument!: (value: typeof document) => void;
  const promise = new Promise<typeof document>((resolve) => {
    resolveDocument = resolve;
  });
  pdfjs.getDocument.mockReturnValue({ promise, destroy: vi.fn() });
  // Fit width draws once the view has a width; jsdom lays nothing out.
  vi.spyOn(HTMLElement.prototype, "clientWidth", "get").mockReturnValue(400);
  render(<PdfFilePreview blob={new Blob(["PDF document bytes"])} />);

  await waitFor(() => expect(pdfjs.getDocument).toHaveBeenCalledOnce());
  expect(screen.getByRole("status", { name: "Loading preview…" })).toHaveAttribute(
    "aria-busy",
    "true"
  );
  expect(screen.queryByRole("img", { name: "PDF page 1" })).not.toBeInTheDocument();

  await act(async () => resolveDocument(document));
  // Each page holds its place; only those near the view (here the first) draw.
  await waitFor(() => expect(page.render).toHaveBeenCalledOnce());
  expect(screen.getByRole("img", { name: "PDF page 1" })).toBeVisible();
  expect(screen.getByRole("img", { name: "PDF page 2" })).toBeVisible();
  expect(screen.queryByTestId("file-preview-loading")).not.toBeInTheDocument();
  vi.restoreAllMocks();
});

it("turns focused pages with unmodified keys, clamps bounds and preserves editor keys", async () => {
  loadDocument(3);
  render(
    <>
      <textarea aria-label="Chat input" />
      <PdfFilePreview blob={new Blob(["PDF"])} />
    </>
  );
  const reader = await screen.findByRole("region", { name: "PDF pages" });
  await screen.findByText("Page 1 of 3");
  fireEvent.pointerDown(screen.getByRole("img", { name: "PDF page 1" }));
  expect(reader).toHaveFocus();
  fireEvent.keyDown(reader, { key: "ArrowRight" });
  expect(screen.getByText("Page 2 of 3")).toBeInTheDocument();
  fireEvent.keyDown(reader, { key: "PageDown" });
  fireEvent.keyDown(reader, { key: "ArrowRight" });
  expect(screen.getByText("Page 3 of 3")).toBeInTheDocument();
  fireEvent.keyDown(reader, { key: "ArrowLeft", metaKey: true });
  fireEvent.keyDown(reader, { key: "ArrowLeft", ctrlKey: true });
  fireEvent.keyDown(reader, { key: "ArrowLeft", altKey: true });
  fireEvent.keyDown(reader, { key: "ArrowLeft", shiftKey: true });
  const editor = window.document.createElement("textarea");
  reader.append(editor);
  fireEvent.keyDown(editor, { key: "ArrowLeft" });
  const editable = window.document.createElement("div");
  editable.setAttribute("contenteditable", "true");
  reader.append(editable);
  fireEvent.keyDown(editable, { key: "PageUp" });
  fireEvent.keyDown(screen.getByRole("textbox", { name: "Chat input" }), {
    key: "ArrowLeft",
  });
  expect(screen.getByText("Page 3 of 3")).toBeInTheDocument();
  fireEvent.keyDown(reader, { key: "Home" });
  expect(screen.getByText("Page 1 of 3")).toBeInTheDocument();
  fireEvent.keyDown(reader, { key: "ArrowLeft" });
  expect(screen.getByText("Page 1 of 3")).toBeInTheDocument();
  fireEvent.keyDown(reader, { key: "End" });
  expect(screen.getByText("Page 3 of 3")).toBeInTheDocument();
});

it("leaves keys alone for a single-page document", async () => {
  loadDocument(1);
  render(<PdfFilePreview blob={new Blob(["PDF"])} />);
  const reader = await screen.findByRole("region", { name: "PDF pages" });
  const event = new KeyboardEvent("keydown", {
    key: "ArrowRight",
    bubbles: true,
    cancelable: true,
  });
  await act(async () => reader.dispatchEvent(event));
  expect(event.defaultPrevented).toBe(false);
  expect(screen.getByText("Page 1 of 1")).toBeInTheDocument();
});

it("opens the thumbnail rail and reads the page a thumbnail names or Up and Down reach", async () => {
  loadDocument(3);
  // A thumbnail glides the view, which jsdom does not lay out; the glide itself is checked in a browser.
  const scrollTo = vi.fn();
  stubProperty(HTMLElement.prototype, "scrollTo", { value: scrollTo });
  const { default: userEvent } = await import("@testing-library/user-event");
  const user = userEvent.setup();
  render(<PdfFilePreview blob={new Blob(["PDF"])} />);
  // The whole pill is the button: its page count opens the rail as its panel icon does.
  expect(
    await screen.findByRole("button", { name: "Show page thumbnails" })
  ).toHaveAccessibleDescription("Page 1 of 3");
  await user.click(screen.getByText("1 / 3"));
  const rail = screen.getByRole("navigation", { name: "Page thumbnails" });
  expect(rail).toHaveTextContent("3 pages");
  expect(screen.getByRole("button", { name: "Page 1" })).toHaveAttribute(
    "aria-current",
    "page"
  );
  await user.click(screen.getByRole("button", { name: "Page 3" }));
  expect(screen.getByRole("button", { name: "Page 3" })).toHaveAttribute(
    "aria-current",
    "page"
  );
  expect(scrollTo).toHaveBeenLastCalledWith(
    expect.objectContaining({ behavior: "smooth" })
  );
  expect(screen.getByRole("button", { name: "Page 1" })).not.toHaveAttribute(
    "aria-current"
  );
  // Up and Down step through the list; focus goes with the page, and stops at the last one.
  await user.keyboard("{ArrowUp}");
  const second = screen.getByRole("button", { name: "Page 2" });
  expect(second).toHaveAttribute("aria-current", "page");
  expect(second).toHaveFocus();
  await user.keyboard("{ArrowDown}{ArrowDown}");
  const third = screen.getByRole("button", { name: "Page 3" });
  expect(third).toHaveAttribute("aria-current", "page");
  expect(third).toHaveFocus();
  await user.click(screen.getByRole("button", { name: "Hide page thumbnails" }));
  expect(screen.queryByRole("navigation")).not.toBeInTheDocument();
  expect(screen.getByText("Page 3 of 3")).toBeInTheDocument();
});

it("asks about a dragged area only while Request edits is on, and Escape steps back out", async () => {
  loadDocument(2);
  const slot = window.document.createElement("div");
  window.document.body.append(slot);
  const onRequestEdit = vi.fn();
  render(
    <PdfFilePreview
      blob={new Blob(["PDF"])}
      onRequestEdit={onRequestEdit}
      toolbarSlot={slot}
    />
  );
  const reader = await screen.findByRole("region", { name: "PDF pages" });
  const [first] = await screen.findAllByTestId("file-preview-pdf-page");
  const drag = () => {
    fireEvent.pointerDown(first!, { button: 0, clientX: 4, clientY: 4, pointerId: 1 });
    fireEvent.pointerMove(first!, { clientX: 20, clientY: 16, pointerId: 1 });
    fireEvent.pointerUp(first!, { clientX: 20, clientY: 16, pointerId: 1 });
  };
  drag();
  expect(screen.queryByRole("textbox")).not.toBeInTheDocument();

  const requestEdits = screen.getByRole("button", { name: "Request edits" });
  fireEvent.click(requestEdits);
  expect(requestEdits).toHaveAttribute("aria-pressed", "true");
  expect(screen.getByText("Drag over a page to select an area")).toBeInTheDocument();
  drag();
  const prompt = await screen.findByRole("textbox");
  await waitFor(() => expect(prompt).toHaveFocus());
  expect(
    screen.queryByText("Drag over a page to select an area")
  ).not.toBeInTheDocument();

  fireEvent.keyDown(reader, { key: "Escape" });
  expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
  expect(requestEdits).toHaveAttribute("aria-pressed", "true");
  fireEvent.keyDown(reader, { key: "Escape" });
  expect(requestEdits).toHaveAttribute("aria-pressed", "false");
  expect(onRequestEdit).not.toHaveBeenCalled();
  slot.remove();
});

it("mounts only the pages near the one being read in a long document", async () => {
  loadDocument(200);
  render(<PdfFilePreview blob={new Blob(["PDF"])} />);
  const reader = await screen.findByRole("region", { name: "PDF pages" });
  await screen.findByText("Page 1 of 200");
  expect(screen.getAllByTestId("file-preview-pdf-page").length).toBeLessThan(10);
  fireEvent.keyDown(reader, { key: "End" });
  expect(screen.getByText("Page 200 of 200")).toBeInTheDocument();
  expect(screen.getByRole("img", { name: "PDF page 200" })).toBeInTheDocument();
  expect(screen.queryByRole("img", { name: "PDF page 100" })).not.toBeInTheDocument();
  expect(screen.getAllByTestId("file-preview-pdf-page").length).toBeLessThan(10);
});

it("leaves the keys of its toolbar controls to them", async () => {
  loadDocument(3);
  const slot = window.document.createElement("div");
  window.document.body.append(slot);
  render(
    <PdfFilePreview
      blob={new Blob(["PDF"])}
      onRequestEdit={vi.fn()}
      toolbarSlot={slot}
    />
  );
  await screen.findByText("Page 1 of 3");
  const requestEdits = screen.getByRole("button", { name: "Request edits" });
  for (const key of ["ArrowRight", "PageDown", "End"])
    fireEvent.keyDown(requestEdits, { key });
  expect(screen.getByText("Page 1 of 3")).toBeInTheDocument();
  // Escape still leaves Request edits from its own button.
  fireEvent.click(requestEdits);
  expect(requestEdits).toHaveAttribute("aria-pressed", "true");
  fireEvent.keyDown(requestEdits, { key: "Escape" });
  expect(requestEdits).toHaveAttribute("aria-pressed", "false");
  slot.remove();
});
