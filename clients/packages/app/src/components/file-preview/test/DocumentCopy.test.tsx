import { fireEvent, render, screen, waitFor, within } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { expect, it, vi } from "vitest";
import { FilePreviewPanel } from "../FilePreviewPanel";

it("copies a document as Markdown other products take, with the same document as HTML beside it", async () => {
  const writeText = vi.fn().mockResolvedValue({ ok: true });
  installNativeBridgeMock({ platform: "electron", clipboard: { writeText } });
  render(
    <FilePreviewPanel
      blob={
        new Blob(["# Plan\n**标签：**正文\n* one\n* two\n"], { type: "text/markdown" })
      }
      fileName="plan.md"
      panelId="preview"
      testId="preview"
      download={{
        fileName: "plan.md",
        capability: { execute: async () => ({ status: "success" }) },
      }}
      onOpenBrowser={() => {}}
    />
  );
  fireEvent.click(await screen.findByRole("button", { name: "Copy as Markdown" }));
  await waitFor(() =>
    expect(writeText).toHaveBeenCalledWith({
      text: "# Plan\n\n**标签**：正文\n\n- one\n- two\n",
      html: '<meta charset="utf-8"><h1>Plan</h1><p><strong>标签：</strong>正文</p><ul><li>one</li><li>two</li></ul>',
    })
  );
});

it("keeps a document's front matter out of its page: no title, heading or copied text is read from it", async () => {
  const writeText = vi.fn().mockResolvedValue({ ok: true });
  installNativeBridgeMock({ platform: "electron", clipboard: { writeText } });
  render(
    <FilePreviewPanel
      blob={
        new Blob(["---\ntitle: Draft\ntags: [a, b]\n---\n# Plan\n\nBody.\n"], {
          type: "text/markdown",
        })
      }
      fileName="plan.md"
      panelId="preview"
      testId="preview"
      download={{
        fileName: "plan.md",
        capability: { execute: async () => ({ status: "success" }) },
      }}
      onOpenBrowser={() => {}}
    />
  );
  const page = await screen.findByTestId("file-preview-document");
  await within(page).findByText("Body.");
  // The document opens with its own title, so the page adds none from the file's name.
  expect(
    within(page)
      .getAllByRole("heading")
      .map((heading) => heading.textContent)
  ).toEqual(["Plan"]);
  expect(page.textContent).not.toContain("tags:");
  fireEvent.click(screen.getByRole("button", { name: "Copy as Markdown" }));
  await waitFor(() =>
    expect(writeText).toHaveBeenCalledWith({
      text: "# Plan\n\nBody.\n",
      html: '<meta charset="utf-8"><h1>Plan</h1><p>Body.</p>',
    })
  );
});

it("shows a document that is still loading as its toolbar and a loading mark alone", async () => {
  installNativeBridgeMock({ platform: "web" });
  render(
    <FilePreviewPanel
      annotationContext={{ storageKey: "task:a:file:plan", onSend: () => undefined }}
      documentVersions={{
        items: versionItems,
        current: "three",
        onSelect: () => {},
        comparing: undefined,
        onCompare: () => {},
      }}
      fileName="plan.md"
      panelId="preview"
      testId="preview"
      download={{
        fileName: "plan.md",
        capability: { execute: async () => ({ status: "success" }) },
      }}
      onOpenBrowser={() => {}}
    />
  );
  const panel = screen.getByTestId("preview");
  // The mark is the panel's own child, so it has the panel's whole height to be in the middle of.
  expect(screen.getByTestId("file-preview-loading").parentElement).toBe(panel);
  // No words about notes on a page that has no text yet, and the document's own toolbar from the start.
  expect(panel.textContent).not.toContain("Select text");
  expect(screen.getByRole("button", { name: "Versions of plan.md" })).toBeVisible();
});

const versionItems = [
  { id: "one", title: "Jul 3 at 10:08 AM", author: "Ada", avatar: null },
  { id: "two", title: "Yesterday at 5:46 PM", author: "Comma", avatar: null },
  { id: "three", title: "Today at 3:17 PM", author: "Ada", avatar: null },
];

function Versions({
  current,
  comparing,
  onSelect = () => {},
  onCompare = () => {},
  onRestore,
  onDiscard,
}: {
  current: string;
  comparing?: string;
  onSelect?: (id: string) => void;
  onCompare?: (base: string | undefined) => void;
  onRestore?: (id: string) => void;
  /** The reader has edits of the shown version that no message has carried; this discards them. */
  onDiscard?: () => void;
}) {
  return (
    <FilePreviewPanel
      blob={new Blob(["# Plan\n"], { type: "text/markdown" })}
      documentVersions={{
        items: versionItems,
        current,
        onSelect,
        comparing,
        onCompare,
        onRestore,
        ...(onDiscard
          ? {
              unsent: { title: "Your edits", author: "Ada", avatar: null, onDiscard },
            }
          : {}),
      }}
      fileName="plan.md"
      panelId="preview"
      testId="preview"
      download={{
        fileName: "plan.md",
        capability: { execute: async () => ({ status: "success" }) },
      }}
      onOpenBrowser={() => {}}
    />
  );
}

it("opens a document's versions from its name, newest first, and compares the one shown with the one before it", async () => {
  installNativeBridgeMock({ platform: "web" });
  const onSelect = vi.fn();
  const onCompare = vi.fn();
  render(<Versions current="three" onCompare={onCompare} onSelect={onSelect} />);
  // Nothing is compared yet: the page has no bar about it.
  expect(screen.queryByTestId("document-compare-bar")).toBeNull();
  fireEvent.click(await screen.findByRole("button", { name: "Versions of plan.md" }));
  const versions = await screen.findAllByRole("menuitemradio");
  // The newest is the current one, and each says who wrote it.
  expect(versions.map((item) => item.textContent)).toEqual([
    "Today at 3:17 PMCurrentAda",
    "Yesterday at 5:46 PMComma",
    "Jul 3 at 10:08 AMAda",
  ]);
  expect(versions[0]).toHaveAttribute("aria-checked", "true");
  fireEvent.click(screen.getByRole("menuitemcheckbox", { name: "Compare versions" }));
  expect(onCompare).toHaveBeenCalledWith("two");
  fireEvent.click(versions[1]!);
  expect(onSelect).toHaveBeenCalledWith("two");
});

it("names the two versions a page compares, lets the reader choose the earlier one, and stops with Done", async () => {
  installNativeBridgeMock({ platform: "web" });
  const onCompare = vi.fn();
  render(<Versions comparing="two" current="three" onCompare={onCompare} />);
  const bar = await screen.findByTestId("document-compare-bar");
  // From the earlier version to the one shown.
  expect(bar.textContent).toBe("ComparingYesterday at 5:46 PMToday at 3:17 PMDone");

  // Any earlier version may be what the shown one is compared with; a later one may not.
  fireEvent.click(screen.getByRole("button", { name: "Version to compare with" }));
  const earlier = await screen.findAllByRole("menuitemradio");
  expect(earlier.map((item) => item.textContent)).toEqual([
    "Yesterday at 5:46 PMComma",
    "Jul 3 at 10:08 AMAda",
  ]);
  expect(earlier[0]).toHaveAttribute("aria-checked", "true");
  fireEvent.click(earlier[1]!);
  expect(onCompare).toHaveBeenCalledWith("one");

  fireEvent.click(screen.getByRole("button", { name: "Done" }));
  expect(onCompare).toHaveBeenLastCalledWith(undefined);
});

it("offers no comparison for a document's first version, which has none before it", async () => {
  installNativeBridgeMock({ platform: "web" });
  render(<Versions current="one" />);
  fireEvent.click(await screen.findByRole("button", { name: "Versions of plan.md" }));
  await screen.findAllByRole("menuitemradio");
  expect(screen.queryByRole("menuitemcheckbox")).toBeNull();
});

it("restores an earlier version from its row, and never the current one", async () => {
  installNativeBridgeMock({ platform: "web" });
  const onRestore = vi.fn();
  const onSelect = vi.fn();
  render(<Versions current="three" onRestore={onRestore} onSelect={onSelect} />);
  fireEvent.click(await screen.findByRole("button", { name: "Versions of plan.md" }));
  await screen.findAllByRole("menuitemradio");
  // Each earlier version has its actions; the newest is the current one already.
  const actions = screen.getAllByRole("button", { name: "More actions" });
  expect(actions).toHaveLength(2);
  fireEvent.click(actions[0]!);
  fireEvent.click(
    await screen.findByRole("menuitem", { name: "Restore this version" })
  );
  // The reader is asked first: the dialog names the version, and nothing is restored yet.
  const dialog = await screen.findByRole("dialog");
  expect(dialog.textContent).toContain("Yesterday at 5:46 PM· Comma");
  expect(onRestore).not.toHaveBeenCalled();
  fireEvent.click(within(dialog).getByRole("button", { name: /^Restore/u }));
  expect(onRestore).toHaveBeenCalledExactlyOnceWith("two");
  // Restoring a version is not showing it.
  expect(onSelect).not.toHaveBeenCalled();
});

it("says a page shows an earlier version, and restores it from there", async () => {
  installNativeBridgeMock({ platform: "web" });
  const onRestore = vi.fn();
  const view = render(<Versions current="two" onRestore={onRestore} />);
  const bar = await screen.findByTestId("document-earlier-bar");
  expect(bar.textContent).toBe(
    "Earlier versionYesterday at 5:46 PMRestore this version"
  );
  // Cancel restores nothing.
  fireEvent.click(screen.getByRole("button", { name: "Restore this version" }));
  fireEvent.click(
    within(await screen.findByRole("dialog")).getByRole("button", { name: /^Cancel/u })
  );
  expect(onRestore).not.toHaveBeenCalled();
  fireEvent.click(await screen.findByRole("button", { name: "Restore this version" }));
  fireEvent.click(
    within(await screen.findByRole("dialog")).getByRole("button", { name: /^Restore/u })
  );
  expect(onRestore).toHaveBeenCalledExactlyOnceWith("two");

  // The current version has nothing to restore.
  view.rerender(<Versions current="three" onRestore={onRestore} />);
  expect(screen.queryByTestId("document-earlier-bar")).toBeNull();
});

it("heads the versions with the reader's edits that no message has carried, and discards them from there", async () => {
  installNativeBridgeMock({ platform: "web" });
  const onDiscard = vi.fn();
  const onSelect = vi.fn();
  render(<Versions current="three" onDiscard={onDiscard} onSelect={onSelect} />);
  fireEvent.click(await screen.findByRole("button", { name: "Versions of plan.md" }));
  const rows = await screen.findAllByRole("menuitemradio");
  expect(rows.map((item) => item.textContent)).toEqual([
    "Your editsSavedAda",
    "Today at 3:17 PMCurrentAda",
    "Yesterday at 5:46 PMComma",
    "Jul 3 at 10:08 AMAda",
  ]);
  // The page shows the edits, not the version they are of.
  expect(rows[0]).toHaveAttribute("aria-checked", "true");
  expect(rows[1]).toHaveAttribute("aria-checked", "false");
  fireEvent.click(screen.getAllByRole("button", { name: "More actions" })[0]!);
  fireEvent.click(await screen.findByRole("menuitem", { name: "Discard edits" }));
  expect(onDiscard).toHaveBeenCalledOnce();
  expect(onSelect).not.toHaveBeenCalled();
});
