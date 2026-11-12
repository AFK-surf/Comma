defmodule SalixAnalytics.SlackSemanticQueue do
  @moduledoc """
  Durable source dispatch and finite channel initialization into Oban.
  Oban owns accepted jobs. Source rows own epoch fanout progress.
  Each historical page commits its jobs with its installation cursor.
  """
  use SystemsRuntime.Server
  import Ecto.Query
  alias SalixAnalytics.SlackSemanticJob
  @prefix "slack_semantic"
  @oban __MODULE__.Oban
  @active ~w(available scheduled retryable executing)

  def oban_options do
    [
      name: @oban,
      repo: SalixStore.Repo,
      prefix: @prefix,
      engine: SalixAnalytics.SlackSemanticEngine,
      queues: [semantic_text: 1, semantic_files: 1],
      # Lifeline uses attempt age, not a heartbeat. Its one-hour default
      # exceeds the normal download/upload/extraction budgets (~31 minutes).
      # A 60-second threshold re-dispatches healthy audio/video jobs.
      plugins: [Oban.Plugins.Lifeline]
    ]
  end

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    SystemsRuntime.ETS.new(__MODULE__, [
      :named_table,
      :set,
      :public
    ])

    SystemsRuntime.ETS.insert(
      __MODULE__,
      {:live, %{semantic_text: true, semantic_files: true}, 0}
    )

    SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :refresh)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :prune, 60_000)
    {:ok, schedule_dispatch(%{}, 1000)}
  end

  # This table coalesces wake hints only. Accepted work stays in PostgreSQL.
  def wake do
    if SystemsRuntime.ETS.insert_new(__MODULE__, {:dispatch_notified, true}),
      do: SystemsRuntime.Proc.send(__MODULE__, :dispatch_wake)

    :ok
  rescue
    _ -> :ok
  end

  def pending_live?(lane \\ :all) do
    [{:live, pending, checked}] = SystemsRuntime.ETS.lookup(__MODULE__, :live)

    live =
      if lane == :semantic_text,
        do: pending.semantic_text,
        else: pending.semantic_text or pending.semantic_files

    live or SystemsClock.monotonic_time(:millisecond) - checked > 2500
  rescue
    _ -> true
  end

  def enqueue(scope, timestamp, kind, live, file_id \\ nil, text_start \\ 0) do
    enqueue_job(scope, timestamp, kind, live, file_id, text_start)
  end

  defp enqueue_job(scope, timestamp, kind, live, file_id, text_start) do
    %{
      "scope" => scope,
      "timestamp" => timestamp,
      "kind" => kind,
      "live" => live,
      "file_id" => file_id,
      "text_start" => text_start
    }
    |> SlackSemanticJob.new(
      queue: if(kind == "text", do: :semantic_text, else: :semantic_files),
      priority: if(live, do: 0, else: 9),
      # Every accepted source round gets an independent durable job. A rescued
      # older executor must not acknowledge a newer epoch's observation.
      unique: false
    )
    |> then(&Oban.insert(@oban, &1))
  end

  @doc "One channel's finite initialization position. Exhaustion retains the final position."
  def history_cursor(scope) do
    safe(fn ->
      case SalixStore.Repo.query!(
             "SELECT before_ts_us FROM slack_semantic.search_cursors WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND group_id=$4 AND connect_id=$5",
             scope_key(scope)
           ).rows do
        [[cursor]] -> {:ok, cursor}
        [] -> {:ok, 0}
      end
    end)
  end

  @doc "Commit one canonical page and cursor at its captured position."
  def enqueue_history_page(scope, expected_cursor, rows) when length(rows) <= 20 do
    safe(fn ->
      SalixStore.Repo.transaction(fn ->
        key = scope_key(scope)

        current =
          SalixStore.Repo.query!(
            """
            SELECT before_ts_us, completed FROM slack_semantic.search_cursors
            WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND group_id=$4 AND connect_id=$5 FOR UPDATE
            """,
            key
          ).rows

        if current == [[expected_cursor, false]] do
          live =
            SalixStore.SlackSearchSources.live_timestamps!(
              scope,
              Enum.map(rows, & &1["message_ts_us"])
            )

          Enum.each(rows, fn row ->
            case enqueue(
                   scope,
                   row["message_ts_us"],
                   "text",
                   MapSet.member?(live, row["message_ts_us"])
                 ) do
              {:ok, _} -> :ok
              error -> SalixStore.Repo.rollback(error)
            end
          end)

          next = if rows == [], do: expected_cursor, else: List.last(rows)["message_ts_us"]

          SalixStore.Repo.query!(
            """
            UPDATE slack_semantic.search_cursors SET before_ts_us=$6, completed=$7,
              due_at=timezone('UTC', clock_timestamp())
            WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND group_id=$4 AND connect_id=$5
            """,
            key ++ [next, rows == []]
          )

          :advanced
        else
          :stale
        end
      end)
    end)
  end

  def defer_initialization(scope, expected_cursor) do
    safe(fn ->
      SalixStore.Repo.query!(
        """
        UPDATE slack_semantic.search_cursors SET due_at=timezone('UTC',clock_timestamp())+interval '5 seconds'
        WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND group_id=$4 AND connect_id=$5
          AND before_ts_us=$6 AND NOT completed
        """,
        scope_key(scope) ++ [expected_cursor]
      )

      :ok
    end)
  end

  # Canonical messages are shared, but installations can have different file
  # access. One bot must not advance another bot past files it cannot read.
  defp scope_key(scope),
    do:
      Enum.map(~w(tenant_id workspace_id channel_id), &Map.fetch!(scope, &1)) ++
        Enum.map(~w(group_id connect_id), &(scope[&1] || ""))

  defp schedule_dispatch(state, delay) do
    token = SystemsRuntime.Proc.make_ref()
    timer = SystemsClock.send_after(SystemsRuntime.Proc.self(), {:dispatch, token}, delay)
    Map.merge(state, %{dispatch_token: token, dispatch_timer: timer})
  end

  @impl true
  def handle_info(:dispatch_wake, state) do
    SystemsClock.cancel_timer(state.dispatch_timer)
    {:noreply, schedule_dispatch(state, 1)}
  end

  def handle_info({:dispatch, token}, %{dispatch_token: token} = state) do
    SystemsRuntime.ETS.delete(__MODULE__, :dispatch_notified)

    result =
      Enum.reduce_while(1..20, :idle, fn _, progress ->
        case SalixStore.SlackSearchSources.dispatch_page(&enqueue(&1, &2, "text", &3)) do
          {:ok, status} when status in [:advanced, :waiting] -> {:cont, :progress}
          {:ok, :idle} -> {:halt, progress}
          _ -> {:halt, :error}
        end
      end)

    {:noreply, schedule_dispatch(state, if(result == :progress, do: 1, else: 1000))}
  end

  def handle_info({:dispatch, _}, state), do: {:noreply, state}

  def handle_info(:refresh, state) do
    if SalixAnalytics.SlackSemanticIndex.active?() do
      _ = SalixStore.SlackSearchFiles.reconcile_page(&enqueue(&1, &2, "file", true, &3))
    end

    source_live = safe(&SalixStore.SlackSearchSources.live_pending?/0) != false

    pending =
      Map.new([:semantic_text, :semantic_files], fn lane ->
        live =
          safe(fn ->
            SalixStore.Repo.exists?(
              from(j in Oban.Job,
                prefix: ^@prefix,
                where:
                  j.queue == ^Atom.to_string(lane) and j.priority == 0 and
                    j.state in ["available", "executing"]
              )
            )
          end) != false

        {lane, live or (lane == :semantic_text and source_live)}
      end)

    result = oldest(0)

    SystemsRuntime.ETS.insert(
      __MODULE__,
      {:live, pending, SystemsClock.monotonic_time(:millisecond)}
    )

    report_age(result, "live")
    report_age(oldest(9), "history")
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :refresh, 1000)
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    _ = SalixStore.SlackSearchWindows.prune()

    safe(fn ->
      cutoff = DateTime.add(SystemsClock.utc_now(), -86_400)

      ids =
        SalixStore.Repo.all(
          from(j in Oban.Job,
            prefix: ^@prefix,
            where: j.state in ["completed", "cancelled"] and j.inserted_at < ^cutoff,
            order_by: [j.inserted_at, j.id],
            limit: 1000,
            select: j.id
          )
        )

      Oban.delete_all_jobs(
        @oban,
        from(j in Oban.Job,
          where:
            j.id in ^ids and j.state in ["completed", "cancelled"] and j.inserted_at < ^cutoff
        )
      )
    end)

    SystemsClock.send_after(SystemsRuntime.Proc.self(), :prune, 60_000)
    {:noreply, state}
  end

  defp oldest(priority) do
    safe(fn ->
      SalixStore.Repo.one(
        from(j in Oban.Job,
          prefix: ^@prefix,
          where: j.priority == ^priority and j.state in ^@active,
          order_by: j.inserted_at,
          limit: 1,
          select: j.inserted_at
        ),
        timeout: 2000
      )
    end)
  end

  defp report_age(:error, _lane), do: observe("error")

  defp report_age(oldest, lane) do
    safe(fn ->
      age = if oldest, do: max(DateTime.diff(SystemsClock.utc_now(), oldest, :second), 0), else: 0

      SystemsRuntime.Telemetry.execute(
        [:salix, :semantic_queue, :backlog],
        %{age_seconds: age},
        %{lane: lane}
      )
    end)
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp observe(outcome),
    do:
      SalixAnalytics.SlackSemanticIndex.observe(
        "slack_semantic_enqueue",
        SystemsClock.monotonic_time(),
        outcome
      )
end
