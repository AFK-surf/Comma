import { useCommaMessages } from "@comma/i18n/react";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import { SkillFileSource } from "@comma/ui/components/plugins";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { cx } from "@comma/ui/components/utils";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useCommaUiThemeName } from "../commaUiTheme";
import {
  PreviewMessage,
  PreviewNotice,
  usePreviewLinkHandlers,
} from "./FilePreviewChrome";
import { FilePreviewLoading } from "./FilePreviewLoading";
import type { RangedFile } from "./PdfFilePreview";
import {
  notebookPreviewMaxBytes,
  notebookPreviewMaxCells,
  parseNotebook,
  type NotebookCell,
  type NotebookOutput,
  type ParsedNotebook,
} from "./notebook";
import { wholeFileOf } from "./wholeFile";

// Text an output prints: stdout reads quietly under its cell; stderr keeps the same type with a red rule beside it.
const outputTextClassName =
  "m-0 font-mono text-xs whitespace-pre-wrap break-words [overflow-wrap:anywhere]";

function NotebookOutputView({
  output,
  onOpenBrowser,
}: {
  output: NotebookOutput;
  onOpenBrowser: (url: string) => void;
}) {
  const policy = useMemo(() => ({ onOpenLink: onOpenBrowser }), [onOpenBrowser]);
  if (output.kind === "stream") {
    return output.name === "stderr" ? (
      <pre
        className={cx(
          outputTextClassName,
          "border-l-2 border-error pl-md text-secondary"
        )}
        data-output-kind="stderr"
      >
        {output.text}
      </pre>
    ) : (
      <pre
        className={cx(outputTextClassName, "text-tertiary")}
        data-output-kind="stdout"
      >
        {output.text}
      </pre>
    );
  }
  if (output.kind === "image") {
    // Plots are drawn for a white page (dark labels on a clear background), so they keep one in dark mode too, framed
    // so the white reads as the figure's own paper and not as a hole in the panel.
    return (
      <div className="w-fit max-w-full overflow-hidden rounded-md border-[0.5px] border-primary bg-base-white p-sm">
        <img
          alt=""
          className="block max-h-(--container-sm) max-w-full object-contain"
          src={output.dataUrl}
        />
      </div>
    );
  }
  if (output.kind === "html") {
    return (
      <div
        className="comma-notebook-html min-w-0 overflow-x-auto"
        // Sanitized via DOMPurify in `sanitizeNotebookHtml` with scripts, styles, forms and active embeds forbidden.
        dangerouslySetInnerHTML={{ __html: output.html }}
      />
    );
  }
  if (output.kind === "markdown") {
    return (
      <div className="min-w-0">
        <MarkdownStream
          animation="none"
          content={output.markdown}
          documentResourcePolicy={policy}
          final
          htmlPolicy="escape"
        />
      </div>
    );
  }
  if (output.kind === "error") {
    return (
      <div
        className="flex min-w-0 flex-col gap-xs border-l-2 border-error-solid pl-md font-mono text-xs"
        data-output-kind="error"
      >
        <div className="font-semibold break-words text-error-primary [overflow-wrap:anywhere]">
          {output.ename}
          {output.evalue ? `: ${output.evalue}` : ""}
        </div>
        {output.traceback ? (
          <pre className={cx(outputTextClassName, "text-secondary")}>
            {output.traceback}
          </pre>
        ) : null}
      </div>
    );
  }
  return <pre className={cx(outputTextClassName, "text-secondary")}>{output.text}</pre>;
}

// Every cell is a two-column row: the execution count in a narrow gutter, the cell in the rest. Markdown cells leave
// the gutter empty, so prose and code share one left edge down the notebook.
const cellRowClassName =
  "grid min-w-0 grid-cols-[var(--spacing-4xl)_minmax(0,1fr)] gap-x-md";

function NotebookCellView({
  cell,
  languageExtension,
  isDark,
  onOpenBrowser,
}: {
  cell: NotebookCell;
  languageExtension: string;
  isDark: boolean;
  onOpenBrowser: (url: string) => void;
}) {
  const policy = useMemo(() => ({ onOpenLink: onOpenBrowser }), [onOpenBrowser]);
  if (cell.kind === "markdown") {
    return (
      <div className={cellRowClassName} data-cell-kind="markdown">
        <div className="col-start-2 min-w-0">
          <MarkdownStream
            animation="none"
            content={cell.source}
            documentResourcePolicy={policy}
            final
            htmlPolicy="escape"
          />
        </div>
      </div>
    );
  }
  if (cell.kind === "raw") {
    return (
      <div className={cellRowClassName} data-cell-kind="raw">
        <pre
          className={cx(
            outputTextClassName,
            "col-start-2 rounded-md border-[0.5px] border-dashed border-primary px-md py-sm text-tertiary"
          )}
        >
          {cell.source}
        </pre>
      </div>
    );
  }
  const executed = cell.executionCount !== null;
  return (
    <div className={cellRowClassName} data-cell-kind="code">
      {/* Lined up with the cell's first source line. "In" is read, not drawn: the gutter only needs the count. */}
      <div className="flex justify-end pt-sm">
        <span
          className={cx(
            "flex h-(--text-sm--line-height) items-center font-mono text-xs tabular-nums",
            executed ? "text-tertiary" : "text-quaternary"
          )}
        >
          <span className="sr-only">In </span>[
          {executed ? cell.executionCount : "\u00a0"}]
        </span>
      </div>
      <div className="flex min-w-0 flex-col gap-sm">
        <div className="min-w-0 rounded-md border-[0.5px] border-secondary bg-secondary px-md py-sm">
          <SkillFileSource
            isDark={isDark}
            path={`cell.${languageExtension}`}
            text={cell.source}
          />
        </div>
        {cell.outputs.length > 0 ? (
          <div
            className="flex min-w-0 flex-col gap-sm px-md"
            data-testid="notebook-cell-outputs"
          >
            {cell.outputs.map((output, index) => (
              // Outputs within a cell have no stable identifier beyond their order.
              // eslint-disable-next-line react/no-array-index-key
              <NotebookOutputView
                key={index}
                onOpenBrowser={onOpenBrowser}
                output={output}
              />
            ))}
          </div>
        ) : null}
      </div>
    </div>
  );
}

/**
 * A Jupyter Notebook (.ipynb): Markdown cells, syntax-highlighted code cells with execution counts, and rendered
 * text, image, HTML table, and error outputs.
 */
export function NotebookFilePreview({
  blob,
  ranged,
  onOpenBrowser,
  children,
}: {
  blob?: Blob | undefined;
  ranged?: RangedFile | undefined;
  onOpenBrowser: (url: string) => void;
  /** Content after the notebook, in the same scroll. */
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  const isDark = useCommaUiThemeName() === "Dark mode";
  const [state, setState] = useState<
    | { status: "loading" }
    | { status: "too_large" }
    | { status: "failed" }
    | { status: "ready"; parsed: ParsedNotebook }
  >({ status: "loading" });

  useEffect(() => {
    if (!blob && !ranged) return undefined;
    const controller = new AbortController();
    const { signal } = controller;
    setState({ status: "loading" });
    void (async () => {
      try {
        const read = await wholeFileOf(
          { blob, ranged },
          signal,
          notebookPreviewMaxBytes
        );
        if (signal.aborted) return;
        if ("error" in read) {
          setState({ status: read.error });
          return;
        }
        const text = new TextDecoder("utf-8").decode(read.bytes);
        const parsed = parseNotebook(text, notebookPreviewMaxCells);
        setState({ status: "ready", parsed });
      } catch {
        if (!signal.aborted) setState({ status: "failed" });
      }
    })();
    return () => controller.abort();
  }, [blob, ranged]);

  const linkHandlers = usePreviewLinkHandlers(onOpenBrowser);

  if (state.status === "loading") return <FilePreviewLoading />;

  if (state.status === "too_large" || state.status === "failed") {
    return (
      <PreviewMessage alert>
        {state.status === "too_large"
          ? messages.file_preview_office_too_large({ limit: 16 })
          : messages.file_preview_failed()}
      </PreviewMessage>
    );
  }

  const { parsed } = state;

  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col">
      {parsed.truncated ? (
        <PreviewNotice testId="file-preview-notebook-truncated">
          {messages.file_preview_notebook_truncated({ count: parsed.cells.length })}
        </PreviewNotice>
      ) : null}
      <ScrollArea
        className="min-h-0 flex-1"
        viewportClassName="h-full"
        contentClassName="flex min-h-full flex-col"
        edgeEffect="none"
      >
        <div className="flex min-h-full flex-1 flex-col">
          <div
            className="flex min-w-0 flex-1 flex-col gap-xl py-xl pr-xl pl-md"
            data-testid="file-preview-notebook"
            {...linkHandlers}
          >
            {parsed.cells.length === 0 ? (
              <PreviewMessage>{messages.file_preview_notebook_empty()}</PreviewMessage>
            ) : (
              parsed.cells.map((cell, index) => (
                // Notebook cells have no guaranteed stable id in nbformat <= 4.4.
                // eslint-disable-next-line react/no-array-index-key
                <NotebookCellView
                  cell={cell}
                  isDark={isDark}
                  key={index}
                  languageExtension={parsed.languageExtension}
                  onOpenBrowser={onOpenBrowser}
                />
              ))
            )}
          </div>
          {children}
        </div>
      </ScrollArea>
    </div>
  );
}
