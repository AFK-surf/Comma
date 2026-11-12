defmodule SalixAnalytics.SlackSemanticProgressTest do
  import Ecto.Query
  import SystemsClock.Assertions
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:slack_semantic, :slack_mirror_outbox]
  alias SalixAnalytics.SlackSemanticQueue, as: Queue
  alias SalixStore.{Repo, SlackMirrorOutbox, SlackSearchCatalog, SlackSearchSources}

  @scope %{
    "tenant_id" => "progress",
    "workspace_id" => "T1",
    "channel_id" => "C1",
    "group_id" => "G1",
    "connect_id" => "I01",
    "connect_generation" => "g1"
  }

  defmodule CanonicalPages do
    import Plug.Conn
    def init(state), do: state

    def call(conn, state) do
      conn = fetch_query_params(conn)
      channel = conn.query_params["param_channel_id"]
      latest = String.to_integer(conn.query_params["param_latest"])
      fail = Agent.get_and_update(state, fn s -> {s.fail, %{s | calls: [channel | s.calls]}} end)

      case Agent.get(state, &Map.get(&1, :hold)) do
        pid when is_pid(pid) ->
          send(pid, {:canonical_page_waiting, self()})

          receive do
            :release_canonical_page -> :ok
          end

        _ ->
          :ok
      end

      if channel == "C1" and fail do
        send_resp(conn, 500, "source temporarily unavailable")
      else
        timestamp = if channel == "C1", do: 11, else: 21

        send_resp(
          conn,
          200,
          if(latest > timestamp, do: Jason.encode!(%{"message_ts_us" => timestamp}), else: "")
        )
      end
    end
  end

  setup_all do
    SalixStore.RepoTestSetup.ensure!()
    :ok
  end

  setup do
    SystemsClock.manual(scope: ["Elixir.Salix"])
    on_exit(&SystemsClock.reset/0)

    Repo.query!(
      "TRUNCATE slack_semantic.search_sources, slack_semantic.search_components, slack_semantic.search_cursors, slack_semantic.search_channels, slack_semantic.search_connects, slack_semantic.search_files"
    )

    start_supervised!(
      {Oban, Queue.oban_options() |> Keyword.merge(queues: [], plugins: [], testing: :manual)}
    )

    :ok
  end

  test "a failed canonical page yields to another channel, resumes, then leaves no idle reads" do
    installation!(1)
    :ok = SlackSearchCatalog.remember_channels(@scope, ["C2"])
    {:ok, state} = start_supervised({Agent, fn -> %{fail: true, calls: []} end})

    SystemsRuntime.put_env(:salix_analytics, :clickhouse,
      base_url: "http://127.0.0.1:1",
      database: "fixture"
    )

    SystemsRuntime.put_env(:salix_analytics, :slack_semantic_search,
      environment: "test",
      req_options: [plug: {CanonicalPages, state}]
    )

    pid = start_supervised!({SalixAnalytics.SlackSemanticIndexer, start_delay_ms: 60000})

    tick = fn ->
      send(pid, :tick)
      :sys.get_state(pid)
    end

    tick.()
    assert jobs() == []

    assert [[true]] =
             Repo.query!(
               "SELECT due_at > timezone('UTC',clock_timestamp()) FROM slack_semantic.search_cursors WHERE channel_id='C1'"
             ).rows

    tick.()
    assert [job] = jobs()
    assert job.args["scope"]["channel_id"] == "C2"
    tick.()
    Agent.update(state, &%{&1 | fail: false})
    SystemsClock.advance(5000)
    :sys.get_state(pid)
    tick.()
    assert Enum.any?(jobs(), &(&1.args["scope"]["channel_id"] == "C1"))
    tick.()
    assert {:ok, nil} = SlackSearchCatalog.next_initialization()
    before = Agent.get(state, & &1.calls)
    for _ <- 1..20, do: tick.()
    assert Agent.get(state, & &1.calls) == before
  end

  test "live admission continues while the canonical initialization request waits" do
    installation!(1)
    owner = self()
    {:ok, state} = start_supervised({Agent, fn -> %{fail: false, calls: [], hold: owner} end})

    SystemsRuntime.put_env(:salix_analytics, :clickhouse,
      base_url: "http://127.0.0.1:1",
      database: "fixture"
    )

    SystemsRuntime.put_env(:salix_analytics, :slack_semantic_search,
      environment: "test",
      req_options: [plug: {CanonicalPages, state}]
    )

    indexer = start_supervised!({SalixAnalytics.SlackSemanticIndexer, start_delay_ms: 0})
    SystemsClock.advance(0)
    settle_receive({:canonical_page_waiting, request})
    Repo.transaction(fn -> SlackSearchSources.admit!(for n <- 1..120, do: row(n, "webhook")) end)
    queue = start_supervised!(Queue)
    Queue.wake()
    :sys.get_state(queue)

    turns =
      Enum.reduce_while(1..120, nil, fn turn, _ ->
        SystemsClock.advance(1)
        :sys.get_state(queue)
        if length(jobs()) == 120, do: {:halt, turn}, else: {:cont, nil}
      end)

    assert turns
    assert length(jobs()) == 120
    assert Enum.all?(jobs(), &(&1.priority == 0))
    send(request, :release_canonical_page)
    :sys.get_state(indexer)
  end

  test "admission retains source progress with the write intent and fans out across installations" do
    for n <- 1..23, do: installation!(n)
    row = row(11, "webhook")
    assert :ok = SlackMirrorOutbox.append(row, "message", @scope)
    assert SlackSearchSources.live_pending?() == false
    assert {:ok, :waiting} = dispatch()
    assert jobs() == []

    assert [[1, 0]] =
             Repo.query!(
               "SELECT change_epoch,dispatched_epoch FROM slack_semantic.search_sources"
             ).rows

    Repo.query!("DELETE FROM slack_mirror_outbox")

    Repo.query!(
      "UPDATE slack_semantic.search_sources SET dispatch_due=timezone('UTC',clock_timestamp())"
    )

    assert SlackSearchSources.live_pending?()
    assert {:ok, :advanced} = dispatch()
    assert length(jobs()) == 20
    assert {:ok, :advanced} = dispatch()
    assert length(jobs()) == 23
    assert Enum.all?(jobs(), &(&1.priority == 0))
    refute SlackSearchSources.live_pending?()
    assert {:ok, :idle} = dispatch()
    assert length(jobs()) == 23
  end

  test "a fresh live source dispatches before an old historical backlog" do
    installation!(1)

    Repo.query!("""
    INSERT INTO slack_semantic.search_sources
      (tenant_id,workspace_id,channel_id,message_ts_us,change_epoch,dispatch_epoch,dispatch_due)
    SELECT 'progress','T1','C1',n,1,1,timezone('UTC',now())-interval '1 day'
    FROM generate_series(1,10000) n
    """)

    admit!(row(20000, "webhook"))
    assert {:ok, :advanced} = dispatch()
    assert [job] = jobs()
    assert job.priority == 0 and job.args["timestamp"] == 20000
  end

  test "a hot source finishes its fixed round and yields before dispatching the newer epoch" do
    for n <- 1..23, do: installation!(n)
    admit!(row(11, "history"))
    assert {:ok, :advanced} = dispatch()
    admit!(row(11, "webhook"))
    admit!(row(11, "history"))

    assert [[3, 1, 0, true]] =
             Repo.query!(
               "SELECT change_epoch,dispatch_epoch,dispatched_epoch,dispatch_live FROM slack_semantic.search_sources"
             ).rows

    assert {:ok, :advanced} = dispatch()

    assert Enum.map(Enum.drop(jobs(), 20), & &1.args["scope"]["connect_id"]) == [
             "I21",
             "I22",
             "I23"
           ]

    assert [[3, 3, 1, true]] =
             Repo.query!(
               "SELECT change_epoch,dispatch_epoch,dispatched_epoch,dispatch_live FROM slack_semantic.search_sources"
             ).rows

    admit!(row(12, "webhook"))
    assert {:ok, :advanced} = dispatch()
    assert {:ok, :advanced} = dispatch()
    # Every source receives one finite page before the hot source can finish another round.
    assert Enum.any?(jobs(), &(&1.args["timestamp"] == 12))
    for _ <- 1..3, do: dispatch()

    assert [[3, 3, false]] =
             Repo.query!(
               "SELECT change_epoch,dispatched_epoch,dispatch_live FROM slack_semantic.search_sources WHERE message_ts_us=11"
             ).rows

    assert Enum.count(jobs(), &(&1.args["timestamp"] == 11 and &1.priority == 0)) == 26
  end

  test "a failed job insertion rolls back the whole fanout page and two pods do not duplicate it" do
    installation!(1)
    installation!(2)
    admit!(row(11, "history"))

    Repo.query!(
      "ALTER TABLE slack_semantic.oban_jobs ADD CONSTRAINT reject_progress_connect CHECK (args->'scope'->>'connect_id' <> 'I02')"
    )

    try do
      assert {:error, _} = dispatch()
      assert jobs() == []

      assert [[%{}, 0]] =
               Repo.query!(
                 "SELECT dispatch_cursor,dispatched_epoch FROM slack_semantic.search_sources"
               ).rows
    after
      Repo.query!("ALTER TABLE slack_semantic.oban_jobs DROP CONSTRAINT reject_progress_connect")
    end

    results =
      for _ <- 1..2 do
        Task.async(fn -> SlackSearchSources.dispatch_page(&Queue.enqueue(&1, &2, "text", &3)) end)
      end
      |> Enum.map(&SystemsClock.Test.settled_await/1)

    assert Enum.sort(results) == [{:ok, :advanced}, {:ok, :idle}]
    assert length(jobs()) == 2
  end

  test "a pod crash after an Oban insert rolls back its source page for another pod" do
    installation!(1)
    installation!(2)
    admit!(row(11, "history"))
    owner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        SlackSearchSources.dispatch_page(fn scope, ts, live ->
          result = Queue.enqueue(scope, ts, "text", live)
          send(owner, {:job_inserted, self()})

          receive do
            :continue -> result
          end
        end)
      end)

    settle_receive({:job_inserted, ^pid})
    Process.exit(pid, :kill)
    settle_receive({:DOWN, ^ref, :process, ^pid, :killed})
    # This lock waits for PostgreSQL to release the crashed transaction.
    Repo.transaction(fn ->
      assert [[0, %{}]] =
               Repo.query!(
                 "SELECT dispatched_epoch,dispatch_cursor FROM slack_semantic.search_sources FOR UPDATE"
               ).rows
    end)

    assert jobs() == []
    assert {:ok, :advanced} = dispatch()
    assert Enum.map(jobs(), & &1.args["scope"]["connect_id"]) == ["I01", "I02"]
  end

  test "a rescued older executor cannot acknowledge a newer accepted epoch" do
    installation!(1)
    admit!(row(11, "history"))
    assert {:ok, :advanced} = dispatch()
    [old] = jobs()
    conf = Oban.config(Queue.Oban)
    {:ok, meta} = Oban.Engine.init(conf, queue: "semantic_text", limit: 1)
    {:ok, {_, [executor]}} = Oban.Engine.fetch_jobs(conf, meta, %{})
    Repo.query!("UPDATE slack_semantic.oban_jobs SET state='available' WHERE id=$1", [old.id])
    admit!(row(11, "history"))
    assert {:ok, :advanced} = dispatch()
    assert :ok = Oban.Engine.complete_job(conf, executor)
    assert [completed, fresh] = jobs()
    assert completed.id == old.id and completed.state == "completed"
    assert fresh.id != old.id and fresh.state == "available" and fresh.priority == 9
  end

  test "new channels initialize once, credential rotation retains progress and reactivation catches missed changes" do
    installation!(1)
    assert :ok = SlackSearchCatalog.remember_channels(@scope, ["C2"])
    assert {:ok, :advanced} = SlackSearchCatalog.initialize_connect_page()
    assert {:ok, {scope, 0}} = SlackSearchCatalog.next_initialization()
    assert {:ok, :advanced} = Queue.enqueue_history_page(scope, 0, [%{"message_ts_us" => 11}])

    assert :ok =
             SlackSearchCatalog.remember_connects([Map.put(@scope, "connect_generation", "g2")])

    assert {:ok, 11} = Queue.history_cursor(scope)
    assert {:ok, {fresh, 11}} = SlackSearchCatalog.next_initialization()
    assert fresh["connect_generation"] == "g2"
    assert {:ok, :advanced} = Queue.enqueue_history_page(fresh, 11, [])
    assert {:ok, :stale} = Queue.enqueue_history_page(scope, 11, [])
    assert {:ok, :idle} = SlackSearchCatalog.initialize_connect_page()
    :ok = SlackSearchCatalog.remember_connects([Map.put(@scope, "active", false)])
    :ok = SlackSearchCatalog.remember_connects([Map.put(@scope, "active", true)])
    SystemsClock.advance(1)
    assert {:ok, :advanced} = SlackSearchCatalog.initialize_connect_page()
    assert {:ok, {_, 0}} = SlackSearchCatalog.next_initialization()
  end

  test "workspace replacement retires old initialization and starts only observed new channels" do
    installation!(1)
    :ok = SlackSearchCatalog.remember_channels(@scope, ["C2"])
    fresh = Map.put(@scope, "workspace_id", "T2")
    :ok = SlackSearchCatalog.remember_connects([fresh])
    assert {:ok, nil} = SlackSearchCatalog.next_initialization()

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM slack_semantic.search_cursors WHERE workspace_id='T1' AND NOT completed"
             ).rows

    :ok = SlackSearchCatalog.remember_channels(fresh, ["C3"])
    assert {:ok, {scope, 0}} = SlackSearchCatalog.next_initialization()
    assert scope["workspace_id"] == "T2" and scope["channel_id"] == "C3"
  end

  defp installation!(n) do
    scope = Map.put(@scope, "connect_id", "I" <> String.pad_leading(to_string(n), 2, "0"))
    :ok = SlackSearchCatalog.remember_connects([scope])
    :ok = SlackSearchCatalog.remember_channels(scope, ["C1"])
  end

  defp row(ts, source),
    do:
      Map.merge(@scope, %{
        "message_ts_us" => ts,
        "ingest_source" => source,
        "_semantic_context" => @scope
      })

  defp admit!(row), do: Repo.transaction(fn -> SlackSearchSources.admit!([row]) end)

  defp dispatch do
    SystemsClock.advance(1)
    SlackSearchSources.dispatch_page(&Queue.enqueue(&1, &2, "text", &3))
  end

  defp jobs, do: Repo.all(from(j in Oban.Job, prefix: "slack_semantic", order_by: j.id))
end
