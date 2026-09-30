defmodule SalixStore.SlackTriageChannelCutover do
  @moduledoc """
  Monotonic release barrier for Slack Triage's multi-channel authority.

  Before the barrier, every reader and writer uses the single-channel S3
  authority. PostgreSQL rows may be prepared, but remain dark. After the
  barrier, every reader and writer uses PostgreSQL exclusively; there is no
  per-connect or per-channel fallback.
  """

  alias SalixStore.Repo

  @marker_name "slack_triage_channels_v1"
  @preparing_marker_name "slack_triage_channels_v1_preparing"
  @advisory_lock_namespace 1_397_501_267
  @advisory_lock_key 1
  @preparation_evidence ~w(
    schema_version
    preparation_id
    all_readers_current
    old_control_writers_retired
  )
  @required_evidence ~w(
    schema_version
    preparation_id
    all_readers_current
    old_control_writers_retired
    legacy_rows_materialized
    generation_fences_verified
  )

  @spec mode() :: :legacy | :projected | {:error, :unavailable}
  def mode do
    case Repo.query("SELECT 1 FROM salix_cutover_markers WHERE name = $1", [@marker_name]) do
      {:ok, %{rows: [[1]]}} -> :projected
      {:ok, %{rows: []}} -> :legacy
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Freezes every legacy Slack authority writer before materialization begins."
  @spec begin_preparing(map()) ::
          {:ok, String.t()} | {:error, :invalid_evidence | :already_projected | :unavailable}
  def begin_preparing(evidence) when is_map(evidence) do
    if valid_preparation_evidence?(evidence) do
      preparation_id = evidence["preparation_id"]

      transaction_with_exclusive_lock(fn ->
        with {:ok, false} <- marker_exists?(@marker_name),
             {:ok, preparation} <- marker_evidence(@preparing_marker_name) do
          case preparation do
            nil ->
              insert_marker(@preparing_marker_name, evidence)
              evidence["preparation_id"]

            %{"preparation_id" => ^preparation_id} ->
              preparation_id

            _other ->
              Repo.rollback(:invalid_evidence)
          end
        else
          {:ok, true} -> Repo.rollback(:already_projected)
          {:error, _reason} -> Repo.rollback(:unavailable)
        end
      end)
      |> normalize_transaction_result()
      |> case do
        {:ok, preparation_id} -> {:ok, preparation_id}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_evidence}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def begin_preparing(_evidence), do: {:error, :invalid_evidence}

  @doc "Runs one authority-changing S3 write outside the durable freeze window."
  @spec with_authority_write((-> result)) :: result | {:error, atom()} when result: term()
  def with_authority_write(fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      with :ok <- acquire_shared_lock(),
           {:ok, projected?} <- marker_exists?(@marker_name),
           {:ok, preparing?} <- marker_exists?(@preparing_marker_name) do
        if preparing? and not projected? do
          Repo.rollback(:slack_triage_channel_cutover_pending)
        else
          fun.()
        end
      else
        {:error, _reason} -> Repo.rollback(:slack_triage_authority_unavailable)
      end
    end)
    |> unwrap_transaction_result()
  rescue
    _exception -> {:error, :slack_triage_authority_unavailable}
  catch
    :exit, _reason -> {:error, :slack_triage_authority_unavailable}
  end

  @spec mark_ready(map()) :: :ok | {:error, :invalid_evidence | :unavailable}
  def mark_ready(evidence) when is_map(evidence) do
    if valid_evidence?(evidence) do
      transaction_with_exclusive_lock(fn ->
        with {:ok, preparation} <- marker_evidence(@preparing_marker_name),
             true <- matching_preparation?(preparation, evidence) do
          insert_marker(@marker_name, evidence)
          :ok
        else
          false -> Repo.rollback(:invalid_evidence)
          {:error, _reason} -> Repo.rollback(:unavailable)
        end
      end)
      |> normalize_transaction_result()
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_evidence}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def mark_ready(_evidence), do: {:error, :invalid_evidence}

  defp transaction_with_exclusive_lock(fun) do
    Repo.transaction(fn ->
      case Repo.query(
             "SELECT pg_advisory_xact_lock($1, $2)",
             [@advisory_lock_namespace, @advisory_lock_key]
           ) do
        {:ok, _result} -> fun.()
        {:error, _reason} -> Repo.rollback(:unavailable)
      end
    end)
  end

  defp acquire_shared_lock do
    case Repo.query(
           "SELECT pg_advisory_xact_lock_shared($1, $2)",
           [@advisory_lock_namespace, @advisory_lock_key]
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp marker_exists?(name) do
    case Repo.query("SELECT 1 FROM salix_cutover_markers WHERE name = $1", [name]) do
      {:ok, %{rows: [[1]]}} -> {:ok, true}
      {:ok, %{rows: []}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp marker_evidence(name) do
    case Repo.query("SELECT evidence FROM salix_cutover_markers WHERE name = $1", [name]) do
      {:ok, %{rows: [[evidence]]}} when is_map(evidence) -> {:ok, evidence}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_marker(name, evidence) do
    case Repo.query(
           """
           INSERT INTO salix_cutover_markers (name, completed_at, evidence)
           VALUES ($1, now(), $2)
           ON CONFLICT (name) DO NOTHING
           """,
           [name, evidence]
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> Repo.rollback(:unavailable)
    end
  end

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp unwrap_transaction_result({:ok, result}), do: result
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp valid_preparation_evidence?(evidence) do
    exact_evidence?(evidence, @preparation_evidence) and
      evidence["schema_version"] == 1 and
      valid_preparation_id?(evidence["preparation_id"]) and
      evidence["all_readers_current"] == true and
      evidence["old_control_writers_retired"] == true
  end

  defp valid_evidence?(evidence) do
    exact_evidence?(evidence, @required_evidence) and
      evidence["schema_version"] == 1 and
      valid_preparation_id?(evidence["preparation_id"]) and
      Enum.all?(
        @required_evidence -- ["schema_version", "preparation_id"],
        &(evidence[&1] == true)
      )
  end

  defp exact_evidence?(evidence, keys),
    do: evidence |> Map.keys() |> Enum.sort() == Enum.sort(keys)

  defp valid_preparation_id?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= 128

  defp matching_preparation?(%{"preparation_id" => id}, %{"preparation_id" => id}), do: true
  defp matching_preparation?(_preparation, _evidence), do: false
end
