defmodule SalixAnalytics.SlackSemanticSchedulingTest do
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:slack_semantic]
  alias SalixAnalytics.{SlackSemanticJob, SlackSemanticQueue}
  alias SalixStore.Repo
  alias Oban.Engine

  setup_all do
    SalixStore.RepoTestSetup.ensure!()
    :ok
  end

  setup do
    opts =
      SlackSemanticQueue.oban_options()
      |> Keyword.merge(queues: [], plugins: [], testing: :manual)

    start_supervised!({Oban, opts})
    %{conf: Oban.config(SlackSemanticQueue.Oban)}
  end

  test "dispatch leaves historical jobs untouched while another pod owns live text", %{conf: conf} do
    history = job!("semantic_text", false, attempt: 799, max_attempts: 819)
    live = job!("semantic_text", true, state: "executing")
    file = job!("semantic_files", false)

    for _ <- 1..20 do
      assert [] = fetch!(conf, "semantic_text")
      assert [] = fetch!(conf, "semantic_files")
    end

    assert [["available", 799, 819], ["available", 0, 20]] =
             Repo.query!(
               "SELECT state::text,attempt,max_attempts FROM slack_semantic.oban_jobs WHERE id=ANY($1) ORDER BY id",
               [[history.id, file.id]]
             ).rows

    assert :ok = Engine.complete_job(conf, live)
    assert [%{id: id, attempt: 800}] = fetch!(conf, "semantic_text")
    assert id == history.id
    assert [%{id: file_id}] = fetch!(conf, "semantic_files")
    assert file_id == file.id
  end

  test "a blocked or delayed live file does not hold the text lane", %{conf: conf} do
    history = job!("semantic_text", false)
    file = job!("semantic_files", true, state: "executing")
    assert [%{id: id}] = fetch!(conf, "semantic_text")
    assert id == history.id
    assert :ok = Engine.snooze_job(conf, file, 300)
    more = job!("semantic_text", false)
    assert [%{id: id}] = fetch!(conf, "semantic_text")
    assert id == more.id
    assert Repo.get!(Oban.Job, file.id, prefix: "slack_semantic").state == "scheduled"
  end

  test "runnable live work wins and a delayed retry retains its original job", %{conf: conf} do
    history = job!("semantic_text", false)
    live = job!("semantic_text", true)
    assert [%{id: id} = claimed] = fetch!(conf, "semantic_text")
    assert id == live.id
    assert :ok = Engine.snooze_job(conf, claimed, 300)
    assert [%{id: id}] = fetch!(conf, "semantic_text")
    assert id == history.id

    # Oban stages against the OS clock. An application-clock "now" need not
    # be due there yet; this fixture tests an expired retry, not clock alignment.
    Repo.query!("UPDATE slack_semantic.oban_jobs SET scheduled_at = $2 WHERE id=$1", [
      live.id,
      ~N[2000-01-01 00:00:00]
    ])

    assert {:ok, [_]} = Engine.stage_jobs(conf, Oban.Job, limit: 10)
    assert [%{id: id, attempt: 2}] = fetch!(conf, "semantic_text")
    assert id == live.id
  end

  test "two consumers claim different durable jobs", %{conf: conf} do
    jobs = for _ <- 1..4, do: job!("semantic_text", true)

    claimed =
      for _ <- 1..2 do
        Task.async(fn -> fetch!(conf, "semantic_text") end)
      end
      |> Enum.flat_map(&Task.await(&1, :infinity))

    assert length(Enum.uniq_by(claimed, & &1.id)) == 2
    assert Enum.all?(claimed, &(&1.id in Enum.map(jobs, fn j -> j.id end)))
  end

  test "queue discovery reads a fixed number of rows despite a historical backlog", %{conf: conf} do
    Repo.query!(
      """
      INSERT INTO slack_semantic.oban_jobs (queue,worker,priority,state,args,inserted_at,scheduled_at)
      SELECT 'semantic_text','SalixAnalytics.SlackSemanticJob',9,'available',
        jsonb_build_object('timestamp',n),$1,$1 FROM generate_series(1,10000) n
      """,
      [DateTime.to_naive(SystemsClock.utc_now())]
    )

    Repo.query!("ANALYZE slack_semantic.oban_jobs")
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, meta, pid ->
          if self() == pid, do: send(pid, {:discovery_query, meta.query, meta.params})
        end,
        owner
      )

    try do
      assert {:ok, ["semantic_text"]} = Engine.check_available(conf)
    after
      :telemetry.detach(handler)
    end

    queries = discovery_queries([])
    assert length(queries) in 1..2

    for {query, params} <- queries do
      [[[%{"Plan" => plan}]]] =
        Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> query, params).rows

      assert visited_rows(plan) < 20
    end
  end

  defp discovery_queries(acc) do
    receive do
      {:discovery_query, query, params} -> discovery_queries([{query, params} | acc])
    after
      0 -> acc
    end
  end

  defp visited_rows(plan) do
    (plan["Actual Rows"] + Map.get(plan, "Rows Removed by Filter", 0) +
       Map.get(plan, "Rows Removed by Index Recheck", 0)) * plan["Actual Loops"] +
      Enum.sum(Enum.map(plan["Plans"] || [], &visited_rows/1))
  end

  defp fetch!(conf, queue) do
    {:ok, meta} = Engine.init(conf, queue: queue, limit: 1)
    {:ok, {_, jobs}} = Engine.fetch_jobs(conf, meta, %{})
    jobs
  end

  defp job!(queue, live, opts \\ []) do
    %{
      "kind" => if(queue == "semantic_text", do: "text", else: "file"),
      "live" => live,
      "timestamp" => SystemsRuntime.Proc.unique_integer([:positive])
    }
    |> SlackSemanticJob.new(
      Keyword.merge([queue: queue, priority: if(live, do: 0, else: 9)], opts)
    )
    |> then(&Oban.insert!(SlackSemanticQueue.Oban, &1))
  end
end
