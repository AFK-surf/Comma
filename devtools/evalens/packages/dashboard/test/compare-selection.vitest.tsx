import { fireEvent, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { CompareTray } from "../src/components/CompareTray";
import { dashboardDataSource } from "../src/data/source";
import type { EvalCatalogEntry, EvalComparison } from "../src/data/types";
import {
  CompareSelectionProvider,
  parseStoredSelection,
  useCompareSelection,
} from "../src/selection/CompareSelection";
import { render } from "./render";

vi.mock("@tanstack/react-router", () => ({
  Link: ({ children, search }: { children: React.ReactNode; search: unknown }) => (
    <a data-search={JSON.stringify(search)} href="/compare">
      {children}
    </a>
  ),
  useLocation: () => ({ pathname: "/evaluations" }),
  useNavigate: () => vi.fn(),
}));

const entries = [entry("eval-a"), entry("eval-b"), entry("eval-c")];

beforeEach(() => {
  localStorage.clear();
  vi.restoreAllMocks();
  vi.spyOn(dashboardDataSource, "listEvaluations").mockResolvedValue({
    items: entries,
    page: 1,
    pageSize: 10,
    total: entries.length,
  });
  vi.spyOn(dashboardDataSource, "compareEvaluations").mockImplementation(async (ids) =>
    comparisonFor(ids)
  );
});

describe("compare selection", () => {
  it("rejects corrupt or stale storage and deduplicates stored IDs", () => {
    expect(parseStoredSelection("not-json")).toEqual([]);
    expect(parseStoredSelection('{"version":0,"evalIds":["eval-a"]}')).toEqual([]);
    expect(
      parseStoredSelection('{"version":1,"evalIds":["eval-a","eval-a","eval-b",4]}')
    ).toEqual(["eval-a", "eval-b"]);
    expect(
      parseStoredSelection(
        JSON.stringify({
          version: 1,
          evalIds: Array.from({ length: 9 }, (_, index) => `eval-${index}`),
        })
      )
    ).toEqual([]);
  });

  it("hydrates persisted selections, deduplicates additions, and persists changes", async () => {
    storeSelection("eval-a");
    render(
      <CompareSelectionProvider>
        <Harness />
      </CompareSelectionProvider>
    );
    await screen.findByText("eval-a:valid");
    expect(dashboardDataSource.compareEvaluations).toHaveBeenCalledTimes(1);
    expect(dashboardDataSource.compareEvaluations).toHaveBeenCalledWith(
      ["eval-a"],
      1,
      200
    );
    fireEvent.click(screen.getByRole("button", { name: "Add B twice" }));
    await screen.findByText("eval-a:valid,eval-b:valid");
    expect(
      JSON.parse(localStorage.getItem("evalens.compare-selection") ?? "{}")
    ).toEqual({ version: 1, evalIds: ["eval-a", "eval-b"] });
  });

  it("reuses the resolved hydration response after an empty compare route is seeded", async () => {
    storeSelection("eval-a", "eval-b");
    render(
      <CompareSelectionProvider>
        <Harness />
      </CompareSelectionProvider>
    );
    await screen.findByText("eval-a:valid,eval-b:valid");

    fireEvent.click(screen.getByRole("button", { name: "Load selected comparison" }));

    await screen.findByText("comparison loaded");
    expect(dashboardDataSource.compareEvaluations).toHaveBeenCalledTimes(1);
    expect(dashboardDataSource.compareEvaluations).toHaveBeenCalledWith(
      ["eval-a", "eval-b"],
      1,
      200
    );
  });

  it("rejects a candidate when the loaded catalog has no compatible identity", async () => {
    const incompatible = incompatibleEntry("eval-b");
    render(
      <CompareSelectionProvider>
        <Harness candidates={[entries[0]!, incompatible, entries[2]!]} />
      </CompareSelectionProvider>
    );
    fireEvent.click(screen.getByRole("button", { name: "Add A" }));
    await screen.findByText("eval-a:valid");
    fireEvent.click(screen.getByRole("button", { name: "Add B twice" }));
    await screen.findByText(/Aggregate dataset name or digest differs/);
    expect(screen.getByTestId("selection")).toHaveTextContent("eval-a:valid");
    expect(screen.getByTestId("selection")).not.toHaveTextContent("eval-b");
    expect(dashboardDataSource.compareEvaluations).not.toHaveBeenCalled();
  });

  it("rejects an incompatible persisted group atomically", async () => {
    const incompatible = incompatibleEntry("eval-b");
    vi.mocked(dashboardDataSource.compareEvaluations).mockResolvedValue({
      ...comparisonFor([]),
      evaluations: [
        { ...entries[0]!, items: [] },
        { ...incompatible, items: [] },
      ],
    });
    storeSelection("eval-a", "eval-b");
    render(
      <CompareSelectionProvider>
        <Harness />
      </CompareSelectionProvider>
    );

    await waitFor(() => expect(screen.getByTestId("selection")).toBeEmptyDOMElement());
    expect(dashboardDataSource.compareEvaluations).toHaveBeenCalledTimes(1);
  });

  it("serializes concurrent additions and revalidates against latest state", async () => {
    render(
      <CompareSelectionProvider>
        <Harness candidates={[entries[0]!, entries[1]!, incompatibleEntry("eval-c")]} />
      </CompareSelectionProvider>
    );
    fireEvent.click(screen.getByRole("button", { name: "Add A" }));
    await screen.findByText("eval-a:valid");
    fireEvent.click(screen.getByRole("button", { name: "Add B and C" }));

    await screen.findByText("eval-a:valid,eval-b:valid");
    expect(screen.getByTestId("selection")).not.toHaveTextContent("eval-c");
  });

  it("waits for persisted hydration before validating an add", async () => {
    const pending = Promise.withResolvers<EvalComparison>();
    vi.mocked(dashboardDataSource.compareEvaluations).mockReturnValue(pending.promise);
    storeSelection("eval-a");
    render(
      <CompareSelectionProvider>
        <Harness />
      </CompareSelectionProvider>
    );

    fireEvent.click(screen.getByRole("button", { name: "Add B once" }));
    expect(screen.getByTestId("selection")).toHaveTextContent("eval-a:loading");
    pending.resolve(comparisonFor(["eval-a"]));

    await screen.findByText("eval-a:valid,eval-b:valid");
  });

  it("does not resurrect an add after clear", async () => {
    const pending = Promise.withResolvers<EvalComparison>();
    vi.mocked(dashboardDataSource.compareEvaluations).mockReturnValue(pending.promise);
    storeSelection("eval-a");
    render(
      <CompareSelectionProvider>
        <Harness />
      </CompareSelectionProvider>
    );

    fireEvent.click(screen.getByRole("button", { name: "Add B once" }));
    fireEvent.click(screen.getByRole("button", { name: "Clear" }));
    pending.resolve(comparisonFor(["eval-a"]));

    await screen.findByText(/selection changed/i);
    expect(screen.getByTestId("selection")).toHaveTextContent("");
    expect(screen.getByTestId("selection")).not.toHaveTextContent("eval-b");
  });

  it("does not commit an add across URL replacement", async () => {
    const pending = Promise.withResolvers<EvalComparison>();
    vi.mocked(dashboardDataSource.compareEvaluations).mockImplementation((ids) =>
      ids.includes("eval-a") ? pending.promise : Promise.resolve(comparisonFor(ids))
    );
    storeSelection("eval-a");
    render(
      <CompareSelectionProvider>
        <Harness />
      </CompareSelectionProvider>
    );

    fireEvent.click(screen.getByRole("button", { name: "Add B once" }));
    fireEvent.click(screen.getByRole("button", { name: "Replace from URL" }));
    pending.resolve(comparisonFor(["eval-a"]));

    await screen.findByText("eval-c:valid");
    expect(screen.getByTestId("selection")).not.toHaveTextContent("eval-b");
    expect(screen.getByText(/selection changed/i)).toBeVisible();
  });

  it("revalidates reused and newly loaded URL entries as one group", async () => {
    const incompatible = incompatibleEntry("eval-c");
    vi.mocked(dashboardDataSource.compareEvaluations).mockImplementation(
      async (ids) => ({
        ...comparisonFor([]),
        evaluations: [entries[0]!, incompatible]
          .filter(({ id }) => ids.includes(id))
          .map((candidate) => ({ ...candidate, items: [] })),
      })
    );
    storeSelection("eval-a");
    render(
      <CompareSelectionProvider>
        <Harness candidates={[entries[0]!, entries[1]!, incompatible]} />
      </CompareSelectionProvider>
    );
    await screen.findByText("eval-a:valid");

    fireEvent.click(screen.getByRole("button", { name: "Replace mixed from URL" }));

    await waitFor(() => expect(screen.getByTestId("selection")).toBeEmptyDOMElement());
  });

  it("supports tray ordering, removal, clearing, and compare CTA state", async () => {
    storeSelection("eval-a", "eval-b");
    render(
      <CompareSelectionProvider>
        <CompareTray />
      </CompareSelectionProvider>
    );
    await waitFor(() =>
      expect(screen.getByRole("link", { name: /Compare/ })).toHaveAttribute(
        "data-search",
        expect.stringContaining("eval-a")
      )
    );
    fireEvent.click(screen.getByLabelText("Move eval-b earlier"));
    expect(screen.getByRole("link", { name: /Compare/ })).toHaveAttribute(
      "data-search",
      expect.stringMatching(/eval-b.*eval-a/)
    );
    fireEvent.click(screen.getByLabelText("Remove eval-a from comparison"));
    expect(screen.getByRole("button", { name: /Compare/ })).toBeDisabled();
    expect(screen.getByText("Select one more evaluation.")).toBeVisible();
    fireEvent.click(screen.getByLabelText("Clear selected evaluations"));
    expect(
      screen.queryByLabelText("Selected evaluations for comparison")
    ).not.toBeInTheDocument();
  });
});

function Harness({ candidates = entries }: { candidates?: EvalCatalogEntry[] }) {
  const { selected, add, clear, replaceFromUrl, loadComparison } =
    useCompareSelection();
  const [message, setMessage] = useState("");
  const addWithMessage = (entry: EvalCatalogEntry) =>
    void add(entry).then((result) => {
      if (!result.ok) setMessage(result.message);
    });
  return (
    <div>
      <span data-testid="selection">
        {selected.map(({ id, state }) => `${id}:${state}`).join(",")}
      </span>
      <span>{message}</span>
      <button onClick={() => addWithMessage(candidates[0]!)}>Add A</button>
      <button
        onClick={() => {
          addWithMessage(candidates[1]!);
          void add(candidates[1]!);
        }}
      >
        Add B twice
      </button>
      <button onClick={() => addWithMessage(candidates[1]!)}>Add B once</button>
      <button
        onClick={() => {
          void add(candidates[1]!);
          void add(candidates[2]!);
        }}
      >
        Add B and C
      </button>
      <button onClick={clear}>Clear</button>
      <button onClick={() => replaceFromUrl([candidates[2]!.id])}>
        Replace from URL
      </button>
      <button onClick={() => replaceFromUrl([candidates[0]!.id, candidates[2]!.id])}>
        Replace mixed from URL
      </button>
      <button
        onClick={() =>
          void loadComparison(
            selected.map(({ id }) => id),
            1,
            200
          ).then(() => setMessage("comparison loaded"))
        }
      >
        Load selected comparison
      </button>
    </div>
  );
}

function entry(id: string): EvalCatalogEntry {
  return {
    id,
    status: "finished",
    params: { judge: "gpt-5" },
    aggregatorVersion: "1",
    evaluators: [{ name: "judge", version: "1" }],
    scoreIdentities: [
      { evaluatorName: "judge", evaluatorVersion: "1", scoreKey: "score" },
    ],
    adapters: [],
    aggregateScores: { accuracy: 1 },
    resultCounts: { target: 1, completed: 1, error: 0, skipped: 0 },
    createdAt: "2026-01-01T00:00:00.000Z",
    finishedAt: "2026-01-01T00:01:00.000Z",
    run: {
      id: `run-${id}`,
      experimentName: "basic",
      datasetName: "fixture",
      datasetDigest: "digest",
      datasetSelectionDigest: "digest",
      tags: [],
      params: {},
      createdAt: "2026-01-01T00:00:00.000Z",
    },
  };
}

function incompatibleEntry(id: string): EvalCatalogEntry {
  const candidate = entry(id);
  return {
    ...candidate,
    aggregatorVersion: "2",
    aggregateScores: { quality: 1 },
    run: {
      ...candidate.run,
      datasetDigest: "other-digest",
      datasetSelectionDigest: "other-digest",
    },
  };
}

function storeSelection(...ids: string[]) {
  localStorage.setItem(
    "evalens.compare-selection",
    JSON.stringify({ version: 1, evalIds: ids })
  );
}

function comparisonFor(ids: string[]): EvalComparison {
  return {
    evaluations: entries
      .filter(({ id }) => ids.includes(id))
      .map((candidate) => ({ ...candidate, items: [] })),
    sharedItemCount: 1,
    itemPage: 1,
    itemPageSize: 1,
    itemMetrics: [],
  };
}
