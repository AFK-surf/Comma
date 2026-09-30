defmodule SalixAnalytics.SlackSemanticQueue do
  @moduledoc """
  Bounded asynchronous offers over canonical Slack data. Oban owns durable
  jobs; this bridge retains offers until insertion succeeds. Reconciliation
  repairs offers lost before insertion. Modeled in
  tla/salix/SemanticIndexScheduling.tla. Atomic historical page insertion and
  the persisted channel cursor are modeled in tla/salix/SemanticHistoryPaging.tla.
  """
  use GenServer
  import Ecto.Query
  alias SalixAnalytics.SlackSemanticJob
  @capacity 1024
  @prefix "slack_semantic"
  @oban __MODULE__.Oban
  @active ~w(available scheduled retryable executing)

  def oban_options do
    [
      name: @oban,
      repo: SalixStore.Repo,
      prefix: @prefix,
      queues: [semantic_text: 1, semantic_files: 1],
      # Lifeline uses attempt age, not a heartbeat. Its one-hour default
      # exceeds the normal download/upload/extraction budgets (~31 minutes).
      # A 60-second threshold re-dispatches healthy audio/video jobs.
      plugins: [Oban.Plugins.Lifeline]
    ]
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :ordered_set, :public, write_concurrency: true])
    :ets.insert(__MODULE__, [{:size, 0}, {:live, true, 0}])
    send(self(), :refresh)
    Process.send_after(self(), :prune, 60_000)
    {:ok, nil}
  end

  def offer_live(rows) do
    if SalixAnalytics.SlackSemanticIndex.active?() do
      for row <- rows, row["ingest_source"] == "webhook" do
        scope =
          row
          |> Map.take(~w(tenant_id workspace_id channel_id))
          |> Map.merge(
            Map.take(row["_semantic_context"] || %{}, ~w(group_id connect_id connect_generation))
          )

        offer(scope, row["message_ts_us"])
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def offer(scope, timestamp) do
    reserved = :ets.update_counter(__MODULE__, :size, {2, 1})

    if reserved <= @capacity do
      key = {System.unique_integer([:positive, :monotonic])}
      :ets.insert(__MODULE__, {key, scope, timestamp})
      if :ets.insert_new(__MODULE__, {:notified, true}), do: send(__MODULE__, :flush)
      :ok
    else
      :ets.update_counter(__MODULE__, :size, {2, -1})
      observe("over_budget")
      {:error, :full}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def pending_live? do
    [{:size, size}] = :ets.lookup(__MODULE__, :size)
    [{:live, pending, checked}] = :ets.lookup(__MODULE__, :live)
    size > 0 or pending or System.monotonic_time(:millisecond) - checked > 2500
  rescue
    _ -> true
  end

  def enqueue(scope, timestamp, kind, live, file_id \\ nil, text_start \\ 0) do
    with :ok <- SalixStore.SlackSearchCatalog.remember_channels(scope, [scope["channel_id"]]) do
      enqueue_job(scope, timestamp, kind, live, file_id, text_start)
    end
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
      # Lifeline may rescue a still-running job back to available. Never
      # coalesce a live observation even into an apparently pending job:
      # that old executor could still acknowledge it. Duplicates are cheap
      # exact canonical/missing reads and have independent durable IDs.
      unique:
        if(live,
          do: false,
          else: [period: :infinity, states: [:available, :scheduled, :retryable]]
        )
    )
    |> then(&Oban.insert(@oban, &1))
  end

  @doc "One channel's durable scan position; zero starts a new sweep."
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

  @doc "Commit one bounded page and its cursor together. Modeled in SemanticHistoryPaging.tla."
  def enqueue_history_page(scope, expected_cursor, rows) when length(rows) <= 20 do
    safe(fn ->
      SalixStore.Repo.transaction(fn ->
        key = scope_key(scope)

        SalixStore.Repo.query!(
          """
          INSERT INTO slack_semantic.search_cursors (tenant_id, workspace_id, channel_id, group_id, connect_id)
          VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING
          """,
          key
        )

        [[current]] =
          SalixStore.Repo.query!(
            """
            SELECT before_ts_us FROM slack_semantic.search_cursors
            WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND group_id=$4 AND connect_id=$5 FOR UPDATE
            """,
            key
          ).rows

        if current == expected_cursor do
          Enum.each(rows, fn row ->
            case enqueue(scope, row["message_ts_us"], "text", false) do
              {:ok, _} -> :ok
              error -> SalixStore.Repo.rollback(error)
            end
          end)

          # An exhausted sweep restarts, including when a phase-A worker ACKed
          # only the old projection during rollout. Completed jobs do not
          # coalesce this next visit. MessageSearchWorkerRollout checks coverage.
          next_cursor = if rows == [], do: 0, else: List.last(rows)["message_ts_us"]

          SalixStore.Repo.query!(
            """
            UPDATE slack_semantic.search_cursors SET before_ts_us=$6
            WHERE tenant_id=$1 AND workspace_id=$2 AND channel_id=$3 AND group_id=$4 AND connect_id=$5
            """,
            key ++ [next_cursor]
          )

          :advanced
        else
          :stale
        end
      end)
    end)
  end

  # Canonical messages are shared, but installations can have different file
  # access. One bot must not advance another bot past files it cannot read.
  # Modeled in tla/salix/SemanticInstallationPaging.tla.
  defp scope_key(scope),
    do:
      Enum.map(~w(tenant_id workspace_id channel_id), &Map.fetch!(scope, &1)) ++
        Enum.map(~w(group_id connect_id), &(scope[&1] || ""))

  @impl true
  def handle_info(:flush, state) do
    result =
      Enum.reduce_while(1..20, :ok, fn _, _ ->
        case :ets.next(__MODULE__, :size) do
          :"$end_of_table" ->
            {:halt, :ok}

          key ->
            [{^key, scope, timestamp}] = :ets.lookup(__MODULE__, key)

            case safe(fn -> enqueue(scope, timestamp, "text", true) end) do
              {:ok, _} ->
                :ets.delete(__MODULE__, key)
                :ets.update_counter(__MODULE__, :size, {2, -1})
                {:cont, :ok}

              _ ->
                {:halt, :error}
            end
        end
      end)

    :ets.delete(__MODULE__, :notified)
    [{:size, size}] = :ets.lookup(__MODULE__, :size)

    if size > 0 and :ets.insert_new(__MODULE__, {:notified, true}),
      do: Process.send_after(self(), :flush, if(result == :ok, do: 1, else: 1000))

    if result == :error, do: observe("error")
    {:noreply, state}
  end

  def handle_info(:refresh, state) do
    if SalixAnalytics.SlackSemanticIndex.active?() do
      _ = SalixStore.SlackSearchFiles.reconcile_page(&enqueue(&1, &2, "file", true, &3))
    end

    result = oldest(0)
    :ets.insert(__MODULE__, {:live, result != nil, System.monotonic_time(:millisecond)})
    report_age(result, "live")
    report_age(oldest(9), "history")
    Process.send_after(self(), :refresh, 1000)
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    _ = SalixStore.SlackSearchWindows.prune()

    safe(fn ->
      cutoff = DateTime.add(DateTime.utc_now(), -86_400)

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

    Process.send_after(self(), :prune, 60_000)
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
      age = if oldest, do: max(DateTime.diff(DateTime.utc_now(), oldest, :second), 0), else: 0
      :telemetry.execute([:salix, :semantic_queue, :backlog], %{age_seconds: age}, %{lane: lane})
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
        System.monotonic_time(),
        outcome
      )
end
