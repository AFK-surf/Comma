import { screen, within } from "@testing-library/react";
import type { ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";
import { RunTable } from "../src/components/RunTable";
import type { RunSummary } from "../src/data/types";
import { compactId } from "../src/lib/format";
import { render } from "./render";

vi.mock("@tanstack/react-router", () => ({
  Link: ({ children, className }: { children: ReactNode; className?: string }) => (
    <a className={className} href="#run">
      {children}
    </a>
  ),
}));

vi.mock("../src/components/AddEvaluationButton", () => ({
  AddLatestRunEvaluationButton: () => <button type="button">Compare</button>,
}));

const run: RunSummary = {
  id: "0197fb0d-1595-72b6-85d4-5c29d8101b10",
  experimentName: "basic",
  description: "Basic eval",
  datasetName: "fixture",
  datasetDigest: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  datasetSelectionDigest:
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  targetItemCount: 2,
  status: "finished",
  tags: ["smoke"],
  adapters: [],
  params: {},
  createdAt: "2026-07-11T00:00:00.000Z",
  updatedAt: "2026-07-11T00:01:00.000Z",
  finishedAt: "2026-07-11T00:01:00.000Z",
  itemCounts: { completed: 2, error: 0 },
  evalCount: 1,
};

describe("RunTable", () => {
  it("uses the same middle-compaction rule for run IDs and dataset digests", () => {
    render(<RunTable runs={[run]} />);

    const row = screen.getByRole("row", { name: /basic/ });
    const runId = within(row).getByTitle(run.id);
    const digest = within(row).getByTitle(run.datasetDigest);

    expect(runId).toHaveTextContent(compactId(run.id));
    expect(digest).toHaveTextContent(compactId(run.datasetDigest));
    expect(runId).toHaveTextContent("0197fb0d...101b10");
    expect(digest).toHaveTextContent("01234567...abcdef");
    expect(runId).toHaveAttribute("title", run.id);
    expect(digest).toHaveAttribute("title", run.datasetDigest);
  });

  it("shows both creation and latest update times", () => {
    render(<RunTable runs={[run]} />);

    const table = screen.getByRole("table");
    expect(within(table).getByRole("columnheader", { name: "Created" })).toBeVisible();
    expect(within(table).getByRole("columnheader", { name: "Updated" })).toBeVisible();
    expect(within(table).getByTitle(/2026-07-11T00:00:00.000Z/)).toBeVisible();
    expect(within(table).getByTitle(/2026-07-11T00:01:00.000Z/)).toBeVisible();
  });
});
