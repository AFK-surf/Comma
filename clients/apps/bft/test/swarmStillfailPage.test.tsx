import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { createBftApi, swarmStillfailSchema, type BftSwarmStillfail } from "../src/api";
import { ApiContext } from "../src/resource";
import { SwarmStillfailPage } from "../src/SwarmStillfailPage";

const baseData: BftSwarmStillfail = swarmStillfailSchema.parse({
  project: { id: "prj_1", name: "Support Desk", role: "admin" },
  days: 30,
  stations: [
    {
      id: "dev_1",
      name: "Hypershell · Tokyo",
      workspace_id: "ws_1",
      connected: true,
      connected_at: Date.UTC(2026, 10, 20, 6, 0),
    },
    {
      id: "dev_2",
      name: "Design · Office Mac",
      workspace_id: "ws_2",
      connected: false,
      connected_at: Date.UTC(2026, 10, 19, 6, 0),
    },
  ],
  tasks: [
    {
      id: "st_1:c-login",
      station_id: "st_1",
      device_id: "dev_1",
      title: "Authorize GitHub CLI",
      url: "https://still.fail/c/c-login",
      status: "needs_review",
      attention: "need",
      note: "Approve gh auth login",
      card_kind: "login",
      waits_for: ["lin@example.com"],
      created_by: "lin@example.com",
      last_activity_at: Date.UTC(2026, 10, 25, 2, 0),
    },
    {
      id: "st_2:c-failed",
      station_id: "st_2",
      device_id: "dev_2",
      title: "Export dark-mode tokens",
      url: "https://still.fail/c/c-failed",
      status: "in_progress",
      attention: "failed",
      note: "429 rate limit",
      card_kind: null,
      waits_for: ["wu@example.com"],
      created_by: "wu@example.com",
      last_activity_at: Date.UTC(2026, 10, 25, 1, 0),
    },
    {
      id: "st_1:c-running",
      station_id: "st_1",
      device_id: "dev_1",
      title: "Profile index latency",
      url: "https://still.fail/c/c-running",
      status: "running",
      attention: null,
      note: null,
      card_kind: null,
      waits_for: [],
      created_by: "maya@example.com",
      last_activity_at: Date.UTC(2026, 10, 25, 2, 30),
    },
    {
      id: "st_1:c-legacy-review",
      station_id: "st_1",
      device_id: "dev_1",
      title: "Legacy station review",
      url: "https://still.fail/c/c-legacy-review",
      status: "needs_review",
      attention: null,
      note: null,
      card_kind: null,
      waits_for: [],
      created_by: "legacy@example.com",
      last_activity_at: Date.UTC(2026, 10, 25, 2, 15),
    },
  ],
  usage: [
    {
      key: "lin@example.com",
      calls: 40,
      input: 1000,
      cache_read: 0,
      cache_write: 0,
      output: 200,
      cost: 1.5,
    },
  ],
});

function renderPage(data: BftSwarmStillfail, api = createBftApi()) {
  render(
    <ApiContext value={api}>
      <SwarmStillfailPage
        first={{ state: "ready", data }}
        onRetry={vi.fn()}
        org="acme"
        project="prj_1"
      />
    </ApiContext>
  );
  return { api, user: userEvent.setup() };
}

describe("SwarmStillfailPage", () => {
  it("defaults tasks to an empty array when parsing responses from older backends", () => {
    const parsed = swarmStillfailSchema.parse({
      project: baseData.project,
      days: 30,
      stations: baseData.stations,
      usage: baseData.usage,
    });
    expect(parsed.tasks).toEqual([]);
  });

  it("shows offline notice, classifies legacy needs_review as waiting for reply, and queries backend by device_id", async () => {
    const api = createBftApi();
    const dev2Task = {
      id: "st_2:c-dev2-extra",
      station_id: "st_2",
      device_id: "dev_2",
      title: "Design workspace backlog task",
      url: "https://still.fail/c/c-dev2-extra",
      status: "needs_review",
      attention: "need",
      note: "Fetched via device_id query",
      card_kind: null,
      waits_for: ["wu@example.com", "maya@example.com"],
      created_by: "wu@example.com",
      last_activity_at: Date.UTC(2026, 10, 25, 2, 40),
    };
    const fetchStillfail = vi.spyOn(api, "swarmStillfail").mockResolvedValue({
      ...baseData,
      tasks: [dev2Task],
    });

    const { user } = renderPage(baseData, api);

    const stationsRegion = within(screen.getByRole("region", { name: "Stations" }));
    expect(
      stationsRegion.getByText(
        "Task status sync and replies are paused for offline workspaces and resume automatically when the station reconnects."
      )
    ).toBeVisible();

    const tasksRegion = within(screen.getByRole("region", { name: "Tasks" }));
    const loginLink = tasksRegion.getByRole("link", { name: "Authorize GitHub CLI" });
    expect(loginLink).toHaveAttribute("href", "https://still.fail/c/c-login");
    expect(loginLink).toHaveAttribute("target", "_blank");
    expect(loginLink).toHaveAttribute("rel", "noopener noreferrer");
    expect(tasksRegion.getByText("Approve gh auth login")).toBeVisible();
    expect(tasksRegion.getByText("Authorization needed")).toBeVisible();
    expect(tasksRegion.getByText("Failed")).toBeVisible();
    expect(tasksRegion.getByText("Running")).toBeVisible();
    expect(tasksRegion.getByText("Waiting for reply")).toBeVisible();
    expect(tasksRegion.getByText("maya@example.com")).toBeVisible();

    // Filter to Design · Office Mac: queries backend with device_id=dev_2.
    await user.click(tasksRegion.getByRole("button", { name: /Tasks workspace$/ }));
    await user.click(screen.getByRole("option", { name: "Design · Office Mac" }));

    expect(fetchStillfail).toHaveBeenCalledWith(
      "acme",
      "prj_1",
      expect.any(AbortSignal),
      "dev_2"
    );
    expect(
      await tasksRegion.findByRole("link", { name: "Design workspace backlog task" })
    ).toBeVisible();
    expect(
      tasksRegion.queryByRole("link", { name: "Authorize GitHub CLI" })
    ).toBeNull();
  });

  it("hides offline notice when all stations are connected and shows quiet empty state when there are no tasks", () => {
    renderPage({
      ...baseData,
      stations: [baseData.stations[0]!],
      tasks: [],
    });

    const stationsRegion = within(screen.getByRole("region", { name: "Stations" }));
    expect(
      stationsRegion.queryByText(/Task status sync and replies are paused/)
    ).toBeNull();

    const tasksRegion = within(screen.getByRole("region", { name: "Tasks" }));
    expect(
      tasksRegion.getByText("No recent Monoid tasks need attention.")
    ).toBeVisible();
    expect(tasksRegion.queryByRole("button", { name: /Tasks workspace$/ })).toBeNull();
  });
});
