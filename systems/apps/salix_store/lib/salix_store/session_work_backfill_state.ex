defmodule SalixStore.SessionWorkBackfillState do
  @moduledoc """
  Durable composite cursor for the one-time Session work projection backfill.

  The release operation is exclusive. Strategy v4 first pages every distinct
  Postgres candidate address, then scans local markers. Every successfully
  attempted address atomically reconciles candidates from freshly verified
  Session authority and persists its expected row plus durable keyset cursor.
  The terminal cutover marker is strategy-versioned and is written only after
  a complete zero-uncovered verification.
  Address reconciliation, attempted-prefix persistence, restart, verification,
  and terminal cutover are modeled in `tla/salix/SessionWorkProjection.tla`.
  """

  import Ecto.Query

  alias SalixStore.{
    Repo,
    SessionWorkBackfillExpectedCandidates,
    SessionWorkCandidates
  }

  @name "session_work_candidates_v1"
  @terminal_marker "session_work_candidates_v1"
  @strategy_version 5
  @mutable_columns %{
    phase: "phase",
    candidate_agent_start_after: "candidate_agent_start_after",
    candidate_runtime_kind_start_after: "candidate_runtime_kind_start_after",
    candidate_session_start_after: "candidate_session_start_after",
    agent_start_after: "agent_start_after",
    current_agent_key: "current_agent_key",
    marker_start_after: "marker_start_after",
    uncovered_authoritative_work: "uncovered_authoritative_work",
    processed: "processed",
    projection_gaps: "projection_gaps",
    updated_at_ms: "updated_at_ms",
    strategy_version: "strategy_version"
  }
  @returning_columns [
    "phase",
    "candidate_agent_start_after",
    "candidate_runtime_kind_start_after",
    "candidate_session_start_after",
    "agent_start_after",
    "current_agent_key",
    "marker_start_after",
    "uncovered_authoritative_work",
    "processed",
    "projection_gaps",
    "updated_at_ms",
    "strategy_version"
  ]

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:name, :string, autogenerate: false}
    schema "session_work_backfill_state" do
      field(:phase, :string)
      field(:candidate_agent_start_after, :string)
      field(:candidate_runtime_kind_start_after, :string)
      field(:candidate_session_start_after, :string)
      field(:agent_start_after, :string)
      field(:current_agent_key, :string)
      field(:marker_start_after, :string)
      field(:uncovered_authoritative_work, :integer)
      field(:processed, :integer)
      field(:projection_gaps, :integer)
      field(:updated_at_ms, :integer)
      field(:strategy_version, :integer)
    end
  end

  @spec load() :: {:ok, map()} | {:error, :unavailable}
  def load do
    now = System.system_time(:millisecond)

    Repo.insert_all(
      Row,
      [
        %{
          name: @name,
          phase: "candidate_backfill",
          uncovered_authoritative_work: 0,
          processed: 0,
          projection_gaps: 0,
          updated_at_ms: now,
          strategy_version: @strategy_version
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:name]
    )

    with :ok <- upgrade_strategy(), do: read()
  rescue
    _ -> {:error, :unavailable}
  end

  @spec read() :: {:ok, map()} | {:error, :not_started | :unavailable}
  def read do
    case Repo.get(Row, @name) do
      %Row{} = row -> {:ok, to_map(row)}
      nil -> {:error, :not_started}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @spec put(map()) :: {:ok, map()} | {:error, :unavailable}
  def put(%{} = attrs) do
    attrs = Map.put(attrs, :updated_at_ms, System.system_time(:millisecond))

    update_returning(attrs)
  rescue
    _ -> {:error, :unavailable}
  end

  @spec terminal?() :: {:ok, boolean()} | {:error, :unavailable}
  def terminal? do
    case Repo.query(
           "SELECT 1 FROM salix_cutover_markers " <>
             "WHERE name = $1 AND evidence @> jsonb_build_object('strategy_version', $2::integer)",
           [@terminal_marker, @strategy_version]
         ) do
      {:ok, %{num_rows: 1}} -> {:ok, true}
      {:ok, %{num_rows: 0}} -> {:ok, false}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @spec mark_terminal(map()) :: :ok | {:error, :uncovered_authoritative_work | :unavailable}
  def mark_terminal(%{"uncovered_authoritative_work" => 0, "projection_gaps" => 0} = evidence) do
    completed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    evidence = Map.put(evidence, "strategy_version", @strategy_version)

    case Repo.query(
           "INSERT INTO salix_cutover_markers (name, completed_at, evidence) " <>
             "VALUES ($1, $2, $3) ON CONFLICT (name) DO UPDATE " <>
             "SET completed_at = EXCLUDED.completed_at, evidence = EXCLUDED.evidence",
           [@terminal_marker, completed_at, evidence]
         ) do
      {:ok, _} -> :ok
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def mark_terminal(%{uncovered_authoritative_work: 0, projection_gaps: 0} = evidence) do
    evidence
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> mark_terminal()
  end

  def mark_terminal(_evidence), do: {:error, :uncovered_authoritative_work}

  @spec strategy_version() :: pos_integer()
  def strategy_version, do: @strategy_version

  @spec persist_candidate(map(), map()) :: {:ok, map()} | {:error, term()}
  def persist_candidate(candidate, attrs) do
    transaction(fn ->
      with :ok <- SessionWorkCandidates.reconcile_address_from_authority(candidate),
           :ok <- SessionWorkBackfillExpectedCandidates.replace_from_authority(candidate),
           {:ok, state} <- update_returning(with_updated_at(attrs)) do
        state
      end
    end)
  end

  @spec persist_stable(map(), map()) :: {:ok, map()} | {:error, term()}
  def persist_stable(address, attrs) do
    transaction(fn ->
      with :ok <- SessionWorkCandidates.delete_address(address),
           :ok <- SessionWorkBackfillExpectedCandidates.delete_address(address),
           {:ok, state} <- update_returning(with_updated_at(attrs)) do
        state
      end
    end)
  end

  defp transaction(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:error, reason} -> Repo.rollback(reason)
             value -> value
           end
         end) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp upgrade_strategy do
    transaction(fn ->
      case Repo.one(from(r in Row, where: r.name == ^@name, lock: "FOR UPDATE")) do
        %Row{strategy_version: version} when version >= @strategy_version ->
          :ok

        %Row{} ->
          with :ok <- SessionWorkBackfillExpectedCandidates.reset(),
               {:ok, _state} <-
                 update_returning(%{
                   strategy_version: @strategy_version,
                   phase: "candidate_backfill",
                   candidate_agent_start_after: nil,
                   candidate_runtime_kind_start_after: nil,
                   candidate_session_start_after: nil,
                   agent_start_after: nil,
                   current_agent_key: nil,
                   marker_start_after: nil,
                   uncovered_authoritative_work: 0,
                   processed: 0,
                   projection_gaps: 0,
                   updated_at_ms: System.system_time(:millisecond)
                 }) do
            :ok
          end

        nil ->
          {:error, :unavailable}
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_returning(attrs) do
    assignments =
      attrs
      |> Map.to_list()
      |> Enum.filter(fn {key, _value} -> Map.has_key?(@mutable_columns, key) end)

    values = Enum.map(assignments, &elem(&1, 1))

    set_sql =
      assignments
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{key, _value}, index} ->
        Map.fetch!(@mutable_columns, key) <> " = $#{index}"
      end)

    name_index = length(values) + 1

    sql =
      "UPDATE session_work_backfill_state SET " <>
        set_sql <>
        " WHERE name = $#{name_index} RETURNING " <> Enum.join(@returning_columns, ", ")

    case Repo.query(sql, values ++ [@name]) do
      {:ok, %{num_rows: 1, rows: [row]}} -> {:ok, returned_to_map(row)}
      _ -> {:error, :unavailable}
    end
  end

  defp with_updated_at(attrs),
    do: Map.put(attrs, :updated_at_ms, System.system_time(:millisecond))

  defp to_map(%Row{} = row) do
    %{
      phase: row.phase,
      candidate_agent_start_after: row.candidate_agent_start_after,
      candidate_runtime_kind_start_after: row.candidate_runtime_kind_start_after,
      candidate_session_start_after: row.candidate_session_start_after,
      agent_start_after: row.agent_start_after,
      current_agent_key: row.current_agent_key,
      marker_start_after: row.marker_start_after,
      uncovered_authoritative_work: row.uncovered_authoritative_work,
      processed: row.processed,
      projection_gaps: row.projection_gaps,
      updated_at_ms: row.updated_at_ms,
      strategy_version: row.strategy_version
    }
  end

  defp returned_to_map(values) do
    @returning_columns
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.zip(values)
    |> Map.new()
  end
end
