defmodule SalixStore.FeishuTenantApps do
  @moduledoc """
  Postgres data access for Feishu bot app records (docs/storage-search.md).

  One row per tenant, a field-parity image of the retired S3 blob
  (`ctl/feishu/tenant_apps/{tenant_id}.json`): string-keyed maps in and out,
  `updated_at` in epoch seconds exactly as `Salix.Control.Store.now/0` produced.
  The app id and the three bot secrets (`app_secret`, `verification_token`,
  `encrypt_key`) are stored as-is, so `Salix.Control.Tenants` keeps all its
  merge/redaction logic and never sees Ecto.
  """

  import Ecto.Query

  alias SalixStore.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:tenant_id, :string, autogenerate: false}
    schema "feishu_tenant_apps" do
      field(:app_id, :string)
      field(:app_secret, :string)
      field(:verification_token, :string)
      field(:encrypt_key, :string)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(tenant_id) when is_binary(tenant_id) do
    case Repo.get(Row, tenant_id) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  end

  @doc "Create or replace the record for `tenant_id`."
  @spec put(map()) :: {:ok, map()}
  def put(%{"tenant_id" => tenant_id} = record) when is_binary(tenant_id) do
    row = from_record(record)

    {:ok, _} =
      Repo.insert(row,
        on_conflict:
          {:replace, [:app_id, :app_secret, :verification_token, :encrypt_key, :updated_at]},
        conflict_target: :tenant_id,
        # The row carries the Feishu bot secrets; keep them out of the Ecto query
        # log (which prints bind parameters at debug level).
        log: false
      )

    {:ok, to_record(row)}
  end

  @spec delete(String.t()) :: :ok
  def delete(tenant_id) when is_binary(tenant_id) do
    Row |> where([r], r.tenant_id == ^tenant_id) |> Repo.delete_all()
    :ok
  end

  @doc """
  Idempotent import for the cutover step. A pre-existing identical row is fine;
  a pre-existing divergent row is a hard error (the equality gate must abort).
  """
  @spec import_record(map()) :: :ok | {:error, {:divergent_row, String.t()}}
  def import_record(%{"tenant_id" => tenant_id} = record) when is_binary(tenant_id) do
    row = from_record(record)
    Repo.insert(row, on_conflict: :nothing, conflict_target: :tenant_id, log: false)

    case Repo.get(Row, tenant_id) do
      %Row{} = landed ->
        if to_record(landed) == canonical(record),
          do: :ok,
          else: {:error, {:divergent_row, tenant_id}}

      nil ->
        {:error, {:divergent_row, tenant_id}}
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
      "tenant_id" => record["tenant_id"],
      "app_id" => record["app_id"] || "",
      "app_secret" => record["app_secret"] || "",
      "verification_token" => record["verification_token"] || "",
      "encrypt_key" => record["encrypt_key"] || "",
      "updated_at" => record["updated_at"]
    }
  end

  defp to_record(%Row{} = row) do
    %{
      "tenant_id" => row.tenant_id,
      "app_id" => row.app_id,
      "app_secret" => row.app_secret,
      "verification_token" => row.verification_token,
      "encrypt_key" => row.encrypt_key,
      "updated_at" => DateTime.to_unix(row.updated_at, :second)
    }
  end

  defp from_record(record) do
    %Row{
      tenant_id: record["tenant_id"],
      app_id: record["app_id"] || "",
      app_secret: record["app_secret"] || "",
      verification_token: record["verification_token"] || "",
      encrypt_key: record["encrypt_key"] || "",
      updated_at: DateTime.from_unix!((record["updated_at"] || 0) * 1_000_000, :microsecond)
    }
  end
end
