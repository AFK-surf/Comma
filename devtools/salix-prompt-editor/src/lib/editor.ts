import type {
  Catalog,
  Classification,
  EditedLine,
  FrontmatterField,
  PendingChanges,
  PromptDocument,
  PromptLine,
} from "../../shared/schema";

export type DraftDocument = {
  lines: PromptLine[];
  frontmatter: FrontmatterField[];
  updatedAt: string;
};

export type DraftMap = Record<string, DraftDocument>;

export type TextStats = {
  characters: number;
  words: number;
};

export type ClassificationCounts = Record<Classification, number>;

export type DuplicateOccurrence = {
  documentId: string;
  lineId: string;
  text: string;
};

export function textStats(text: string): TextStats {
  return {
    characters: Array.from(text).length,
    words: text.match(/[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/gu)?.length ?? 0,
  };
}

export function effectiveLines(
  document: PromptDocument,
  drafts: DraftMap,
): PromptLine[] {
  return drafts[document.id]?.lines ?? document.lines;
}

export function effectiveFrontmatter(
  document: PromptDocument,
  drafts: DraftMap,
): FrontmatterField[] {
  return drafts[document.id]?.frontmatter ?? document.frontmatter;
}

function lineIdentity(line: PromptLine): string {
  return JSON.stringify({ id: line.id, kind: line.kind, text: line.text });
}

function fieldIdentity(field: FrontmatterField): string {
  return JSON.stringify({ key: field.key, value: field.value });
}

export function documentChanged(
  document: PromptDocument,
  lines: PromptLine[],
  frontmatter: FrontmatterField[],
): boolean {
  if (lines.length !== document.lines.length) return true;
  if (frontmatter.length !== document.frontmatter.length) return true;
  if (lines.some((line, index) => lineIdentity(line) !== lineIdentity(document.lines[index]!))) {
    return true;
  }
  return frontmatter.some(
    (field, index) => fieldIdentity(field) !== fieldIdentity(document.frontmatter[index]!),
  );
}

export function updateDraft(
  drafts: DraftMap,
  document: PromptDocument,
  lines: PromptLine[],
  frontmatter: FrontmatterField[],
): DraftMap {
  if (!documentChanged(document, lines, frontmatter)) {
    const next = { ...drafts };
    delete next[document.id];
    return next;
  }
  return {
    ...drafts,
    [document.id]: {
      lines,
      frontmatter,
      updatedAt: new Date().toISOString(),
    },
  };
}

export function createInsertedLine(anchor: PromptLine): PromptLine {
  return {
    id: `new:${crypto.randomUUID()}`,
    kind: "text",
    text: "",
    translation: "",
    source: { ...anchor.source },
    editable: true,
    classification: "pending",
    classificationReason: "新增行将在下次全量提取时分类",
  };
}

export function annotateEditedLines(
  original: PromptLine[],
  edited: PromptLine[],
): EditedLine[] {
  const originalById = new Map(original.map((line, index) => [line.id, { line, index }]));
  return edited.map((line, index) => {
    const before = originalById.get(line.id);
    let operation: EditedLine["operation"] = "unchanged";
    if (!before) operation = "inserted";
    else if (before.line.text !== line.text || before.line.kind !== line.kind) {
      operation = "modified";
    } else if (before.index !== index) operation = "moved";
    return { ...line, operation };
  });
}

export function buildPendingChanges(
  catalog: Catalog,
  drafts: DraftMap,
): PendingChanges {
  const documents = catalog.documents.flatMap((document) => {
    const draft = drafts[document.id];
    if (!draft) return [];
    return [
      {
        documentId: document.id,
        category: document.category,
        title: document.title,
        sourcePaths: document.sourcePaths,
        originalFrontmatter: document.frontmatter,
        editedFrontmatter: draft.frontmatter,
        originalLines: document.lines,
        editedLines: annotateEditedLines(document.lines, draft.lines),
      },
    ];
  });

  return {
    schemaVersion: 1,
    catalogVersion: catalog.catalogVersion,
    createdAt: new Date().toISOString(),
    documents,
  };
}

export function classificationCounts(lines: PromptLine[]): ClassificationCounts {
  const counts: ClassificationCounts = {
    positive: 0,
    negative: 0,
    mixed: 0,
    non_rule: 0,
    pending: 0,
  };
  for (const line of lines) counts[line.classification] += 1;
  return counts;
}

export function duplicateGroups(
  catalog: Catalog,
  drafts: DraftMap,
): Map<string, DuplicateOccurrence[]> {
  const groups = new Map<string, DuplicateOccurrence[]>();
  for (const document of catalog.documents) {
    for (const line of effectiveLines(document, drafts)) {
      if (line.kind !== "text" || !line.text.trim()) continue;
      const key = line.text.trim();
      const group = groups.get(key) ?? [];
      group.push({ documentId: document.id, lineId: line.id, text: line.text });
      groups.set(key, group);
    }
  }
  for (const [key, group] of groups) {
    if (group.length < 2) groups.delete(key);
  }
  return groups;
}

export function documentTextStats(lines: PromptLine[]): TextStats {
  return lines.reduce(
    (total, line) => {
      const next = textStats(line.text);
      return {
        characters: total.characters + next.characters,
        words: total.words + next.words,
      };
    },
    { characters: 0, words: 0 },
  );
}

export function domId(...parts: string[]): string {
  let hash = 2166136261;
  const value = parts.join("\u0000");
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return `atlas-${(hash >>> 0).toString(36)}`;
}

export function deletedLineCount(document: PromptDocument, draft: DraftDocument): number {
  const ids = new Set(draft.lines.map((line) => line.id));
  return document.lines.filter((line) => !ids.has(line.id)).length;
}
