import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import { cleanup, render } from "@comma/test-utils/render";
import { useState } from "react";
import { afterEach, expect, it, vi } from "vitest";
import { commands, page as browserPage, userEvent } from "vitest/browser";
import { DocumentFilePreview, type DocumentWriter } from "../DocumentFilePreview";
import { documentCaretMark } from "../documentRevision";
import type { DocumentEdit, DocumentPassage } from "../DocumentSelectionEdit";

const markdown = (text: string) => new Blob([text], { type: "text/markdown" });
const first = "# Plan\n\nThe plugin talks to the desktop.\n\n## Risks\n\nNone yet.\n";
const second = "# Plan\n\nThe plugin talks to the server.\n\n## Risks\n\nNone yet.\n";

function Page({ text, writer }: { text: string; writer?: DocumentWriter }) {
  return (
    <div style={{ display: "flex", height: 480, width: 520 }}>
      <DocumentFilePreview
        blob={markdown(text)}
        fileName="plan.md"
        onOpenBrowser={() => undefined}
        playFirst={writer !== undefined}
        writer={writer}
      />
    </div>
  );
}

const page = () => document.querySelector<HTMLElement>(".comma-document-page")!;
const caret = () =>
  document.querySelector<HTMLElement>("[data-testid='document-writer-caret']");
/** The page's words as a reader has them, without the caret's own name. */
const words = () =>
  (page().querySelector(".markdown-renderer")?.textContent ?? "").replace(
    documentCaretMark,
    ""
  );

afterEach(cleanup);

/** Until the page shows it: the page changing is what is waited on. */
async function untilPage(what: () => boolean) {
  while (!what())
    await new Promise<void>((resolve) => {
      const seen = new MutationObserver(() => {
        seen.disconnect();
        resolve();
      });
      seen.observe(document.body, {
        attributes: true,
        characterData: true,
        childList: true,
        subtree: true,
      });
    });
}

it("types a writer's versions under its caret, and leaves the page plain when the writer stops", async () => {
  const view = render(<Page text={first} writer={{ name: "Comma", active: true }} />);
  // The first version is typed: the page holds part of it before all of it.
  await untilPage(() => words().length > 0);
  expect(caret()?.textContent).toBe("Comma");
  await untilPage(
    () => words() === "PlanThe plugin talks to the desktop.RisksNone yet."
  );
  expect(caret()?.dataset.present).toBe("true");

  // The next version changes one line: the caret goes to that line, and the text after it stays.
  view.rerender(<Page text={second} writer={{ name: "Comma", active: true }} />);
  await untilPage(
    () => words() === "PlanThe plugin talks to the server.RisksNone yet."
  );
  const line = Array.from(page().querySelectorAll("p")).find((node) =>
    node.textContent?.includes("server")
  )!;
  await untilPage(() => {
    const bar = caret()!.getBoundingClientRect();
    const text = line.getBoundingClientRect();
    return bar.top >= text.top - 1 && bar.bottom <= text.bottom + 1;
  });

  // The writer stops: its caret leaves, and the page's text is the file's own.
  view.rerender(<Page text={second} writer={{ name: "Comma", active: false }} />);
  await untilPage(() => caret()?.dataset.present === "false");
  expect(page().textContent).not.toContain(documentCaretMark);
  // The shine leaves by its fade.
  await untilPage(() => document.querySelector("[data-document-writing]") === null);
});

it("shows a document nobody is writing at once, with the file's name where its text has no title", async () => {
  render(<Page text={"Notes without a heading.\n"} />);
  await untilPage(() => words() === "Notes without a heading.");
  expect(page().querySelector("h1")?.textContent).toBe("plan");
  expect(caret()).toBeNull();
});

function PageWithToolbar({ text, writer }: { text: string; writer?: DocumentWriter }) {
  const [toolbar, setToolbar] = useState<HTMLElement | null>(null);
  return (
    <div style={{ display: "flex", flexDirection: "column", height: 360, width: 520 }}>
      <div ref={setToolbar} />
      <DocumentFilePreview
        blob={markdown(text)}
        fileName="plan.md"
        onOpenBrowser={() => undefined}
        playFirst={writer !== undefined}
        toolbarSlot={toolbar}
        writer={writer}
      />
    </div>
  );
}
const sections = (count: number) =>
  `# Plan\n\n${Array.from(
    { length: count },
    (_, index) =>
      `## Section ${index + 1}\n\nWhat section ${index + 1} says, at some length.\n`
  ).join("\n")}`;
const viewport = () =>
  page().closest<HTMLElement>('[data-slot="scroll-area-viewport"]')!;
const notice = () =>
  document.querySelector<HTMLElement>("[data-testid='document-writer-notice']")!;
const inView = (element: Element) => {
  const bounds = element.getBoundingClientRect();
  const frame = viewport().getBoundingClientRect();
  return bounds.top >= frame.top - 1 && bounds.bottom <= frame.bottom + 1;
};

const menuItem = () =>
  Array.from(document.querySelectorAll("[role='menuitem']")).find(
    (node) => node.textContent === "Section 60"
  );

it("goes to a heading far down a long document from its outline", async () => {
  render(<PageWithToolbar text={sections(60)} />);
  const heading = () =>
    Array.from(page().querySelectorAll("h2")).find(
      (node) => node.textContent === "Section 60"
    );
  await untilPage(() => heading() !== undefined);
  expect(inView(heading()!)).toBe(false);
  await userEvent.click(
    document.querySelector("[data-testid='file-preview-outline']")!
  );
  await untilPage(() => menuItem() !== undefined);
  const item = menuItem()!;
  expect(document.querySelectorAll("[role='menuitem']")).toHaveLength(61);
  await userEvent.click(item);
  // Choosing a heading goes to it at once.
  expect(inView(heading()!)).toBe(true);
});

it("tells a reader who scrolled away that the writer is at work, and takes them there", async () => {
  render(
    <PageWithToolbar text={sections(12)} writer={{ name: "Comma", active: true }} />
  );
  // The page follows the writer to the end of the version.
  await untilPage(() => page().textContent?.includes("What section 12 says") === true);
  await untilPage(() => inView(caret()!));
  expect(notice().dataset.shown).toBe("false");

  // The reader wheels back up the page, as a reader does.
  const frame = viewport().getBoundingClientRect();
  await commands.mouseMove(frame.left + frame.width / 2, frame.top + frame.height / 2);
  const wheeled = new Promise((resolve) =>
    viewport().addEventListener("scroll", resolve, { once: true })
  );
  await commands.mouseWheel(0, -4000);
  await wheeled;
  // The page tells what is in view on a frame of its own: the wait is on the notice, which the frame changes.
  await expect
    .element(browserPage.elementLocator(notice()))
    .toHaveAttribute("data-shown", "true");
  expect(notice().textContent).toBe("Comma is writing");
  // The page's clock is the test's, and the notice's fade does not move on it: the press is at its place.
  const button = notice().querySelector("button")!.getBoundingClientRect();
  await commands.mouseMove(
    button.left + button.width / 2,
    button.top + button.height / 2
  );
  await commands.mouseDown();
  await commands.mouseUp();
  await expect
    .element(browserPage.elementLocator(notice()))
    .toHaveAttribute("data-shown", "false");
  expect(inView(caret()!)).toBe(true);
});

/** Where `passage` is drawn in `root`. */
function boxOfWords(root: HTMLElement, passage: string) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const at = node.textContent?.indexOf(passage) ?? -1;
    if (at < 0) continue;
    const range = document.createRange();
    range.setStart(node, at);
    range.setEnd(node, at + passage.length);
    return range.getBoundingClientRect();
  }
  throw new Error(`The page has no "${passage}".`);
}

/** A press of the pointer at a place of the page. */
async function press(x: number, y: number) {
  await commands.mouseMove(x, y);
  await commands.mouseDown();
  await commands.mouseUp();
}

/** A reader's drag over `passage` of the page they edit. */
async function dragOver(root: HTMLElement, passage: string) {
  const box = boxOfWords(root, passage);
  await commands.mouseMove(box.left + 1, box.top + box.height / 2);
  await commands.mouseDown();
  await commands.mouseMove(box.right - 1, box.top + box.height / 2, 6);
  await commands.mouseUp();
  await untilPage(() => toolbarButton("Bold") !== null);
}

const editWindow = () => document.querySelector("[data-testid='document-edit-window']");
const editorPage = () => document.querySelector<HTMLElement>(".comma-document-editor");
const toolbarButton = (label: string) =>
  document.querySelector(
    `[data-testid='document-format-toolbar'] [aria-label='${label}']`
  );
/** The tile on the toolbar's colour button. */
const colorMark = () =>
  document.querySelector("[data-testid='document-format-color-mark']")!;
const pressButton = async (button: Element) => {
  const box = button.getBoundingClientRect();
  await press(box.left + box.width / 2, box.top + box.height / 2);
};

/** A document a reader may change: their edits as the page reports them, and what they asked Comma. */
function Editable({
  text,
  record,
  width = 560,
}: {
  text: string;
  record: { drafts: (string | undefined)[]; asked: DocumentEdit[] };
  /** The panel's width. */
  width?: number;
}) {
  const [editing, setEditing] = useState<{ draft: string | undefined; resets: number }>(
    {
      draft: undefined,
      resets: 0,
    }
  );
  const [staged, setStaged] = useState<(DocumentPassage & { id: string })[]>([]);
  // What a panel does with pictures the reader puts in: it keeps each under its own name.
  const [images] = useState(() => {
    const kept = new Map<string, File>();
    return {
      read: async (name: string) => kept.get(name),
      add: (files: readonly File[]) =>
        files.map((file) => {
          kept.set(file.name, file);
          return file.name;
        }),
    };
  });
  return (
    <div style={{ display: "flex", flexDirection: "column", height: 520, width }}>
      {/* What a panel does when the reader discards their edits: the page is the file again. */}
      <button
        data-testid="discard"
        onClick={() =>
          setEditing(({ resets }) => ({ draft: undefined, resets: resets + 1 }))
        }
        type="button"
      >
        Discard
      </button>
      {/* The reader's edits as the page last reported them. */}
      <output data-testid="draft" hidden>
        {editing.draft}
      </output>
      <DocumentFilePreview
        blob={markdown(text)}
        editing={{
          ...editing,
          images,
          onDraft: (next) => {
            record.drafts.push(next);
            setEditing((current) => ({ ...current, draft: next }));
          },
        }}
        edits={{
          staged,
          onAdd: (edit) => {
            record.asked.push(edit);
            setStaged((current) => [
              ...current,
              { ...edit, id: `edit-${current.length}` },
            ]);
            return true;
          },
        }}
        fileName="plan.md"
        onOpenBrowser={vi.fn()}
      />
    </div>
  );
}

it("keeps the toolbar away from a selection the pointer still drags, and shows it when the pointer is let go", async () => {
  render(<Editable record={{ drafts: [], asked: [] }} text={first} />);
  await untilPage(() => editorPage() !== null);
  // What the page shows as the drag ends, before the release is answered.
  let underDrag: boolean | undefined;
  document.addEventListener(
    "pointerup",
    () => {
      underDrag = toolbarButton("Bold") !== null;
    },
    { capture: true, once: true }
  );
  await dragOver(editorPage()!, "desktop");
  expect(underDrag).toBe(false);
  expect(toolbarButton("Bold")).not.toBeNull();
});

it("marks the toolbar's colour button with the colours the selection has, and keeps the selection through both", async () => {
  render(<Editable record={{ drafts: [], asked: [] }} text={first} />);
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;
  // The passage opens its paragraph: a selection from a block's start is the one a new mark is hardest on.
  await dragOver(editor, "The plugin");
  const plain = getComputedStyle(colorMark());
  const [plainInk, plainWash] = [plain.color, plain.backgroundColor];
  /** Takes a colour from the button's menu. A choice reads as its tile's letter, then its name. */
  const choose = async (name: string) => {
    const choice = () =>
      Array.from(document.querySelectorAll("[role='menuitem']")).find((item) =>
        item.textContent?.endsWith(name)
      );
    // The button may stand past the edge of the test's window: the click brings it into view first.
    await userEvent.click(toolbarButton("Color")!);
    await untilPage(() => choice() !== undefined);
    await userEvent.click(choice()!);
  };

  await choose("Red text");
  const colored = () => editor.querySelector("span[data-color='red']");
  await untilPage(() => colored() !== null);
  // The mark's letter is the colour the text now has.
  const ink = getComputedStyle(colored()!).color;
  expect(ink).not.toBe(plainInk);
  expect(getComputedStyle(colorMark()).color).toBe(ink);

  // The selection is still the reader's: a ground is the next thing they give it, and the mark has both.
  await choose("Orange background");
  const grounded = () => editor.querySelector("mark[data-color='orange']");
  await untilPage(() => grounded() !== null);
  await untilPage(() => document.activeElement === editor);
  expect(String(getSelection())).toBe("The plugin");
  const wash = getComputedStyle(grounded()!).backgroundColor;
  expect(wash).not.toBe(plainWash);
  expect(getComputedStyle(colorMark()).backgroundColor).toBe(wash);
  expect(getComputedStyle(colorMark()).color).toBe(ink);
});

it("keeps every form in a narrow panel: the forms used less are in a bar that More opens", async () => {
  render(<Editable record={{ drafts: [], asked: [] }} text={first} width={300} />);
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;
  await dragOver(editor, "desktop");
  // The toolbar is in the panel, with the forms used most.
  const bar = document
    .querySelector("[data-testid='document-format-toolbar']")!
    .getBoundingClientRect();
  const panel = document
    .querySelector("[data-testid='file-preview-document']")!
    .getBoundingClientRect();
  expect(bar.left).toBeGreaterThanOrEqual(panel.left);
  expect(bar.right).toBeLessThanOrEqual(panel.right);
  expect(toolbarButton("Italic")).toBeNull();

  await pressButton(toolbarButton("More")!);
  await untilPage(() => toolbarButton("Italic") !== null);
  await pressButton(toolbarButton("Italic")!);
  await untilPage(() => editor.querySelector("em")?.textContent === "desktop");
});

it("asks Comma about a selected passage from the toolbar: its window takes what to change, and the passage stays marked once added", async () => {
  const record = { drafts: [], asked: [] as DocumentEdit[] };
  render(<Editable record={record} text={first} />);
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;
  expect(editWindow()).toBeNull();

  await dragOver(editor, "desktop");
  await pressButton(document.querySelector("[data-testid='document-format-ask']")!);
  await untilPage(() => editWindow()?.textContent?.includes("desktop") === true);
  // The window's field has the caret: what is typed next is what to change.
  await untilPage(() => document.activeElement?.tagName === "TEXTAREA");
  await userEvent.keyboard("Say server instead");
  await userEvent.keyboard("{Enter}");

  expect(record.asked).toEqual([
    {
      start: 28,
      end: 35,
      quote: "desktop",
      note: "Say server instead",
      before: "PlanThe plugin talks to the ",
      after: ".RisksNone yet.",
      heading: "Plan",
    },
  ]);
  expect(editWindow()).toBeNull();
  // The staged passage is marked where it is in the page.
  await untilPage(() => {
    const mark = document
      .querySelector(".comma-document-edit-mark")
      ?.getBoundingClientRect();
    const line = Array.from(editor.querySelectorAll("p"))
      .find((node) => node.textContent?.includes("desktop"))!
      .getBoundingClientRect();
    return (
      mark !== undefined && mark.top >= line.top - 1 && mark.bottom <= line.bottom + 1
    );
  });

  // Escape closes a window without adding its passage.
  await dragOver(editor, "None");
  await pressButton(document.querySelector("[data-testid='document-format-ask']")!);
  await untilPage(() => editWindow() !== null);
  await userEvent.keyboard("{Escape}");
  expect(editWindow()).toBeNull();
  expect(record.asked).toHaveLength(1);
});

it("is the reader's to change from the start: a block from the / menu and bold from the toolbar are reported as the reader's edits, and discarding them gives the file again", async () => {
  const record = { drafts: [] as (string | undefined)[], asked: [] };
  render(
    <Editable record={record} text={"# Plan\n\nThe plugin talks to the desktop.\n"} />
  );
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;
  expect(editor.textContent).toBe("PlanThe plugin talks to the desktop.");
  // The page opens to be read: nothing of it has the focus, and nothing is reported.
  expect(editor.contains(document.activeElement)).toBe(false);
  expect(record.drafts).toEqual([]);

  // A new line at the end, and a block from the menu at `/`.
  const sentence = boxOfWords(editor, "desktop.");
  await press(sentence.right - 1, sentence.top + sentence.height / 2);
  await userEvent.keyboard("{Enter}/");
  await untilPage(
    () => document.querySelector("[data-testid='document-slash-menu']") !== null
  );
  await userEvent.keyboard("todo");
  await untilPage(
    () =>
      document.querySelectorAll("[data-testid='document-slash-menu'] [role='option']")
        .length === 1
  );
  await userEvent.keyboard("{Enter}");
  await userEvent.keyboard("Review the plan");
  await untilPage(() => editor.querySelector("ul[data-type='taskList']") !== null);

  // Bold from the toolbar over a selection the reader drags.
  await dragOver(editor, "desktop");
  await pressButton(toolbarButton("Bold")!);
  await untilPage(() => editor.querySelector("strong") !== null);

  // A press elsewhere in the page moves the caret there: what is typed next goes there, not over the selection.
  // (the task's own paragraph: its box's label names the task too)
  const task = boxOfWords(
    editor.querySelector<HTMLElement>("ul[data-type='taskList'] p")!,
    "Review the plan"
  );
  await press(task.right - 1, task.top + task.height / 2);
  await userEvent.keyboard(" today");
  await untilPage(() => editor.textContent?.includes("Review the plan today") === true);

  // The page reports the reader's version as it stands, as Markdown.
  const version =
    "# Plan\n\nThe plugin talks to the **desktop**.\n\n- [ ] Review the plan today\n";
  await untilPage(
    () => document.querySelector("[data-testid='draft']")?.textContent === version
  );
  expect(record.drafts.at(-1)).toBe(version);

  // Edits set aside from outside the page: the page is the file again.
  await userEvent.click(document.querySelector("[data-testid='discard']")!);
  await untilPage(
    () => editorPage()?.textContent === "PlanThe plugin talks to the desktop."
  );
});

const table =
  "# Plan\n\n| Item | Rule |\n| --- | --- |\n| Mode | view |\n| Store | local |\n";
const draft = () => document.querySelector("[data-testid='draft']")?.textContent;
/** Takes a choice from a table handle's menu. */
async function fromHandle(side: "row" | "column", name: string) {
  const choice = () =>
    Array.from(document.querySelectorAll("[role='menuitem']")).find(
      (item) => item.textContent === name
    );
  const handle = () => document.querySelector(`[data-testid='document-table-${side}']`);
  await untilPage(() => handle() !== null);
  await userEvent.click(handle()!);
  await untilPage(() => choice() !== undefined);
  await userEvent.click(choice()!);
}
/** A control of the table the caret is in. */
const control = (name: string) =>
  document.querySelector(`[data-testid='document-table-${name}']`)!;
/** Whether a choice of the open menu is off: undefined while the menu has no such choice. */
const off = (name: string) =>
  Array.from(document.querySelectorAll("[role='menuitem']"))
    .find((item) => item.textContent === name)
    ?.getAttribute("aria-disabled");
/** Puts the caret in the cell that holds `words`. */
async function caretIn(root: HTMLElement, passage: string) {
  const box = boxOfWords(root, passage);
  await press(box.right - 1, box.top + box.height / 2);
}

it("changes a table from the handles of the caret's row and column, and writes the table as Markdown", async () => {
  render(<Editable record={{ drafts: [], asked: [] }} text={table} />);
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;

  // A row under the caret's row, with the caret in it.
  await caretIn(editor, "view");
  await fromHandle("row", "Insert row below");
  await untilPage(() => editor.querySelectorAll("tr").length === 4);
  await userEvent.keyboard("Auth");
  await untilPage(
    () =>
      draft() ===
      "# Plan\n\n| Item | Rule |\n| --- | --- |\n| Mode | view |\n|  | Auth |\n| Store | local |\n"
  );

  // The column is centred, then dragged by its handle to before the other, then its new row is deleted.
  await fromHandle("column", "Align center");
  const grip = control("column").getBoundingClientRect();
  const start = editor.querySelector("th")!.getBoundingClientRect();
  await commands.mouseMove(grip.left + grip.width / 2, grip.top + grip.height / 2);
  await commands.mouseDown();
  await commands.mouseMove(start.left + 4, grip.top + grip.height / 2, 6);
  await commands.mouseUp();
  await untilPage(() => editor.querySelector("th")?.textContent === "Rule");
  await fromHandle("row", "Delete row");
  await untilPage(
    () =>
      draft() ===
      "# Plan\n\n| Rule | Item |\n| :-: | --- |\n| view | Mode |\n| local | Store |\n"
  );

  // The header row stays the table's first row.
  await caretIn(editor, "Rule");
  await userEvent.click(document.querySelector("[data-testid='document-table-row']")!);
  await untilPage(() => off("Delete row") !== undefined);
  expect(off("Delete row")).toBe("true");
  expect(off("Insert row above")).toBe("true");
  expect(off("Insert row below")).not.toBe("true");
  await userEvent.keyboard("{Escape}");

  // A cell is a line of text: the / menu offers what goes in one.
  await caretIn(editor, "local");
  await userEvent.keyboard(" /");
  await untilPage(
    () => document.querySelector("[data-testid='document-slash-menu']") !== null
  );
  expect(
    Array.from(
      document.querySelectorAll("[data-testid='document-slash-menu'] [role='option']"),
      (option) => option.textContent
    )
  ).toEqual(["Link", "Date"]);
});

it("adds to a table from its bars, copies a row, moves a row by its handle, and sets every cell's form at once", async () => {
  // A panel the test's window holds whole: the bar at the table's end is past the table.
  render(<Editable record={{ drafts: [], asked: [] }} text={table} width={400} />);
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;

  // A row from the bar under the table, a column from the bar at its end, and a copy of a row.
  await caretIn(editor, "view");
  await untilPage(() => control("add-row") !== null);
  await userEvent.click(control("add-row"));
  await untilPage(() => editor.querySelectorAll("tr").length === 4);
  await userEvent.keyboard("New");
  await userEvent.click(control("add-column"));
  await untilPage(() => editor.querySelectorAll("th").length === 3);
  await caretIn(editor, "Mode");
  await fromHandle("row", "Duplicate");
  await untilPage(
    () =>
      draft() ===
      "# Plan\n\n| Item | Rule |  |\n| --- | --- | --- |\n| Mode | view |  |\n| Mode | view |  |\n| Store | local |  |\n|  | New |  |\n"
  );

  // The row of Store is dragged by its handle to above the first Mode row.
  await caretIn(editor, "Store");
  await untilPage(() => control("row") !== null);
  const grip = control("row").getBoundingClientRect();
  const target = editor.querySelectorAll("tr")[1]!.getBoundingClientRect();
  await commands.mouseMove(grip.left + grip.width / 2, grip.top + grip.height / 2);
  await commands.mouseDown();
  await commands.mouseMove(grip.left + grip.width / 2, target.top + 2, 6);
  await commands.mouseUp();
  await untilPage(() => editor.querySelectorAll("tr")[1]?.textContent === "Storelocal");

  // The corner's mark selects the table: bold from the toolbar is every cell's.
  await userEvent.click(control("select"));
  await untilPage(() => toolbarButton("Bold") !== null);
  // The toolbar stands over the table's first cell, clear of its words.
  expect(
    document
      .querySelector("[data-testid='document-format-toolbar']")!
      .getBoundingClientRect().bottom
  ).toBeLessThanOrEqual(boxOfWords(editor, "Item").top);
  await pressButton(toolbarButton("Bold")!);
  await untilPage(
    () =>
      draft() ===
      "# Plan\n\n| **Item** | **Rule** |  |\n| --- | --- | --- |\n| **Store** | **local** |  |\n| **Mode** | **view** |  |\n| **Mode** | **view** |  |\n|  | **New** |  |\n"
  );
});

it("puts a link in from the / menu: its words are selected and the toolbar takes its address", async () => {
  render(<Editable record={{ drafts: [], asked: [] }} text={first} />);
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;
  const end = boxOfWords(editor, "None yet.");
  await press(end.right - 1, end.top + end.height / 2);
  await userEvent.keyboard(" /link");
  await untilPage(
    () =>
      document.querySelectorAll("[data-testid='document-slash-menu'] [role='option']")
        .length === 1
  );
  await userEvent.keyboard("{Enter}");
  await untilPage(() => document.activeElement?.tagName === "INPUT");
  await userEvent.keyboard("https://comma.test/docs{Enter}");
  await untilPage(
    () =>
      draft() ===
      "# Plan\n\nThe plugin talks to the desktop.\n\n## Risks\n\nNone yet. [Link](https://comma.test/docs)\n"
  );
});

/** The chevron of a section, by what it says it does. */
const chevron = (name: string) =>
  document.querySelector(`[data-testid='document-section-fold'][aria-label='${name}']`);

it("folds a section away from its heading's chevron, leaves the document as it is, and shows the section when the reader types under the heading", async () => {
  const record = { drafts: [] as (string | undefined)[], asked: [] };
  render(<Editable record={record} text={first} />);
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;
  const under = () =>
    Array.from(editor.querySelectorAll("p")).find(
      (line) => line.textContent === "None yet."
    )!;

  // The caret's heading has a chevron: it folds what is under the heading away.
  await caretIn(editor, "Risks");
  await untilPage(() => chevron("Collapse section") !== null);
  await pressButton(chevron("Collapse section")!);
  await untilPage(() => chevron("Expand section") !== null);
  expect(under().getClientRects()).toHaveLength(0);
  // A fold is how the page is shown: the reader made no edit.
  expect(record.drafts).toHaveLength(0);

  // The chevron shows the section again.
  await pressButton(chevron("Expand section")!);
  await untilPage(() => under().getClientRects().length > 0);

  // A line the reader makes under a folded heading is not made out of sight.
  await pressButton(chevron("Collapse section")!);
  await untilPage(() => chevron("Expand section") !== null);
  await userEvent.keyboard("{End}{Enter}Soon");
  await untilPage(() => under().getClientRects().length > 0);
  await untilPage(
    () =>
      draft() ===
      "# Plan\n\nThe plugin talks to the desktop.\n\n## Risks\n\nSoon\n\nNone yet.\n"
  );
});

it("takes a picture dropped on the page from outside it: the page shows it, and the document names its file", async () => {
  render(<Editable record={{ drafts: [], asked: [] }} text={first} />);
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;
  // The smallest picture there is: one transparent pixel.
  const pixel = Uint8Array.from(
    atob(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    ),
    (one) => one.charCodeAt(0)
  );
  const carried = new DataTransfer();
  carried.items.add(new File([pixel], "chart.png", { type: "image/png" }));
  const over = boxOfWords(editor, "desktop");
  editor.dispatchEvent(
    new DragEvent("drop", {
      bubbles: true,
      cancelable: true,
      clientX: over.left + 2,
      clientY: over.top + over.height / 2,
      dataTransfer: carried,
    })
  );
  // It is a block of its own after the paragraph it was dropped on, drawn from its file.
  await untilPage(() => editor.querySelector(".comma-document-image img") !== null);
  expect(
    editor.querySelector<HTMLImageElement>(".comma-document-image img")!.src
  ).toMatch(/^blob:/u);
  await untilPage(
    () =>
      draft() ===
      "# Plan\n\nThe plugin talks to the desktop.\n\n![chart](chart.png)\n\n## Risks\n\nNone yet.\n"
  );
});

it("keeps a block it cannot edit as the page that is read draws it: an address in it is named, never loaded", async () => {
  // Two pictures in one paragraph are no picture block of the page: the editor keeps the paragraph as written.
  render(
    <Editable
      record={{ drafts: [], asked: [] }}
      text={"# Plan\n\n![Chart](chart.png) ![Far](https://example.com/far.png)\n"}
    />
  );
  await untilPage(
    () => editorPage()?.querySelector(".comma-document-raw .markdown-renderer") != null
  );
  const raw = editorPage()!.querySelector(".comma-document-raw")!;
  await untilPage(
    () => raw.querySelector("img") !== null || raw.textContent!.includes("Far")
  );
  expect(raw.querySelectorAll("img")).toHaveLength(0);
  expect(raw.textContent).toContain("Image: Far (not loaded)");
});

/** A control of the bar over a selected picture. */
const pictureBar = (label: string) =>
  document.querySelector(
    `[data-testid='document-picture-toolbar'] [aria-label='${label}']`
  );
const deletePicture = () =>
  Array.from(document.querySelectorAll("[role='menuitem']")).find(
    (item) => item.textContent === "Delete picture"
  );

it("sets a selected picture to a side, gives it a width from its grip, and deletes it", async () => {
  render(<Editable record={{ drafts: [], asked: [] }} text={first} />);
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;
  // A picture wide enough to press and to drag.
  const canvas = document.createElement("canvas");
  canvas.width = 120;
  canvas.height = 60;
  canvas.getContext("2d")!.fillRect(0, 0, 120, 60);
  const picture = await new Promise<Blob>((resolve) =>
    canvas.toBlob((made) => resolve(made!), "image/png")
  );
  const carried = new DataTransfer();
  carried.items.add(new File([picture], "chart.png", { type: "image/png" }));
  const over = boxOfWords(editor, "desktop");
  editor.dispatchEvent(
    new DragEvent("drop", {
      bubbles: true,
      cancelable: true,
      clientX: over.left + 2,
      clientY: over.top + over.height / 2,
      dataTransfer: carried,
    })
  );
  const shown = () =>
    editor.querySelector<HTMLImageElement>(".comma-document-image img");
  await untilPage(() => shown() !== null);
  // The picture is drawn once it is decoded: no change of the page says so.
  await shown()!.decode();

  // A press on the picture selects it: its bar sets it in the middle of the page.
  const at = shown()!.getBoundingClientRect();
  await press(at.left + at.width / 2, at.top + at.height / 2);
  await untilPage(() => pictureBar("Align center") !== null);
  await pressButton(pictureBar("Align center")!);
  await untilPage(
    () =>
      draft() ===
      '# Plan\n\nThe plugin talks to the desktop.\n\n<p align="center"><img src="chart.png" alt="chart"></p>\n\n## Risks\n\nNone yet.\n'
  );

  // Its grip is dragged outward: the picture in the middle grows on both sides, so twice as far.
  const grip = document
    .querySelector("[data-testid='document-picture-grip-end']")!
    .getBoundingClientRect();
  await commands.mouseMove(grip.left + grip.width / 2, grip.top + grip.height / 2);
  await commands.mouseDown();
  await commands.mouseMove(
    grip.left + grip.width / 2 + 30,
    grip.top + grip.height / 2,
    4
  );
  await commands.mouseUp();
  await untilPage(() => draft()?.includes('width="180"') === true);

  // More deletes it: the document reads as its file again.
  await userEvent.click(pictureBar("More")!);
  await untilPage(() => deletePicture() !== undefined);
  await userEvent.click(deletePicture()!);
  await untilPage(() => shown() === null);
  await untilPage(() => !draft());
});

it("draws the document's own pictures in a page that is read, from their files and never from an address", async () => {
  const canvas = document.createElement("canvas");
  canvas.width = 120;
  canvas.height = 60;
  canvas.getContext("2d")!.fillRect(0, 0, 120, 60);
  const picture = await new Promise<Blob>((resolve) =>
    canvas.toBlob((made) => resolve(made!), "image/png")
  );
  const asked: string[] = [];
  const read = async (name: string) => {
    asked.push(name);
    return name === "gone.png" ? undefined : picture;
  };
  render(
    <div style={{ display: "flex", height: 480, width: 400 }}>
      <DocumentFilePreview
        blob={markdown(
          '# Plan\n\n![Chart](chart.png)\n\n<p align="center"><img src="wide.png" alt="Wide" width="60"></p>\n\n![Gone](gone.png)\n\n![Far](https://example.com/far.png)\n'
        )}
        fileName="plan.md"
        onOpenBrowser={() => undefined}
        pictures={read}
      />
    </div>
  );
  const drawn = () =>
    Array.from(page().querySelectorAll<HTMLImageElement>(".comma-document-image img"));
  await untilPage(() => drawn().length === 2);
  // The pictures are drawn once they are decoded: no change of the page says so.
  await Promise.all(drawn().map((one) => one.decode()));
  expect(drawn().map((one) => [one.alt, one.src.slice(0, 5)])).toEqual([
    ["Chart", "blob:"],
    ["Wide", "blob:"],
  ]);
  // The one the document set in the middle and gave a width is there, at that width.
  const wide = drawn()[1]!;
  expect(wide.getBoundingClientRect().width).toBe(60);
  expect(wide.closest(".comma-document-image")!.getAttribute("data-align")).toBe(
    "center"
  );
  const column = page().querySelector(".markdown-renderer")!.getBoundingClientRect();
  const box = wide.getBoundingClientRect();
  expect(
    Math.abs(box.left + box.width / 2 - (column.left + column.width / 2))
  ).toBeLessThan(1);
  // A file the document does not have here is its words; an address is named and not loaded.
  await untilPage(() => words().includes("Gone"));
  expect(words()).toContain("Image: Far (not loaded)");
  expect(asked.toSorted()).toEqual(["chart.png", "gone.png", "wide.png"]);
});

const slashMenu = () =>
  document.querySelector<HTMLElement>("[data-testid='document-slash-menu']");

it("keeps the menu of blocks inside what is seen of the page: over the caret where the page ends under it", async () => {
  // The reader presses at the foot of the page: the window is tall enough to hold the whole panel, whatever size
  // the file that ran before this one left it at.
  await browserPage.viewport(900, 900);
  render(<Editable record={{ drafts: [], asked: [] }} text={sections(8)} />);
  await untilPage(() => editorPage() !== null);
  const editor = editorPage()!;
  const inside = () => {
    const box = slashMenu()!.getBoundingClientRect();
    const seen = viewport().getBoundingClientRect();
    return box.top >= seen.top && box.bottom <= seen.bottom && box.height > 0;
  };

  // At the top of the page the menu is under the caret, as it has room there.
  const start = boxOfWords(editor, "What section 1 says, at some length.");
  await press(start.right - 1, start.top + start.height / 2);
  await userEvent.keyboard("{Enter}/");
  await untilPage(() => slashMenu() !== null);
  expect(slashMenu()!.getAttribute("data-side")).toBeNull();
  expect(inside()).toBe(true);
  await userEvent.keyboard("{Escape}{Backspace}{Backspace}");
  await untilPage(() => slashMenu() === null);

  // The reader goes to the page's end: a `/` in its last line has no room under it.
  viewport().scrollTop = viewport().scrollHeight;
  const last = boxOfWords(editor, "What section 8 says, at some length.");
  expect(last.bottom).toBeLessThanOrEqual(viewport().getBoundingClientRect().bottom);
  await press(last.right - 1, last.top + last.height / 2);
  await userEvent.keyboard("{Enter}/");
  // The menu is placed as it is drawn: once it is in the page, it is where it stays.
  await untilPage(() => slashMenu() !== null);
  expect(slashMenu()!.getAttribute("data-side")).toBe("above");
  expect(inside()).toBe(true);
  // The menu opened over the pointer, which rests where it pressed: the keys still start from the first block.
  expect(slashMenu()!.querySelector("[aria-selected='true']")?.textContent).toContain(
    "Text"
  );
  // Every block is there to take: the list scrolls where it is taller than its room.
  expect(slashMenu()!.querySelectorAll("[role='option']").length).toBeGreaterThan(10);
  await browserPage.viewport(1280, 720);
});
