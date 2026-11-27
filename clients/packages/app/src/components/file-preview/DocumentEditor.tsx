// The document's page as an editor (TipTap). A document a reader may change is this page from the start: there is
// no mode to enter. It draws the page as the reader sees it (`.comma-document-prose`), with a toolbar over a
// selection (ask Comma about the passage, or set the text's form) and a menu at `/` for blocks. What it writes is
// Markdown (`documentEditorModel`).
//
// The page reports the reader's edits as they are made (`onDraft`). What becomes of them is the panel's: beside a
// chat they go with the chat's next message.
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import {
  AlignCenterIcon,
  AlignLeftIcon,
  AlignRightIcon,
  BoldIcon,
  CalendarIcon,
  ChainLinkIcon,
  ChecklistIcon,
  ChevronDownSmallIcon,
  CodeIcon,
  DividerIcon,
  FormulaIcon,
  HeadingOneIcon,
  HeadingThreeIcon,
  HeadingTwoIcon,
  ImageIcon,
  ItalicIcon,
  ListBulletsIcon,
  MoreHorizontalIcon,
  NumberedListIcon,
  OpenQuoteIcon,
  StrikeThroughIcon,
  TableIcon,
  TextIndentIcon,
  TextOutdentIcon,
  TextIcon,
} from "@comma/ui/components/icons";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  menuSurfaceClasses,
} from "@comma/ui/components/menu";
import {
  appKeyModifierKeycaps,
  detectAppKeybindingPlatform,
} from "@comma/ui/components/settings-shortcut";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import {
  Mark,
  mergeAttributes,
  Node as EditorNodeType,
  type Editor,
} from "@tiptap/core";
import type { Node as PageNode } from "@tiptap/pm/model";
import { NodeSelection, TextSelection } from "@tiptap/pm/state";
import type { EditorView } from "@tiptap/pm/view";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { TableCell, TableHeader, TableKit } from "@tiptap/extension-table";
import { Placeholder } from "@tiptap/extensions";
import {
  EditorContent,
  NodeViewWrapper,
  ReactNodeViewRenderer,
  useEditor,
  useEditorState,
  type ReactNodeViewProps,
} from "@tiptap/react";
import { StarterKit } from "@tiptap/starter-kit";
import {
  createContext,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { Button as AriaButton, Focusable, MenuTrigger } from "react-aria-components";
import { SectionFolding, SectionFolds } from "./DocumentSections";
import { TableControls } from "./DocumentTableControls";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { ColorChoices, colorCheck, colorOf } from "./DocumentColorChoices";
import type { DocumentColor } from "./documentColors";
import {
  documentToEditor,
  documentVideoName,
  editorToDocument,
  type EditorNode,
} from "./documentEditorModel";
import {
  DocumentPassageMarks,
  DocumentPassageWindow,
  selectedPassage,
  usePassageMarks,
  type DocumentPassages,
} from "./DocumentSelectionEdit";
import {
  documentPictureDrawer,
  useDocumentPictureAddress,
  type DocumentPictureRead,
} from "./DocumentPictureView";

/** A reader's own edits of the document shown, which are no version of it until they are sent in the chat. */
export type DocumentEditing = {
  /** The edits no message has carried yet, as the whole document; undefined: the page is the file. */
  draft: string | undefined;
  /**
   * The times `draft` was set from outside the page (a version restored, edits discarded): the page starts anew on
   * each, where otherwise it reads `draft` once, when it opens.
   */
  resets: number;
  /** The page changed: what it now holds, or undefined when it reads as the file again. */
  onDraft: (markdown: string | undefined) => void;
  /** The document's pictures; without it the page takes none, and names the ones it has. */
  images?: DocumentImages | undefined;
  /** The pictures, by file name, that a message is carrying now: each says so until it has arrived. */
  sending?: ReadonlySet<string> | undefined;
};

/**
 * The pictures of a document that go with it as files. The document names each by its file name
 * (`documentImageName`); the files are kept and sent by what shows the page.
 */
export type DocumentImages = {
  /** The file of this name, where the document has one. */
  read: DocumentPictureRead;
  /**
   * Takes pictures the reader put in the page, and gives the name each is kept under, in their order. Without it
   * the page takes no new pictures.
   */
  add?: ((files: readonly File[]) => string[]) | undefined;
};

type Messages = ReturnType<typeof useCommaMessages>;

const two = (value: number) => String(value).padStart(2, "0");

// ── Markdown the editor keeps as written ────────────────────────────────────

/** Markdown the editor has no node for, as one block: drawn as the page draws it, and edited as its source. */
function RawBlockView({ node, updateAttributes, selected }: ReactNodeViewProps) {
  const messages = useCommaMessages();
  const markdown = String(node.attrs.markdown ?? "");
  // A block just put in by the menu opens on its source; one the document came with shows as it reads.
  const [editing, setEditing] = useState(() =>
    /^\$\$\s*\$\$$|^!\[[^\]]*\]\((?:https:\/\/)?\)$/u.test(markdown)
  );
  const field = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    if (editing) field.current?.focus();
  }, [editing]);
  // The block is drawn as the page that is read draws the document: its own pictures from their files, an address
  // named and never loaded. The block is inert, so its links are not followed from it.
  const images = useContext(DocumentImagesContext);
  const resources = useMemo(
    () => ({
      onOpenLink: () => undefined,
      ...(images ? { renderPicture: documentPictureDrawer(images.read) } : {}),
    }),
    [images]
  );
  return (
    <NodeViewWrapper
      className="comma-document-raw"
      data-selected={selected ? "true" : undefined}
      onDoubleClick={() => setEditing(true)}
    >
      {editing ? (
        <textarea
          aria-label={messages.file_preview_document_editor_source()}
          className="comma-document-raw-source"
          onBlur={() => setEditing(false)}
          onChange={(event) => updateAttributes({ markdown: event.target.value })}
          onKeyDown={(event) => {
            // The editor's own keys do not reach the source.
            event.stopPropagation();
            if (event.key === "Escape") setEditing(false);
          }}
          ref={field}
          spellCheck={false}
          value={markdown}
        />
      ) : (
        <div contentEditable={false} inert>
          <MarkdownStream
            animation="none"
            content={markdown}
            documentResourcePolicy={resources}
            final
            htmlPolicy="escape"
          />
        </div>
      )}
    </NodeViewWrapper>
  );
}

const RawBlock = EditorNodeType.create({
  name: "rawBlock",
  group: "block",
  atom: true,
  selectable: true,
  draggable: false,
  addAttributes: () => ({ markdown: { default: "" } }),
  parseHTML: () => [{ tag: "div[data-raw-block]" }],
  renderHTML: ({ HTMLAttributes }) => [
    "div",
    mergeAttributes(HTMLAttributes, { "data-raw-block": "" }),
  ],
  addNodeView: () => ReactNodeViewRenderer(RawBlockView),
});

const DocumentImagesContext = createContext<DocumentImages | undefined>(undefined);
// Its own context: a picture is read again when `images` changes, and only marked again when this does.
const DocumentSendingContext = createContext<ReadonlySet<string> | undefined>(
  undefined
);

/** A picture of the document's own: its file, drawn; its words where the file cannot be read. */
// The least width a reader drags a picture to.
const pictureMinWidth = 80;

function DocumentImageView({
  node,
  selected,
  updateAttributes,
  deleteNode,
}: ReactNodeViewProps) {
  const messages = useCommaMessages();
  const images = useContext(DocumentImagesContext);
  const sending = useContext(DocumentSendingContext);
  const name = String(node.attrs.src ?? "");
  const words = String(node.attrs.alt ?? "") || name;
  const address = useDocumentPictureAddress(images?.read, name);
  const video = documentVideoName(name);
  const align = String(node.attrs.align ?? "") || "left";
  const width = Number(node.attrs.width) || undefined;
  // The picture's width while a reader drags one of its sides.
  const [dragged, setDragged] = useState<number>();
  const frame = useRef<HTMLSpanElement>(null);
  /** A drag of one of the picture's sides sets its width; a picture in the middle grows on both sides at once. */
  const resize = (side: "start" | "end") => (event: ReactPointerEvent) => {
    const box = frame.current;
    const page = box?.parentElement;
    if (event.button !== 0 || !box || !page) return;
    event.preventDefault();
    const view = box.ownerDocument;
    const from = event.clientX;
    const start = box.getBoundingClientRect().width;
    const most = page.getBoundingClientRect().width;
    const rate = (side === "end" ? 1 : -1) * (align === "center" ? 2 : 1);
    let next = start;
    const move = (moving: PointerEvent) => {
      next = Math.round(
        Math.min(
          most,
          Math.max(pictureMinWidth, start + (moving.clientX - from) * rate)
        )
      );
      setDragged(next);
    };
    const end = () => {
      view.removeEventListener("pointermove", move);
      view.removeEventListener("pointerup", end);
      view.removeEventListener("pointercancel", end);
      setDragged(undefined);
      if (next !== Math.round(start)) updateAttributes({ width: next });
    };
    view.addEventListener("pointermove", move);
    view.addEventListener("pointerup", end);
    view.addEventListener("pointercancel", end);
  };
  // What a reader does with the picture they selected, where the page takes their edits.
  const controls = selected && images !== undefined;
  const side = (to: "left" | "center" | "right", label: string, icon: ReactNode) => (
    <FormatButton
      active={align === to}
      label={label}
      // Left is where a picture is with no side set.
      onPress={() => updateAttributes({ align: to === "left" ? null : to })}
    >
      {icon}
    </FormatButton>
  );
  return (
    <NodeViewWrapper
      className="comma-document-image"
      data-align={align}
      data-selected={selected ? "true" : undefined}
    >
      {address ? (
        <span
          className="comma-document-image-frame"
          // A drawing has no size of its own: it is as wide as the page.
          data-kind={/\.svg$/iu.test(name) ? "drawing" : undefined}
          data-sized={(dragged ?? width) === undefined ? undefined : "true"}
          ref={frame}
          style={{ width: dragged ?? width }}
        >
          {video ? (
            // oxlint-disable-next-line jsx-a11y/media-has-caption -- A file the reader put in has no captions track.
            <video aria-label={words} controls preload="metadata" src={address} />
          ) : (
            <img alt={words} draggable={false} src={address} />
          )}
          {sending?.has(name) ? (
            // The picture is on its way with a message: a skeleton stands over it until it has arrived.
            <output
              aria-busy="true"
              aria-label={messages.chat_question_uploading()}
              className="comma-document-image-skeleton"
            />
          ) : null}
          {controls ? (
            <>
              <span
                aria-label={words}
                className="comma-document-format comma-document-image-bar"
                contentEditable={false}
                data-testid="document-picture-toolbar"
                role="toolbar"
              >
                {side(
                  "left",
                  messages.file_preview_document_table_align_left(),
                  <AlignLeftIcon aria-hidden className={glyph} />
                )}
                {side(
                  "center",
                  messages.file_preview_document_table_align_center(),
                  <AlignCenterIcon aria-hidden className={glyph} />
                )}
                {side(
                  "right",
                  messages.file_preview_document_table_align_right(),
                  <AlignRightIcon aria-hidden className={glyph} />
                )}
                <span aria-hidden="true" className="comma-document-format-rule" />
                <MenuTrigger>
                  <Tooltip
                    content={messages.file_preview_document_format_more()}
                    placement="top"
                  >
                    <AriaButton
                      aria-label={messages.file_preview_document_format_more()}
                      className="comma-document-format-button"
                    >
                      <MoreHorizontalIcon aria-hidden className={glyph} />
                    </AriaButton>
                  </Tooltip>
                  <MenuPopover
                    className={cx("w-44 overflow-hidden", menuSurfaceClasses)}
                    placement="bottom end"
                  >
                    <Menu
                      aria-label={messages.file_preview_document_format_more()}
                      className="py-sm"
                      onAction={() => deleteNode()}
                      variant="embedded"
                    >
                      <MenuItem id="delete" tone="destructive">
                        {video
                          ? messages.file_preview_document_video_delete()
                          : messages.file_preview_document_picture_delete()}
                      </MenuItem>
                    </Menu>
                  </MenuPopover>
                </MenuTrigger>
              </span>
              {(["start", "end"] as const).map((one) => (
                <span
                  aria-hidden="true"
                  className="comma-document-image-grip"
                  data-side={one}
                  data-testid={`document-picture-grip-${one}`}
                  key={one}
                  onPointerDown={resize(one)}
                />
              ))}
            </>
          ) : null}
        </span>
      ) : address === undefined ? (
        // Its file is being read: a skeleton keeps a picture's place.
        <span
          aria-hidden="true"
          className="comma-document-image-skeleton"
          data-wait="true"
        />
      ) : (
        // The document has no such file here: its words stand for it.
        <span className="comma-document-image-wait">{words}</span>
      )}
    </NodeViewWrapper>
  );
}

const DocumentImage = EditorNodeType.create({
  name: "documentImage",
  group: "block",
  atom: true,
  selectable: true,
  draggable: false,
  addAttributes: () => ({
    src: { default: "" },
    alt: { default: "" },
    // The side the picture is set to and its width: neither, where it is as Markdown's own picture is.
    align: { default: null },
    width: { default: null },
  }),
  parseHTML: () => [{ tag: "div[data-document-image]" }],
  renderHTML: ({ HTMLAttributes }) => [
    "div",
    mergeAttributes(HTMLAttributes, { "data-document-image": "" }),
  ],
  addNodeView: () => ReactNodeViewRenderer(DocumentImageView),
});

/** The pictures and videos among what a drop or a paste carries: the kinds the page shows. */
const picturesOf = (carried: DataTransfer | null) =>
  Array.from(carried?.files ?? []).filter((file) =>
    /^(?:image\/(?:png|jpeg|gif|webp|svg\+xml)|video\/(?:webm|mp4|quicktime))$/u.test(
      file.type
    )
  );

const RawInline = EditorNodeType.create({
  name: "rawInline",
  group: "inline",
  inline: true,
  atom: true,
  addAttributes: () => ({ markdown: { default: "" } }),
  parseHTML: () => [{ tag: "span[data-raw-inline]" }],
  renderHTML: ({ node, HTMLAttributes }) => [
    "span",
    mergeAttributes(HTMLAttributes, {
      "data-raw-inline": "",
      class: "comma-document-raw-inline",
    }),
    String(node.attrs.markdown ?? ""),
  ],
});

/**
 * A colour of the text (`<span data-color>`) or of the ground behind it (`<mark data-color>`), by its name in the
 * document's palette (`documentColors`).
 */
const colorMark = (name: "textColor" | "ground", tag: "span" | "mark") =>
  Mark.create({
    name,
    addAttributes: () => ({
      color: {
        default: null,
        parseHTML: (element: HTMLElement) => element.getAttribute("data-color"),
        renderHTML: (attributes: { color?: string | null }) =>
          attributes.color ? { "data-color": attributes.color } : {},
      },
    }),
    parseHTML: () => [{ tag: `${tag}[data-color]` }],
    renderHTML: ({ HTMLAttributes }) => [tag, mergeAttributes(HTMLAttributes), 0],
  });
const TextColor = colorMark("textColor", "span");
const Ground = colorMark("ground", "mark");

/** A table cell keeps its column's alignment through an edit. */
const aligned = {
  align: {
    default: null,
    parseHTML: (element: HTMLElement) => element.style.textAlign || null,
    renderHTML: (attributes: { align?: string | null }) =>
      attributes.align ? { style: `text-align: ${attributes.align}` } : {},
  },
};
// A cell of a Markdown table is one line of text: it holds paragraphs and nothing else.
const AlignedCell = TableCell.extend({
  content: "paragraph+",
  addAttributes() {
    return { ...this.parent?.(), ...aligned };
  },
});
const AlignedHeader = TableHeader.extend({
  content: "paragraph+",
  addAttributes() {
    return { ...this.parent?.(), ...aligned };
  },
});
// The least width of a table's column, as where the page is read (9rem): a table of more columns than the page
// has room for is moved sideways.
const columnMinWidth = 144;

// ── Blocks the `/` menu puts in ─────────────────────────────────────────────

type Block = {
  id: string;
  /** What shows before the name: the block's glyph. */
  mark: ReactNode;
  label: string;
  /** What a reader may type to find it besides its name. */
  words: string;
  /** The Markdown that makes it when typed, shown as a hint. */
  hint?: string;
  /** It goes in a line of text, so a table's cell takes it too. */
  inline?: boolean;
  run: (editor: Editor) => void;
};

const glyph = "size-xl";
const headingMarks = [
  <HeadingOneIcon aria-hidden className={glyph} key="h1" />,
  <HeadingTwoIcon aria-hidden className={glyph} key="h2" />,
  <HeadingThreeIcon aria-hidden className={glyph} key="h3" />,
];

// How the `/` menu asks the toolbar of an editor for its link field.
const linkFields = new WeakMap<Editor, () => void>();

function blocks(messages: Messages): Block[][] {
  const heading = (level: 1 | 2 | 3 | 4): Block => ({
    id: `h${level}`,
    // The glyph set stops at the third level.
    mark: headingMarks[level - 1] ?? `H${level}`,
    label: messages.file_preview_document_block_heading({ level }),
    words: `heading h${level} 标题`,
    hint: "#".repeat(level),
    run: (editor) => editor.chain().focus().setHeading({ level }).run(),
  });
  return [
    [
      {
        id: "text",
        mark: <TextIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_text(),
        words: "text paragraph 正文 文本",
        run: (editor) => editor.chain().focus().setParagraph().run(),
      },
      heading(1),
      heading(2),
      heading(3),
      heading(4),
      {
        id: "bullet",
        mark: <ListBulletsIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_bulleted(),
        words: "bulleted list unordered 无序 列表",
        hint: "-",
        run: (editor) => editor.chain().focus().toggleBulletList().run(),
      },
      {
        id: "numbered",
        mark: <NumberedListIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_numbered(),
        words: "numbered ordered list 有序 编号 列表",
        hint: "1.",
        run: (editor) => editor.chain().focus().toggleOrderedList().run(),
      },
      {
        id: "todo",
        mark: <ChecklistIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_todo(),
        words: "todo task checklist 待办 任务",
        hint: "[]",
        run: (editor) => editor.chain().focus().toggleTaskList().run(),
      },
      {
        id: "quote",
        mark: <OpenQuoteIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_quote(),
        words: "quote blockquote 引用",
        hint: ">",
        run: (editor) => editor.chain().focus().setBlockquote().run(),
      },
      {
        id: "divider",
        mark: <DividerIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_divider(),
        words: "divider rule line hr 分割线",
        hint: "---",
        run: (editor) => editor.chain().focus().setHorizontalRule().run(),
      },
    ],
    [
      {
        id: "code",
        mark: <CodeIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_code(),
        words: "code block 代码",
        hint: "```",
        run: (editor) => editor.chain().focus().setCodeBlock().run(),
      },
      {
        id: "table",
        mark: <TableIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_table(),
        words: "table grid 表格",
        run: (editor) =>
          editor
            .chain()
            .focus()
            .insertTable({ rows: 3, cols: 3, withHeaderRow: true })
            .run(),
      },
      {
        id: "image",
        mark: <ImageIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_image(),
        words: "image picture photo 图片",
        run: (editor) =>
          editor
            .chain()
            .focus()
            .insertContent({ type: "rawBlock", attrs: { markdown: "![](https://)" } })
            .run(),
      },
      {
        id: "equation",
        mark: <FormulaIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_equation(),
        words: "equation math formula latex 公式",
        hint: "$$",
        run: (editor) =>
          editor
            .chain()
            .focus()
            .insertContent({ type: "rawBlock", attrs: { markdown: "$$\n\n$$" } })
            .run(),
      },
      {
        id: "link",
        mark: <ChainLinkIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_link(),
        words: "link url address web 链接 网址",
        inline: true,
        // The link's words are put in and selected, and the toolbar asks for its address.
        run: (editor) => {
          const words = messages.file_preview_document_block_link();
          const from = editor.state.selection.from;
          editor
            .chain()
            .focus()
            .insertContent(words)
            .setTextSelection({ from, to: from + words.length })
            .run();
          linkFields.get(editor)?.();
        },
      },
      {
        id: "date",
        mark: <CalendarIcon aria-hidden className={glyph} />,
        label: messages.file_preview_document_block_date(),
        words: "date today 日期 今天",
        inline: true,
        run: (editor) => {
          const now = new Date(uiClock.now());
          editor
            .chain()
            .focus()
            .insertContent(
              `${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())}`
            )
            .run();
        },
      },
    ],
  ];
}

/** `/` and what was typed after it, when the caret is in a paragraph right after them. */
function slashAt(editor: Editor) {
  const { selection } = editor.state;
  if (!selection.empty || selection.$from.parent.type.name !== "paragraph")
    return undefined;
  const before = selection.$from.parent.textBetween(
    0,
    selection.$from.parentOffset,
    "\n",
    "\n"
  );
  const typed = /(?:^|\s)\/([^\s/]*)$/u.exec(before);
  if (!typed) return undefined;
  return {
    query: typed[1]!.toLowerCase(),
    from: selection.from - typed[1]!.length - 1,
    to: selection.from,
    // The paragraph is a table cell's: it takes what goes in a line of text.
    cell: selection.$from.node(-1).type.name.startsWith("table"),
  };
}

/** Where a place in the document is on the page, from the page's own corner. */
function placeOf(editor: Editor, position: number, frame: HTMLElement) {
  const at = editor.view.coordsAtPos(position);
  const origin = frame.getBoundingClientRect();
  return {
    left: at.left - origin.left,
    top: at.top - origin.top,
    bottom: at.bottom - origin.top,
  };
}

// How far the menu of blocks stays from the caret and from the edge of what is seen (`--spacing-sm`).
const slashMargin = 8;

/**
 * The menu of blocks under a `/`: the reader goes on typing to narrow it, and takes one with Enter or a press. The
 * caret stays in the page, so the menu is a list the page's keys move in, not a menu that takes the focus.
 */
function SlashMenu({
  editor,
  frame,
  keys,
}: {
  editor: Editor;
  frame: HTMLElement | null;
  /** Where the page's key handler asks the menu to act on a key; true: the menu took it. */
  keys: { current: ((key: string) => boolean) | undefined };
}) {
  const messages = useCommaMessages();
  const groups = useMemo(() => blocks(messages), [messages]);
  const slash = useEditorState({
    editor,
    selector: ({ editor: current }) => slashAt(current),
  });
  // Escape closes the menu for the `/` it was opened by.
  const [closedAt, setClosedAt] = useState<number>();
  const open = slash !== undefined && slash.from !== closedAt;
  const shown = useMemo(
    () =>
      groups.map((group) =>
        group.filter(
          (block) =>
            (!slash?.cell || block.inline === true) &&
            (!slash?.query ||
              block.label.toLowerCase().includes(slash.query) ||
              block.words.includes(slash.query))
        )
      ),
    [groups, slash?.cell, slash?.query]
  );
  const flat = shown.flat();
  const [active, setActive] = useState(0);
  useEffect(() => setActive(0), [slash?.query, slash?.from]);
  const take = (block: Block | undefined) => {
    if (!block || !slash) return;
    editor.chain().focus().deleteRange({ from: slash.from, to: slash.to }).run();
    block.run(editor);
  };
  keys.current =
    open && flat.length > 0
      ? (key) => {
          if (key === "ArrowDown") setActive((active + 1) % flat.length);
          else if (key === "ArrowUp")
            setActive((active + flat.length - 1) % flat.length);
          else if (key === "Enter" || key === "Tab") take(flat[active]);
          else if (key === "Escape") setClosedAt(slash.from);
          else return false;
          return true;
        }
      : undefined;
  // The menu's own size with all of its rows: what tells whether it fits under the caret, and beside it.
  const menu = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState<{ width: number; height: number }>();
  const listed = open && frame ? flat.length : 0;
  useLayoutEffect(() => {
    const element = menu.current;
    if (!element) return;
    // Its rows and its own edges; its height as it is when nothing bounds it.
    const height = element.scrollHeight + element.offsetHeight - element.clientHeight;
    setSize((current) =>
      current?.width === element.offsetWidth && current.height === height
        ? current
        : { width: element.offsetWidth, height }
    );
  }, [listed]);
  if (!open || !frame || flat.length === 0) return null;
  const place = placeOf(editor, slash.from, frame);
  // The menu stays inside what the reader sees of the page (the panel's scroll area): it is under the caret where
  // it fits there or there is more room than over it, and over the caret otherwise. It is no taller than its room,
  // and scrolls in it.
  const origin = frame.getBoundingClientRect();
  const seen = (
    frame.closest('[data-slot="scroll-area-viewport"]') ??
    frame.ownerDocument.documentElement
  ).getBoundingClientRect();
  const under = seen.bottom - (origin.top + place.bottom) - slashMargin * 2;
  const over = origin.top + place.top - seen.top - slashMargin * 2;
  const above = size !== undefined && size.height > under && over > under;
  return (
    <div
      aria-label={messages.file_preview_document_blocks()}
      className={cx("comma-document-slash", menuSurfaceClasses)}
      data-side={above ? "above" : undefined}
      data-testid="document-slash-menu"
      ref={menu}
      // The caret stays in the page, so the list is the page's own and no form control.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listbox"
      style={{
        // Its end stays inside the page's column where the caret is near the column's end.
        left: Math.max(0, Math.min(place.left, origin.width - (size?.width ?? 0))),
        ...(above ? { bottom: origin.height - place.top } : { top: place.bottom }),
        ["--comma-document-slash-room" as string]: `${Math.max(0, above ? over : under)}px`,
      }}
    >
      {shown.map((group, index) =>
        group.length === 0 ? null : (
          // oxlint-disable-next-line react/no-array-index-key
          <div className="comma-document-slash-group" key={index} role="presentation">
            {group.map((block) => (
              <div
                aria-selected={flat[active] === block}
                className="comma-document-slash-item"
                key={block.id}
                // The press keeps the caret in the page.
                onMouseDown={(event) => {
                  event.preventDefault();
                  take(block);
                }}
                // A pointer that moves over a row takes it. One that rests where the menu opens does not: the
                // row the keys start from stays the first.
                onMouseMove={() => {
                  if (flat[active] !== block) setActive(flat.indexOf(block));
                }}
                // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                role="option"
                tabIndex={-1}
              >
                <span aria-hidden="true" className="comma-document-slash-mark">
                  {block.mark}
                </span>
                <span className="comma-document-slash-label">{block.label}</span>
                {block.hint ? (
                  <span aria-hidden="true" className="comma-document-slash-hint">
                    {block.hint}
                  </span>
                ) : null}
              </div>
            ))}
          </div>
        )
      )}
    </div>
  );
}

// ── The toolbar over a selection ────────────────────────────────────────────

/** The keys of a form's shortcut, as this machine names them: the editor's Mod is Command on a Mac. */
function formKeys(key: string, shift = false) {
  const mac = detectAppKeybindingPlatform() === "macos";
  return [
    ...appKeyModifierKeycaps({ alt: false, control: !mac, meta: mac, shift }),
    key,
  ];
}

/**
 * A form's button. Its name, and the keys that set the form where it has some, show over it: the toolbar stands
 * over the selection, so what says what a button does stands clear of the text.
 */
function FormatButton({
  active,
  children,
  disabled = false,
  label,
  onPress,
  shortcut,
  tip = "top",
}: {
  active: boolean;
  children: ReactNode;
  disabled?: boolean;
  label: string;
  onPress: () => void;
  shortcut?: readonly string[] | undefined;
  /** The side of the button its name shows on. */
  tip?: "top" | "bottom";
}) {
  return (
    <Tooltip content={label} placement={tip} {...(shortcut ? { shortcut } : {})}>
      <Focusable>
        <button
          aria-label={label}
          aria-pressed={active}
          className="comma-document-format-button"
          disabled={disabled}
          // The press keeps the selection it acts on.
          onMouseDown={(event) => {
            event.preventDefault();
            onPress();
          }}
          type="button"
        >
          {children}
        </button>
      </Focusable>
    </Tooltip>
  );
}

// How far the toolbar stays from the panel's edges (`--spacing-md`, its distance from the selection).
const toolbarEdge = 8;

const styleGlyphs: Record<string, ReactNode> = {
  text: <TextIcon aria-hidden className={glyph} />,
  h1: headingMarks[0],
  h2: headingMarks[1],
  h3: headingMarks[2],
};
const listGlyphs: Record<string, ReactNode> = {
  none: <ListBulletsIcon aria-hidden className={glyph} />,
  bullet: <ListBulletsIcon aria-hidden className={glyph} />,
  numbered: <NumberedListIcon aria-hidden className={glyph} />,
  todo: <ChecklistIcon aria-hidden className={glyph} />,
};

/**
 * What a reader does with the selected text. First, asking Comma to change it (`onAsk`). Then its form: its block
 * (text or a heading), bold, italic, strikethrough, code, its list and indent, and a link. The toolbar stands over
 * the selection while the reader has one in the page.
 */
function FormatToolbar({
  editor,
  frame,
  hidden,
  onAsk,
}: {
  editor: Editor;
  frame: HTMLElement | null;
  /** Something else stands at the selection now. */
  hidden: boolean;
  onAsk?: (() => void) | undefined;
}) {
  const messages = useCommaMessages();
  const state = useEditorState({
    editor,
    selector: ({ editor: current }) => {
      const { selection } = current.state;
      const level = [1, 2, 3, 4].find((one) =>
        current.isActive("heading", { level: one })
      );
      return {
        // Where the selection starts on the page: the first of its cells, where it is of cells.
        from: Math.min(...selection.ranges.map((range) => range.$from.pos)),
        to: selection.to,
        empty: selection.empty,
        // The selection was drawn from its end to its start.
        backward: selection.anchor > selection.head,
        text: selection instanceof TextSelection,
        // One block selected whole (a picture, a rule) takes no form of text.
        node: selection instanceof NodeSelection,
        // The selection is in a table: a cell is a line of text, so it takes no block's form.
        cell: selection.$from.node(-1)?.type.name.startsWith("table") === true,
        focused: current.isFocused,
        bold: current.isActive("bold"),
        italic: current.isActive("italic"),
        strike: current.isActive("strike"),
        code: current.isActive("code"),
        link: current.isActive("link"),
        block: level ? `h${level}` : "text",
        list: current.isActive("taskList")
          ? "todo"
          : current.isActive("orderedList")
            ? "numbered"
            : current.isActive("bulletList")
              ? "bullet"
              : "none",
        color: colorOf(current.getAttributes("textColor").color),
        ground: colorOf(current.getAttributes("ground").color),
        // Code is text as written: it takes no form of its own.
        plain: current.isActive("codeBlock"),
        // An item goes a level in under the item before it, and a level out from a list in a list or its own.
        indents: ["taskItem", "listItem"].some((item) =>
          current.can().sinkListItem(item)
        ),
        outdents: ["taskItem", "listItem"].some((item) =>
          current.can().liftListItem(item)
        ),
      };
    },
  });
  // A menu of the toolbar, or its link field, has the focus while it is used: the toolbar stays for it.
  const [menu, setMenu] = useState(false);
  const [linking, setLinking] = useState<string>();
  const linkField = useRef<HTMLInputElement>(null);
  const linkOpen = linking !== undefined;
  useEffect(() => {
    linkFields.set(editor, () => setLinking(""));
    return () => void linkFields.delete(editor);
  }, [editor]);
  useEffect(() => {
    if (linkOpen) linkField.current?.focus();
  }, [linkOpen]);
  // A selection made with the pointer is not done until the pointer is let go: the toolbar waits for that, so it
  // is never under a drag. It then comes in along the way the selection was drawn (`data-direction`), as the
  // chat's bar over a selection does; one made at the keyboard has it at once.
  const [pressed, setPressed] = useState(false);
  const byPointer = useRef(false);
  // A double or triple press selects a word or a line outright: the pointer drew nothing.
  const multiple = useRef(false);
  useEffect(() => {
    if (!frame) return undefined;
    const view = frame.ownerDocument;
    const down = (event: PointerEvent) => {
      // A press with the control key is the context menu's, and has no release.
      if (event.button !== 0 || event.ctrlKey) return;
      if (
        !(
          event.target instanceof Element &&
          event.target.closest(".comma-document-editor")
        )
      )
        return;
      byPointer.current = true;
      setPressed(true);
    };
    const up = () => setPressed(false);
    const keys = () => {
      byPointer.current = false;
    };
    // The press's count is the mouse event's, and it comes before the release.
    const count = (event: MouseEvent) => {
      multiple.current = event.detail >= 2;
    };
    frame.addEventListener("pointerdown", down);
    frame.addEventListener("mousedown", count, true);
    frame.addEventListener("keydown", keys);
    // A drag of the selected text ends with no release of its own.
    for (const end of ["pointerup", "pointercancel", "dragend"] as const)
      view.addEventListener(end, up);
    return () => {
      frame.removeEventListener("pointerdown", down);
      frame.removeEventListener("mousedown", count, true);
      frame.removeEventListener("keydown", keys);
      for (const end of ["pointerup", "pointercancel", "dragend"] as const)
        view.removeEventListener(end, up);
    };
  }, [frame]);
  // A press that puts a selection of text away is in the page before the editor has read it: until then the
  // editor still holds the selection before, and the toolbar does not come back over it.
  const putAway =
    byPointer.current &&
    state.text &&
    state.focused &&
    frame?.ownerDocument.getSelection()?.isCollapsed === true;
  const shown =
    frame !== null &&
    !hidden &&
    !pressed &&
    !putAway &&
    !state.node &&
    !state.empty &&
    (state.focused || menu || linkOpen);
  const place = shown ? placeOf(editor, state.from, frame) : undefined;
  const bar = useRef<HTMLDivElement>(null);
  const left = place?.left;
  // In a panel narrower than the whole toolbar, the forms used less go to a second bar that More opens over it
  // (`narrow`, `more`). The whole toolbar's width is kept from when it was last drawn whole.
  const [narrow, setNarrow] = useState(false);
  const [more, setMore] = useState(false);
  const whole = useRef(0);
  useEffect(() => {
    if (!shown) setMore(false);
  }, [shown]);
  // The toolbar starts where the selection does and stays in the panel: it may stand over the page's margins, as
  // far from the panel's edge as it is from the selection.
  useLayoutEffect(() => {
    const element = bar.current;
    if (!element || !frame || left === undefined) return;
    const text = frame.getBoundingClientRect();
    const panel = (frame.closest(".comma-document") ?? frame).getBoundingClientRect();
    const least = Math.min(0, panel.left - text.left + toolbarEdge);
    const room = Math.max(text.width, panel.right - text.left - toolbarEdge) - least;
    if (!narrow && !linkOpen) whole.current = element.offsetWidth;
    if (whole.current > room !== narrow) {
      // It is drawn again in its other form, and placed then.
      setNarrow(!narrow);
      return;
    }
    const most = Math.max(least, least + room - element.offsetWidth);
    element.style.left = `${Math.min(Math.max(least, left), most)}px`;
    // Whatever changes the toolbar's place or its width: the selection, its forms, and the toolbar's own form.
  }, [frame, left, linkOpen, more, narrow, state]);
  if (!place) return null;
  const textStyle = (id: string) => {
    const chain = editor.chain().focus();
    if (id === "text") chain.setParagraph().run();
    else chain.setHeading({ level: Number(id.slice(1)) as 1 | 2 | 3 }).run();
  };
  const colour = (mark: "textColor" | "ground", color: DocumentColor | "default") => {
    const chain = editor.chain().focus();
    if (color === "default") chain.unsetMark(mark).run();
    else chain.setMark(mark, { color }).run();
  };
  const list = (id: string) => {
    const chain = editor.chain().focus();
    if (id === "bullet") chain.toggleBulletList().run();
    else if (id === "numbered") chain.toggleOrderedList().run();
    else if (id === "todo") chain.toggleTaskList().run();
    else {
      const item = state.list === "todo" ? "taskItem" : "listItem";
      if (id === "indent") chain.sinkListItem(item).run();
      else chain.liftListItem(item).run();
    }
  };
  // The toolbar's parts. Its own row holds the forms used most; the rest are in the row too where there is room,
  // and in the bar over it where there is not.
  const tip = narrow && more ? "bottom" : "top";
  const rule = <span aria-hidden="true" className="comma-document-format-rule" />;
  const styleMenu = (
    <MenuTrigger onOpenChange={setMenu}>
      <Tooltip content={messages.file_preview_document_format_style()} placement={tip}>
        <AriaButton
          aria-label={messages.file_preview_document_format_style()}
          className="comma-document-format-button comma-document-format-menu"
          isDisabled={state.cell}
        >
          {styleGlyphs[state.block] ?? (
            <span aria-hidden="true" className="comma-document-format-type">
              {state.block.toUpperCase()}
            </span>
          )}
          <ChevronDownSmallIcon aria-hidden className="size-lg" />
        </AriaButton>
      </Tooltip>
      <MenuPopover
        className={cx("w-48 overflow-hidden", menuSurfaceClasses)}
        placement="bottom start"
      >
        <Menu
          aria-label={messages.file_preview_document_format_style()}
          className="py-sm"
          disallowEmptySelection
          onAction={(key) => textStyle(String(key))}
          selectedKeys={[state.block]}
          selectionMode="single"
          variant="embedded"
        >
          <MenuItem icon={styleGlyphs.text} id="text" selectionIndicator="check">
            {messages.file_preview_document_block_text()}
          </MenuItem>
          {([1, 2, 3] as const).map((level) => (
            <MenuItem
              icon={styleGlyphs[`h${level}`]}
              id={`h${level}`}
              key={level}
              selectionIndicator="check"
            >
              {messages.file_preview_document_block_heading({ level })}
            </MenuItem>
          ))}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
  const bold = (
    <FormatButton
      active={state.bold}
      disabled={state.plain}
      label={messages.file_preview_document_format_bold()}
      shortcut={formKeys("B")}
      tip={tip}
      onPress={() => editor.chain().focus().toggleBold().run()}
    >
      <BoldIcon aria-hidden className={glyph} />
    </FormatButton>
  );
  const link = (
    <FormatButton
      active={state.link}
      disabled={state.plain}
      label={messages.file_preview_document_format_link()}
      tip={tip}
      onPress={() => setLinking(String(editor.getAttributes("link").href ?? ""))}
    >
      <ChainLinkIcon aria-hidden className={glyph} />
    </FormatButton>
  );
  const rest = (
    <>
      <FormatButton
        active={state.italic}
        disabled={state.plain}
        label={messages.file_preview_document_format_italic()}
        shortcut={formKeys("I")}
        onPress={() => editor.chain().focus().toggleItalic().run()}
      >
        <ItalicIcon aria-hidden className={glyph} />
      </FormatButton>
      <FormatButton
        active={state.strike}
        disabled={state.plain}
        label={messages.file_preview_document_format_strike()}
        shortcut={formKeys("S", true)}
        onPress={() => editor.chain().focus().toggleStrike().run()}
      >
        <StrikeThroughIcon aria-hidden className={glyph} />
      </FormatButton>
      <FormatButton
        active={state.code}
        disabled={state.plain}
        label={messages.file_preview_document_format_code()}
        shortcut={formKeys("E")}
        onPress={() => editor.chain().focus().toggleCode().run()}
      >
        <CodeIcon aria-hidden className={glyph} />
      </FormatButton>
    </>
  );
  const menus = (
    <>
      <MenuTrigger onOpenChange={setMenu}>
        <Tooltip
          content={messages.file_preview_document_format_color()}
          placement="top"
        >
          <AriaButton
            aria-label={messages.file_preview_document_format_color()}
            className="comma-document-format-button comma-document-format-menu"
            isDisabled={state.plain}
          >
            {/* The selection's own colours: the tile is the button's mark and says what is set. */}
            <span
              aria-hidden="true"
              className="comma-document-swatch"
              data-ink={state.color}
              data-testid="document-format-color-mark"
              data-wash={state.ground}
            >
              A
            </span>
            <ChevronDownSmallIcon aria-hidden className="size-lg" />
          </AriaButton>
        </Tooltip>
        <MenuPopover
          className={cx("w-56 overflow-hidden", menuSurfaceClasses)}
          placement="bottom start"
        >
          <ScrollArea className="max-h-[inherit]" viewportClassName="max-h-[inherit]">
            <ColorChoices
              current={state.color}
              kind="color"
              label={messages.file_preview_document_color_text()}
              onChoose={(color) => colour("textColor", color)}
            />
            <MenuSeparator />
            <ColorChoices
              current={state.ground}
              kind="ground"
              label={messages.file_preview_document_color_ground()}
              onChoose={(color) => colour("ground", color)}
            />
          </ScrollArea>
        </MenuPopover>
      </MenuTrigger>
      {rule}
      <MenuTrigger onOpenChange={setMenu}>
        <Tooltip content={messages.file_preview_document_format_list()} placement="top">
          <AriaButton
            aria-label={messages.file_preview_document_format_list()}
            className="comma-document-format-button comma-document-format-menu"
            data-active={state.list !== "none" ? "true" : undefined}
            isDisabled={state.cell}
          >
            {listGlyphs[state.list]}
            <ChevronDownSmallIcon aria-hidden className="size-lg" />
          </AriaButton>
        </Tooltip>
        <MenuPopover
          className={cx("w-56 overflow-hidden", menuSurfaceClasses)}
          placement="bottom start"
        >
          {/* The list the selection is in is checked at the row's end, so every row's glyph is in one
              column with the indent rows' under them. */}
          <Menu
            aria-label={messages.file_preview_document_format_list()}
            className="py-sm"
            onAction={(key) => list(String(key))}
            variant="embedded"
          >
            {(
              [
                ["bullet", messages.file_preview_document_block_bulleted()],
                ["numbered", messages.file_preview_document_block_numbered()],
                ["todo", messages.file_preview_document_block_todo()],
              ] as const
            ).map(([id, name]) => (
              <MenuItem
                icon={listGlyphs[id]}
                id={id}
                key={id}
                shortcut={state.list === id ? colorCheck : undefined}
              >
                {name}
              </MenuItem>
            ))}
          </Menu>
          <MenuSeparator />
          <Menu
            aria-label={messages.file_preview_document_format_indent()}
            className="pb-sm"
            disabledKeys={[
              ...(state.indents ? [] : ["indent"]),
              ...(state.outdents ? [] : ["outdent"]),
            ]}
            onAction={(key) => list(String(key))}
            variant="embedded"
          >
            <MenuItem
              icon={<TextIndentIcon aria-hidden className={glyph} />}
              id="indent"
            >
              {messages.file_preview_document_format_indent()}
            </MenuItem>
            <MenuItem
              icon={<TextOutdentIcon aria-hidden className={glyph} />}
              id="outdent"
            >
              {messages.file_preview_document_format_outdent()}
            </MenuItem>
          </Menu>
        </MenuPopover>
      </MenuTrigger>
    </>
  );
  return (
    <div
      aria-label={messages.file_preview_document_format()}
      className="comma-document-format"
      data-direction={
        byPointer.current
          ? multiple.current
            ? "none"
            : state.backward
              ? "backward"
              : "forward"
          : undefined
      }
      data-testid="document-format-toolbar"
      ref={bar}
      role="toolbar"
      style={{ top: place.top }}
    >
      {linking !== undefined ? (
        <form
          className="comma-document-format-link"
          onSubmit={(event) => {
            event.preventDefault();
            const href = linking.trim();
            const chain = editor.chain().focus().extendMarkRange("link");
            if (href) chain.setLink({ href }).run();
            else chain.unsetLink().run();
            setLinking(undefined);
          }}
        >
          <ChainLinkIcon aria-hidden className={glyph} />
          <input
            aria-label={messages.file_preview_document_format_link()}
            onChange={(event) => setLinking(event.target.value)}
            onKeyDown={(event) => {
              if (event.key !== "Escape") return;
              event.preventDefault();
              setLinking(undefined);
              editor.commands.focus();
            }}
            placeholder="https://"
            ref={linkField}
            value={linking}
          />
          <Button hierarchy="tertiary-gray" size="xs" type="submit">
            {messages.file_preview_document_format_apply()}
          </Button>
        </form>
      ) : (
        <>
          {onAsk && state.text ? (
            <>
              <button
                className="comma-document-format-button comma-document-format-ask"
                data-testid="document-format-ask"
                // The press keeps the selection it asks about.
                onMouseDown={(event) => {
                  event.preventDefault();
                  onAsk();
                }}
                type="button"
              >
                {messages.file_preview_document_edit_ask()}
              </button>
              <span aria-hidden="true" className="comma-document-format-rule" />
            </>
          ) : null}
          {styleMenu}
          {/* The narrow row is one group after Ask: it is as short as its buttons. */}
          {narrow ? null : rule}
          {bold}
          {narrow ? null : rest}
          {link}
          {narrow ? (
            <>
              <FormatButton
                active={more}
                label={messages.file_preview_document_format_more()}
                onPress={() => setMore(!more)}
                tip={tip}
              >
                <MoreHorizontalIcon aria-hidden className={glyph} />
              </FormatButton>
              {more ? (
                <div
                  aria-label={messages.file_preview_document_format_more()}
                  className="comma-document-format-more"
                  data-testid="document-format-more"
                  // The rest of the toolbar's buttons, not a form's set of fields.
                  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
                  role="group"
                >
                  {rest}
                  {menus}
                </div>
              ) : null}
            </>
          ) : (
            menus
          )}
        </>
      )}
    </div>
  );
}

// ── The editor ──────────────────────────────────────────────────────────────

/** Puts the pictures of these file names in the page, each a block, after the page's own block that holds `at`. */
function putPictures(view: EditorView, at: number, names: readonly string[]) {
  const type = view.state.schema.nodes.documentImage;
  if (!type || names.length === 0) return;
  const place = view.state.doc.resolve(Math.min(at, view.state.doc.content.size));
  const after = place.depth === 0 ? place.pos : place.after(1);
  view.dispatch(
    view.state.tr
      .insert(
        after,
        names.map((name) =>
          type.create({ src: name, alt: name.replace(/\.[^.]+$/u, "") })
        )
      )
      .scrollIntoView()
  );
  view.focus();
}

// How long after the reader's last change the page's Markdown is written.
const draftMs = 250;

/**
 * The document as a page the reader changes. It opens with the reader's edits of the file that no message has
 * carried yet (`editing.draft`), or with the file, and reports each change of the page.
 */
export default function DocumentEditor({
  markdown,
  editing,
  passages,
  onOpenBrowser,
}: {
  /** The file's text. */
  markdown: string;
  editing: DocumentEditing;
  /** Asking Comma to change a selected passage; without it the toolbar has no such action. */
  passages?: DocumentPassages | undefined;
  onOpenBrowser: (url: string) => void;
}) {
  const messages = useCommaMessages();
  const [file] = useState(() => documentToEditor(markdown));
  const [opened] = useState(() =>
    editing.draft === undefined ? file : documentToEditor(editing.draft)
  );
  const [frame, setFrame] = useState<HTMLDivElement | null>(null);
  const slashKeys = useRef<((key: string) => boolean) | undefined>(undefined);
  // The edits are of the version the page opened with: they are reported to it, whatever the panel shows next.
  const [onDraft] = useState(() => editing.onDraft);
  const latest = useRef({ onOpenBrowser, images: editing.images });
  latest.current = { onOpenBrowser, images: editing.images };

  // The page with edits not written out yet, the timer that writes them, and the file as the page writes it.
  const unwritten = useRef<PageNode | undefined>(undefined);
  const timer = useRef<CancelUiTimer | undefined>(undefined);
  const baseline = useRef<string | undefined>(undefined);
  /** Writes the page out as Markdown and reports it. */
  const write = (page: PageNode) => {
    const markdownOf = (doc: PageNode) =>
      editorToDocument(doc.toJSON() as EditorNode, file.frontMatter);
    timer.current?.();
    timer.current = undefined;
    unwritten.current = undefined;
    // The file through the editor's own nodes, so a page that reads as the file is written as it.
    baseline.current ??= markdownOf(page.type.schema.nodeFromJSON(file.doc));
    const now = markdownOf(page);
    onDraft(now === baseline.current ? undefined : now);
  };
  const writer = useRef(write);
  writer.current = write;
  // Edits made in the last moment before the page goes are written too: when the page is taken off, and when its
  // window closes or the app does, which takes the page with it at once.
  useEffect(() => {
    const flush = () => {
      timer.current?.();
      if (unwritten.current) writer.current(unwritten.current);
    };
    window.addEventListener("pagehide", flush);
    return () => {
      window.removeEventListener("pagehide", flush);
      flush();
    };
  }, []);

  const editor = useEditor({
    extensions: [
      StarterKit.configure({ underline: false, link: { openOnClick: false } }),
      TaskList,
      TaskItem.configure({ nested: true }),
      TableKit.configure({
        table: { resizable: false, renderWrapper: true, cellMinWidth: columnMinWidth },
        tableCell: false,
        tableHeader: false,
      }),
      AlignedCell,
      AlignedHeader,
      Placeholder.configure({
        placeholder: messages.file_preview_document_editor_placeholder(),
      }),
      RawBlock,
      DocumentImage,
      RawInline,
      TextColor,
      Ground,
      SectionFolding,
    ],
    content: opened.doc,
    // The page opens to be read: the caret is the reader's to place.
    autofocus: false,
    editorProps: {
      attributes: {
        "aria-label": messages.file_preview_document_editor(),
        class: "comma-document-prose comma-document-editor",
      },
      // The `/` menu takes the keys that move in it and choose from it.
      handleKeyDown: (_view, event) => slashKeys.current?.(event.key) ?? false,
      // Pictures dropped on the page from outside it, or pasted: each goes in as a block of its own, after the
      // block it was dropped on, and is kept as a file of the document.
      handleDrop: (view, event) => {
        const pictures = picturesOf(event.dataTransfer);
        const add = latest.current.images?.add;
        if (!add || pictures.length === 0) return false;
        event.preventDefault();
        const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
        putPictures(view, at?.pos ?? view.state.selection.from, add(pictures));
        return true;
      },
      handlePaste: (view, event) => {
        const pictures = picturesOf(event.clipboardData);
        const add = latest.current.images?.add;
        if (!add || pictures.length === 0) return false;
        event.preventDefault();
        putPictures(view, view.state.selection.from, add(pictures));
        return true;
      },
      // A press on a link follows it, as in a page that is read.
      handleClick: (_view, _position, event) => {
        const link =
          event.target instanceof Element ? event.target.closest("a[href]") : null;
        if (!link) return false;
        latest.current.onOpenBrowser(link.getAttribute("href")!);
        return true;
      },
    },
    onUpdate: ({ editor: current }) => {
      unwritten.current = current.state.doc;
      timer.current?.();
      timer.current = uiClock.after(draftMs, () => {
        if (unwritten.current) writer.current(unwritten.current);
      });
    },
  });

  // The passage the reader asks Comma about, and where its window stands.
  const [asking, setAsking] = useState<ReturnType<typeof selectedPassage>>();
  const [root, setRoot] = useState<HTMLElement | null>(null);
  useEffect(
    () => setRoot(frame?.querySelector<HTMLElement>(".comma-document-editor") ?? null),
    [frame]
  );
  const staged = passages?.staged;
  const marked = useMemo(
    () => [...(staged ?? []), ...(asking ? [{ id: "asking", ...asking.passage }] : [])],
    [asking, staged]
  );
  const rects = usePassageMarks(root, marked);

  return (
    <div className="comma-document-edit" data-testid="document-editor" ref={setFrame}>
      <DocumentPassageMarks rects={rects} />
      <DocumentImagesContext.Provider value={editing.images}>
        <DocumentSendingContext.Provider value={editing.sending}>
          <EditorContent editor={editor} />
        </DocumentSendingContext.Provider>
      </DocumentImagesContext.Provider>
      <FormatToolbar
        editor={editor}
        frame={frame}
        hidden={asking !== undefined}
        onAsk={
          passages
            ? () => {
                const selected = root ? selectedPassage(root) : undefined;
                if (selected) setAsking(selected);
              }
            : undefined
        }
      />
      <SlashMenu editor={editor} frame={frame} keys={slashKeys} />
      <TableControls editor={editor} frame={frame} />
      <SectionFolds editor={editor} frame={frame} />
      {asking && passages ? (
        <DocumentPassageWindow
          left={asking.left}
          onAdd={passages.onAdd}
          onClose={() => setAsking(undefined)}
          passage={asking.passage}
          top={asking.top}
        />
      ) : null}
    </div>
  );
}
