// @vitest-environment jsdom

import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { PromptDocument, PromptLine } from "../../shared/schema";
import { LineRow } from "./LineRow";

const line: PromptLine = {
  id: "line-1",
  kind: "text",
  text: "Always verify.",
  translation: "",
  source: { path: "systems/example.ex", lineStart: 12, lineEnd: 12 },
  editable: true,
  classification: "positive",
  classificationReason: "明确要求",
};

const document: PromptDocument = {
  id: "system:example",
  category: "system",
  title: "Example",
  description: "",
  sourcePaths: ["systems/example.ex"],
  frontmatter: [],
  lines: [line],
};

afterEach(cleanup);

function setup() {
  const onUpdate = vi.fn();
  const onInsert = vi.fn();
  const onExplain = vi.fn().mockResolvedValue({
    explanation: "这行要求代理在行动前核实事实。",
    sessionId: "11111111-1111-4111-8111-111111111111",
  });
  const view = render(
    <LineRow
      document={document}
      line={line}
      originalLine={line}
      index={0}
      total={1}
      duplicates={[]}
      explanationContext="Router System Prompt · 01 Base"
      onUpdate={onUpdate}
      onInsert={onInsert}
      onDelete={vi.fn()}
      onMove={vi.fn()}
      onExplain={onExplain}
      onJumpDuplicate={vi.fn()}
    />,
  );
  return { onUpdate, onInsert, onExplain, ...view };
}

describe("LineRow", () => {
  it("edits in the existing text element and Esc restores the starting value", async () => {
    const user = userEvent.setup();
    const { container, onUpdate } = setup();
    const editor = screen.getByRole("textbox", { name: /编辑 systems\/example.ex:12/ });
    expect(editor.tagName).toBe("DIV");
    expect(editor).toHaveAttribute("contenteditable", "true");
    expect(container.querySelector("textarea")).not.toBeInTheDocument();
    await user.click(editor);
    expect(screen.getByRole("textbox", { name: /编辑 systems\/example.ex:12/ })).toBe(editor);
    await user.clear(editor);
    await user.type(editor, "Changed");
    await user.keyboard("{Escape}");
    expect(onUpdate).toHaveBeenLastCalledWith("line-1", "Always verify.");
  });

  it("inserts a new logical line when Enter is pressed in the editor", async () => {
    const user = userEvent.setup();
    const { onInsert } = setup();
    await user.click(screen.getByRole("textbox", { name: /编辑 systems\/example.ex:12/ }));
    await user.keyboard("{Enter}");
    expect(onInsert).toHaveBeenCalledWith("line-1");
  });

  it("asks the repository-aware Codex session to explain on explicit click", async () => {
    const user = userEvent.setup();
    const { onExplain } = setup();
    await user.click(screen.getByRole("button", { name: /解释 systems\/example\.ex:12/ }));
    expect(await screen.findByText("这行要求代理在行动前核实事实。")).toBeInTheDocument();
    expect(screen.getByText(/Codex 专用会话 · 11111111/)).toBeInTheDocument();
    expect(onExplain).toHaveBeenCalledWith(
      "system:example",
      "line-1",
      "Router System Prompt · 01 Base",
    );
  });
});
