defmodule SalixStore.GroupApiKeys do
  @moduledoc """
  Postgres data access for agent group API keys
  (docs/product-features.md).

  String-keyed maps in and out, epoch seconds for every timestamp, exactly as
  `SalixStore.TenantApiKeys` does; callers never see Ecto. Domain rules (key
  generation, the per-group cap, what a valid key means) live in
  `Salix.Control.GroupApiKeys`.

  `key_hash` is the primary key and `key_id` is unique on its own, so a
  presented key resolves by one indexed read and a management call resolves by
  another. Updates and deletes are always predicated on `(group_id, key_id)`:
  one group's request can never touch another group's row.

  `kind` is `inbound` (Router post-message and Loop events) or `voice` (voice
  sessions, docs/messaging-voice.md). The per-group cap counts one kind, and a
  management call that names a kind touches only rows of that kind.
  """

  import Ecto.Query

  alias SalixStore.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:key_hash, :string, autogenerate: false}
    schema "agent_group_api_keys" do
      field(:key_id, :string)
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:name, :string)
      field(:prefix, :string)
      field(:status, :string)
      field(:kind, :string, default: "inbound")
      field(:created_by, :string)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
      field(:expires_at, :utc_datetime_usec)
      field(:last_used_at, :utc_datetime_usec)
    end
  end

  @spec get_by_hash(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_by_hash(key_hash) when is_binary(key_hash) do
    case Repo.get(Row, key_hash) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  end

  @spec get(String.t(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, :not_found}
  def get(group_id, key_id, kind \\ nil) when is_binary(group_id) and is_binary(key_id) do
    Row
    |> where([r], r.group_id == ^group_id and r.key_id == ^key_id)
    |> of_kind(kind)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  end

  @spec list_by_group(String.t(), String.t() | nil) :: [map()]
  def list_by_group(group_id, kind \\ nil) when is_binary(group_id) do
    Row
    |> where([r], r.group_id == ^group_id)
    |> of_kind(kind)
    |> order_by([r], desc: r.created_at, desc: r.key_id)
    |> Repo.all()
    |> Enum.map(&to_record/1)
  end

  @spec count_by_group(String.t(), String.t() | nil) :: non_neg_integer()
  def count_by_group(group_id, kind \\ nil) when is_binary(group_id) do
    Row
    |> where([r], r.group_id == ^group_id)
    |> of_kind(kind)
    |> Repo.aggregate(:count)
  end

  defp of_kind(query, nil), do: query
  defp of_kind(query, kind) when is_binary(kind), do: where(query, [r], r.kind == ^kind)

  @doc """
  Insert a new key. `{:error, :exists}` when the hash or the id is already
  taken (a random collision, which the caller may retry).

  `max_per_group` counts keys of the record's kind inside the same
  transaction as the insert, so two concurrent creates cannot both squeeze
  past the cap.
  """
  @spec insert(map(), pos_integer()) :: {:ok, map()} | {:error, :exists | :limit_reached}
  def insert(%{"key_hash" => _} = record, max_per_group) when is_integer(max_per_group) do
    row = from_record(record)

    Repo.transaction(fn ->
      # The advisory lock serializes creates for one group; the count that
      # follows is then exact, and the cap is a real cap.
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [row.group_id])

      if count_by_group(row.group_id, row.kind) >= max_per_group do
        Repo.rollback(:limit_reached)
      else
        case Repo.insert(row, on_conflict: :nothing, conflict_target: :key_hash) do
          {:ok, %Row{}} ->
            case Repo.get(Row, row.key_hash) do
              %Row{key_id: key_id} = landed when key_id == row.key_id -> to_record(landed)
              _other -> Repo.rollback(:exists)
            end

          {:error, _changeset} ->
            Repo.rollback(:exists)
        end
      end
    end)
  rescue
    # A unique violation on `key_id` raises rather than conflicting: read it as
    # the same "taken" answer the hash path gives.
    _error in Ecto.ConstraintError -> {:error, :exists}
  end

  @doc """
  Update `name`, `status`, `expires_at` (any subset) on one group's key. With
  a `kind`, only a key of that kind matches.
  """
  @spec update(String.t(), String.t(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, :not_found}
  def update(group_id, key_id, changes, kind \\ nil) when is_map(changes) do
    now = DateTime.utc_now()

    fields =
      changes
      |> Map.take(["name", "status", "expires_at"])
      |> Enum.map(fn
        {"expires_at", value} -> {:expires_at, from_epoch(value)}
        {key, value} -> {String.to_existing_atom(key), value}
      end)
      |> Keyword.put(:updated_at, now)

    Row
    |> where([r], r.group_id == ^group_id and r.key_id == ^key_id)
    |> of_kind(kind)
    |> Repo.update_all(set: fields)
    |> case do
      {1, _} -> get(group_id, key_id)
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Delete predicated on both group and id (and `kind` when given); :ok when
  already absent.
  """
  @spec delete(String.t(), String.t(), String.t() | nil) :: :ok
  def delete(group_id, key_id, kind \\ nil) when is_binary(group_id) and is_binary(key_id) do
    Row
    |> where([r], r.group_id == ^group_id and r.key_id == ^key_id)
    |> of_kind(kind)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Record a use, but only when the stored mark is older than `min_interval_s`:
  a busy caller writes one row per minute, not one per message.
  """
  @spec touch_last_used(String.t(), pos_integer()) :: :ok
  def touch_last_used(key_id, min_interval_s) when is_binary(key_id) do
    now = DateTime.utc_now()
    threshold = DateTime.add(now, -min_interval_s, :second)

    Row
    |> where([r], r.key_id == ^key_id)
    |> where([r], is_nil(r.last_used_at) or r.last_used_at < ^threshold)
    |> Repo.update_all(set: [last_used_at: now])

    :ok
  end

  defp to_record(%Row{} = row) do
    %{
      "key_hash" => row.key_hash,
      "key_id" => row.key_id,
      "tenant_id" => row.tenant_id,
      "group_id" => row.group_id,
      "name" => row.name,
      "prefix" => row.prefix,
      "status" => row.status,
      "kind" => row.kind,
      "created_by" => row.created_by,
      "created_at" => to_epoch(row.created_at),
      "updated_at" => to_epoch(row.updated_at),
      "expires_at" => to_epoch(row.expires_at),
      "last_used_at" => to_epoch(row.last_used_at)
    }
  end

  defp from_record(record) do
    %Row{
      key_hash: record["key_hash"],
      key_id: record["key_id"],
      tenant_id: record["tenant_id"],
      group_id: record["group_id"],
      name: record["name"],
      prefix: record["prefix"],
      status: record["status"] || "active",
      kind: record["kind"] || "inbound",
      created_by: record["created_by"],
      created_at: from_epoch(record["created_at"]),
      updated_at: from_epoch(record["updated_at"] || record["created_at"]),
      expires_at: from_epoch(record["expires_at"]),
      last_used_at: from_epoch(record["last_used_at"])
    }
  end

  defp to_epoch(nil), do: nil
  defp to_epoch(%DateTime{} = dt), do: DateTime.to_unix(dt, :second)

  defp from_epoch(nil), do: nil
  defp from_epoch(%DateTime{} = dt), do: dt

  defp from_epoch(seconds) when is_integer(seconds),
    do: DateTime.from_unix!(seconds * 1_000_000, :microsecond)
end
