defmodule SalixStore.StationStatsIndexTest do
  @moduledoc """
  The Stats index a station sends (`SalixStore.StationStatsIndex`) and its
  analysis (`SalixStore.StationStats`): rows of every source a station gives
  kept by revision as the Task index
  is, added up by person, source, model or day, and the chats listed; a removed
  station's rows go, and so do a removed still.fail station's.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.{StationStats, StationStatsIndex, Stations, StillfailStations}

  @tenant "tnt_stats_index"
  @group "grp_stats_index"

  setup do
    SalixStore.Repo.query!(
      "TRUNCATE salix_stations, salix_station_stats_index, salix_stillfail_stations"
    )

    {:ok, _station, nil} = Stations.admit(@tenant, @group, id(1), %{name: "Mac"})
    {:ok, _station, nil} = Stations.admit(@tenant, @group, id(2), %{name: "Studio"})
    :ok
  end

  defp id(n), do: Base.encode16(<<n::256>>, case: :lower)

  defp usage(source, day, person, model, calls, cost, rev) do
    %{
      "key" => Enum.join([source, "usage", day, person, model], "|"),
      "source" => source,
      "kind" => "usage",
      "rev" => rev,
      "row" => %{
        "day" => day,
        "session" => "s1",
        "person" => person,
        "model" => model,
        "runtime" => "claude",
        "calls" => calls,
        "input" => calls * 100,
        "cacheRead" => calls * 10,
        "cacheWrite" => 0,
        "output" => calls * 5,
        "cost" => cost
      }
    }
  end

  defp task(source, thread, title, active, rev) do
    %{
      "key" => "#{source}|task|#{thread}",
      "source" => source,
      "kind" => "task",
      "rev" => rev,
      "row" => %{
        "thread" => thread,
        "title" => title,
        "state" => "all_done",
        "creator" => "ann@x",
        "createdAt" => 1,
        "lastActiveAt" => active
      }
    }
  end

  defp apply_page(station, rows, opts \\ []) do
    {:ok, s} = Stations.active_station(id(station))

    StationStatsIndex.apply_page(s, "dev_#{station}", %{
      "epoch" => Keyword.get(opts, :epoch, "e1"),
      "reset" => Keyword.get(opts, :reset, false),
      "since" => Keyword.get(opts, :since, 0),
      "through" => Keyword.get(opts, :through, 0),
      "rows" => rows
    })
  end

  test "every source's rows are kept by revision and added up as one" do
    assert {:ok, %{"epoch" => "e1", "through" => 3}} =
             apply_page(
               1,
               [
                 usage("self", "2026-10-28", "ann@x", "claude-opus-5-5", 2, 1.5, 1),
                 usage("stillfail", "2026-10-28", "ann@x", "claude-opus-5-5", 3, 2.0, 2),
                 task("stillfail", 7, "Fix the build", 5_000, 3)
               ],
               reset: true
             )

    assert {:ok, _} =
             apply_page(2, [usage("self", "2026-10-29", "bob@x", "gpt-6", 4, nil, 1)],
               reset: true
             )

    assert {:ok, by_person} = StationStats.usage(@group, "2026-10-28", "2026-10-29", :person)

    assert [
             %{"key" => "ann@x", "calls" => 5, "input" => 500, "cost" => 3.5},
             %{"key" => "bob@x", "calls" => 4}
           ] = by_person

    assert {:ok, by_source} = StationStats.usage(@group, "2026-10-28", "2026-10-28", :source)

    assert Enum.sort_by(by_source, & &1["key"]) |> Enum.map(&{&1["key"], &1["calls"]}) == [
             {"self", 2},
             {"stillfail", 3}
           ]

    assert [%{"source" => "stillfail", "task" => %{"title" => "Fix the build"}}] =
             StationStats.tasks(@group, 1_000)

    assert [] = StationStats.tasks(@group, 6_000)

    # a later revision replaces a row; a tombstone takes it away; a page from before what Salix holds is not applied
    assert {:ok, %{"through" => 5}} =
             apply_page(
               1,
               [
                 usage("self", "2026-10-28", "ann@x", "claude-opus-5-5", 10, 1.5, 4),
                 %{
                   "key" => "stillfail|task|7",
                   "source" => "stillfail",
                   "kind" => "task",
                   "rev" => 5,
                   "removed" => true
                 }
               ],
               since: 3,
               through: 5
             )

    assert {:ok, [%{"calls" => 13}]} =
             StationStats.usage(@group, "2026-10-28", "2026-10-28", :day)

    assert [] = StationStats.tasks(@group)

    assert {:ok, %{"epoch" => "e1", "through" => 5}} =
             apply_page(1, [usage("self", "2026-10-28", "x", "m", 1, 0.1, 9)],
               since: 7,
               through: 9
             )

    assert {:error, :invalid_span} = StationStats.usage(@group, "2026-01-01", "2027-06-01", :day)

    assert {:error, :invalid_grouping} =
             StationStats.usage(@group, "2026-10-28", "2026-10-28", :nonsense)

    assert {:error, :invalid_page} =
             apply_page(1, [
               %{"key" => "k", "source" => "self", "kind" => "other", "rev" => 1, "row" => %{}}
             ])
  end

  test "usage of one source alone" do
    status = %{
      "key" => "stillfail|source",
      "source" => "stillfail",
      "kind" => "source",
      "rev" => 3,
      "row" => %{"source" => "stillfail", "state" => "granted", "at" => 5, "scopes" => ["usage"]}
    }

    assert {:ok, _} =
             apply_page(
               1,
               [
                 usage("self", "2026-10-28", "ann@x", "m", 2, 1.0, 1),
                 usage("stillfail", "2026-10-28", "ann@x", "m", 3, 2.0, 2),
                 status
               ],
               reset: true
             )

    assert {:ok, [%{"key" => "ann@x", "calls" => 3}]} =
             StationStats.usage(@group, "2026-10-28", "2026-10-28", :person, "stillfail")
  end

  test "a removed station's rows go" do
    assert {:ok, _} =
             apply_page(1, [usage("self", "2026-10-28", "ann@x", "m", 2, 1.0, 1)], reset: true)

    assert :ok = Stations.remove(@tenant, @group, id(1))
    assert {:ok, []} = StationStats.usage(@group, "2026-10-28", "2026-10-28", :person)
  end

  test "a still.fail station's pages are held on its own record, counted with the Group's, and go with it" do
    {:ok, station} = StillfailStations.ensure(@tenant, @group, "dev_sf")

    page = fn rows, opts ->
      StationStatsIndex.apply_page(station_now("dev_sf"), "dev_sf", %{
        "epoch" => "sf1",
        "reset" => Keyword.get(opts, :reset, false),
        "since" => Keyword.get(opts, :since, 0),
        "through" => Keyword.get(opts, :through, 0),
        "rows" => rows
      })
    end

    assert station.id == "stillfail-dev_sf"

    assert {:ok, %{"epoch" => "sf1", "through" => 2}} =
             page.(
               [
                 usage("stillfail", "2026-10-28", "ann@x", "m", 3, 2.0, 1),
                 task("stillfail", 7, "Fix", 9, 2)
               ],
               reset: true
             )

    # What it held: a page that continues it applies, one that does not is not.
    assert {:ok, %{"through" => 3}} =
             page.([usage("stillfail", "2026-10-28", "bo@x", "m", 1, 0.5, 3)], since: 2)

    assert {:ok, %{"through" => 3}} =
             page.([usage("stillfail", "2026-10-28", "cy@x", "m", 1, 0.5, 9)], since: 5)

    assert {:ok, rows} =
             StationStats.usage(@group, "2026-10-28", "2026-10-28", :person, "stillfail")

    assert Enum.sort(Enum.map(rows, & &1["key"])) == ["ann@x", "bo@x"]

    assert [%{"station_id" => "stillfail-dev_sf", "source" => "stillfail"}] =
             StationStats.tasks(@group)

    # Another Group's device under the same id is not this record.
    assert {:error, :not_this_group} = StillfailStations.ensure(@tenant, "grp_other", "dev_sf")

    assert :ok = StillfailStations.remove("dev_sf")
    assert {:ok, []} = StationStats.usage(@group, "2026-10-28", "2026-10-28", :person)
    assert [] = StationStats.tasks(@group)
  end

  test "a still.fail workspace's spending added up by Task, of one person, names each Task as its Task index does" do
    {:ok, _station} = StillfailStations.ensure(@tenant, @group, "dev_sf")

    row = fn key, person, thread, station, calls, cost, rev ->
      %{
        "key" => key,
        "source" => "stillfail",
        "kind" => "usage",
        "rev" => rev,
        "row" =>
          %{
            "day" => "2026-11-02",
            "session" => key,
            "thread" => thread,
            "person" => person,
            "model" => "m",
            "runtime" => "claude",
            "calls" => calls,
            "input" => calls,
            "cacheRead" => 0,
            "cacheWrite" => 0,
            "output" => calls,
            "cost" => cost
          }
          |> then(&if(station, do: Map.put(&1, "station", station), else: &1))
      }
    end

    assert {:ok, _} =
             StationStatsIndex.apply_page(station_now("dev_sf"), "dev_sf", %{
               "epoch" => "sf1",
               "reset" => true,
               "since" => 0,
               "through" => 0,
               "rows" => [
                 row.("a", "ann@x", 7, nil, 2, 1.0, 1),
                 row.("b", "ann@x", 7, nil, 1, 0.5, 2),
                 row.("c", "ann@x", 9, "st2", 4, 2.0, 3),
                 row.("d", "bob@x", 7, nil, 8, 4.0, 4),
                 row.("e", "ann@x", nil, nil, 1, 0.25, 5)
               ]
             })

    assert {:ok, rows} =
             StationStats.usage(@group, "2026-11-01", "2026-11-03", :task, "stillfail", "ann@x")

    assert Enum.map(rows, &{&1["key"], &1["calls"], &1["cost"]}) == [
             {"station:stillfail-dev_sf:9@st2", 4, 2.0},
             {"station:stillfail-dev_sf:7", 3, 1.5},
             {nil, 1, 0.25}
           ]

    assert {:ok, [%{"key" => "station:stillfail-dev_sf:7", "calls" => 11}, _, _]} =
             StationStats.usage(@group, "2026-11-01", "2026-11-03", :task)
  end

  defp station_now(device),
    do: SalixStore.Repo.get(StillfailStations.Station, StillfailStations.id(device))
end
