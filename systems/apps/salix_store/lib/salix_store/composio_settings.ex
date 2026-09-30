defmodule SalixStore.ComposioSettings do
  @moduledoc """
  Postgres data access for Composio settings (docs/storage-search.md).

  One row per **scope**: a tenant id, or `default_scope/0` for the
  deployment-wide default record (retired S3 key `ctl/composio/default.json`).
  Rows are field-parity images of the S3 blobs — string-keyed maps in and out,
  `updated_at` in epoch seconds exactly as `Salix.Control.Store.now/0` produced
  — so `Salix.Control.ComposioSettings` keeps all its resolution/merge/redaction
  logic and never sees Ecto. Tenant ids are `ten..`-shaped and never collide
  with the reserved default scope.
  """

  import Ecto.Query

  alias SalixStore.Repo

  # Reserved scope for the deployment default. A real tenant id can never take
  # this value (tenant ids are generated identifiers, never this literal).
  @default_scope "__composio_default__"

  @doc "The reserved scope under which the deployment default record is stored."
  @spec default_scope() :: String.t()
  def default_scope, do: @default_scope

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:scope, :string, autogenerate: false}
    schema "composio_settings" do
      field(:api_key, :string)
      field(:webhook_secret, :string, redact: true)
      field(:base_url, :string)
      field(:enabled, :boolean)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(scope) when is_binary(scope) do
    case Repo.get(Row, scope) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  end

  @doc "Create or replace the record at `scope`."
  @spec put(String.t(), map()) :: {:ok, map()}
  def put(scope, %{} = record) when is_binary(scope) do
    row = from_record(scope, record)

    {:ok, _} =
      Repo.insert(row,
        on_conflict: {:replace, [:api_key, :base_url, :enabled, :updated_at, :webhook_secret]},
        conflict_target: :scope,
        # The row carries the Composio api_key; keep the secret out of the Ecto
        # query log (which prints bind parameters at debug level).
        log: false
      )

    {:ok, to_record(row)}
  end

  @doc "Resolve the secret ingress URL without scanning settings."
  def by_webhook_secret(secret) when is_binary(secret) and byte_size(secret) == 43 do
    case Repo.one(from(r in Row, where: r.webhook_secret == ^secret and r.enabled == true),
           log: false
         ) do
      nil -> {:error, :not_found}
      row -> {:ok, row.scope, to_record(row)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def by_webhook_secret(_), do: {:error, :not_found}

  @doc "Serialize settings changes and webhook registration within this scope."
  def locked(scope, fun) do
    Repo.transaction(
      fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["composio_settings:" <> scope])

        case fun.() do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: 60_000
    )
  rescue
    _ -> {:error, :unavailable}
  end

  @spec delete(String.t()) :: :ok
  def delete(scope) when is_binary(scope) do
    Row |> where([r], r.scope == ^scope) |> Repo.delete_all()
    :ok
  end

  @doc """
  Idempotent import for the cutover step. A pre-existing identical row is fine;
  a pre-existing divergent row is a hard error (the equality gate must abort).
  """
  @spec import_record(String.t(), map()) :: :ok | {:error, {:divergent_row, String.t()}}
  def import_record(scope, %{} = record) when is_binary(scope) do
    row = from_record(scope, record)
    Repo.insert(row, on_conflict: :nothing, conflict_target: :scope, log: false)

    case Repo.get(Row, scope) do
      %Row{} = landed ->
        if to_record(landed) == canonical(record),
          do: :ok,
          else: {:error, {:divergent_row, scope}}

      nil ->
        {:error, {:divergent_row, scope}}
    end
  end

  @doc "Every row as `{scope, record}`, for the cutover equality gate."
  @spec all_scoped_records() :: [{String.t(), map()}]
  def all_scoped_records do
    Row |> Repo.all() |> Enum.map(fn %Row{scope: scope} = row -> {scope, to_record(row)} end)
  end

  @doc "Canonical comparable shape of an S3-or-PG record (scope-independent fields)."
  @spec canonical(map()) :: map()
  def canonical(record) when is_map(record) do
    %{
      "api_key" => record["api_key"],
      "webhook_secret" => record["webhook_secret"],
      "base_url" => record["base_url"] || "",
      "enabled" => record["enabled"] != false,
      "updated_at" => record["updated_at"]
    }
  end

  defp to_record(%Row{} = row) do
    %{
      "api_key" => row.api_key,
      "webhook_secret" => row.webhook_secret,
      "base_url" => row.base_url,
      "enabled" => row.enabled,
      "updated_at" => DateTime.to_unix(row.updated_at, :second)
    }
  end

  defp from_record(scope, record) do
    %Row{
      scope: scope,
      api_key: record["api_key"],
      webhook_secret: record["webhook_secret"],
      base_url: record["base_url"] || "",
      enabled: record["enabled"] != false,
      updated_at: DateTime.from_unix!((record["updated_at"] || 0) * 1_000_000, :microsecond)
    }
  end
end
