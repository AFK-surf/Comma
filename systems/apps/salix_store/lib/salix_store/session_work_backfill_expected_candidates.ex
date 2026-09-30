defmodule SalixStore.SessionWorkBackfillExpectedCandidates do
  @moduledoc """
  Durable expected projection captured by exclusive strategy-v5 certification.

  The table is release-local evidence, not a runtime discovery surface. Final
  verification reconciles it against `session_work_candidates` entirely in
  Postgres, so verification cannot repeat either authoritative address phase.
  """

  import Ecto.Query

  alias SalixStore.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "session_work_backfill_expected_candidates" do
      field(:agent_id, :string, primary_key: true)
      field(:runtime_kind, :string, primary_key: true)
      field(:session_id, :string, primary_key: true)
      field(:candidate_token, :string)
      field(:base_revision, :string)
      field(:workload_id, :string)
      field(:device_runtime_id, :string)
      field(:due_at_ms, :integer)
      field(:reasons, {:array, :string})
    end
  end

  @runtime_kinds ~w(internal external)

  @spec replace_from_authority(map()) :: :ok | {:error, :invalid | :unavailable}
  def replace_from_authority(%{} = record) do
    row = row_from_record(record)

    if valid_row?(row) do
      Repo.insert_all(Row, [row],
        on_conflict:
          {:replace,
           [
             :candidate_token,
             :base_revision,
             :workload_id,
             :device_runtime_id,
             :due_at_ms,
             :reasons
           ]},
        conflict_target: [:agent_id, :runtime_kind, :session_id]
      )

      :ok
    else
      {:error, :invalid}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @spec delete_address(map()) :: :ok | {:error, :unavailable}
  def delete_address(%{agent_id: agent_id, runtime_kind: runtime_kind, session_id: session_id}) do
    Row
    |> where(
      [r],
      r.agent_id == ^agent_id and r.runtime_kind == ^to_string(runtime_kind) and
        r.session_id == ^session_id
    )
    |> Repo.delete_all()

    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Count missing, extra, or field-mismatched projection rows without reading S3."
  @spec uncovered_count() :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def uncovered_count do
    sql = """
    SELECT COUNT(*)::bigint
    FROM (
      SELECT e.candidate_token
      FROM session_work_backfill_expected_candidates e
      LEFT JOIN session_work_candidates c
        ON c.candidate_token = e.candidate_token
      WHERE c.candidate_token IS NULL
         OR c.agent_id IS DISTINCT FROM e.agent_id
         OR c.runtime_kind IS DISTINCT FROM e.runtime_kind
         OR c.session_id IS DISTINCT FROM e.session_id
         OR c.base_revision IS DISTINCT FROM e.base_revision
         OR c.workload_id IS DISTINCT FROM e.workload_id
         OR c.device_runtime_id IS DISTINCT FROM e.device_runtime_id
         OR c.due_at_ms IS DISTINCT FROM e.due_at_ms
         OR c.reasons IS DISTINCT FROM e.reasons

      UNION ALL

      SELECT c.candidate_token
      FROM session_work_candidates c
      LEFT JOIN session_work_backfill_expected_candidates e
        ON e.candidate_token = c.candidate_token
      WHERE e.candidate_token IS NULL
    ) gaps
    """

    case Repo.query(sql) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 -> {:ok, count}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @spec reset() :: :ok | {:error, :unavailable}
  def reset do
    Repo.delete_all(Row)
    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  @spec count() :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def count do
    {:ok, Repo.aggregate(Row, :count)}
  rescue
    _ -> {:error, :unavailable}
  end

  defp row_from_record(record) do
    %{
      candidate_token: record["token"],
      agent_id: record["agent_id"],
      runtime_kind: record["runtime_kind"],
      session_id: record["session_id"],
      base_revision: record["base_revision"],
      workload_id: record["workload_id"],
      device_runtime_id: record["device_runtime_id"],
      due_at_ms: record["recover_after_ms"],
      reasons: record["reasons"]
    }
  end

  defp valid_row?(row) do
    is_binary(row.candidate_token) and row.candidate_token != "" and
      is_binary(row.agent_id) and row.agent_id != "" and
      row.runtime_kind in @runtime_kinds and is_binary(row.session_id) and
      row.session_id != "" and
      (is_nil(row.base_revision) or
         (is_binary(row.base_revision) and row.base_revision != "")) and
      (is_nil(row.workload_id) or
         (row.runtime_kind == "external" and is_binary(row.workload_id) and
            row.workload_id != "")) and
      (is_nil(row.due_at_ms) or is_integer(row.due_at_ms)) and
      is_list(row.reasons) and row.reasons != [] and
      Enum.all?(row.reasons, &(is_binary(&1) and &1 != ""))
  end
end
