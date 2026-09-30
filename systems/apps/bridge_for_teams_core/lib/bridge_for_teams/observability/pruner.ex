defmodule BridgeForTeams.Observability.Pruner do
  @moduledoc """
  Scheduled retention pruning for BFT Operations records.

  The worker is intentionally thin: `BridgeForTeams.Observability.prune_expired/1`
  remains the single pruning boundary used by operators, tests, and the
  scheduler. The GenServer only decides when to call that boundary and keeps
  failures from taking down the supervision tree.
  """
  use GenServer

  require Logger

  alias BridgeForTeams.{Observability, Repo}

  @default_interval_ms 86_400_000
  @default_batch_size 200
  @default_lease_ms 60_000
  @scan_id "operations-retention"
  @phase_count 5

  @type counts :: %{
          stderr_tails_cleared: non_neg_integer(),
          observability_events_deleted: non_neg_integer(),
          operation_runs_deleted: non_neg_integer(),
          check_results_deleted: non_neg_integer(),
          audit_logs_deleted: non_neg_integer()
        }

  @doc "Start the scheduled observability pruning worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name_option(opts))
  end

  @doc """
  Run the pruning boundary once without crashing the caller.

  Options:

    * `:prune_fun` - injectable pruning function for tests.
    * `:prune_opts` - options forwarded to the pruning function.
  """
  @spec prune_once(keyword()) :: {:ok, counts()} | {:error, {:exception, Exception.t()}}
  def prune_once(opts \\ []) do
    prune_fun = Keyword.get(opts, :prune_fun, &Observability.prune_expired/1)
    prune_opts = Keyword.get(opts, :prune_opts, [])

    prune_fun.(prune_opts)
  rescue
    exception ->
      Logger.error("bridge_for_teams.observability.pruner.failed #{Exception.message(exception)}")
      {:error, {:exception, exception}}
  end

  @doc """
  Claim and execute one bounded retention batch.

  The singleton claim is BFT-specific and persisted in PostgreSQL. Each
  successful acknowledgement advances to the next relation, so a permanently
  busy relation cannot starve the rest of the retention set.
  """
  def run_batch_once(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, claim} when not is_nil(claim) <- claim_scan(repo, opts),
         {:ok, counts} <- prune_claimed_batch(repo, claim, opts),
         :ok <- acknowledge_scan(repo, claim) do
      {:ok, counts |> Map.put(:claimed, true) |> Map.put(:phase, claim.phase)}
    else
      {:ok, nil} -> {:ok, Map.put(empty_counts(), :claimed, false)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:exception, error}}
  end

  @impl true
  def init(opts) do
    cfg = Application.get_env(:bridge_for_teams_core, __MODULE__, [])

    state = %{
      enabled: Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, scheduled_by_policy?())),
      interval_ms:
        positive_integer(opts[:interval_ms] || cfg[:interval_ms], @default_interval_ms),
      run_on_start: Keyword.get(opts, :run_on_start, Keyword.get(cfg, :run_on_start, false)),
      prune_fun: Keyword.get(opts, :prune_fun, &Observability.prune_expired/1),
      prune_opts: Keyword.get(opts, :prune_opts, Keyword.get(cfg, :prune_opts, [])),
      durable_batch?:
        Keyword.get(
          opts,
          :durable_batch,
          Keyword.get(cfg, :durable_batch, not Keyword.has_key?(opts, :prune_fun))
        ),
      cycle_work: false
    }

    if state.enabled do
      if state.run_on_start, do: send(self(), :prune), else: schedule(state.interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:prune, state) do
    if state.durable_batch? do
      result = run_batch_once(state.prune_opts)
      {delay, cycle_work} = next_batch_delay(result, state)
      schedule(delay)
      {:noreply, %{state | cycle_work: cycle_work}}
    else
      _ = prune_once(prune_fun: state.prune_fun, prune_opts: state.prune_opts)
      schedule(state.interval_ms)
      {:noreply, state}
    end
  end

  defp next_batch_delay({:ok, %{claimed: true, phase: phase} = counts}, state) do
    work? =
      Enum.any?(
        [
          :stderr_tails_cleared,
          :observability_events_deleted,
          :operation_runs_deleted,
          :check_results_deleted,
          :audit_logs_deleted
        ],
        &(Map.get(counts, &1, 0) > 0)
      )

    cycle_work = state.cycle_work or work?

    if phase == @phase_count - 1 do
      if cycle_work, do: {0, false}, else: {state.interval_ms, false}
    else
      {0, cycle_work}
    end
  end

  defp next_batch_delay(_result, state), do: {state.interval_ms, state.cycle_work}

  defp claim_scan(repo, opts) do
    lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)
    token = Ecto.UUID.generate()

    repo.transaction(fn ->
      repo.query!(
        """
        INSERT INTO observability_prune_scans (id, phase, generation, created_at, updated_at)
        VALUES ($1, 0, 1, now(), now())
        ON CONFLICT (id) DO NOTHING
        """,
        [@scan_id]
      )

      case repo.query!(
             """
             SELECT phase, generation
             FROM observability_prune_scans
             WHERE id = $1 AND (lease_expires_at IS NULL OR lease_expires_at <= now())
             FOR UPDATE SKIP LOCKED
             """,
             [@scan_id]
           ).rows do
        [] ->
          nil

        [[phase, generation]] ->
          repo.query!(
            """
            UPDATE observability_prune_scans
            SET lease_token = $2::text::uuid,
                lease_expires_at = now() + ($3::bigint * interval '1 millisecond'),
                updated_at = now()
            WHERE id = $1
            """,
            [@scan_id, token, lease_ms]
          )

          %{phase: phase, generation: generation, token: token}
      end
    end)
  end

  defp prune_claimed_batch(repo, claim, opts) do
    policy = Keyword.get(opts, :policy, Observability.retention_policy())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, @default_batch_size)

    {count_key, sql, cutoff} = phase_spec(claim.phase, policy, now)

    count =
      if is_nil(cutoff) do
        0
      else
        case repo.query!(sql, [cutoff, limit]).rows do
          [[value]] -> value
        end
      end

    {:ok, Map.put(empty_counts(), count_key, count)}
  rescue
    error ->
      _ = release_scan(repo, claim, error)
      {:error, {:exception, error}}
  end

  defp acknowledge_scan(repo, claim) do
    next_phase = rem(claim.phase + 1, @phase_count)

    result =
      repo.query!(
        """
        UPDATE observability_prune_scans
        SET phase = $3,
            generation = generation + 1,
            lease_token = NULL,
            lease_expires_at = NULL,
            last_error = NULL,
            updated_at = now()
        WHERE id = $1 AND lease_token = $2::text::uuid AND generation = $4
        """,
        [@scan_id, claim.token, next_phase, claim.generation]
      )

    if result.num_rows == 1, do: :ok, else: {:error, :stale_observability_prune_claim}
  end

  defp release_scan(repo, claim, reason) do
    repo.query(
      """
      UPDATE observability_prune_scans
      SET lease_token = NULL, lease_expires_at = NULL, last_error = $3, updated_at = now()
      WHERE id = $1 AND lease_token = $2::text::uuid
      """,
      [@scan_id, claim.token, reason_class(reason)]
    )
  end

  defp reason_class({:exception, _detail}), do: "exception"
  defp reason_class({:error, reason}), do: reason_class(reason)
  defp reason_class({reason, _detail}) when is_atom(reason), do: safe_atom(reason)
  defp reason_class(reason) when is_atom(reason), do: safe_atom(reason)
  defp reason_class(%{__struct__: module}) when is_atom(module), do: safe_atom(module)
  defp reason_class(_reason), do: "external_error"

  defp safe_atom(atom), do: atom |> Atom.to_string() |> String.slice(0, 128)

  defp phase_spec(0, policy, now) do
    {:stderr_tails_cleared,
     """
     WITH targets AS (
       SELECT id FROM operation_runs
       WHERE created_at < $1 AND stderr_tail_redacted IS NOT NULL
       ORDER BY created_at, id LIMIT $2
     ), updated AS (
       UPDATE operation_runs r SET stderr_tail_redacted = NULL
       FROM targets t WHERE r.id = t.id
       RETURNING r.id
     )
     SELECT count(*)::bigint FROM updated
     """, cutoff(now, policy[:stderr_tail_days])}
  end

  defp phase_spec(1, policy, now),
    do:
      delete_phase(
        :observability_events_deleted,
        "observability_events",
        "occurred_at",
        cutoff(now, policy[:observability_events_days])
      )

  defp phase_spec(2, policy, now),
    do:
      delete_phase(
        :operation_runs_deleted,
        "operation_runs",
        "created_at",
        cutoff(now, policy[:operation_runs_days])
      )

  defp phase_spec(3, policy, now),
    do:
      delete_phase(
        :check_results_deleted,
        "check_results",
        "ran_at",
        cutoff(now, policy[:check_results_days])
      )

  defp phase_spec(4, policy, now),
    do:
      delete_phase(
        :audit_logs_deleted,
        "audit_logs",
        "created_at",
        cutoff(now, policy[:audit_logs_days])
      )

  defp delete_phase(key, table, timestamp, cutoff) do
    {key,
     """
     WITH targets AS (
       SELECT id FROM #{table}
       WHERE #{timestamp} < $1
       ORDER BY #{timestamp}, id LIMIT $2
     ), deleted AS (
       DELETE FROM #{table} row
       USING targets t WHERE row.id = t.id
       RETURNING row.id
     )
     SELECT count(*)::bigint FROM deleted
     """, cutoff}
  end

  defp cutoff(_now, value) when value in [nil, false], do: nil
  defp cutoff(_now, days) when is_integer(days) and days <= 0, do: nil
  defp cutoff(now, days) when is_integer(days), do: DateTime.add(now, -days * 86_400, :second)

  defp empty_counts do
    %{
      stderr_tails_cleared: 0,
      observability_events_deleted: 0,
      operation_runs_deleted: 0,
      check_results_deleted: 0,
      audit_logs_deleted: 0
    }
  end

  defp scheduled_by_policy? do
    Observability.retention_policy()
    |> Map.get(:pruning)
    |> Kernel.==(:scheduled)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp schedule(interval_ms), do: Process.send_after(self(), :prune, interval_ms)

  defp name_option(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> []
      {:ok, false} -> []
      {:ok, name} -> [name: name]
      :error -> [name: __MODULE__]
    end
  end
end
