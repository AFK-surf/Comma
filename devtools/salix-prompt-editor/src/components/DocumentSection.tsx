import { memo, useMemo } from "react";
import type {
  FrontmatterField,
  ExplanationResponse,
  PromptDocument,
  PromptLine,
} from "../../shared/schema";
import {
  classificationCounts,
  createInsertedLine,
  deletedLineCount,
  documentTextStats,
  domId,
  type DraftDocument,
  type DuplicateOccurrence,
} from "../lib/editor";
import { LineRow } from "./LineRow";

type DocumentSectionProps = {
  document: PromptDocument;
  instanceId?: string;
  compositionLabel?: string;
  explanationContext?: string;
  draft: DraftDocument | undefined;
  duplicatesByText: Map<string, DuplicateOccurrence[]>;
  duplicatesOnly: boolean;
  onChange: (
    document: PromptDocument,
    lines: PromptLine[],
    frontmatter: FrontmatterField[],
  ) => void;
  onExplain: (
    documentId: string,
    lineId: string,
    context?: string,
  ) => Promise<ExplanationResponse>;
  onJumpDuplicate: (line: PromptLine, occurrences: DuplicateOccurrence[]) => void;
};

const categoryLabels = {
  system: "System Prompt",
  tool: "Tool",
  skill: "Skill",
} as const;

const classLabels = {
  positive: "正",
  negative: "负",
  mixed: "混",
  non_rule: "非规则",
  pending: "待提取",
} as const;

export const DocumentSection = memo(function DocumentSection({
  document,
  instanceId,
  compositionLabel,
  explanationContext,
  draft,
  duplicatesByText,
  duplicatesOnly,
  onChange,
  onExplain,
  onJumpDuplicate,
}: DocumentSectionProps) {
  const documentDomId = instanceId ?? document.id;
  const lines = draft?.lines ?? document.lines;
  const frontmatter = draft?.frontmatter ?? document.frontmatter;
  const originalById = useMemo(
    () => new Map(document.lines.map((line) => [line.id, line])),
    [document.lines],
  );
  const currentStats = documentTextStats(lines);
  const originalStats = documentTextStats(document.lines);
  const counts = classificationCounts(lines);
  const classifiedTotal = Math.max(
    1,
    counts.positive + counts.negative + counts.mixed + counts.non_rule,
  );
  const deleted = draft ? deletedLineCount(document, draft) : 0;

  function commit(nextLines: PromptLine[], nextFrontmatter = frontmatter) {
    onChange(document, nextLines, nextFrontmatter);
  }

  function updateLine(lineId: string, text: string) {
    commit(lines.map((line) => (line.id === lineId ? { ...line, text } : line)));
  }

  function insertLine(lineId: string) {
    const index = lines.findIndex((line) => line.id === lineId);
    if (index < 0) return;
    const next = [...lines];
    next.splice(index + 1, 0, createInsertedLine(lines[index]!));
    commit(next);
  }

  function deleteLine(lineId: string) {
    commit(lines.filter((line) => line.id !== lineId));
  }

  function moveLine(lineId: string, direction: -1 | 1) {
    const index = lines.findIndex((line) => line.id === lineId);
    const target = index + direction;
    if (index < 0 || target < 0 || target >= lines.length) return;
    const next = [...lines];
    const [line] = next.splice(index, 1);
    next.splice(target, 0, line!);
    commit(next);
  }

  function updateFrontmatter(index: number, value: string) {
    const next = frontmatter.map((field, fieldIndex) =>
      fieldIndex === index ? { ...field, value } : field,
    );
    onChange(document, lines, next);
  }

  async function copyDocumentLocation() {
    await navigator.clipboard.writeText(document.sourcePaths.join("\n"));
  }

  const indexedLines = lines.map((line, index) => ({ line, index }));
  const visibleLines = duplicatesOnly
    ? indexedLines.filter(
        ({ line }) => (duplicatesByText.get(line.text.trim())?.length ?? 0) > 1,
      )
    : indexedLines;

  return (
    <article
      id={domId("document", documentDomId)}
      className={`document-section${draft ? " document-section--draft" : ""}`}
    >
      <header className="document-header">
        <div>
          <div className="document-eyebrow">
            <span>{categoryLabels[document.category]}</span>
            {compositionLabel ? <span className="composition-label">{compositionLabel}</span> : null}
            {draft ? <span className="draft-badge">草稿</span> : null}
          </div>
          <h2>{document.title}</h2>
          {document.description ? <p>{document.description}</p> : null}
        </div>
        <button className="source-button" type="button" onClick={copyDocumentLocation}>
          {document.sourcePaths.length === 1
            ? document.sourcePaths[0]
            : `${document.sourcePaths.length} 个源文件`}
        </button>
      </header>

      <div className="document-stats tabular">
        <span>{lines.length} 个元素</span>
        <span>
          {currentStats.characters.toLocaleString()} 字符
          {draft && currentStats.characters !== originalStats.characters ? (
            <em>
              {currentStats.characters > originalStats.characters ? "+" : ""}
              {currentStats.characters - originalStats.characters}
            </em>
          ) : null}
        </span>
        <span>{currentStats.words.toLocaleString()} 词</span>
        {deleted ? <span className="danger-text">删除 {deleted} 行</span> : null}
        {Object.entries(counts).map(([classification, count]) => (
          <span key={classification} className={`stat-class stat-class--${classification}`}>
            {classLabels[classification as keyof typeof classLabels]} {count} ·{" "}
            {Math.round((count / classifiedTotal) * 100)}%
          </span>
        ))}
      </div>

      {frontmatter.length ? (
        <section className="frontmatter-editor" aria-label={`${document.title} frontmatter`}>
          <div className="frontmatter-title">YAML frontmatter</div>
          <div className="frontmatter-grid">
            {frontmatter.map((field, index) => (
              <label key={`${field.key}:${index}`}>
                <span>
                  {field.key}
                  <button
                    type="button"
                    onClick={() =>
                      navigator.clipboard.writeText(
                        `${field.source.path}:${field.source.lineStart}`,
                      )
                    }
                  >
                    {field.source.lineStart}
                  </button>
                </span>
                <textarea
                  rows={field.key === "description" ? 3 : 1}
                  value={field.value}
                  disabled={!field.editable}
                  onChange={(event) => updateFrontmatter(index, event.target.value)}
                />
              </label>
            ))}
          </div>
        </section>
      ) : null}

      <div className="line-list">
        {visibleLines.map(({ line, index }) => {
          const duplicates = duplicatesByText.get(line.text.trim()) ?? [];
          return (
            <div id={domId("line", documentDomId, line.id)} key={line.id}>
              <LineRow
                document={document}
                line={line}
                originalLine={originalById.get(line.id)}
                index={index}
                total={lines.length}
                duplicates={duplicates}
                onUpdate={updateLine}
                onInsert={insertLine}
                onDelete={deleteLine}
                onMove={moveLine}
                explanationContext={explanationContext}
                onExplain={onExplain}
                onJumpDuplicate={onJumpDuplicate}
              />
            </div>
          );
        })}
        {duplicatesOnly && visibleLines.length === 0 ? (
          <div className="empty-filter">这个 section 没有精确重复文本。</div>
        ) : null}
      </div>
    </article>
  );
});
