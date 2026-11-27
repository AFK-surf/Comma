import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import {
  CheckIcon,
  ChevronDownSmallIcon,
  ChevronsCollapseVerticalIcon,
  ChevronsExpandVerticalIcon,
  CodeIcon,
  CopyIcon,
  EyeIcon,
  TableIcon,
} from "@comma/ui/components/icons";
import { SkillFileSource } from "@comma/ui/components/plugins";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { toast } from "@comma/ui/components/toast";
import { cx } from "@comma/ui/components/utils";
import { uiClock, type CancelUiTimer } from "@comma/ui/clock";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { nativePlatformClipboard } from "../../nativePlatformActions";
import { useCommaUiThemeName } from "../commaUiTheme";
import {
  PreviewMessage,
  PreviewNotice,
  PreviewToolbarAction,
  PreviewToolbarPortal,
  PreviewViewToggle,
  usePreviewLinkHandlers,
} from "./FilePreviewChrome";
import { FilePreviewLoading } from "./FilePreviewLoading";
import type { RangedFile } from "./PdfFilePreview";
import { PreviewDataTable, PreviewDataTableNotice } from "./PreviewDataTable";
import { decodeCsvBytes, isCellUrl } from "./csv";
import {
  flattenJsonTree,
  formatJsonValue,
  isJsonContainer,
  isJsonNumber,
  jsonPreviewMaxBytes,
  jsonSourceMaxBytes,
  jsonTreeMaxRows,
  parseJsonLines,
  parseJsonPreservingNumbers,
  type JsonTreeLabel,
  type JsonTreeRow,
  type JsonValue,
  type ParsedJsonLines,
} from "./jsonPreview";
import { readPrefix } from "./readPrefix";

type ViewMode = "structured" | "source";
/** How long a row's copy button shows its check after a copy. */
const copiedFeedbackMs = 1500;
type Messages = ReturnType<typeof useCommaMessages>;

/** What "Copy value" puts on the clipboard: a string as its text, anything else as precision-preserving JSON. */
function copyText(value: JsonValue): string {
  if (typeof value === "string") return value;
  if (isJsonNumber(value)) return value.raw;
  return isJsonContainer(value) ? formatJsonValue(value, 2) : String(value);
}

function JsonPrimitive({ value }: { value: JsonValue }) {
  if (value === null) return <span className="comma-json-null">null</span>;
  if (typeof value === "boolean") {
    return <span className="comma-json-boolean">{String(value)}</span>;
  }
  if (typeof value === "number" || isJsonNumber(value)) {
    return (
      <span className="comma-json-number">
        {isJsonNumber(value) ? value.raw : String(value)}
      </span>
    );
  }
  if (typeof value === "object") {
    return (
      <span className="comma-json-punct">{Array.isArray(value) ? "[]" : "{}"}</span>
    );
  }
  const trimmed = value.trim();
  if (isCellUrl(trimmed)) {
    return (
      <span className="comma-json-string">
        &quot;<a href={trimmed}>{value}</a>&quot;
      </span>
    );
  }
  return <span className="comma-json-string">{JSON.stringify(value)}</span>;
}

function JsonKey({ label }: { label: JsonTreeLabel | undefined }) {
  if (!label) return null;
  return (
    <span className={label.index ? "comma-json-index" : "comma-json-key"}>
      {label.index ? label.text : JSON.stringify(label.text).slice(1, -1)}
      <span className="comma-json-punct">:</span>
    </span>
  );
}

/** One vertical guide per ancestor, each under its ancestor's chevron. */
function JsonGuides({ depth }: { depth: number }) {
  if (depth === 0) return null;
  return (
    <>
      {Array.from({ length: depth }, (_, level) => (
        // Guides are positional: one per level.
        // eslint-disable-next-line react/no-array-index-key
        <span aria-hidden className="comma-json-guide" key={level} />
      ))}
    </>
  );
}

function JsonCopyButton({
  value,
  label,
  copied,
  onCopy,
  messages,
}: {
  value: JsonValue;
  /** The row's key or index; the label names it so each row's button is told apart. */
  label: JsonTreeLabel | undefined;
  copied: boolean;
  onCopy: (value: JsonValue) => void;
  messages: Messages;
}) {
  return (
    <Button
      aria-label={
        copied
          ? messages.file_preview_json_copied()
          : label
            ? messages.file_preview_json_copy_value_of({
                key: label.index ? `[${label.text}]` : label.text,
              })
            : messages.file_preview_json_copy_value()
      }
      className={cx("comma-json-copy", copied && "comma-json-copy-done")}
      hierarchy="tertiary-gray"
      iconLeading={
        copied ? (
          <CheckIcon className="comma-input-icon" />
        ) : (
          <CopyIcon className="comma-input-icon" />
        )
      }
      iconOnly
      onPress={() => onCopy(value)}
      size="xs"
    />
  );
}

function JsonTreeRowView({
  row,
  copied,
  onToggle,
  onCopy,
  messages,
}: {
  row: JsonTreeRow;
  copied: boolean;
  onToggle: (path: string, currentExpanded: boolean) => void;
  onCopy: (path: string, value: JsonValue) => void;
  messages: Messages;
}) {
  if (row.kind === "close") {
    return (
      <div className="comma-json-row">
        <JsonGuides depth={row.depth} />
        <span aria-hidden className="comma-json-chevron" />
        <span className="comma-json-punct">{row.array ? "]" : "}"}</span>
      </div>
    );
  }
  const copy = (
    <JsonCopyButton
      copied={copied}
      label={row.label}
      messages={messages}
      onCopy={(value) => onCopy(row.path, value)}
      value={row.value}
    />
  );
  if (row.kind === "value") {
    return (
      <div className="comma-json-row">
        <JsonGuides depth={row.depth} />
        <span aria-hidden className="comma-json-chevron" />
        <span className="comma-json-line">
          <JsonKey label={row.label} />
          <JsonPrimitive value={row.value} />
        </span>
        {copy}
      </div>
    );
  }
  const array = Array.isArray(row.value);
  return (
    <div className="comma-json-row">
      <JsonGuides depth={row.depth} />
      <button
        aria-expanded={row.expanded}
        className="comma-json-line comma-json-branch"
        onClick={() => onToggle(row.path, row.expanded)}
        type="button"
      >
        <span aria-hidden className="comma-json-chevron">
          <ChevronDownSmallIcon className={cx(!row.expanded && "-rotate-90")} />
        </span>
        <JsonKey label={row.label} />
        <span className="comma-json-punct">
          {array ? "[" : "{"}
          {row.expanded ? null : <>…{array ? "]" : "}"}</>}
        </span>
        <span className="comma-json-meta">
          {array
            ? messages.file_preview_json_items({ count: row.count })
            : messages.file_preview_json_keys({ count: row.count })}
        </span>
      </button>
      {copy}
    </div>
  );
}

function JsonTree({
  root,
  defaultExpandDepth,
  overrides,
  onToggle,
  onOpenBrowser,
  children,
}: {
  root: JsonValue;
  defaultExpandDepth: number;
  overrides: ReadonlyMap<string, boolean>;
  onToggle: (path: string, currentExpanded: boolean) => void;
  onOpenBrowser: (url: string) => void;
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  const linkHandlers = usePreviewLinkHandlers(onOpenBrowser);
  const { rows, capped } = useMemo(
    () =>
      flattenJsonTree(
        root,
        (path, depth) => overrides.get(path) ?? depth < defaultExpandDepth,
        jsonTreeMaxRows
      ),
    [root, overrides, defaultExpandDepth]
  );
  const [copiedPath, setCopiedPath] = useState<string | null>(null);
  const copiedTimer = useRef<CancelUiTimer | null>(null);
  useEffect(() => () => copiedTimer.current?.(), []);
  const copy = (path: string, value: JsonValue) => {
    void nativePlatformClipboard.writeText(copyText(value)).then(
      () => {
        setCopiedPath(path);
        copiedTimer.current?.();
        copiedTimer.current = uiClock.after(copiedFeedbackMs, () => {
          setCopiedPath(null);
        });
      },
      () => toast.error(messages.copy_failed_title())
    );
  };

  return (
    <>
      {capped ? (
        <PreviewNotice testId="file-preview-json-tree-capped">
          {messages.file_preview_json_tree_capped({ count: jsonTreeMaxRows })}
        </PreviewNotice>
      ) : null}
      <ScrollArea
        className="min-h-0 flex-1"
        viewportClassName="h-full"
        contentClassName="flex min-h-full w-max min-w-full flex-col"
        edgeEffect="none"
        orientation="both"
      >
        <div className="flex min-h-full flex-1 flex-col">
          <div
            className="comma-json-tree min-w-0 flex-1"
            data-testid="file-preview-json-tree"
            {...linkHandlers}
          >
            {rows.map((row) => (
              <JsonTreeRowView
                copied={copiedPath === row.path && row.kind !== "close"}
                key={`${row.kind === "close" ? "/" : ""}${row.path}`}
                messages={messages}
                onCopy={copy}
                onToggle={onToggle}
                row={row}
              />
            ))}
          </div>
          {children}
        </div>
      </ScrollArea>
    </>
  );
}

type LoadedJson =
  | {
      kind: "json";
      value: JsonValue;
      sourceText: string;
      sourceTruncated: boolean;
    }
  | {
      kind: "jsonl";
      parsed: ParsedJsonLines;
      /** The records as one array, for the tree when they are not a table. */
      root: JsonValue[];
      sourceText: string;
      sourceTruncated: boolean;
    }
  | { kind: "raw"; sourceText: string; sourceTruncated: boolean };

/**
 * Structured preview for `.json` (interactive collapsible tree) and `.jsonl`/`.ndjson` (tabular records), with a
 * toolbar toggle to switch to syntax-highlighted source.
 */
export function JsonFilePreview({
  fileName,
  lines = false,
  blob,
  ranged,
  toolbarSlot,
  onOpenBrowser,
  children,
}: {
  fileName: string;
  /** True for `.jsonl` / `.ndjson` line-delimited JSON files. */
  lines?: boolean;
  blob?: Blob | undefined;
  ranged?: RangedFile | undefined;
  /** Where the structured/source toggle goes: the file preview toolbar. */
  toolbarSlot?: HTMLElement | null | undefined;
  onOpenBrowser: (url: string) => void;
  /** Content after the preview, in the same scroll. */
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  const isDark = useCommaUiThemeName() === "Dark mode";
  const [state, setState] = useState<
    { status: "loading" } | { status: "failed" } | { status: "ready"; data: LoadedJson }
  >({ status: "loading" });
  const [view, setView] = useState<ViewMode>("structured");
  const [defaultExpandDepth, setDefaultExpandDepth] = useState(2);
  const [overrides, setOverrides] = useState<Map<string, boolean>>(() => new Map());

  useEffect(() => {
    if (!blob && !ranged) return undefined;
    const controller = new AbortController();
    const { signal } = controller;
    setState({ status: "loading" });
    setView("structured");
    setDefaultExpandDepth(2);
    setOverrides(new Map());
    void (async () => {
      try {
        if (lines) {
          const { bytes, truncated } = await readPrefix(
            { blob, ranged },
            signal,
            jsonPreviewMaxBytes
          );
          if (signal.aborted) return;
          const text = decodeCsvBytes(bytes, truncated);
          const sourceTruncated = truncated || bytes.length > jsonSourceMaxBytes;
          const sourceText =
            bytes.length > jsonSourceMaxBytes
              ? decodeCsvBytes(bytes.subarray(0, jsonSourceMaxBytes), true)
              : text;
          const parsed = parseJsonLines(text, { byteTruncated: truncated });
          if (parsed.invalid) {
            setState({
              status: "ready",
              data: { kind: "raw", sourceText, sourceTruncated },
            });
            return;
          }
          setState({
            status: "ready",
            data: {
              kind: "jsonl",
              parsed,
              root: parsed.records.map((entry) => entry.value),
              sourceText,
              sourceTruncated,
            },
          });
          return;
        }

        // For `.json`, avoid pulling 2 MB when the file already exceeds the structured-parse cap:
        // a truncated JSON document always falls back to the 256 KB source preview.
        let bytes: Uint8Array;
        let truncated = false;
        if (ranged) {
          const first = await ranged.read(0, jsonSourceMaxBytes, signal);
          if (signal.aborted) return;
          const tooBigForTree = first.size > jsonPreviewMaxBytes;
          const target = tooBigForTree
            ? Math.min(first.size, jsonSourceMaxBytes)
            : first.size;
          const out = new Uint8Array(target);
          const initial = Math.min(first.bytes.length, target);
          out.set(first.bytes.subarray(0, initial));
          let offset = initial;
          while (offset < target) {
            const part = await ranged.read(offset, target - offset, signal);
            if (signal.aborted) return;
            if (part.bytes.length === 0) break;
            const take = Math.min(part.bytes.length, target - offset);
            out.set(part.bytes.subarray(0, take), offset);
            offset += take;
          }
          bytes = offset < target ? out.subarray(0, offset) : out;
          truncated = tooBigForTree || first.size > offset;
        } else if (blob) {
          if (blob.size > jsonPreviewMaxBytes) {
            bytes = new Uint8Array(
              await blob.slice(0, jsonSourceMaxBytes).arrayBuffer()
            );
            truncated = true;
          } else {
            bytes = new Uint8Array(await blob.arrayBuffer());
          }
          if (signal.aborted) return;
        } else {
          return;
        }

        const text = decodeCsvBytes(bytes, truncated);
        const sourceTruncated = truncated || bytes.length > jsonSourceMaxBytes;
        const sourceText =
          bytes.length > jsonSourceMaxBytes
            ? decodeCsvBytes(bytes.subarray(0, jsonSourceMaxBytes), true)
            : text;
        if (truncated) {
          setState({
            status: "ready",
            data: { kind: "raw", sourceText, sourceTruncated: true },
          });
          return;
        }
        try {
          const value = parseJsonPreservingNumbers(text);
          setState({
            status: "ready",
            data: { kind: "json", value, sourceText, sourceTruncated },
          });
        } catch {
          setState({
            status: "ready",
            data: { kind: "raw", sourceText, sourceTruncated },
          });
        }
      } catch {
        if (!signal.aborted) setState({ status: "failed" });
      }
    })();
    return () => controller.abort();
  }, [blob, lines, ranged]);

  const togglePath = (path: string, currentExpanded: boolean) => {
    setOverrides((current) => {
      const next = new Map(current);
      next.set(path, !currentExpanded);
      return next;
    });
  };

  if (state.status === "loading") return <FilePreviewLoading />;

  if (state.status === "failed") {
    return <PreviewMessage alert>{messages.file_preview_failed()}</PreviewMessage>;
  }

  const { data } = state;
  const canShowStructured =
    data.kind === "json" ||
    (data.kind === "jsonl" &&
      (data.parsed.table !== undefined || data.parsed.records.length > 0));
  const activeView: ViewMode = canShowStructured ? view : "source";
  // JSONL records that are not a table show as a tree, so the toggle names the tree.
  const structuredIsTable = data.kind === "jsonl" && data.parsed.table !== undefined;

  const rootValue =
    data.kind === "json" ? data.value : data.kind === "jsonl" ? data.root : null;
  // The tree's Expand all / Collapse all sit in the toolbar beside the view toggle while the tree shows.
  const treeShown =
    activeView === "structured" && !structuredIsTable && isJsonContainer(rootValue);
  const setAllExpanded = (expanded: boolean) => {
    // Collapsing all keeps the root open: its first level is the overview.
    setDefaultExpandDepth(expanded ? Number.POSITIVE_INFINITY : 1);
    setOverrides(new Map());
  };

  const toolbarToggle = canShowStructured ? (
    <PreviewToolbarPortal slot={toolbarSlot}>
      {treeShown ? (
        <>
          <PreviewToolbarAction
            icon={<ChevronsExpandVerticalIcon className="comma-input-icon" />}
            label={messages.file_preview_expand_all()}
            onPress={() => setAllExpanded(true)}
            testId="file-preview-json-expand-all"
          />
          <PreviewToolbarAction
            icon={<ChevronsCollapseVerticalIcon className="comma-input-icon" />}
            label={messages.file_preview_collapse_all()}
            onPress={() => setAllExpanded(false)}
            testId="file-preview-json-collapse-all"
          />
        </>
      ) : null}
      <PreviewViewToggle<ViewMode>
        label={messages.file_preview_view_mode()}
        onChange={setView}
        options={[
          {
            value: "structured",
            label: structuredIsTable
              ? messages.file_preview_view_table()
              : messages.file_preview_view_tree(),
            icon: structuredIsTable ? (
              <TableIcon className="comma-input-icon" />
            ) : (
              <EyeIcon className="comma-input-icon" />
            ),
          },
          {
            value: "source",
            label: messages.file_preview_view_source(),
            icon: <CodeIcon className="comma-input-icon" />,
          },
        ]}
        testId="file-preview-view-toggle"
        value={activeView}
      />
    </PreviewToolbarPortal>
  ) : null;

  if (activeView === "source") {
    return (
      <div className="flex min-h-0 min-w-0 flex-1 flex-col">
        {toolbarToggle}
        {data.sourceTruncated ? (
          <PreviewNotice testId="file-preview-json-source-truncated">
            {messages.file_preview_text_truncated()}
          </PreviewNotice>
        ) : null}
        <ScrollArea
          className="min-h-0 flex-1"
          viewportClassName="h-full"
          contentClassName="flex min-h-full flex-col"
          edgeEffect="none"
        >
          <div className="flex min-h-full flex-1 flex-col">
            <div className="w-full flex-1 p-xl" data-testid="file-preview-json-source">
              <SkillFileSource isDark={isDark} path={fileName} text={data.sourceText} />
            </div>
            {children}
          </div>
        </ScrollArea>
      </div>
    );
  }

  if (data.kind === "jsonl" && data.parsed.table) {
    const table = data.parsed.table;
    return (
      <div className="flex min-h-0 min-w-0 flex-1 flex-col">
        {toolbarToggle}
        <PreviewDataTableNotice table={table} testId="file-preview-jsonl-truncated" />
        <PreviewDataTable
          onOpenBrowser={onOpenBrowser}
          table={table}
          testId="file-preview-jsonl-table"
        >
          {children}
        </PreviewDataTable>
      </div>
    );
  }

  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col">
      {toolbarToggle}
      <JsonTree
        defaultExpandDepth={defaultExpandDepth}
        onOpenBrowser={onOpenBrowser}
        onToggle={togglePath}
        overrides={overrides}
        root={rootValue}
      >
        {children}
      </JsonTree>
    </div>
  );
}
