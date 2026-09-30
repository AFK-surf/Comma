import { fireEvent, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  AddEvaluationButton,
  AddLatestRunEvaluationButton,
} from "../src/components/AddEvaluationButton";
import { dashboardDataSource } from "../src/data/source";
import { LocaleMenu } from "../src/i18n/locale";
import type { EvalCatalogEntry, EvalComparison } from "../src/data/types";
import {
  CompareSelectionProvider,
  useCompareSelection,
} from "../src/selection/CompareSelection";
import { render } from "./render";

const entries = {
  selected: entry("eval-a"),
  compatible: entry("eval-b"),
  incompatible: incompatibleEntry("eval-c"),
};

beforeEach(() => {
  localStorage.clear();
  vi.restoreAllMocks();
  vi.spyOn(dashboardDataSource, "listEvaluations").mockResolvedValue({
    items: Object.values(entries),
    page: 1,
    pageSize: 10,
    total: 3,
  });
  vi.spyOn(dashboardDataSource, "compareEvaluations").mockImplementation(async (ids) =>
    comparisonFor(ids)
  );
});

describe("evaluation comparison controls", () => {
  it("pre-disables incompatible candidates with an out-of-flow accessible reason", async () => {
    storeSelection(entries.selected.id);
    const { container } = render(
      <CompareSelectionProvider>
        <ButtonTable />
      </CompareSelectionProvider>
    );

    const incompatible = await screen.findByRole("button", {
      name: `Add evaluation ${entries.incompatible.id} for comparison`,
    });
    await waitFor(() => expect(incompatible).toBeDisabled());
    const trigger = incompatible.closest(".compare-action");
    expect(trigger).toHaveAttribute("tabindex", "0");
    if (!trigger) throw new Error("compare action wrapper not found");
    fireEvent.mouseEnter(trigger);
    fireEvent.focus(trigger);
    const tooltip = screen.getByRole("tooltip");
    expect(tooltip).toHaveTextContent("Aggregate dataset name or digest differs");
    expect(tooltip).toHaveClass("compare-action-tooltip");
    expect(container.querySelector(".control-message")).not.toBeInTheDocument();
    expect(incompatible.closest("td")?.children).toHaveLength(1);
  });

  it("prechecks the latest evaluation shown by a Runs table row", async () => {
    storeSelection(entries.selected.id);
    render(
      <CompareSelectionProvider>
        <AddLatestRunEvaluationButton run={runSummary(entries.incompatible)} />
      </CompareSelectionProvider>
    );
    const button = await screen.findByRole("button", {
      name: `Add latest finished evaluation for run ${entries.incompatible.run.id}`,
    });
    await waitFor(() => expect(button).toBeDisabled());
    expect(dashboardDataSource.compareEvaluations).toHaveBeenCalledTimes(1);
    await waitFor(() => {
      const current = screen.getByRole("button", {
        name: `Add latest finished evaluation for run ${entries.incompatible.run.id}`,
      });
      fireEvent.mouseEnter(current.closest(".compare-action")!);
      expect(screen.getByRole("tooltip")).toHaveTextContent(
        "Aggregate dataset name or digest differs"
      );
    });
  });

  it("keeps compatible candidates selectable and selected candidates removable", async () => {
    storeSelection(entries.selected.id);
    render(
      <CompareSelectionProvider>
        <ButtonTable />
      </CompareSelectionProvider>
    );

    const selected = await screen.findByRole("button", {
      name: `Remove ${entries.selected.id} from comparison`,
    });
    expect(selected).toBeEnabled();

    const compatible = await screen.findByRole("button", {
      name: `Add evaluation ${entries.compatible.id} for comparison`,
    });
    await waitFor(() => expect(compatible).toBeEnabled());
    fireEvent.click(compatible);
    const removeCompatible = await screen.findByRole("button", {
      name: `Remove ${entries.compatible.id} from comparison`,
    });
    fireEvent.click(removeCompatible);
    await screen.findByRole("button", {
      name: `Add evaluation ${entries.compatible.id} for comparison`,
    });

    fireEvent.click(selected);
    await screen.findByRole("button", {
      name: `Add evaluation ${entries.selected.id} for comparison`,
    });
  });

  it("allows every finished candidate when the selection is empty", async () => {
    render(
      <CompareSelectionProvider>
        <AddEvaluationButton entry={entries.compatible} />
      </CompareSelectionProvider>
    );
    const button = screen.getByRole("button", {
      name: `Add evaluation ${entries.compatible.id} for comparison`,
    });
    await waitFor(() => expect(button).toBeEnabled());
    expect(dashboardDataSource.compareEvaluations).not.toHaveBeenCalled();
  });

  it("recomputes a disabled compatibility tooltip after changing locale", async () => {
    storeSelection(entries.selected.id);
    render(
      <CompareSelectionProvider>
        <LocaleMenu />
        <AddEvaluationButton entry={entries.incompatible} />
      </CompareSelectionProvider>
    );
    const button = await screen.findByRole("button", {
      name: `Add evaluation ${entries.incompatible.id} for comparison`,
    });
    await waitFor(() => expect(button).toBeDisabled());
    const action = button.closest(".compare-action");
    if (!action) throw new Error("compare action wrapper not found");
    fireEvent.mouseEnter(action);
    expect(screen.getByRole("tooltip")).toHaveTextContent(
      "Aggregate dataset name or digest differs"
    );

    fireEvent.click(screen.getByLabelText("Change language"));
    fireEvent.click(screen.getByRole("menuitemradio", { name: "简体中文" }));
    await waitFor(() => {
      fireEvent.mouseEnter(action);
      expect(screen.getByRole("tooltip")).toHaveTextContent("聚合数据集名称或摘要不同");
    });
  });
});

function ButtonTable() {
  const { selected } = useCompareSelection();
  return (
    <table>
      <tbody>
        <tr>
          <td>
            <AddEvaluationButton compact entry={entries.selected} />
          </td>
          <td>
            <AddEvaluationButton compact entry={entries.compatible} />
          </td>
          <td>
            <AddEvaluationButton compact entry={entries.incompatible} />
          </td>
        </tr>
        <tr>
          <td data-testid="selected-count">{selected.length}</td>
        </tr>
      </tbody>
    </table>
  );
}

function storeSelection(...ids: string[]) {
  localStorage.setItem(
    "evalens.compare-selection",
    JSON.stringify({ version: 1, evalIds: ids })
  );
}

function entry(id: string): EvalCatalogEntry {
  return {
    id,
    status: "finished",
    params: {},
    aggregatorVersion: "1",
    evaluators: [{ name: "judge", version: "1" }],
    scoreIdentities: [
      { evaluatorName: "judge", evaluatorVersion: "1", scoreKey: "score" },
    ],
    adapters: [],
    aggregateScores: { accuracy: 1 },
    resultCounts: { target: 1, completed: 1, error: 0, skipped: 0 },
    createdAt: "2026-01-01T00:00:00.000Z",
    run: {
      id: `run-${id}`,
      experimentName: "basic",
      datasetName: "fixture",
      datasetDigest: "digest",
      datasetSelectionDigest: "selection",
      tags: [],
      params: {},
      createdAt: "2026-01-01T00:00:00.000Z",
    },
  };
}

function runSummary(candidate: EvalCatalogEntry) {
  return {
    ...candidate.run,
    description: "Fixture run",
    targetItemCount: 1,
    status: "finished" as const,
    adapters: [],
    updatedAt: "2026-01-01T00:01:00.000Z",
    finishedAt: "2026-01-01T00:01:00.000Z",
    itemCounts: { completed: 1, error: 0 },
    evalCount: 1,
    latestFinishedEvaluation: candidate,
  };
}

function incompatibleEntry(id: string): EvalCatalogEntry {
  const candidate = entry(id);
  return {
    ...candidate,
    aggregatorVersion: "2",
    aggregateScores: { quality: 1 },
    run: { ...candidate.run, datasetSelectionDigest: "other-selection" },
  };
}

function comparisonFor(ids: string[]): EvalComparison {
  return {
    evaluations: Object.values(entries)
      .filter(({ id }) => ids.includes(id))
      .map((candidate) => ({ ...candidate, items: [] })),
    sharedItemCount: 1,
    itemPage: 1,
    itemPageSize: 1,
    itemMetrics: [],
  };
}
