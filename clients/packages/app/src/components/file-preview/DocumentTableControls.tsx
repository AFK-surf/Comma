// What a reader does with a table of the page they edit (`DocumentEditor`). While the caret is in a table:
//
// - a handle stands on the table's top edge over the caret's column, and one on its left edge by the caret's row.
//   A press opens the column's or the row's menu (colour it, put one in beside it, copy it, clear it, move it,
//   delete it, and for a column set its alignment); a drag moves the row or the column to where it is let go;
// - a bar under the table adds a row, and one at its end adds a column;
// - six dots in the page's margin by the table's first row select every cell, so the toolbar over a selection sets the whole table's form.
//
// A Markdown table has one header row, and a cell is one line of text. So the header row stays the first row: it is
// not deleted or moved, and no row is put in above it.
import { useCommaMessages } from "@comma/i18n/react";
import {
  AlignCenterIcon,
  AlignLeftIcon,
  AlignRightIcon,
  ArrowDownIcon,
  ArrowLeftIcon,
  ArrowRightIcon,
  ArrowUpIcon,
  CheckLargeIcon,
  ChevronRightSmallIcon,
  CircleXIcon,
  ColorRollIcon,
  CopyIcon,
  DragHandleIcon,
  MoreHorizontalIcon,
  PlusSmallIcon,
  TrashCanIcon,
} from "@comma/ui/components/icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  SubmenuTrigger,
  menuSurfaceClasses,
} from "@comma/ui/components/menu";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { motionDuration } from "@comma/ui/tokens";
import type { Editor } from "@tiptap/core";
import { Fragment, type MarkType, type Node as PageNode } from "@tiptap/pm/model";
import { TextSelection } from "@tiptap/pm/state";
import { CellSelection } from "@tiptap/pm/tables";
import { useEditorState } from "@tiptap/react";
import {
  useEffect,
  useReducer,
  useRef,
  useState,
  type CSSProperties,
  type PointerEvent,
  type ReactNode,
} from "react";
import { Button as AriaButton, Focusable } from "react-aria-components";
import { ColorMenu } from "./DocumentColorChoices";
import type { DocumentColor } from "./documentColors";

/** A table's cells, row by row. */
type Cells = PageNode[][];

/** Where the caret is in a table: the table's place in the document, and the caret's row and column in it. */
type Place = { table: number; row: number; column: number };

/** One change of a table: its cells after it, and the cell the caret is in then. */
type Change = (
  rows: Cells,
  /** A new empty cell: of the header row or not, with its column's alignment. */
  make: (header: boolean, align: unknown) => PageNode
) => { rows: Cells; row: number; column: number };

/** A row or a column. */
type Side = "row" | "column";

/** Makes `change` to the table at `place`, as one step the reader undoes, and puts the caret in its cell. */
function changeTable(editor: Editor, place: Place, change: Change) {
  editor
    .chain()
    .focus()
    .command(({ tr, state }) => {
      const table = state.doc.nodeAt(place.table);
      if (table?.type.name !== "table") return false;
      const { tableCell, tableHeader, tableRow } = state.schema.nodes;
      if (!tableCell || !tableHeader || !tableRow) return false;
      const rows: Cells = [];
      table.forEach((row) => {
        const cells: PageNode[] = [];
        row.forEach((cell) => cells.push(cell));
        rows.push(cells);
      });
      const next = change(
        rows,
        (header, align) => (header ? tableHeader : tableCell).createAndFill({ align })!
      );
      const changed = table.type.create(
        table.attrs,
        next.rows.map((cells) => tableRow.create(null, cells))
      );
      tr.replaceWith(place.table, place.table + table.nodeSize, changed);
      // The caret's cell: past the table's start, the rows before its row, the row's start and the cells before it.
      let at = place.table + 1;
      for (let row = 0; row < next.row; row += 1) at += changed.child(row).nodeSize;
      at += 1;
      for (let column = 0; column < next.column; column += 1)
        at += changed.child(next.row).child(column).nodeSize;
      tr.setSelection(TextSelection.near(tr.doc.resolve(at + 1)));
      return true;
    })
    .run();
}

/** Selects every cell of the table at `table`, as a drag from its first cell to its last does. */
function selectTable(editor: Editor, table: number) {
  editor
    .chain()
    .focus()
    .command(({ tr }) => {
      const node = tr.doc.nodeAt(table);
      if (node?.type.name !== "table" || !node.lastChild) return false;
      let last = table + 1;
      for (let row = 0; row < node.childCount - 1; row += 1)
        last += node.child(row).nodeSize;
      last += 1;
      for (let column = 0; column < node.lastChild.childCount - 1; column += 1)
        last += node.lastChild.child(column).nodeSize;
      tr.setSelection(CellSelection.create(tr.doc, table + 2, last));
      return true;
    })
    .run();
}

/** `items` with the one at `from` put at `to`. */
function moved<Item>(items: readonly Item[], from: number, to: number) {
  const next = items.filter((_, index) => index !== from);
  next.splice(to, 0, items[from]!);
  return next;
}

/** `cell` with `mark` set to `color` on all its text, or taken off it. */
function painted(cell: PageNode, mark: MarkType, color: DocumentColor | "default") {
  const paint = (node: PageNode): PageNode => {
    if (node.isText)
      return node.mark(
        color === "default"
          ? mark.removeFromSet(node.marks)
          : mark.create({ color }).addToSet(node.marks)
      );
    const inner: PageNode[] = [];
    node.forEach((one) => inner.push(paint(one)));
    return node.copy(Fragment.fromArray(inner));
  };
  return paint(cell);
}

/**
 * Where a row or a column dragged to the pointer would go: the edge between two of them that the pointer is
 * nearest, counted from the table's start. No row goes above the header row.
 */
function edgeAt(table: HTMLTableElement, side: Side, x: number, y: number) {
  if (side === "row") {
    const lines = Array.from(table.rows, (line) => line.getBoundingClientRect());
    const under = lines.findIndex((line) => y < (line.top + line.bottom) / 2);
    return Math.max(1, under < 0 ? lines.length : under);
  }
  const cells = Array.from(table.rows[0]?.cells ?? [], (one) =>
    one.getBoundingClientRect()
  );
  const after = cells.findIndex((one) => x < (one.left + one.right) / 2);
  return after < 0 ? cells.length : after;
}

/**
 * A control that acts as it is pressed and leaves the caret in the page: the controls show while the caret is in
 * their table, so one that took the focus would be gone before its press ended.
 */
function Press({
  children,
  className,
  label,
  onPress,
  side,
  style,
  testId,
  tip,
}: {
  children: ReactNode;
  className: string;
  label: string;
  onPress: () => void;
  side?: Side;
  style: CSSProperties;
  testId: string;
  /** The side of the control its name shows on. */
  tip: "top" | "bottom" | "right";
}) {
  return (
    <Tooltip content={label} placement={tip}>
      <Focusable>
        <button
          aria-label={label}
          className={className}
          data-side={side}
          data-testid={testId}
          onMouseDown={(event) => {
            event.preventDefault();
            onPress();
          }}
          style={style}
          type="button"
        >
          {children}
        </button>
      </Focusable>
    </Tooltip>
  );
}

// A menu row's glyph.
const glyph = "size-xl";
const check = <CheckLargeIcon className="size-xl text-fg-brand-primary" />;
const chevron = <ChevronRightSmallIcon className="size-xl text-fg-quaternary" />;
// How far the pointer goes from a handle's press before the press is a drag.
const dragStart = 4;

/** The handles of the table the caret is in, and their menus. */
export function TableControls({
  editor,
  frame,
}: {
  editor: Editor;
  /** What the handles are placed in: the page's own frame. */
  frame: HTMLElement | null;
}) {
  const messages = useCommaMessages();
  const state = useEditorState({
    editor,
    selector: ({ editor: current }) => {
      const { $from, from } = current.state.selection;
      for (let depth = $from.depth; depth > 1; depth -= 1) {
        const name = $from.node(depth).type.name;
        if (name !== "tableCell" && name !== "tableHeader") continue;
        const table = $from.node(depth - 2);
        return {
          focused: current.isFocused,
          cell: $from.before(depth),
          table: $from.before(depth - 2),
          row: $from.index(depth - 2),
          column: $from.index(depth - 1),
          rows: table.childCount,
          columns: $from.node(depth - 1).childCount,
          align: String($from.node(depth).attrs.align ?? "left"),
          // The handles follow the caret's cell as the table's text grows.
          from,
          size: table.nodeSize,
        };
      }
      return { focused: current.isFocused, cell: undefined };
    },
  });
  // The menu that is open. It has the focus while it is used: the handles stay for it.
  const [open, setOpen] = useState<Side>();
  // A press on a handle, from its start to its release: a press alone opens the handle's menu, a drag moves its
  // row or column to the edge the pointer is nearest (`drop`).
  const [held, setHeld] = useState<Side>();
  const [drop, setDrop] = useState<number>();
  // The row or column a drag just moved: it is marked where it went, and the mark fades.
  const [landed, setLanded] = useState<{ side: Side; count: number }>();
  const press = useRef<{ side: Side; x: number; y: number; drop?: number }>(undefined);
  // The table moves under the page sideways: the handles are placed again.
  const [, replace] = useReducer((count: number) => count + 1, 0);
  const cell =
    frame && state.cell !== undefined && (state.focused || open || held)
      ? editor.view.nodeDOM(state.cell)
      : null;
  const table = cell instanceof HTMLElement ? cell.closest("table") : null;
  const scroller = table?.parentElement ?? null;
  useEffect(() => {
    if (!scroller) return undefined;
    scroller.addEventListener("scroll", replace);
    return () => scroller.removeEventListener("scroll", replace);
  }, [scroller]);
  // What a drag that is let go acts on: the table as the page last drew it.
  const latest = useRef<
    { table: HTMLTableElement; act: (side: Side, to: number) => void } | undefined
  >(undefined);
  if (
    !frame ||
    !(cell instanceof HTMLElement) ||
    !table ||
    !scroller ||
    state.cell === undefined
  )
    return null;

  const origin = frame.getBoundingClientRect();
  const view = scroller.getBoundingClientRect();
  const around = table.getBoundingClientRect();
  const box = cell.getBoundingClientRect();
  const middle = box.left + box.width / 2;
  const place: Place = { table: state.table, row: state.row, column: state.column };
  const { row, column, rows, columns } = state;
  const body = row > 0;
  // The part of the table the page shows.
  const shownLeft = Math.max(around.left, view.left);
  const shownRight = Math.min(around.right, view.right);
  const { textColor, ground } = editor.schema.marks;

  /** The caret's row or column to another place among the rows or columns. */
  const move = (side: Side, to: number) => {
    if (side === "row")
      changeTable(editor, place, (cells) => ({
        rows: moved(cells, row, to),
        row: to,
        column,
      }));
    else
      changeTable(editor, place, (cells) => ({
        rows: cells.map((line) => moved(line, column, to)),
        row,
        column: to,
      }));
  };
  latest.current = {
    table,
    // The row or column goes to an edge: one place less when the edge is after its own place.
    act: (side, edge) => {
      const from = side === "row" ? row : column;
      const to = edge > from ? edge - 1 : edge;
      if (to === from) {
        editor.commands.focus();
        return;
      }
      move(side, to);
      setLanded((last) => ({ side, count: (last?.count ?? 0) + 1 }));
    },
  };
  const paint = (
    side: Side,
    mark: MarkType | undefined,
    color: DocumentColor | "default"
  ) => {
    setOpen(undefined);
    if (!mark) return;
    changeTable(editor, place, (cells) => ({
      rows: cells.map((line, at) =>
        line.map((one, index) =>
          (side === "row" ? at === row : index === column)
            ? painted(one, mark, color)
            : one
        )
      ),
      row,
      column,
    }));
  };
  const columnAction = (key: string) => {
    if (key === "table") editor.chain().focus().deleteTable().run();
    else if (key === "insert-left" || key === "insert-right") {
      const at = column + (key === "insert-right" ? 1 : 0);
      changeTable(editor, place, (cells, make) => ({
        rows: cells.map((line, index) => [
          ...line.slice(0, at),
          make(index === 0, null),
          ...line.slice(at),
        ]),
        row,
        column: at,
      }));
    } else if (key === "copy")
      changeTable(editor, place, (cells) => ({
        rows: cells.map((line) => [
          ...line.slice(0, column + 1),
          line[column]!,
          ...line.slice(column + 1),
        ]),
        row,
        column: column + 1,
      }));
    else if (key === "clear")
      changeTable(editor, place, (cells) => ({
        rows: cells.map((line) =>
          line.map((one, index) =>
            index === column ? one.type.createAndFill(one.attrs)! : one
          )
        ),
        row,
        column,
      }));
    else if (key === "delete")
      changeTable(editor, place, (cells) => ({
        rows: cells.map((line) => line.filter((_, index) => index !== column)),
        row,
        column: Math.min(column, columns - 2),
      }));
    else if (key === "left" || key === "center" || key === "right")
      changeTable(editor, place, (cells) => ({
        rows: cells.map((line) =>
          line.map((one, index) =>
            index === column
              ? one.type.create(
                  // Left is how a column is read where none is set.
                  { ...one.attrs, align: key === "left" ? null : key },
                  one.content
                )
              : one
          )
        ),
        row,
        column,
      }));
  };
  const rowAction = (key: string) => {
    if (key === "table") editor.chain().focus().deleteTable().run();
    else if (key === "above" || key === "below") {
      const at = row + (key === "below" ? 1 : 0);
      changeTable(editor, place, (cells, make) => ({
        rows: [
          ...cells.slice(0, at),
          // A new row's cells are aligned as their columns are.
          cells[0]!.map((head) => make(false, head.attrs.align)),
          ...cells.slice(at),
        ],
        row: at,
        column,
      }));
    } else if (key === "copy")
      changeTable(editor, place, (cells, make) => ({
        rows: [
          ...cells.slice(0, row + 1),
          // A copy of the header row is a row of the table's body.
          cells[row]!.map((one) => make(false, one.attrs.align).copy(one.content)),
          ...cells.slice(row + 1),
        ],
        row: row + 1,
        column,
      }));
    else if (key === "clear")
      changeTable(editor, place, (cells) => ({
        rows: cells.map((line, at) =>
          at === row ? line.map((one) => one.type.createAndFill(one.attrs)!) : line
        ),
        row,
        column,
      }));
    else if (key === "delete")
      changeTable(editor, place, (cells) => ({
        rows: cells.filter((_, index) => index !== row),
        row: Math.min(row, rows - 2),
        column,
      }));
  };

  /** A handle's press: it becomes a drag once the pointer leaves the handle's place. */
  const onPress = (side: Side) => (event: PointerEvent) => {
    if (event.button !== 0) return;
    const page = event.currentTarget.ownerDocument;
    press.current = { side, x: event.clientX, y: event.clientY };
    setHeld(side);
    // The header row is not moved.
    const drags = side === "column" || body;
    const onMove = (moving: globalThis.PointerEvent) => {
      const pressed = press.current;
      const shown = latest.current;
      if (!pressed || !shown || !drags) return;
      if (
        pressed.drop === undefined &&
        Math.hypot(moving.clientX - pressed.x, moving.clientY - pressed.y) < dragStart
      )
        return;
      pressed.drop = edgeAt(shown.table, side, moving.clientX, moving.clientY);
      setDrop(pressed.drop);
    };
    const onEnd = (ending: globalThis.PointerEvent) => {
      page.removeEventListener("pointermove", onMove);
      page.removeEventListener("pointerup", onEnd);
      page.removeEventListener("pointercancel", onEnd);
      const pressed = press.current;
      press.current = undefined;
      setHeld(undefined);
      setDrop(undefined);
      if (!pressed || ending.type === "pointercancel") return;
      // A press that did not travel opens the menu, as it is let go.
      if (pressed.drop === undefined) setOpen(side);
      else latest.current?.act(side, pressed.drop);
    };
    page.addEventListener("pointermove", onMove);
    page.addEventListener("pointerup", onEnd);
    page.addEventListener("pointercancel", onEnd);
  };
  /** The menu's own request: the keyboard opens it at once, the pointer when its press is let go. */
  const onOpenChange = (side: Side) => (next: boolean) => {
    if (!next) setOpen(undefined);
    else if (!press.current) setOpen(side);
  };

  // Where a row or a column is on the page, in the part of the table the page shows.
  const span = (side: Side, index: number) => {
    if (side === "row") {
      const one = table.rows[index]?.getBoundingClientRect();
      return one
        ? {
            left: shownLeft - origin.left,
            top: one.top - origin.top,
            width: shownRight - shownLeft,
            height: one.height,
          }
        : undefined;
    }
    const one = table.rows[0]?.cells[index]?.getBoundingClientRect();
    return one
      ? {
          left: one.left - origin.left,
          top: around.top - origin.top,
          width: one.width,
          height: around.height,
        }
      : undefined;
  };
  const dragged = held && drop !== undefined ? held : undefined;
  // The edge a dragged row or column would go to, as a line on the table. It is moved by its transform alone.
  const line = (() => {
    if (!dragged || drop === undefined) return undefined;
    if (dragged === "row") {
      const lines = Array.from(table.rows, (one) => one.getBoundingClientRect());
      const top = drop < lines.length ? lines[drop]!.top : lines.at(-1)!.bottom;
      return {
        width: shownRight - shownLeft,
        transform: `translate3d(${shownLeft - origin.left}px, ${top - origin.top}px, 0)`,
      };
    }
    const cells = Array.from(table.rows[0]?.cells ?? [], (one) =>
      one.getBoundingClientRect()
    );
    const left = drop < cells.length ? cells[drop]!.left : cells.at(-1)!.right;
    return {
      height: around.height,
      transform: `translate3d(${left - origin.left}px, ${around.top - origin.top}px, 0)`,
    };
  })();
  const lifted = dragged ? span(dragged, dragged === "row" ? row : column) : undefined;
  const settled = landed
    ? span(landed.side, landed.side === "row" ? row : column)
    : undefined;

  const columnLabel = messages.file_preview_document_table_column();
  const rowLabel = messages.file_preview_document_table_row();
  const menuClass = cx("w-52 overflow-hidden", menuSurfaceClasses);
  const align = (key: string, name: string, icon: ReactNode) => (
    <MenuItem icon={icon} id={key} shortcut={state.align === key ? check : undefined}>
      {name}
    </MenuItem>
  );
  /** The colours of a row's or a column's text, as a menu beside the menu. */
  const colors = (side: Side) => (
    <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
      <MenuItem
        icon={<ColorRollIcon aria-hidden className={glyph} />}
        id="color"
        shortcut={chevron}
      >
        {messages.file_preview_document_format_color()}
      </MenuItem>
      <MenuPopover
        className={cx("w-56 overflow-hidden", menuSurfaceClasses)}
        offset={0}
        placement="right top"
      >
        <ScrollArea className="max-h-[inherit]" viewportClassName="max-h-[inherit]">
          <ColorMenu
            label={messages.file_preview_document_format_color()}
            onChoose={(kind, color) =>
              paint(side, kind === "ground" ? ground : textColor, color)
            }
          />
        </ScrollArea>
      </MenuPopover>
    </SubmenuTrigger>
  );
  const handle = (side: Side, label: string, left: number, top: number) => (
    <span
      className="comma-document-table-handle"
      data-dragging={dragged === side ? "true" : undefined}
      data-side={side}
      onPointerDownCapture={onPress(side)}
      style={{ left: left - origin.left, top: top - origin.top }}
    >
      <Tooltip
        content={label}
        isDisabled={held !== undefined}
        placement={side === "row" ? "left" : "top"}
        {...(side === "column" || body
          ? { supportingText: messages.file_preview_document_table_drag() }
          : {})}
      >
        <AriaButton aria-label={label} data-testid={`document-table-${side}`}>
          <MoreHorizontalIcon aria-hidden className="size-lg" />
        </AriaButton>
      </Tooltip>
    </span>
  );

  return (
    <>
      {/* The six dots by the table's first row select the whole table. */}
      <Press
        className="comma-document-table-corner"
        label={messages.file_preview_document_table_select()}
        onPress={() => selectTable(editor, state.table)}
        style={{
          left: shownLeft - origin.left,
          top: (table.rows[0]?.getBoundingClientRect().top ?? around.top) - origin.top,
          height: table.rows[0]?.getBoundingClientRect().height ?? 0,
        }}
        testId="document-table-select"
        tip="top"
      >
        <DragHandleIcon aria-hidden className="size-lg" />
      </Press>
      {/* The column's handle shows while its column is in the table's own window. */}
      {middle >= view.left && middle <= view.right ? (
        <MenuTrigger isOpen={open === "column"} onOpenChange={onOpenChange("column")}>
          {handle("column", columnLabel, middle, around.top)}
          <MenuPopover className={menuClass} placement="bottom">
            <Menu
              aria-label={columnLabel}
              className="py-sm"
              disabledKeys={columns === 1 ? ["delete"] : []}
              onAction={(key) => columnAction(String(key))}
              variant="embedded"
            >
              {colors("column")}
              <MenuSeparator />
              <MenuItem
                icon={<ArrowLeftIcon aria-hidden className={glyph} />}
                id="insert-left"
              >
                {messages.file_preview_document_table_insert_left()}
              </MenuItem>
              <MenuItem
                icon={<ArrowRightIcon aria-hidden className={glyph} />}
                id="insert-right"
              >
                {messages.file_preview_document_table_insert_right()}
              </MenuItem>
              <MenuItem icon={<CopyIcon aria-hidden className={glyph} />} id="copy">
                {messages.file_preview_document_table_duplicate()}
              </MenuItem>
              <MenuItem icon={<CircleXIcon aria-hidden className={glyph} />} id="clear">
                {messages.file_preview_document_table_clear()}
              </MenuItem>
              <MenuSeparator />
              {align(
                "left",
                messages.file_preview_document_table_align_left(),
                <AlignLeftIcon aria-hidden className={glyph} />
              )}
              {align(
                "center",
                messages.file_preview_document_table_align_center(),
                <AlignCenterIcon aria-hidden className={glyph} />
              )}
              {align(
                "right",
                messages.file_preview_document_table_align_right(),
                <AlignRightIcon aria-hidden className={glyph} />
              )}
              <MenuSeparator />
              <MenuItem
                icon={<TrashCanIcon aria-hidden className={glyph} />}
                id="delete"
                tone="destructive"
              >
                {messages.file_preview_document_table_delete_column()}
              </MenuItem>
              <MenuItem
                icon={<TrashCanIcon aria-hidden className={glyph} />}
                id="table"
                tone="destructive"
              >
                {messages.file_preview_document_table_delete_table()}
              </MenuItem>
            </Menu>
          </MenuPopover>
        </MenuTrigger>
      ) : null}
      <MenuTrigger isOpen={open === "row"} onOpenChange={onOpenChange("row")}>
        {handle("row", rowLabel, shownLeft, box.top + box.height / 2)}
        <MenuPopover className={menuClass} placement="bottom start">
          <Menu
            aria-label={rowLabel}
            className="py-sm"
            // The header row is the table's first row, whatever is done to the rows.
            disabledKeys={body ? [] : ["above", "delete"]}
            onAction={(key) => rowAction(String(key))}
            variant="embedded"
          >
            {colors("row")}
            <MenuSeparator />
            <MenuItem icon={<ArrowUpIcon aria-hidden className={glyph} />} id="above">
              {messages.file_preview_document_table_insert_above()}
            </MenuItem>
            <MenuItem icon={<ArrowDownIcon aria-hidden className={glyph} />} id="below">
              {messages.file_preview_document_table_insert_below()}
            </MenuItem>
            <MenuItem icon={<CopyIcon aria-hidden className={glyph} />} id="copy">
              {messages.file_preview_document_table_duplicate()}
            </MenuItem>
            <MenuItem icon={<CircleXIcon aria-hidden className={glyph} />} id="clear">
              {messages.file_preview_document_table_clear()}
            </MenuItem>
            <MenuSeparator />
            <MenuItem
              icon={<TrashCanIcon aria-hidden className={glyph} />}
              id="delete"
              tone="destructive"
            >
              {messages.file_preview_document_table_delete_row()}
            </MenuItem>
            <MenuItem
              icon={<TrashCanIcon aria-hidden className={glyph} />}
              id="table"
              tone="destructive"
            >
              {messages.file_preview_document_table_delete_table()}
            </MenuItem>
          </Menu>
        </MenuPopover>
      </MenuTrigger>
      {lifted ? (
        <span aria-hidden="true" className="comma-document-table-lift" style={lifted} />
      ) : null}
      {line ? (
        <span aria-hidden="true" className="comma-document-table-drop" style={line} />
      ) : null}
      {landed && settled && !dragged ? (
        <span
          aria-hidden="true"
          className="comma-document-table-lift"
          data-landed="true"
          key={landed.count}
          style={settled}
        />
      ) : null}
      {/* A row more under the table, and a column more at its end. */}
      <Press
        className="comma-document-table-add"
        label={messages.file_preview_document_table_add_row()}
        onPress={() =>
          changeTable(editor, place, (cells, make) => ({
            rows: [...cells, cells[0]!.map((head) => make(false, head.attrs.align))],
            row: cells.length,
            column,
          }))
        }
        style={{
          left: shownLeft - origin.left,
          top: around.bottom - origin.top,
          width: shownRight - shownLeft,
        }}
        testId="document-table-add-row"
        tip="bottom"
      >
        <PlusSmallIcon aria-hidden className="size-lg" />
      </Press>
      {/* The bar at the table's end shows while the end is in the table's own window. */}
      {around.right <= view.right + 1 ? (
        <Press
          className="comma-document-table-add"
          label={messages.file_preview_document_table_add_column()}
          onPress={() =>
            changeTable(editor, place, (cells, make) => ({
              rows: cells.map((cellsOfRow, index) => [
                ...cellsOfRow,
                make(index === 0, null),
              ]),
              row,
              column: columns,
            }))
          }
          side="column"
          style={{
            left: around.right - origin.left,
            top: around.top - origin.top,
            height: around.height,
          }}
          testId="document-table-add-column"
          tip="right"
        >
          <PlusSmallIcon aria-hidden className="size-lg" />
        </Press>
      ) : null}
    </>
  );
}
