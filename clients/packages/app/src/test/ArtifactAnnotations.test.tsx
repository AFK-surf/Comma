import { act, render, screen } from "@comma/test-utils/render";
import { fireEvent } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { ArtifactAnnotations } from "../components/file-preview/ArtifactAnnotations";
import { FilePreviewContent } from "../components/file-preview/FilePreviewContent";

beforeEach(() => {
  sessionStorage.clear();
  vi.spyOn(Range.prototype, "getBoundingClientRect").mockReturnValue(
    new DOMRect(0, 0, 100, 20)
  );
  vi.spyOn(Range.prototype, "getClientRects").mockReturnValue([
    new DOMRect(0, 0, 100, 20),
  ] as unknown as DOMRectList);
});
afterEach(() => vi.restoreAllMocks());

function selectText() {
  const text = screen.getByText("First paragraph. Second paragraph.");
  const range = document.createRange();
  range.setStart(text.firstChild!, 17);
  range.setEnd(text.firstChild!, 33);
  const selection = document.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
  fireEvent.pointerUp(text);
}
const preview = (key: string, send: (text: string) => void) => (
  <ArtifactAnnotations storageKey={key} fileName="notes.md" onSend={send}>
    <p>First paragraph. Second paragraph.</p>
  </ArtifactAnnotations>
);

it("saves an anchored selection, restores it, edits it, sends it and deletes it", async () => {
  const send = vi.fn();
  const view = render(preview("task:a:file:1", send));
  selectText();
  fireEvent.click(screen.getByRole("button", { name: "Annotate selection" }));
  fireEvent.change(screen.getByRole("textbox", { name: "Annotation" }), {
    target: { value: "Clarify the date" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Save annotation" }));
  expect(JSON.parse(sessionStorage.getItem("task:a:file:1")!)[0]).toMatchObject({
    start: 17,
    end: 33,
    quote: "Second paragraph",
    body: "Clarify the date",
  });
  expect(view.container.querySelector("mark")).toBeInTheDocument();
  view.unmount();
  const restored = render(preview("task:a:file:1", send));
  expect(screen.getByText("Clarify the date")).toBeVisible();
  fireEvent.click(screen.getByRole("button", { name: "Edit" }));
  fireEvent.change(screen.getByRole("textbox", { name: "Annotation" }), {
    target: { value: "Use next Monday" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Save annotation" }));
  fireEvent.click(
    screen.getByRole("button", { name: "Send annotations to conversation" })
  );
  expect(send).toHaveBeenCalledWith(
    expect.stringContaining(
      '1. Quote: "Second paragraph"\nContext: "First paragraph. Second paragraph."\nComment: Use next Monday'
    )
  );
  fireEvent.click(screen.getByRole("button", { name: "Delete" }));
  expect(screen.queryByText("Use next Monday")).not.toBeInTheDocument();
  expect(restored.container.querySelector("mark")).not.toBeInTheDocument();
  expect(JSON.parse(sessionStorage.getItem("task:a:file:1")!)).toEqual([]);
});

it("sends Markdown quotes the agent can find in the source, not preview offsets", async () => {
  const source = "# Plan\n\nShip **Monday** at noon.\n\n- first item\n- second item\n";
  const send = vi.fn();
  render(
    <ArtifactAnnotations storageKey="task:a:file:md" fileName="plan.md" onSend={send}>
      <FilePreviewContent
        fileName="plan.md"
        blob={new Blob([source], { type: "text/markdown" })}
        onOpenBrowser={() => {}}
      />
    </ArtifactAnnotations>
  );
  const start = (await screen.findByText("Monday")).firstChild!;
  const end = screen.getByText("first item").firstChild!;
  const range = document.createRange();
  range.setStart(start, 0);
  range.setEnd(end, 5);
  document.getSelection()!.removeAllRanges();
  document.getSelection()!.addRange(range);
  fireEvent.pointerUp(start.parentElement!);
  fireEvent.click(screen.getByRole("button", { name: "Annotate selection" }));
  fireEvent.keyDown(screen.getByRole("textbox", { name: "Annotation" }), {
    key: "Escape",
  });
  expect(screen.queryByRole("textbox", { name: "Annotation" })).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "Annotate selection" }));
  fireEvent.change(screen.getByRole("textbox", { name: "Annotation" }), {
    target: { value: "Move to Tuesday" },
  });
  fireEvent.click(screen.getByRole("button", { name: "Save annotation" }));
  fireEvent.click(
    screen.getByRole("button", { name: "Send annotations to conversation" })
  );
  const sent = send.mock.calls[0]![0] as string;
  // Blocks were joined with no separator ("noon.first"), and the offsets
  // pointed into the rendered text, not the file.
  expect(sent).toContain('1. Quote: "Monday at noon.\\nfirst"');
  expect(sent).toContain(
    'Context: "Plan\\nShip Monday at noon.\\nfirst item\\nsecond item"'
  );
  expect(sent).not.toMatch(/\[\d+, \d+\]/);
});

it("does not remeasure highlights when only the parent renders again", () => {
  sessionStorage.setItem(
    "task:a:file:1",
    JSON.stringify([{ id: "saved", start: 0, end: 5, quote: "First", body: "Note" }])
  );
  const view = render(preview("task:a:file:1", vi.fn()));
  const measured = vi.mocked(Range.prototype.getClientRects).mock.calls.length;
  expect(measured).toBeGreaterThan(0);
  view.rerender(preview("task:a:file:1", vi.fn()));
  view.rerender(preview("task:a:file:1", vi.fn()));
  expect(Range.prototype.getClientRects).toHaveBeenCalledTimes(measured);
});

it("keeps another conversation's annotations separate and does not publish failed saves", async () => {
  sessionStorage.setItem(
    "task:a:file:1",
    JSON.stringify([
      { id: "saved", start: 0, end: 5, quote: "First", body: "Private note" },
    ])
  );
  render(preview("task:b:file:1", vi.fn()));
  expect(screen.queryByText("Private note")).not.toBeInTheDocument();
  selectText();
  fireEvent.click(screen.getByRole("button", { name: "Annotate selection" }));
  fireEvent.change(screen.getByRole("textbox", { name: "Annotation" }), {
    target: { value: "Unsaved" },
  });
  vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
    throw new Error("Storage full");
  });
  await act(async () =>
    fireEvent.click(screen.getByRole("button", { name: "Save annotation" }))
  );
  expect(screen.getByRole("alert")).toHaveTextContent("Could not save annotations");
  expect(
    screen.queryByRole("complementary", { name: "Annotations" })
  ).not.toBeInTheDocument();
  expect(sessionStorage.getItem("task:a:file:1")).toContain("Private note");
});
