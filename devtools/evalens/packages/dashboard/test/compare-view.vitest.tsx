import { fireEvent, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { aggregateEvaluationLabels, CompareView } from "../src/components/CompareView";
import type { EvalCatalogEntry, EvalComparison } from "../src/data/types";
import { render } from "./render";

vi.mock("../src/components/Chart", () => ({
  Chart: ({ option }: { option: object }) => (
    <div data-option={JSON.stringify(option)} data-testid="chart" />
  ),
}));

const comparison: EvalComparison = {
  sharedItemCount: 1,
  itemPage: 1,
  itemPageSize: 200,
  itemMetrics: [],
  evaluations: ["eval-a", "eval-b"].map((id) => ({
    id,
    status: "finished" as const,
    params: {},
    aggregatorVersion: "1",
    evaluators: [],
    scoreIdentities: [],
    adapters: [],
    aggregateScores: { accuracy: 1 },
    resultCounts: { target: 0, completed: 0, error: 0, skipped: 0 },
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
    items: [],
  })),
};

describe("CompareView", () => {
  it("uses eval IDs only to disambiguate repeated experiment labels", () => {
    expect(aggregateEvaluationLabels(comparison.evaluations)).toEqual([
      "basic\neval-a",
      "basic\neval-b",
    ]);
  });

  it("changes reference and removes a selected evaluation", () => {
    const onChange = vi.fn();
    render(
      <CompareView
        catalog={{ items: [], page: 1, pageSize: 100, total: 0 }}
        comparison={comparison}
        filters={{}}
        onCatalogPage={vi.fn()}
        onChange={onChange}
        onFilter={vi.fn()}
        onPage={vi.fn()}
        onReload={vi.fn()}
        reference="eval-a"
      />
    );
    const references = screen.getAllByRole("radio", { name: "Reference" });
    fireEvent.click(references[1]!);
    expect(onChange).toHaveBeenCalledWith(["eval-a", "eval-b"], "eval-b");
    fireEvent.click(screen.getAllByTitle("Remove")[0]!);
    expect(onChange).toHaveBeenCalledWith(["eval-b"], undefined);
  });

  it("disables incompatible picker options with the shared precise reason", () => {
    const selected = comparison.evaluations[0]!;
    const compatible = catalogEntry("eval-compatible");
    const incompatible = {
      ...catalogEntry("eval-incompatible"),
      aggregatorVersion: "2",
      aggregateScores: { quality: 1 },
      run: {
        ...catalogEntry("eval-incompatible").run,
        datasetSelectionDigest: "other-selection",
      },
    };
    render(
      <CompareView
        catalog={{
          items: [compatible, incompatible],
          page: 1,
          pageSize: 100,
          total: 2,
        }}
        comparison={{ ...comparison, evaluations: [selected] }}
        filters={{}}
        onCatalogPage={vi.fn()}
        onChange={vi.fn()}
        onFilter={vi.fn()}
        onPage={vi.fn()}
        onReload={vi.fn()}
      />
    );

    const incompatibleOption = screen.getByRole("option", {
      name: /eval-incompatible.*Cannot compare.*dataset name or digest differs/i,
    });
    expect(incompatibleOption).toBeDisabled();
    expect(incompatibleOption).toHaveAttribute(
      "title",
      expect.stringContaining("Aggregate dataset name or digest differs")
    );
    expect(screen.getByRole("option", { name: /eval-compatible/i })).toBeEnabled();
  });

  it("renders each aggregate metric with an independent value axis", () => {
    const withDifferentScales = {
      ...comparison,
      evaluations: comparison.evaluations.map((evaluation, index) => ({
        ...evaluation,
        aggregateScores: { tiny_score: index, huge_count: 20_000 + index },
        run: {
          ...evaluation.run,
          experimentName:
            index === 0
              ? "salix-router-single-session-preprovisioned-worker-compacted"
              : "salix-router-single-session-router-only-fresh",
        },
      })),
    };
    render(
      <CompareView
        catalog={{ items: [], page: 1, pageSize: 100, total: 0 }}
        comparison={withDifferentScales}
        filters={{}}
        onCatalogPage={vi.fn()}
        onChange={vi.fn()}
        onFilter={vi.fn()}
        onPage={vi.fn()}
        onReload={vi.fn()}
      />
    );

    expect(screen.getByRole("heading", { name: "tiny_score" })).not.toHaveAttribute(
      "title"
    );
    expect(screen.getByRole("heading", { name: "huge_count" })).not.toHaveAttribute(
      "title"
    );
    const options = screen
      .getAllByTestId("chart")
      .map((chart) => JSON.parse(chart.dataset.option ?? "{}"));
    expect(options).toHaveLength(2);
    expect(options.map((option) => option.series[0].name)).toEqual([
      "huge_count",
      "tiny_score",
    ]);
    expect(
      options.every(
        (option) =>
          option.xAxis.data.join("|") === "with worker\ncompacted|router only\nfresh"
      )
    ).toBe(true);
    expect(
      options.map((option) =>
        option.series[0].data.map(({ value }: { value: number }) => value)
      )
    ).toEqual([
      [20_000, 20_001],
      [0, 1],
    ]);
    expect(options.every((option) => option.yAxis.scale === true)).toBe(true);
  });
});

function catalogEntry(id: string): EvalCatalogEntry {
  const source = comparison.evaluations[0]!;
  const { items: _items, ...entry } = source;
  return {
    ...entry,
    id,
    run: { ...entry.run, id: `run-${id}` },
  };
}
