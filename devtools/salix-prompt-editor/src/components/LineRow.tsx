import { memo, useLayoutEffect, useRef, useState } from "react";
import type {
  ExplanationResponse,
  PromptDocument,
  PromptLine,
} from "../../shared/schema";
import type { DuplicateOccurrence } from "../lib/editor";
import { textStats } from "../lib/editor";

const classificationLabels = {
  positive: "正",
  negative: "负",
  mixed: "混",
  non_rule: "文",
  pending: "待",
} as const;

type LineRowProps = {
  document: PromptDocument;
  line: PromptLine;
  originalLine: PromptLine | undefined;
  index: number;
  total: number;
  duplicates: DuplicateOccurrence[];
  onUpdate: (lineId: string, text: string) => void;
  onInsert: (lineId: string) => void;
  onDelete: (lineId: string) => void;
  onMove: (lineId: string, direction: -1 | 1) => void;
  explanationContext?: string;
  onExplain: (
    documentId: string,
    lineId: string,
    context?: string,
  ) => Promise<ExplanationResponse>;
  onJumpDuplicate: (line: PromptLine, occurrences: DuplicateOccurrence[]) => void;
};

type InlineExplanationState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "ready"; explanation: string; sessionId: string }
  | { status: "error"; message: string };

export const LineRow = memo(function LineRow({
  document,
  line,
  originalLine,
  index,
  total,
  duplicates,
  onUpdate,
  onInsert,
  onDelete,
  onMove,
  explanationContext,
  onExplain,
  onJumpDuplicate,
}: LineRowProps) {
  const [editing, setEditing] = useState(false);
  const [active, setActive] = useState(false);
  const [explanationVisible, setExplanationVisible] = useState(false);
  const [explanationState, setExplanationState] = useState<InlineExplanationState>({
    status: "idle",
  });
  const editStart = useRef(line.text);
  const lineTextRef = useRef<HTMLDivElement>(null);
  const stats = textStats(line.text);
  const beforeStats = textStats(originalLine?.text ?? "");
  const delta = stats.characters - beforeStats.characters;
  const inserted = line.id.startsWith("new:");
  const canExplain = line.kind === "text" && !inserted;
  const changed = inserted || !originalLine || originalLine.text !== line.text;
  const sourceRange =
    line.source.lineStart === line.source.lineEnd
      ? `${line.source.lineStart}`
      : `${line.source.lineStart}–${line.source.lineEnd}`;

  useLayoutEffect(() => {
    const element = lineTextRef.current;
    if (!editing && element && element.textContent !== line.text) {
      element.textContent = line.text;
    }
  }, [editing, line.text]);

  async function copyLocation(event: React.MouseEvent) {
    event.stopPropagation();
    await navigator.clipboard.writeText(`${line.source.path}:${sourceRange}`);
  }

  async function toggleExplanation() {
    if (!canExplain || explanationState.status === "loading") return;
    if (explanationState.status === "ready") {
      setExplanationVisible((visible) => !visible);
      return;
    }

    setExplanationVisible(true);
    setExplanationState({ status: "loading" });
    try {
      const result = await onExplain(document.id, line.id, explanationContext);
      setExplanationState({
        status: "ready",
        explanation: result.explanation,
        sessionId: result.sessionId,
      });
    } catch (reason) {
      setExplanationState({
        status: "error",
        message: reason instanceof Error ? reason.message : String(reason),
      });
    }
  }

  function pastePlainText(event: React.ClipboardEvent<HTMLDivElement>) {
    event.preventDefault();
    const element = event.currentTarget;
    const text = event.clipboardData.getData("text/plain").replace(/\r?\n/g, "");
    const selection = window.getSelection();
    const textNode = window.document.createTextNode(text);

    if (!selection || selection.rangeCount === 0) {
      element.append(textNode);
    } else {
      const range = selection.getRangeAt(0);
      if (!element.contains(range.commonAncestorContainer)) {
        element.append(textNode);
      } else {
        range.deleteContents();
        range.insertNode(textNode);
        range.setStartAfter(textNode);
        range.collapse(true);
        selection.removeAllRanges();
        selection.addRange(range);
      }
    }

    onUpdate(line.id, element.textContent ?? "");
  }

  if (line.kind === "blank_range") {
    const count = line.source.lineEnd - line.source.lineStart + 1;
    return (
      <div
        className="prompt-line prompt-line--blank"
        onMouseEnter={() => {
          setActive(true);
        }}
        onMouseLeave={() => {
          setActive(false);
        }}
        onFocusCapture={() => setActive(true)}
        onBlurCapture={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget)) setActive(false);
        }}
      >
        <button className="line-location" onClick={copyLocation} type="button">
          {sourceRange}
        </button>
        <span className="blank-rule" aria-label={`${count} 个连续空白行`} />
        <span className="blank-label">折叠空白行 ×{count}</span>
        {active ? (
          <details className="line-menu" onClick={(event) => event.stopPropagation()}>
            <summary aria-label="空白行操作">•••</summary>
            <div>
              <button type="button" onClick={() => onInsert(line.id)}>
                在下方插入
              </button>
              <button type="button" onClick={() => onDelete(line.id)}>
                删除空白范围
              </button>
            </div>
          </details>
        ) : null}
      </div>
    );
  }

  return (
    <div
      className={`prompt-line${changed ? " prompt-line--draft" : ""}${line.editable ? "" : " prompt-line--readonly"}`}
      onMouseEnter={() => {
        setActive(true);
      }}
      onMouseLeave={() => {
        if (!editing) setActive(false);
      }}
      onFocusCapture={() => setActive(true)}
      onBlurCapture={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setActive(false);
      }}
    >
      <button className="line-location" onClick={copyLocation} type="button">
        {inserted ? "+" : sourceRange}
      </button>
      <span
        className={`classification classification--${line.classification}`}
        aria-label={line.classificationReason}
      >
        {classificationLabels[line.classification]}
      </span>
      <div className="line-content">
        {line.editable ? (
          <div
            ref={lineTextRef}
            className="line-text line-text--editable"
            role="textbox"
            tabIndex={0}
            contentEditable
            suppressContentEditableWarning
            aria-multiline="false"
            aria-placeholder="空行"
            data-placeholder="空行"
            aria-label={`编辑 ${line.source.path}:${sourceRange}`}
            onFocus={(event) => {
              editStart.current = event.currentTarget.textContent ?? line.text;
              setEditing(true);
            }}
            onInput={(event) => {
              onUpdate(line.id, (event.currentTarget.textContent ?? "").replace(/\r?\n/g, ""));
            }}
            onPaste={pastePlainText}
            onBlur={() => setEditing(false)}
            onKeyDown={(event) => {
              if (event.key === "Escape") {
                event.preventDefault();
                event.currentTarget.textContent = editStart.current;
                onUpdate(line.id, editStart.current);
                event.currentTarget.blur();
              } else if (event.key === "Enter") {
                event.preventDefault();
                event.currentTarget.blur();
                onInsert(line.id);
              }
            }}
          />
        ) : (
          <div className="line-text">{line.text}</div>
        )}
        {line.kind === "placeholder" ? (
          <span className="readonly-reason">{line.readonlyReason ?? "动态内容"}</span>
        ) : null}
        {explanationVisible && explanationState.status !== "idle" ? (
          <div
            className={`line-explanation line-explanation--${explanationState.status}`}
            aria-live="polite"
          >
            {explanationState.status === "loading" ? (
              <span>Codex 正在结合 Salix 仓库解释这一行…</span>
            ) : explanationState.status === "error" ? (
              <span>解释失败：{explanationState.message}</span>
            ) : (
              <>
                <span>{explanationState.explanation}</span>
                <small>Codex 专用会话 · {explanationState.sessionId.slice(0, 8)}</small>
              </>
            )}
          </div>
        ) : null}
      </div>
      <div className="line-metrics tabular">
        <span>{stats.characters}c</span>
        <span>{stats.words}w</span>
        {changed && delta !== 0 ? (
          <span className={delta > 0 ? "delta-positive" : "delta-negative"}>
            {delta > 0 ? "+" : ""}
            {delta}
          </span>
        ) : null}
      </div>
      {canExplain ? (
        <button
          type="button"
          className="explanation-button"
          aria-expanded={explanationVisible}
          aria-label={`${explanationState.status === "error" ? "重试解释" : explanationVisible ? "收起解释" : "解释"} ${line.source.path}:${sourceRange}`}
          title={
            explanationState.status === "loading"
              ? "Codex 正在解释"
              : explanationVisible
                ? "收起解释"
                : explanationState.status === "error"
                  ? "重试解释"
                  : "结合 Salix 仓库解释这一行"
          }
          disabled={explanationState.status === "loading"}
          onClick={toggleExplanation}
        >
          {explanationState.status === "loading"
            ? "…"
            : explanationState.status === "error"
              ? "重试"
              : explanationVisible
                ? "收起"
                : "解释"}
        </button>
      ) : null}
      {duplicates.length > 1 ? (
        <button
          type="button"
          className="duplicate-badge"
          onClick={(event) => {
            event.stopPropagation();
            onJumpDuplicate(line, duplicates);
          }}
        >
          重复 {duplicates.length}
        </button>
      ) : null}
      {line.editable && active ? (
        <details className="line-menu" onClick={(event) => event.stopPropagation()}>
          <summary aria-label="行操作">•••</summary>
          <div>
            <button type="button" disabled={index === 0} onClick={() => onMove(line.id, -1)}>
              上移
            </button>
            <button
              type="button"
              disabled={index === total - 1}
              onClick={() => onMove(line.id, 1)}
            >
              下移
            </button>
            <button type="button" onClick={() => onInsert(line.id)}>
              在下方插入
            </button>
            <button type="button" onClick={() => onDelete(line.id)}>
              删除
            </button>
          </div>
        </details>
      ) : null}
    </div>
  );
});
