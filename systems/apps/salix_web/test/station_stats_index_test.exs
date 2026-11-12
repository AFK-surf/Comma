defmodule SalixWeb.StationStatsIndexTest do
  @moduledoc """
  A `stats.index` or `task.index` page from a Connector run that proved no
  station key (`SalixWeb.StationStatsIndex`, `SalixWeb.StationTaskIndex`): a
  still.fail device's run sends its workspace's statistics and chats, held on
  its own record; any other device's is refused.
  """
  use SystemsClock.Case, async: false

  alias SalixEnv.Registry
  alias SalixStore.{StationStats, StationTaskIndex}
  alias SalixWeb.StationStatsIndex

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Stats pages"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Stats pages"}, tenant["tenant_id"])
    {:ok, tenant: tenant["tenant_id"], group: group["group_id"]}
  end

  defp connect!(tenant, group, meta) do
    device = "device-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    transport_id = "run-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        Map.merge(
          %{
            "tenant_id" => tenant,
            "group_id" => group,
            "device_id" => device,
            "connector_id" => "connector-" <> transport_id,
            "name" => "Mac"
          },
          meta
        ),
        transport_id: transport_id
      )

    %{
      tenant_id: tenant,
      group_id: group,
      device_id: device,
      connector_run_id: record["connector_run_id"]
    }
  end

  defp page(rows, opts \\ []) do
    %{
      "epoch" => "e1",
      "reset" => Keyword.get(opts, :reset, true),
      "since" => 0,
      "through" => 0,
      "rows" => rows
    }
  end

  defp usage(person, rev) do
    %{
      "key" => "stillfail|usage|#{person}",
      "source" => "stillfail",
      "kind" => "usage",
      "rev" => rev,
      "row" => %{"day" => "2026-11-01", "person" => person, "calls" => 2, "cost" => 0.5}
    }
  end

  test "a still.fail device's pages are its own statistics", %{tenant: tenant, group: group} do
    view = connect!(tenant, group, %{"device_kind" => "stillfail"})

    assert {:ok, %{"epoch" => "e1", "through" => 1}} =
             StationStatsIndex.receive_page(nil, view, page([usage("ann@x", 1)]))

    assert {:ok, [%{"key" => "ann@x", "calls" => 2}]} =
             StationStats.usage(group, "2026-11-01", "2026-11-01", :person, "stillfail")

    # Sent again by the same device: the same record, continued.
    assert {:ok, %{"through" => 2}} =
             StationStatsIndex.receive_page(nil, view, %{
               page([usage("bo@x", 2)], reset: false)
               | "since" => 1
             })
  end

  test "another device's run that proved no station key sends none", %{
    tenant: tenant,
    group: group
  } do
    view = connect!(tenant, group, %{})

    assert {:error, :not_this_group} =
             StationStatsIndex.receive_page(nil, view, page([usage("ann@x", 1)]))

    assert {:ok, []} = StationStats.usage(group, "2026-11-01", "2026-11-01", :person)
  end

  test "a still.fail device's chats are the Group's station-hosted Tasks, until the device goes",
       %{tenant: tenant, group: group} do
    view = connect!(tenant, group, %{"device_kind" => "stillfail"})

    task = %{
      "thread" => "7@st-there",
      "rev" => 1,
      "task" => "7@st-there",
      "title" => "Fix the build",
      "status" => "needs_review",
      "created_by" => "ann@x",
      "created_at" => 1,
      "last_activity_at" => 2
    }

    assert {:ok, %{"epoch" => "e1", "through" => 1}} =
             SalixWeb.StationTaskIndex.receive_page(nil, view, page([task]))

    station_id = "stillfail-" <> view.device_id

    assert [%{station_id: ^station_id, thread: "7@st-there", status: "needs_review"}] =
             StationTaskIndex.list_group(group)

    assert %StationTaskIndex.Row{device_id: device} =
             StationTaskIndex.get(group, station_id, "7@st-there")

    assert device == view.device_id

    assert {:error, :not_this_group} =
             SalixWeb.StationTaskIndex.receive_page(
               nil,
               connect!(tenant, group, %{}),
               page([task])
             )

    assert :ok = SalixStore.StillfailStations.remove(view.device_id)
    assert [] = StationTaskIndex.list_group(group)
  end
end
