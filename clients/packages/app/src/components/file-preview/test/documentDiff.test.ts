import { describe, expect, it } from "vitest";
import { documentDiff, documentDiffHasChanges } from "../documentDiff";
import { documentBodyHtml, documentTree } from "../documentExport";

const compared = (before: string, after: string) =>
  documentBodyHtml(documentDiff(documentTree(before), documentTree(after)));

describe("two versions of a document, compared", () => {
  it("marks the words a paragraph lost and gained, and keeps its other marks", () => {
    expect(
      compared(
        "# 实现状态\n\n代码已写在分支 `plugin` 上，还没有提交。没有端到端跑过。\n",
        "# 实现状态\n\n代码已写在分支 `plugin` 上，还没有提交。已用真实的 Raycast 手测。\n"
      )
    ).toBe(
      "<h1>实现状态</h1><p>代码已写在分支 <code>plugin</code> 上，还没有提交。" +
        "<del>没有端到端跑过</del><ins>已用真实的 Raycast 手测</ins>。</p>"
    );
  });

  it("shows a rewritten sentence as one removal and one addition, not word by word", () => {
    expect(
      compared(
        "还没有提交。没有在真实的 Raycast 和桌面端上端到端跑过。\n",
        "还没有提交。已用真实的 Raycast 和本分支的开发版桌面端对 staging 手测，Ask Comma 填草稿都和预期一致。\n"
      )
    ).toBe(
      "<p>还没有提交。<del>没有在真实的 Raycast 和桌面端上端到端跑过</del>" +
        "<ins>已用真实的 Raycast 和本分支的开发版桌面端对 staging 手测，Ask Comma 填草稿都和预期一致</ins>。</p>"
    );
  });

  it("marks whole blocks that came and went, and compares a list item by item", () => {
    expect(
      compared(
        "## Risks\n\n- one\n- two\n\nOld close.\n",
        "## Risks\n\n- one\n- two again\n- three\n\n| A |\n| --- |\n| 1 |\n"
      )
    ).toBe(
      "<h2>Risks</h2><ul><li>one</li><li>two<ins> again</ins></li>" +
        '<li data-diff="ins">three</li></ul>' +
        '<p data-diff="del">Old close.</p>' +
        '<table data-diff="ins"><thead><tr><th style="text-align: left">A</th></tr></thead>' +
        '<tbody><tr><td style="text-align: left">1</td></tr></tbody></table>'
    );
  });

  it("compares a table row by row and cell by cell", () => {
    expect(
      compared(
        "| 风险 | 应对 |\n| --- | --- |\n| 续期失败 | 重试 |\n",
        "| 风险 | 应对 |\n| --- | --- |\n| 续期失败 | 重试 3 次 |\n| 离线 | 只读 |\n"
      )
    ).toContain(
      '<tbody><tr><td style="text-align: left">续期失败</td>' +
        '<td style="text-align: left">重试<ins> 3 次</ins></td></tr>' +
        '<tr data-diff="ins">'
    );
  });

  it("marks nothing where the two versions draw the same", () => {
    const tree = documentDiff(
      documentTree("# Plan\n* one\n* two\n"),
      documentTree("# Plan\n\n- one\n- two\n")
    );
    expect(documentDiffHasChanges(tree)).toBe(false);
    expect(
      documentDiffHasChanges(documentDiff(documentTree("a\n"), documentTree("b\n")))
    ).toBe(true);
  });
});
