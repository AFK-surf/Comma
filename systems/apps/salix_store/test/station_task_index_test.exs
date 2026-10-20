defmodule SalixStore.StationTaskIndexTest do
  @moduledoc """
  The Task index a station sends (`SalixStore.StationTaskIndex`): a reset
  replaces the station's rows, later pages of the same epoch add to them and
  tombstones delete; a page Salix cannot continue from is not applied and
  Salix answers what it holds. Removing or moving the station deletes its
  rows.
  """
  use SystemsClock.Case, async: false

  import Ecto.Query

  alias SalixStore.{Repo, StationTaskIndex, Stations}
  alias SalixStore.StationTaskIndex.Row

  @tenant "tnt_task_index"
  @group "grp_task_index_a"
  @other_group "grp_task_index_b"

  setup do
    Repo.query!("TRUNCATE salix_stations, salix_station_task_index")
    {:ok, station, nil} = Stations.admit(@tenant, @group, id(1), %{name: "Mac"})
    {:ok, station: station}
  end

  defp id(n), do: Base.encode16(<<n::256>>, case: :lower)

  defp row(thread, rev, fields \\ %{}) do
    Map.merge(
      %{
        "thread" => thread,
        "rev" => rev,
        "title" => "Task #{thread}",
        "status" => "in_progress",
        "created_by" => "usr_1",
        "created_at" => 1_000,
        "last_activity_at" => 2_000,
        "runtime" => "codex",
        "model" => "gpt-5.5"
      },
      fields
    )
  end

  defp page(epoch, rows, opts \\ []) do
    %{
      "epoch" => epoch,
      "reset" => Keyword.get(opts, :reset, false),
      "since" => Keyword.get(opts, :since, 0),
      "through" => Keyword.get(opts, :through, 0),
      "rows" => rows
    }
  end

  defp apply_page(page, device \\ "dev_1") do
    {:ok, station} = Stations.active_station(id(1))
    StationTaskIndex.apply_page(station, device, page)
  end

  defp rows(station_id \\ id(1)) do
    Repo.all(from(r in Row, where: r.station_id == ^station_id, order_by: r.thread))
    |> Map.new(&{&1.thread, &1})
  end

  test "a reset replaces the rows; later pages add, update and delete by revision" do
    assert {:ok, %{"epoch" => nil, "through" => 0}} = apply_page(page("e1", []))
    assert rows() == %{}

    assert {:ok, %{"epoch" => "e1", "through" => 2}} =
             apply_page(page("e1", [row("EMBER/1", 1), row("EMBER/2", 2)], reset: true))

    assert %{"EMBER/1" => first, "EMBER/2" => _} = rows()
    assert {first.group_id, first.device_id, first.status} == {@group, "dev_1", "in_progress"}

    # A station from before labels sends none: the Task has none.
    assert first.labels == []

    # A later page of the same epoch: a status change with labels, a new Task, a tombstone.
    later = [
      row("EMBER/1", 3, %{"status" => "needs_review", "labels" => ["lbl_b", "lbl_a", "lbl_b"]}),
      row("EMBER/3", 4),
      %{"thread" => "EMBER/2", "rev" => 5, "removed" => true}
    ]

    assert {:ok, %{"epoch" => "e1", "through" => 5}} =
             apply_page(page("e1", later, since: 2, through: 5), "dev_2")

    held = rows()
    assert Map.keys(held) == ["EMBER/1", "EMBER/3"]
    assert {held["EMBER/1"].status, held["EMBER/1"].rev} == {"needs_review", 3}
    assert held["EMBER/1"].labels == ["lbl_a", "lbl_b"]
    # Salix stamps the Device of the run each page came on.
    assert held["EMBER/3"].device_id == "dev_2"

    # A page sent again after Salix held it changes nothing: the removed
    # Task does not come back.
    assert {:ok, %{"through" => 5}} =
             apply_page(page("e1", [row("EMBER/2", 2), row("EMBER/1", 1)], through: 2))

    assert Map.keys(rows()) == ["EMBER/1", "EMBER/3"]
    assert rows()["EMBER/1"].status == "needs_review"

    # A reset with a new epoch replaces every row.
    assert {:ok, %{"epoch" => "e2", "through" => 1}} =
             apply_page(page("e2", [row("EMBER/9", 1)], reset: true))

    assert Map.keys(rows()) == ["EMBER/9"]
  end

  test "a page Salix cannot continue from is not applied, and Salix says what it holds" do
    {:ok, _} = apply_page(page("e1", [row("EMBER/1", 1)], reset: true))

    # Another epoch without a reset: the station must send all of it again.
    assert {:ok, %{"epoch" => "e1", "through" => 1}} =
             apply_page(page("e2", [row("EMBER/2", 2)], since: 1))

    # A gap: it starts after what Salix holds.
    assert {:ok, %{"epoch" => "e1", "through" => 1}} =
             apply_page(page("e1", [row("EMBER/3", 5)], since: 4))

    assert Map.keys(rows()) == ["EMBER/1"]
  end

  test "pages are bounded and carry no participant threads" do
    many = for n <- 1..(StationTaskIndex.max_page_rows() + 1), do: row("EMBER/#{n}", n)
    assert {:error, :page_too_large} = apply_page(page("e1", many, reset: true))

    long = String.duplicate("x", 400)
    big = for n <- 1..180, do: row("EMBER/#{n}", n, %{"title" => long})
    assert {:error, :page_too_large} = apply_page(page("e1", big, reset: true))

    # Another station's Task this station only takes part in.
    assert {:error, :invalid_page} = apply_page(page("e1", [row("TASK/1", 1)], reset: true))

    too_many_labels = for n <- 1..21, do: "lbl_#{n}"

    assert {:error, :invalid_page} =
             apply_page(
               page("e1", [row("EMBER/1", 1, %{"labels" => too_many_labels})], reset: true)
             )

    assert {:error, :invalid_page} =
             apply_page(page("e1", [row("EMBER/1", 1, %{"status" => "x"})]))

    assert {:error, :invalid_page} = apply_page(%{"rows" => []})

    # A title is cut to 120 characters.
    {:ok, _} = apply_page(page("e1", [row("EMBER/1", 1, %{"title" => long})], reset: true))
    assert String.length(rows()["EMBER/1"].title) == 120
  end

  test "a station holds at most max_rows Tasks" do
    now = SystemsClock.timestamp(:utc_datetime_usec)

    1..StationTaskIndex.max_rows()
    |> Enum.chunk_every(2_000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(
        Row,
        for n <- chunk do
          %{
            station_id: id(1),
            thread: "EMBER/#{n}",
            tenant_id: @tenant,
            group_id: @group,
            task: "EMBER/#{n}",
            title: "t",
            status: "done",
            created_at: 0,
            last_activity_at: 0,
            rev: n,
            inserted_at: now,
            updated_at: now
          }
        end
      )
    end)

    Repo.update_all(from(s in Stations.Station, where: s.id == ^id(1)),
      set: [index_epoch: "e1", index_through: StationTaskIndex.max_rows()]
    )

    since = StationTaskIndex.max_rows()

    assert {:error, :too_many_tasks} =
             apply_page(page("e1", [row("EMBER/new", since + 1)], since: since))

    # An update of a held Task still applies.
    assert {:ok, _} =
             apply_page(page("e1", [row("EMBER/1", since + 1)], since: since))
  end

  test "a Group lists its stations' Tasks, the latest activity first" do
    {:ok, _} =
      apply_page(
        page(
          "e1",
          [
            row("EMBER/1", 1, %{"last_activity_at" => 3_000}),
            row("EMBER/2", 2, %{"last_activity_at" => 5_000, "status" => "needs_review"})
          ],
          reset: true
        )
      )

    {:ok, _other, nil} = Stations.admit(@tenant, @other_group, id(2))
    {:ok, other} = Stations.active_station(id(2))

    {:ok, _} =
      StationTaskIndex.apply_page(other, "dev_2", page("e1", [row("EMBER/9", 1)], reset: true))

    assert [
             %{
               thread: "EMBER/2",
               status: "needs_review",
               device_id: "dev_1",
               last_activity_at: 5_000
             },
             %{thread: "EMBER/1", station_id: station_id, last_activity_at: 3_000}
           ] = StationTaskIndex.list_group(@group)

    assert station_id == id(1)
    assert [%{thread: "EMBER/2"}] = StationTaskIndex.list_group(@group, 1)
  end

  test "removing a station, moving it or replacing the Cloud VM station deletes its rows" do
    {:ok, _} = apply_page(page("e1", [row("EMBER/1", 1)], reset: true))
    assert :ok = Stations.remove(@tenant, @group, id(1))
    assert rows() == %{}
    assert {:error, :not_found} = Stations.remove(@tenant, @group, id(1))

    # Back afresh: Salix holds nothing of it, so it sends a reset.
    {:ok, station, nil} = Stations.admit(@tenant, @group, id(1))
    assert StationTaskIndex.held(station) == %{"epoch" => nil, "through" => 0}
    {:ok, _} = apply_page(page("e1", [row("EMBER/1", 1)], reset: true))

    {:ok, moved, {@tenant, @group}} = Stations.admit(@tenant, @other_group, id(1))
    assert rows() == %{}
    assert StationTaskIndex.held(moved) == %{"epoch" => nil, "through" => 0}

    {:ok, _vm, nil} = Stations.place_cloud_station(@tenant, @group, id(2), nil, nil)
    {:ok, vm} = Stations.active_station(id(2))

    {:ok, _} =
      StationTaskIndex.apply_page(vm, "dev_vm", page("e1", [row("EMBER/1", 1)], reset: true))

    assert map_size(rows(id(2))) == 1

    {:ok, _vm, replaced} = Stations.place_cloud_station(@tenant, @group, id(3), id(2), nil)
    assert replaced == id(2)
    assert rows(id(2)) == %{}
  end
end
