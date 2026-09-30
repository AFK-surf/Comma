import { screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { describe, expect, test } from "vitest";
import {
  TrajectoryViewer,
  type TrajectoryViewState,
} from "../src/trajectory/TrajectoryViewer";
import { parseTrajectories } from "../src/trajectory/model";
import { render } from "./render";

const raw = [
  {
    id: "router",
    steps: [
      {
        type: "user",
        content: "find this needle",
        timestamp: "2026-07-11T00:00:01.000Z",
      },
    ],
  },
  {
    id: "worker",
    steps: [
      {
        type: "assistant",
        content: "another event",
        timestamp: "2026-07-11T00:00:02.000Z",
      },
    ],
  },
];

function Harness() {
  const [state, setState] = useState<TrajectoryViewState>({
    mode: "merged",
    lanes: ["router", "worker"],
    query: "",
    matchesOnly: false,
    raw: false,
  });
  return (
    <>
      <output data-testid="state">{JSON.stringify(state)}</output>
      <TrajectoryViewer
        parsed={parseTrajectories(raw)}
        rawValue={raw}
        state={state}
        onStateChange={setState}
      />
    </>
  );
}

describe("TrajectoryViewer state", () => {
  test("switches grouped/merged, lanes, search, matches-only, and raw state", async () => {
    const user = userEvent.setup();
    render(<Harness />);

    expect(screen.getByTestId("state")).toHaveTextContent('"mode":"merged"');
    await user.click(screen.getByRole("button", { name: "Grouped" }));
    expect(screen.getByTestId("state")).toHaveTextContent('"mode":"grouped"');

    await user.click(screen.getByRole("button", { name: "Merged timeline" }));
    await user.click(screen.getByLabelText(/worker/));
    expect(screen.getByTestId("state")).toHaveTextContent('"lanes":["router"]');

    await user.type(
      screen.getByLabelText("Search messages, tools, data, models, or trajectory IDs"),
      "needle"
    );
    await user.click(screen.getByText("Only show matches"));
    expect(screen.getByTestId("state")).toHaveTextContent('"query":"needle"');
    expect(screen.getByTestId("state")).toHaveTextContent('"matchesOnly":true');
    expect(document.querySelectorAll(".trajectory-event")).toHaveLength(1);

    await user.click(screen.getByRole("button", { name: "Raw JSON" }));
    expect(screen.getByTestId("state")).toHaveTextContent('"raw":true');
    expect(screen.getByText(/find this needle/)).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Structured view" }));
    expect(screen.getByTestId("state")).toHaveTextContent('"raw":false');
    expect(
      screen.getByLabelText("Search messages, tools, data, models, or trajectory IDs")
    ).toHaveValue("needle");
  });
});
