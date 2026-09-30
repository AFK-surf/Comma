import { describe, expect, it } from "vitest";
import type { Catalog, PromptDocument, PromptLine } from "../../shared/schema";
import {
  annotateEditedLines,
  buildPendingChanges,
  createInsertedLine,
  documentChanged,
  duplicateGroups,
  textStats,
  updateDraft,
} from "./editor";
import { buildPromptStages } from "./catalog-order";

function line(id: string, text: string, sourceLine: number): PromptLine {
  return {
    id,
    kind: "text",
    text,
    translation: "",
    source: { path: "systems/example.ex", lineStart: sourceLine, lineEnd: sourceLine },
    editable: true,
    classification: "positive",
    classificationReason: "test",
  };
}

function document(id = "system:example"): PromptDocument {
  return {
    id,
    category: "system",
    title: "Example",
    description: "",
    sourcePaths: ["systems/example.ex"],
    frontmatter: [],
    lines: [line("one", "Always verify.", 10), line("two", "Never guess.", 11)],
  };
}

function catalog(documents = [document()]): Catalog {
  return {
    schemaVersion: 1,
    catalogVersion: "catalog-v1",
    generatedAt: "2026-08-27T00:00:00.000Z",
    documents,
  };
}

describe("editor model", () => {
  it("mirrors the production Router and Worker prompt composition order", () => {
    const documents = [
      { ...document("skill:one"), category: "skill" as const, title: "Skill One" },
      { ...document("system:other"), title: "Other.system_prompt" },
      {
        ...document("system:collaboration-worker"),
        title: "SalixAgent.MultiAgentCollaborationPrompt.worker",
      },
      {
        ...document("system:common"),
        title: "SalixAgent.ToolPolicy.common_system_prompt",
      },
      {
        ...document("system:router-source"),
        title: "SalixAgent.ToolPolicy.router_source_prompt",
      },
      {
        ...document("system:worker-source"),
        title: "SalixAgent.ToolPolicy.worker_source_prompt",
      },
      {
        ...document("system:collaboration-common"),
        title: "SalixAgent.MultiAgentCollaborationPrompt.common",
      },
      {
        ...document("system:collaboration-router"),
        title: "SalixAgent.MultiAgentCollaborationPrompt.router",
      },
      {
        ...document("system:dynamic"),
        title: "SalixAgent.ToolPolicy.dynamic_sections",
      },
      { ...document("tool:one"), category: "tool" as const, title: "tool.one" },
    ];

    const stages = buildPromptStages(documents);
    expect(stages[0]?.documents.map((item) => item.id)).toEqual([
      "system:common",
      "system:router-source",
      "system:collaboration-common",
      "system:collaboration-router",
      "system:dynamic",
    ]);
    expect(stages[1]?.documents.map((item) => item.id)).toEqual([
      "system:common",
      "system:worker-source",
      "system:collaboration-common",
      "system:collaboration-worker",
      "system:dynamic",
    ]);
    expect(stages[2]?.documents.map((item) => item.id)).toEqual(["system:other"]);
    expect(stages[3]?.documents.map((item) => item.id)).toEqual(["tool:one"]);
    expect(stages[4]?.documents.map((item) => item.id)).toEqual(["skill:one"]);
  });

  it("counts unicode characters and words", () => {
    expect(textStats("Use Café tools — 不猜测.")).toEqual({ characters: 21, words: 4 });
  });

  it("creates and removes a document draft as content diverges and returns", () => {
    const source = document();
    const changed = source.lines.map((item) =>
      item.id === "one" ? { ...item, text: "Always validate." } : item,
    );
    const drafts = updateDraft({}, source, changed, []);
    expect(drafts[source.id]?.lines[0]?.text).toBe("Always validate.");
    expect(documentChanged(source, changed, [])).toBe(true);
    expect(updateDraft(drafts, source, source.lines, source.frontmatter)).toEqual({});
  });

  it("annotates inserted, modified, and moved lines", () => {
    const original = document().lines;
    const inserted = createInsertedLine(original[0]!);
    inserted.text = "Provide evidence.";
    const edited = [{ ...original[1]!, text: "Never invent." }, original[0]!, inserted];
    expect(annotateEditedLines(original, edited).map((item) => item.operation)).toEqual([
      "modified",
      "moved",
      "inserted",
    ]);
  });

  it("groups exact repeated logical text across documents", () => {
    const first = document("system:first");
    const second = {
      ...document("system:second"),
      lines: [line("other", "Always verify.", 20)],
    };
    const groups = duplicateGroups(catalog([first, second]), {});
    expect(groups.get("Always verify.")).toHaveLength(2);
    expect(groups.has("Never guess.")).toBe(false);
  });

  it("builds a pending manifest only for changed documents", () => {
    const source = document();
    const changedLines = source.lines.map((item) =>
      item.id === "one" ? { ...item, text: "Always validate." } : item,
    );
    const drafts = updateDraft({}, source, changedLines, []);
    const pending = buildPendingChanges(catalog([source]), drafts);
    expect(pending.documents).toHaveLength(1);
    expect(pending.documents[0]?.editedLines[0]?.operation).toBe("modified");
    expect(pending.documents[0]?.editedLines[0]?.text).toBe("Always validate.");
  });
});
