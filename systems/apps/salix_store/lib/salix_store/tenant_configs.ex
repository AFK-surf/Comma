defmodule SalixStore.TenantConfigs do
  @moduledoc """
  Postgres data access for discrete tenant config records
  (docs/storage-search.md).

  One row per `(tenant_id, name)`, a field-parity image of the retired S3 blob
  `ctl/tenant_configs/{tenant_id}/{name}.json`. Unlike the flat-column credential
  tables, the payload is arbitrary JSON: the `value` column is `jsonb` and is
  carried in and out as a string-keyed map, so `Salix.Control.Tenants` keeps all
  its merge/strip logic and never sees Ecto. `updated_at` is epoch seconds
  exactly as `Salix.Control.Store.now/0` produced.

  The only two names the runtime writes today are `trajectory_eval` and
  `conversation_links`; the store is name-agnostic so historical/orphan names
  round-trip unchanged. Because the payload is JSON, the cutover equality gate
  compares the DECODED map (see `canonical/1`), never raw bytes/columns.
  """

  import Ecto.Query

  alias SalixStore.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "tenant_configs" do
      field(:tenant_id, :string, primary_key: true)
      field(:name, :string, primary_key: true)
      field(:value, :map)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(tenant_id, name) when is_binary(tenant_id) and is_binary(name) do
    case Repo.get_by(Row, tenant_id: tenant_id, name: name) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  end

  @doc "Create or replace the record for `(tenant_id, name)`."
  @spec put(map()) :: {:ok, map()}
  def put(%{"tenant_id" => tenant_id, "name" => name} = record)
      when is_binary(tenant_id) and is_binary(name) do
    row = from_record(record)

    {:ok, _} =
      Repo.insert(row,
        on_conflict: {:replace, [:value, :updated_at]},
        conflict_target: [:tenant_id, :name]
      )

    {:ok, to_record(row)}
  end

  @spec delete(String.t(), String.t()) :: :ok
  def delete(tenant_id, name) when is_binary(tenant_id) and is_binary(name) do
    Row
    |> where([r], r.tenant_id == ^tenant_id and r.name == ^name)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Idempotent import for the cutover step. A pre-existing identical row is fine;
  a pre-existing divergent row is a hard error (the equality gate must abort).
  """
  @spec import_record(map()) :: :ok | {:error, {:divergent_row, {String.t(), String.t()}}}
  def import_record(%{"tenant_id" => tenant_id, "name" => name} = record)
      when is_binary(tenant_id) and is_binary(name) do
    row = from_record(record)
    Repo.insert(row, on_conflict: :nothing, conflict_target: [:tenant_id, :name])

    case Repo.get_by(Row, tenant_id: tenant_id, name: name) do
      %Row{} = landed ->
        if to_record(landed) == canonical(record),
          do: :ok,
          else: {:error, {:divergent_row, {tenant_id, name}}}

      nil ->
        {:error, {:divergent_row, {tenant_id, name}}}
    end
  end

  @doc "Every row as a canonical record, for the cutover equality gate."
  @spec all_records() :: [map()]
  def all_records do
    Row |> Repo.all() |> Enum.map(&to_record/1)
  end

  @doc """
  Canonical comparable shape of an S3-or-PG record. The `value` is compared as a
  decoded map (jsonb round-trips string keys), so the equality gate never sees
  the raw JSON bytes.
  """
  @spec canonical(map()) :: map()
  def canonical(record) when is_map(record) do
    %{
      "tenant_id" => record["tenant_id"],
      "name" => record["name"],
      "value" => value_map(record["value"]),
      "updated_at" => record["updated_at"]
    }
  end

  defp to_record(%Row{} = row) do
    %{
      "tenant_id" => row.tenant_id,
      "name" => row.name,
      "value" => value_map(row.value),
      "updated_at" => DateTime.to_unix(row.updated_at, :second)
    }
  end

  defp from_record(record) do
    %Row{
      tenant_id: record["tenant_id"],
      name: record["name"],
      value: value_map(record["value"]),
      updated_at: DateTime.from_unix!((record["updated_at"] || 0) * 1_000_000, :microsecond)
    }
  end

  defp value_map(value) when is_map(value), do: value
  defp value_map(_), do: %{}
end
