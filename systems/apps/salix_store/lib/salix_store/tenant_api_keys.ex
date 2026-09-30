defmodule SalixStore.TenantApiKeys do
  @moduledoc """
  Postgres data access for tenant API keys (docs/storage-search.md).

  Rows are field-parity images of the retired S3 records: string-keyed maps in
  and out, `created_at` in epoch seconds exactly as `Salix.Control.Store.now/0`
  produced. Callers never see Ecto. Domain logic (tenant existence, key
  generation, HTTP shapes) stays in `Salix.Control.Tenants`.

  `key_hash` is globally unique (the migrated layout implied this: lookup was
  by hash alone). Deletes are always predicated on `(tenant_id, key_hash)` so
  one tenant's request can never remove another tenant's row.
  """

  import Ecto.Query

  alias SalixStore.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:key_hash, :string, autogenerate: false}
    schema "tenant_api_keys" do
      field(:tenant_id, :string)
      field(:name, :string)
      field(:created_at, :utc_datetime_usec)
    end
  end

  @spec get_by_hash(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_by_hash(key_hash) when is_binary(key_hash) do
    case Repo.get(Row, key_hash) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  end

  @spec list_by_tenant(String.t()) :: [map()]
  def list_by_tenant(tenant_id) when is_binary(tenant_id) do
    Row
    |> where([r], r.tenant_id == ^tenant_id)
    |> order_by([r], desc: r.created_at, desc: r.key_hash)
    |> Repo.all()
    |> Enum.map(&to_record/1)
  end

  @doc """
  Insert a new key record. `{:error, :exists}` mirrors the S3 create-once 412.
  """
  @spec insert(map()) :: {:ok, map()} | {:error, :exists}
  def insert(%{"key_hash" => _} = record) do
    row = from_record(record)

    case Repo.insert(row, on_conflict: :nothing, conflict_target: :key_hash) do
      {:ok, %Row{}} ->
        case Repo.get(Row, row.key_hash) do
          %Row{tenant_id: tenant_id} = landed when tenant_id == row.tenant_id ->
            if to_record(landed) == to_record(row),
              do: {:ok, to_record(landed)},
              else: {:error, :exists}

          _ ->
            {:error, :exists}
        end
    end
  end

  @doc "Delete predicated on both tenant and hash; :ok when already absent."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(tenant_id, key_hash) when is_binary(tenant_id) and is_binary(key_hash) do
    Row
    |> where([r], r.tenant_id == ^tenant_id and r.key_hash == ^key_hash)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Idempotent import for the cutover step. A pre-existing identical row is fine;
  a pre-existing divergent row is a hard error (the equality gate must abort).
  """
  @spec import_record(map()) :: :ok | {:error, {:divergent_row, String.t()}}
  def import_record(%{"key_hash" => key_hash} = record) do
    row = from_record(record)
    Repo.insert(row, on_conflict: :nothing, conflict_target: :key_hash)

    case Repo.get(Row, key_hash) do
      %Row{} = landed ->
        if to_record(landed) == canonical(record),
          do: :ok,
          else: {:error, {:divergent_row, key_hash}}

      nil ->
        {:error, {:divergent_row, key_hash}}
    end
  end

  @doc "Every row as a canonical record, for the cutover equality gate."
  @spec all_records() :: [map()]
  def all_records do
    Row |> Repo.all() |> Enum.map(&to_record/1)
  end

  @doc "Canonical comparable shape of an S3-or-PG record."
  @spec canonical(map()) :: map()
  def canonical(record) when is_map(record) do
    %{
      "key_hash" => record["key_hash"],
      "tenant_id" => record["tenant_id"],
      "name" => record["name"] || "API key",
      "created_at" => record["created_at"]
    }
  end

  defp to_record(%Row{} = row) do
    %{
      "key_hash" => row.key_hash,
      "tenant_id" => row.tenant_id,
      "name" => row.name,
      "created_at" => DateTime.to_unix(row.created_at, :second)
    }
  end

  defp from_record(record) do
    %Row{
      key_hash: record["key_hash"],
      tenant_id: record["tenant_id"],
      name: record["name"] || "API key",
      created_at: DateTime.from_unix!(record["created_at"] * 1_000_000, :microsecond)
    }
  end
end
