import { render, renderHook, screen, waitFor } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import type { CommaApiClient, CommaTaskLabelCatalog } from "../../../api";
import { TaskBadgeChips, useTaskBadges } from "../useTaskBadges";

const GROUP = "grp_badges";
const work = { color: "blue", id: "lbl_work", name: "Work" };
const catalog = (labels = [work]): CommaTaskLabelCatalog => ({
  approval_policy: "ask",
  colors: [],
  labels,
  proposals: [],
});
const tasksOf = (count: number, labels: string[] = []) =>
  Array.from({ length: count }, (_, index) => ({
    conversationId: `task-${index + 1}`,
    labels,
  }));

function stubApi(listTaskLabels = vi.fn(async () => catalog())) {
  const getTaskSummaries = vi.fn();
  return {
    api: {
      listTaskLabels,
      getTaskSummaries,
    } as Partial<CommaApiClient> as CommaApiClient,
    listTaskLabels,
    getTaskSummaries,
  };
}

describe("useTaskBadges", () => {
  it("uses projected membership for every loaded task, including same-timestamp changes", async () => {
    const { api, getTaskSummaries } = stubApi();
    const initialTasks = tasksOf(60);
    initialTasks[54]!.labels = ["lbl_work"];
    const { result, rerender } = renderHook(
      ({ tasks }) => useTaskBadges(api, GROUP, tasks),
      { initialProps: { tasks: initialTasks } }
    );
    expect(result.current.metaById.size).toBe(60);
    expect(result.current.metaById.get("task-55")?.labels).toEqual(["lbl_work"]);
    expect(result.current.metaById.get("task-1")?.labels).toEqual([]);
    rerender({ tasks: tasksOf(60) });
    expect(result.current.metaById.get("task-55")?.labels).toEqual([]);
    await waitFor(() => expect(result.current.catalog).toBeDefined());
    expect(getTaskSummaries).not.toHaveBeenCalled();
  });

  it("shows origin while the catalog is unavailable and leaves old-cache membership unknown", () => {
    const listTaskLabels = vi.fn(
      () => new Promise<ReturnType<typeof catalog>>(() => {})
    );
    const { api, getTaskSummaries } = stubApi(listTaskLabels);
    function Card() {
      const badges = useTaskBadges(api, GROUP, [{ conversationId: "task-1" }]);
      expect(badges.metaById.has("task-1")).toBe(false);
      return (
        <>{badges.renderTaskBadges({ conversationId: "task-1", origin: "comma" })}</>
      );
    }
    render(<Card />);
    expect(screen.getByTestId("task-card-platform")).toHaveTextContent("Comma");
    expect(getTaskSummaries).not.toHaveBeenCalled();
  });

  it("wears the channel's own mark on the platform chip", () => {
    render(<TaskBadgeChips labels={[]} origin="wechat" />);
    const chip = screen.getByTestId("task-card-platform");
    expect(chip).toHaveTextContent("WeChat");
    // The chip names the channel with its own mark, not with the label alone.
    expect(chip.querySelector("svg[data-comma-icon]")).not.toBeNull();
  });

  it("refreshes the catalog for changed membership but not ordinary task updates", async () => {
    let labels = [work];
    const listTaskLabels = vi.fn(async () => catalog(labels));
    const { api, getTaskSummaries } = stubApi(listTaskLabels);
    function Cards({ ids, origin }: { ids: string[]; origin: string }) {
      const badges = useTaskBadges(api, GROUP, tasksOf(60, ids));
      return <>{badges.renderTaskBadges({ conversationId: "task-60", origin })}</>;
    }
    const { rerender } = render(<Cards ids={["lbl_work"]} origin="slack" />);
    expect(await screen.findByText("Work")).toBeVisible();
    expect(listTaskLabels).toHaveBeenCalledTimes(1);
    labels = [...labels, { id: "lbl_new", color: "orange", name: "Release" }];
    const ids = ["lbl_work", "lbl_new", "lbl_deleted"];
    rerender(<Cards ids={ids} origin="slack" />);
    expect(await screen.findByText("Release")).toBeVisible();
    expect(listTaskLabels).toHaveBeenCalledTimes(2);
    rerender(<Cards ids={[...ids]} origin="telegram" />);
    expect(screen.getByText("Telegram")).toBeVisible();
    expect(screen.getByText("Release")).toBeVisible();
    expect(screen.queryByText("lbl_deleted")).toBeNull();
    expect(listTaskLabels).toHaveBeenCalledTimes(2);
    expect(getTaskSummaries).not.toHaveBeenCalled();
  });

  it("keeps known chips after catalog refresh failure without retrying unchanged membership", async () => {
    const { api, listTaskLabels } = stubApi();
    function Card({ ids, origin }: { ids: string[]; origin: string }) {
      const badges = useTaskBadges(api, GROUP, tasksOf(1, ids));
      return <>{badges.renderTaskBadges({ conversationId: "task-1", origin })}</>;
    }
    const { rerender } = render(<Card ids={["lbl_work"]} origin="slack" />);
    expect(await screen.findByText("Work")).toBeVisible();
    listTaskLabels.mockRejectedValue(new Error("catalog unavailable"));
    rerender(<Card ids={["lbl_work", "lbl_new"]} origin="slack" />);
    await waitFor(() => expect(listTaskLabels).toHaveBeenCalledTimes(2));
    expect(screen.getByText("Work")).toBeVisible();
    expect(screen.queryByText("lbl_new")).toBeNull();
    rerender(<Card ids={["lbl_work", "lbl_new"]} origin="telegram" />);
    expect(screen.getByText("Telegram")).toBeVisible();
    expect(screen.getByText("Work")).toBeVisible();
    expect(listTaskLabels).toHaveBeenCalledTimes(2);
  });
});
