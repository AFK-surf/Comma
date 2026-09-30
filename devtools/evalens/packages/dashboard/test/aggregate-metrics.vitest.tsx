import { screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";

import { AggregateMetrics, groupMetrics } from "../src/components/AggregateMetrics";
import { render } from "./render";

const scores = {
  accumulation_loss_preprovisioned_worker: 0,
  accumulation_loss_router_only: 0,
  delegation_preprovisioned_worker_accumulated: 0,
  delegation_preprovisioned_worker_fresh: 0,
  pollution_router_only_fresh: 0,
  tokens_router_only_accumulated: 20_019,
  tokens_router_only_fresh: 19_339.5,
  worker_created_router_only_fresh: 0,
  worker_delta_fresh: 0,
};

describe("AggregateMetrics", () => {
  it("groups score keys into readable metric families", () => {
    const groups = groupMetrics(scores);

    expect(groups.map((group) => group.title)).toEqual([
      "Accumulation loss",
      "Delegation preprovisioned",
      "Pollution",
      "Tokens router",
      "Worker",
    ]);
    expect(groups[0]?.metrics.map((metric) => metric.label)).toEqual([
      "Preprovisioned worker",
      "Router only",
    ]);
    expect(groups.at(-1)?.metrics.map((metric) => metric.label)).toEqual([
      "Created router only fresh",
      "Delta fresh",
    ]);
  });

  it("filters by the original metric key without hiding values", async () => {
    const user = userEvent.setup();
    render(<AggregateMetrics scores={scores} />);

    expect(screen.getByText("9 metrics")).toBeInTheDocument();
    await user.type(screen.getByRole("textbox", { name: "Metric name" }), "tokens");

    expect(screen.getByText("9 metrics", { exact: false })).toHaveTextContent(
      "9 metrics · 2 shown"
    );
    expect(screen.getByText("20,019")).toBeInTheDocument();
    expect(screen.queryByText("Accumulation loss")).not.toBeInTheDocument();
  });
});
