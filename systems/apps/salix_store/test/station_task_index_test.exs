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

  test "a row says what its chat asks of whom, within bounds; a station from before says nothing" do
    asks = %{
      "attention" => "need",
      "waits_for" => ["Ann@X", "bob@x", "ann@x"],
      "note" => "  " <> String.duplicate("n", 310),
      "url" => "https://still.fail/c/1"
    }

    {:ok, _} =
      apply_page(page("e1", [row("EMBER/1", 1, asks), row("EMBER/2", 2)], reset: true))

    held = rows()

    assert {held["EMBER/1"].attention, held["EMBER/1"].waits_for, held["EMBER/1"].url} ==
             {"need", ["ann@x", "bob@x"], "https://still.fail/c/1"}

    # A note is cut to 300 characters, as a title is cut.
    assert held["EMBER/1"].note == String.duplicate("n", 300)

    assert {held["EMBER/2"].attention, held["EMBER/2"].waits_for, held["EMBER/2"].note,
            held["EMBER/2"].url} == {nil, [], nil, nil}

    # A later revision that asks nothing any more clears what the row said.
    {:ok, _} = apply_page(page("e1", [row("EMBER/1", 3)], since: 2))
    assert {rows()["EMBER/1"].attention, rows()["EMBER/1"].waits_for} == {nil, []}

    nine = for n <- 1..9, do: "p#{n}@x"

    for bad <- [
          %{"attention" => "waiting"},
          %{"waits_for" => nine},
          %{"waits_for" => [String.duplicate("a", 199) <> "@x"]},
          %{"waits_for" => "ann@x"},
          %{"note" => 7},
          %{"url" => "http://still.fail/c/1"},
          %{"url" => "https://" <> String.duplicate("u", 493)}
        ] do
      assert {:error, :invalid_page} =
               apply_page(page("e1", [row("EMBER/1", 1, bad)], reset: true)),
             inspect(bad)
    end
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

  test "a Group's Tasks a page at a time, by creator, status, attention, time and source, each page after the last" do
    Repo.query!("TRUNCATE salix_stillfail_stations")

    {:ok, _} =
      apply_page(
        page(
          "e1",
          [
            row("EMBER/1", 1, %{"last_activity_at" => 3_000, "created_by" => "ann@x"}),
            row("EMBER/2", 2, %{
              "last_activity_at" => 5_000,
              "created_by" => "bob@x",
              "attention" => "done",
              "waits_for" => ["Ann@X"]
            }),
            row("EMBER/3", 3, %{
              "last_activity_at" => 5_000,
              "created_by" => "ann@x",
              "status" => "done"
            })
          ],
          reset: true
        )
      )

    {:ok, sf} = SalixStore.StillfailStations.ensure(@tenant, @group, "dev_sf")

    {:ok, _} =
      StationTaskIndex.apply_page(
        sf,
        "dev_sf",
        page(
          "s1",
          [
            row("7", 1, %{
              "last_activity_at" => 4_000,
              "title" => "社区 APP 的 MVP",
              "note" => "Waiting for the 100% design review"
            })
          ],
          reset: true
        )
      )

    page_of = fn opts ->
      {rows, more?} = StationTaskIndex.page_group(@group, opts)
      {Enum.map(rows, & &1.thread), more?}
    end

    assert page_of.(limit: 2) == {["EMBER/2", "EMBER/3"], true}
    {[_, last], true} = StationTaskIndex.page_group(@group, limit: 2)

    assert page_of.(limit: 2, after: {last.last_activity_at, last.station_id, last.thread}) ==
             {["7", "EMBER/1"], false}

    assert page_of.(created_by: "ann@x") == {["EMBER/3", "EMBER/1"], false}
    assert page_of.(status: "done") == {["EMBER/3"], false}
    # Who a chat waits for is not who made it.
    assert page_of.(waits_for: "ANN@x") == {["EMBER/2"], false}
    assert page_of.(attention: "done") == {["EMBER/2"], false}
    assert page_of.(attention: "need") == {[], false}
    assert page_of.(since: 4_500) == {["EMBER/2", "EMBER/3"], false}
    assert page_of.(source: "stillfail") == {["7"], false}
    # One still.fail workspace's chats, by its device.
    assert page_of.(device_id: "dev_sf") == {["7"], false}
    assert page_of.(device_id: "dev_other") == {[], false}
    # Words of a title or a note, any case; LIKE's wildcards are only words.
    assert page_of.(query: "app 的 mvp") == {["7"], false}
    assert page_of.(query: "100% DESIGN") == {["7"], false}
    assert page_of.(query: "Task EMBER/") == {["EMBER/2", "EMBER/3", "EMBER/1"], false}
    assert page_of.(query: "%") == {["7"], false}
    assert page_of.(query: "_") == {[], false}
  end

  test "members list a still.fail station's chats only where the Router wrote, and every Comma station's Task" do
    Repo.query!("TRUNCATE salix_stillfail_stations")

    {:ok, _} =
      apply_page(
        page(
          "e1",
          [
            row("EMBER/1", 1, %{"last_activity_at" => 1_000}),
            # A Comma station's row keeps no link: only still.fail's open in still.fail.
            row("EMBER/2", 2, %{"last_activity_at" => 2_000, "url" => "https://x.test/2"})
          ],
          reset: true
        )
      )

    {:ok, sf} = SalixStore.StillfailStations.ensure(@tenant, @group, "dev_sf")

    # More unlisted chats than a list holds (500), all newer than the listed ones: they must not push them out.
    unlisted =
      for n <- 1..520,
          do:
            row("#{n}", n, %{
              "last_activity_at" => 10_000 + n,
              "url" => "https://still.fail/c/#{n}"
            })

    listed = [
      row("900", 900, %{
        "last_activity_at" => 3_000,
        "router" => true,
        "url" => "https://still.fail/c/900"
      }),
      # Another station of the workspace's chat.
      row("12@st_b", 901, %{
        "last_activity_at" => 4_000,
        "router" => true,
        "url" => "https://still.fail/c/12"
      }),
      # Not `true`: not the Router's.
      row("902", 902, %{
        "last_activity_at" => 5_000,
        "router" => "yes",
        "url" => "https://still.fail/c/902"
      }),
      # The Router's, with no page to open it on.
      row("903", 903, %{"last_activity_at" => 6_000, "router" => true})
    ]

    [first | later] = Enum.chunk_every(unlisted ++ listed, StationTaskIndex.max_page_rows())
    {:ok, held} = StationTaskIndex.apply_page(sf, "dev_sf", page("s1", first, reset: true))

    for rows <- later, reduce: held do
      %{"through" => through} ->
        {:ok, held} =
          StationTaskIndex.apply_page(sf, "dev_sf", page("s1", rows, since: through))

        held
    end

    # The Router's list keeps every row, the latest 500, and says which ones it wrote in.
    all = StationTaskIndex.list_group(@group)
    assert length(all) == 500
    assert [%{thread: "520", router: false, url: "https://still.fail/c/520"} | _] = all
    assert StationTaskIndex.get(@group, sf.id, "903").router

    assert [
             %{thread: "12@st_b", url: "https://still.fail/c/12", device_id: "dev_sf"},
             %{thread: "900", url: "https://still.fail/c/900"},
             %{thread: "EMBER/2", url: nil},
             %{thread: "EMBER/1", url: nil}
           ] = StationTaskIndex.list_for_members(@group)
  end

  test "participants normalization and list_for_members/2 member scoping + device email isolation" do
    {:ok, sf_a} = SalixStore.StillfailStations.ensure(@tenant, @group, "dev_sf_a")
    {:ok, sf_b} = SalixStore.StillfailStations.ensure(@tenant, @group, "dev_sf_b")

    # Invalid participant email is rejected.
    assert {:error, :invalid_page} =
             StationTaskIndex.apply_page(
               sf_a,
               "dev_sf_a",
               page("p_bad", [row("bad", 1, %{"participants" => ["not-an-email"]})], reset: true)
             )

    rows_a = [
      row("r-router", 1, %{
        "last_activity_at" => 10_000,
        "router" => true,
        "created_by" => "teammate@co.test",
        "url" => "https://app.monoid.zone/chats/r-router"
      }),
      row("r-created", 2, %{
        "last_activity_at" => 9_000,
        "created_by" => "  Owner@Comma.Test ",
        "url" => "https://app.monoid.zone/chats/r-created"
      }),
      row("r-waits", 3, %{
        "last_activity_at" => 8_000,
        "created_by" => "teammate@co.test",
        "waits_for" => ["  Owner-Alt@Monoid.Test "],
        "url" => "https://app.monoid.zone/chats/r-waits"
      }),
      row("r-participant", 4, %{
        "last_activity_at" => 7_000,
        "created_by" => "teammate@co.test",
        "participants" => ["  Owner@Comma.Test ", "owner@comma.test", "peer@co.test"],
        "url" => "https://app.monoid.zone/chats/r-participant"
      }),
      row("r-third-party", 5, %{
        "last_activity_at" => 6_000,
        "created_by" => "teammate@co.test",
        "participants" => ["peer@co.test"],
        "url" => "https://app.monoid.zone/chats/r-third-party"
      })
    ]

    # Station B has a chat referencing owner-alt@monoid.test, which is ONLY bound to dev_sf_a.
    rows_b = [
      row("b-other-device-email", 1, %{
        "last_activity_at" => 11_000,
        "created_by" => "owner-alt@monoid.test",
        "url" => "https://app.monoid.zone/chats/b-other"
      })
    ]

    assert {:ok, _} =
             StationTaskIndex.apply_page(sf_a, "dev_sf_a", page("p1", rows_a, reset: true))

    assert {:ok, _} =
             StationTaskIndex.apply_page(sf_b, "dev_sf_b", page("p1", rows_b, reset: true))

    # Participants are stored lowercased, trimmed, and deduplicated.
    assert StationTaskIndex.get(@group, sf_a.id, "r-participant").participants == [
             "owner@comma.test",
             "peer@co.test"
           ]

    # Owner with dev_sf_a bound to owner-alt@monoid.test sees router, created_by, waits_for,
    # and participants on dev_sf_a, but NOT third-party chats and NOT dev_sf_b's owner-alt row.
    owner_threads =
      @group
      |> StationTaskIndex.list_for_members(%{
        email: "owner@comma.test",
        device_emails: %{"dev_sf_a" => "owner-alt@monoid.test"}
      })
      |> Enum.map(& &1.thread)

    assert owner_threads == ["r-router", "r-created", "r-waits", "r-participant"]

    # Non-owner member (peer@co.test, no device_emails) sees router + rows where peer participates,
    # never owner's personal chats.
    peer_threads =
      @group
      |> StationTaskIndex.list_for_members(%{
        email: "peer@co.test",
        device_emails: %{}
      })
      |> Enum.map(& &1.thread)

    assert peer_threads == ["r-router", "r-participant", "r-third-party"]
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
