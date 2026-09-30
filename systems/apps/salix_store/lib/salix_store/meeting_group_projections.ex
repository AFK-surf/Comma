defmodule SalixStore.MeetingGroupProjections do
  @moduledoc """
  PostgreSQL projection for bounded meeting lookup by product group.

  Meeting state remains authoritative in S3. A projection row is written
  before a new meeting state and is re-verified against that state on read;
  a later online release backfill seals `meeting_group_projection_v1` only
  after the projection-first writer has already reached every environment and
  every pre-existing state has a row.

  Modeled in `tla/salix/MeetingGroupIndex.tla`.
  """

  alias SalixStore.Repo

  @marker_name "meeting_group_projection_v1"
  @max_limit 50

  @spec ensure(String.t(), String.t()) ::
          :ok | {:error, :identity_conflict | :invalid | :unavailable}
  def ensure(group_id, meeting_id) when is_binary(group_id) and is_binary(meeting_id) do
    if valid_identity?(group_id) and valid_identity?(meeting_id) do
      case Repo.query(
             """
             INSERT INTO meeting_group_projections (meeting_id, group_id)
             VALUES ($1, $2)
             ON CONFLICT (meeting_id) DO UPDATE
             SET group_id = meeting_group_projections.group_id
             RETURNING group_id
             """,
             [meeting_id, group_id]
           ) do
        {:ok, %{rows: [[^group_id]]}} -> :ok
        {:ok, %{rows: [[_other_group]]}} -> {:error, :identity_conflict}
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def ensure(_group_id, _meeting_id), do: {:error, :invalid}

  @spec list_group(String.t(), keyword()) ::
          {:ok, %{meeting_ids: [String.t()], truncated: boolean()}}
          | {:error, :invalid | :unavailable}
  def list_group(group_id, opts \\ [])

  def list_group(group_id, opts) when is_binary(group_id) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 25)

    if valid_identity?(group_id) and is_integer(limit) and limit in 1..@max_limit and
         Keyword.keys(opts) -- [:limit] == [] do
      case Repo.query(
             """
             SELECT meeting_id
             FROM meeting_group_projections
             WHERE group_id = $1
             ORDER BY meeting_id
             LIMIT $2
             """,
             [group_id, limit + 1]
           ) do
        {:ok, %{rows: rows}} ->
          ids = Enum.map(rows, &hd/1)
          {:ok, %{meeting_ids: Enum.take(ids, limit), truncated: length(ids) > limit}}

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def list_group(_group_id, _opts), do: {:error, :invalid}

  @doc "Read one bounded page in stable meeting-ID order, not chronological order."
  def list_group_page(group_id, after_id \\ nil) do
    if is_binary(group_id) and valid_identity?(group_id) and
         (is_nil(after_id) or (is_binary(after_id) and byte_size(after_id) in 1..128)) do
      case Repo.query(
             """
             SELECT meeting_id FROM meeting_group_projections
             WHERE group_id = $1 AND meeting_id > $2
             ORDER BY meeting_id LIMIT 21
             """,
             [group_id, after_id || ""],
             timeout: 2_000
           ) do
        {:ok, %{rows: rows}} ->
          ids = rows |> Enum.take(20) |> Enum.map(&hd/1)
          {:ok, %{meeting_ids: ids, next_cursor: if(length(rows) > 20, do: List.last(ids))}}

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec fetch_group(String.t()) :: {:ok, String.t()} | {:error, :not_found | :unavailable}
  def fetch_group(meeting_id) when is_binary(meeting_id) and meeting_id != "" do
    case Repo.query(
           "SELECT group_id FROM meeting_group_projections WHERE meeting_id = $1",
           [meeting_id]
         ) do
      {:ok, %{rows: [[group_id]]}} -> {:ok, group_id}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def fetch_group(_meeting_id), do: {:error, :not_found}

  @spec ready?() :: boolean()
  def ready?, do: marker_status() == :present

  @doc "Three-state release marker read; database failure is never treated as absence."
  @spec marker_status() :: :present | :absent | {:error, term()}
  def marker_status do
    case Repo.query("SELECT 1 FROM salix_cutover_markers WHERE name = $1", [@marker_name]) do
      {:ok, %{rows: [[1]]}} -> :present
      {:ok, %{rows: []}} -> :absent
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec mark_ready(map()) :: :ok | {:error, :unavailable}
  def mark_ready(evidence) when is_map(evidence) do
    case Repo.query(
           """
           INSERT INTO salix_cutover_markers (name, completed_at, evidence)
           VALUES ($1, now(), $2)
           ON CONFLICT (name) DO NOTHING
           """,
           [@marker_name, evidence]
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec count() :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def count do
    case Repo.query("SELECT count(*) FROM meeting_group_projections") do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp valid_identity?(value),
    do: value != "" and String.valid?(value) and String.trim(value) != ""
end
