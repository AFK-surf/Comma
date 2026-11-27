defmodule BridgeForTeamsWeb.DashboardSwarmStillfailTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Projects
  alias BridgeForTeams.Salix.Reconciler

  @now ~U[2026-11-25 03:00:00.000000Z]

  defmodule FakeStillfailClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def stillfail_stations(_group_id) do
      {:ok,
       [
         %{
           "id" => "dev_1",
           "name" => "Hypershell · Tokyo",
           "workspace_id" => "ws_1",
           "connected" => true,
           "connected_at" => DateTime.to_unix(~U[2026-11-24 10:00:00Z], :millisecond)
         },
         %{
           "id" => "dev_2",
           "name" => "Design · Office Mac",
           "workspace_id" => "ws_2",
           "connected" => false,
           "connected_at" => DateTime.to_unix(~U[2026-11-23 10:00:00Z], :millisecond)
         }
       ]}
    end

    def station_usage(_group_id, _from, _to, _by, _source, _device) do
      {:ok, []}
    end

    def daily_brief_station_tasks(_group_id) do
      SystemsRuntime.get_env(:bridge_for_teams_core, :stillfail_page_test_tasks, {:ok, []})
    end
  end

  setup %{conn: conn} do
    :ok = SystemsClock.manual(epoch: @now)
    on_exit(&SystemsClock.reset/0)

    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Ops", "slug" => "ops"})
    drain_all()

    with_client(FakeStillfailClient)

    on_exit(fn ->
      SystemsRuntime.delete_env(:bridge_for_teams_core, :stillfail_page_test_tasks)
    end)

    %{conn: conn, user: user, org: org, project: project}
  end

  test "returns tasks sorted by priority, filtered by https URL and 24h active window, and capped at 50",
       %{conn: conn, org: org, project: project} do
    now_ms = DateTime.to_unix(@now, :millisecond)

    rows = [
      # Active running task within 24h (rank 4)
      %{
        station_id: "st_1",
        device_id: "dev_1",
        thread: "c-running",
        title: "Running build",
        url: "https://still.fail/c/c-running",
        status: "running",
        attention: nil,
        note: "Compiling",
        labels: [],
        waits_for: [],
        created_by: "alice@example.test",
        last_activity_at: now_ms - 60_000
      },
      # Stale active task >24h ago with no attention -> excluded
      %{
        station_id: "st_1",
        device_id: "dev_1",
        thread: "c-stale-running",
        title: "Old running",
        url: "https://still.fail/c/c-stale-running",
        status: "running",
        attention: nil,
        labels: [],
        waits_for: [],
        created_by: "alice@example.test",
        last_activity_at: now_ms - 25 * 3_600_000
      },
      # Invalid URL -> excluded
      %{
        station_id: "st_1",
        device_id: "dev_1",
        thread: "c-http",
        title: "Insecure URL",
        url: "http://still.fail/c/c-http",
        status: "needs_review",
        attention: "need",
        labels: ["card:login"],
        waits_for: ["alice@example.test"],
        last_activity_at: now_ms - 10_000
      },
      # Done task (rank 3)
      %{
        station_id: "st_1",
        device_id: "dev_1",
        thread: "c-done",
        title: "Finished deploy",
        url: "https://still.fail/c/c-done",
        status: "done",
        attention: "done",
        note: "Merged",
        labels: [],
        waits_for: ["bob@example.test"],
        created_by: "bob@example.test",
        last_activity_at: now_ms - 5_000
      },
      # Failed task (rank 2)
      %{
        station_id: "st_2",
        device_id: "dev_2",
        thread: "c-failed",
        title: "Failed export",
        url: "https://still.fail/c/c-failed",
        status: "in_progress",
        attention: "failed",
        note: "429 rate limit",
        labels: [],
        waits_for: ["wu@example.test"],
        created_by: "wu@example.test",
        last_activity_at: now_ms - 20_000
      },
      # Ordinary need task (rank 1)
      %{
        station_id: "st_1",
        device_id: "dev_1",
        thread: "c-need",
        title: "Pick target",
        url: "https://still.fail/c/c-need",
        status: "needs_review",
        attention: "need",
        note: "Staging or Prod",
        labels: ["card:options"],
        waits_for: ["alice@example.test"],
        created_by: "alice@example.test",
        last_activity_at: now_ms - 30_000
      },
      # Legacy station without attention field but status needs_review (rank 1)
      %{
        station_id: "st_1",
        device_id: "dev_1",
        thread: "c-legacy-review",
        title: "Legacy review",
        url: "https://still.fail/c/c-legacy-review",
        status: "needs_review",
        attention: nil,
        note: nil,
        labels: [],
        waits_for: [],
        created_by: "legacy@example.test",
        last_activity_at: now_ms - 40_000
      },
      # System auth card need (rank 0)
      %{
        station_id: "st_1",
        device_id: "dev_1",
        thread: "c-login",
        title: "Login required",
        url: "https://still.fail/c/c-login",
        status: "needs_review",
        attention: "need",
        note: "gh auth login",
        labels: ["card:login"],
        waits_for: ["lin@example.test"],
        created_by: "lin@example.test",
        last_activity_at: now_ms - 120_000
      }
    ]

    SystemsRuntime.put_env(:bridge_for_teams_core, :stillfail_page_test_tasks, {:ok, rows})

    data = conn |> get(swarm_path(org, project, "/stillfail")) |> json_response(200) |> data()
    tasks = data["tasks"]

    assert Enum.map(tasks, & &1["id"]) == [
             "st_1:c-login",
             "st_1:c-need",
             "st_1:c-legacy-review",
             "st_2:c-failed",
             "st_1:c-done",
             "st_1:c-running"
           ]

    [login_task | _] = tasks

    assert login_task == %{
             "id" => "st_1:c-login",
             "station_id" => "st_1",
             "device_id" => "dev_1",
             "title" => "Login required",
             "url" => "https://still.fail/c/c-login",
             "status" => "needs_review",
             "attention" => "need",
             "note" => "gh auth login",
             "card_kind" => "login",
             "waits_for" => ["lin@example.test"],
             "created_by" => "lin@example.test",
             "last_activity_at" => now_ms - 120_000
           }

    # Filtering by device_id returns only that station's tasks.
    filtered =
      conn
      |> get(swarm_path(org, project, "/stillfail?device_id=dev_2"))
      |> json_response(200)
      |> data()

    assert Enum.map(filtered["tasks"], & &1["id"]) == ["st_2:c-failed"]

    # Cap at 50 tasks.
    many_rows =
      for i <- 1..60 do
        %{
          station_id: "st_1",
          device_id: "dev_1",
          thread: "c-done-#{i}",
          title: "Done #{i}",
          url: "https://still.fail/c/c-done-#{i}",
          status: "done",
          attention: "done",
          labels: [],
          waits_for: [],
          last_activity_at: now_ms - i * 1_000
        }
      end

    SystemsRuntime.put_env(:bridge_for_teams_core, :stillfail_page_test_tasks, {:ok, many_rows})

    capped = conn |> get(swarm_path(org, project, "/stillfail")) |> json_response(200) |> data()
    assert length(capped["tasks"]) == 50
    assert hd(capped["tasks"])["id"] == "st_1:c-done-1"
  end

  test "degrades tasks to empty list without failing the page when Salix task index is unsupported or unavailable",
       %{conn: conn, org: org, project: project} do
    for error <- [{:error, :unsupported}, {:error, :unavailable}] do
      SystemsRuntime.put_env(:bridge_for_teams_core, :stillfail_page_test_tasks, error)

      data = conn |> get(swarm_path(org, project, "/stillfail")) |> json_response(200) |> data()
      assert data["tasks"] == []
      assert length(data["stations"]) == 2
    end
  end

  defp swarm_path(org, project, suffix),
    do: "/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}#{suffix}"

  defp data(%{"ok" => true, "data" => payload}), do: payload

  defp with_client(client) do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, client)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)
    end)
  end

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end
end
