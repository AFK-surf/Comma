defmodule SalixStore.OAuthProviderApps do
  @moduledoc """
  Postgres data access for OAuth static client credentials
  (docs/storage-search.md, PR-1).

  One row per **scope**: a tenant id, or `default_scope/0` for the deployment-wide
  default app (retired S3 key `ctl/oauth/default_apps/{provider}.json`). Rows are
  field-parity images of the retired S3 blobs — string-keyed maps in and out,
  `updated_at` in epoch seconds exactly as `Salix.Control.Store.now/0` produced —
  so `Salix.Control.OAuthApps` keeps all its tenant-first resolution / redaction /
  view logic and never sees Ecto. Tenant ids are `ten..`-shaped and never collide
  with the reserved default scope. The `client_secret` is a secret, kept out of
  the Ecto query log.
  """

  import Ecto.Query

  alias SalixStore.Repo

  # Reserved scope for the deployment default. A real tenant id can never take
  # this value (tenant ids are generated identifiers, never this literal).
  @default_scope "__oauth_default__"

  @doc "The reserved scope under which the deployment default apps are stored."
  @spec default_scope() :: String.t()
  def default_scope, do: @default_scope

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "oauth_provider_apps" do
      field(:scope, :string, primary_key: true)
      field(:provider, :string, primary_key: true)
      field(:client_id, :string)
      field(:client_secret, :string)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(scope, provider) when is_binary(scope) and is_binary(provider) do
    case Repo.get_by(Row, scope: scope, provider: provider) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  end

  @doc "Create or replace the record at `(scope, provider)`."
  @spec put(String.t(), map()) :: {:ok, map()}
  def put(scope, %{"provider" => provider} = record)
      when is_binary(scope) and is_binary(provider) do
    row = from_record(scope, record)

    {:ok, _} =
      Repo.insert(row,
        on_conflict: {:replace, [:client_id, :client_secret, :updated_at]},
        conflict_target: [:scope, :provider],
        # The row carries the OAuth client_secret; keep it out of the Ecto query
        # log (which prints bind parameters at debug level).
        log: false
      )

    {:ok, to_record(row)}
  end

  @spec delete(String.t(), String.t()) :: :ok
  def delete(scope, provider) when is_binary(scope) and is_binary(provider) do
    Row
    |> where([r], r.scope == ^scope and r.provider == ^provider)
    |> Repo.delete_all()

    :ok
  end

  @doc "Every record at `scope` (a tenant's apps, or the deployment defaults)."
  @spec list_by_scope(String.t()) :: [map()]
  def list_by_scope(scope) when is_binary(scope) do
    Row
    |> where([r], r.scope == ^scope)
    |> Repo.all()
    |> Enum.map(&to_record/1)
  end

  @doc """
  Idempotent import for the cutover step. A pre-existing identical row is fine;
  a pre-existing divergent row is a hard error (the equality gate must abort).

  `opts` may carry `:timeout` — the cutover passes the exclusive-step budget so
  the insert and read-back are not cut off by Ecto's 15s default mid-transaction.
  """
  @spec import_record(String.t(), map(), keyword()) ::
          :ok | {:error, {:divergent_row, {String.t(), String.t()}}}
  def import_record(scope, %{"provider" => provider} = record, opts \\ [])
      when is_binary(scope) and is_binary(provider) do
    row = from_record(scope, record)

    Repo.insert(
      row,
      [on_conflict: :nothing, conflict_target: [:scope, :provider], log: false] ++
        Keyword.take(opts, [:timeout])
    )

    case Repo.get_by(Row, [scope: scope, provider: provider], Keyword.take(opts, [:timeout])) do
      %Row{} = landed ->
        if to_record(landed) == canonical(record),
          do: :ok,
          else: {:error, {:divergent_row, {scope, provider}}}

      nil ->
        {:error, {:divergent_row, {scope, provider}}}
    end
  end

  @doc """
  Every row as `{scope, record}`, for the cutover equality gate. `opts` may carry
  `:timeout` (the cutover passes its exclusive-step budget).
  """
  @spec all_scoped_records(keyword()) :: [{String.t(), map()}]
  def all_scoped_records(opts \\ []) do
    Row
    |> Repo.all(Keyword.take(opts, [:timeout]))
    |> Enum.map(fn %Row{scope: scope} = row -> {scope, to_record(row)} end)
  end

  @doc "Canonical comparable shape of an S3-or-PG record (scope-independent fields)."
  @spec canonical(map()) :: map()
  def canonical(record) when is_map(record) do
    %{
      "provider" => record["provider"],
      "client_id" => record["client_id"] || "",
      "client_secret" => record["client_secret"] || "",
      # from_record substitutes 0 for a nil updated_at, so canonical must too or a
      # nil-updated_at record would read back as divergent from itself.
      "updated_at" => record["updated_at"] || 0
    }
  end

  defp to_record(%Row{} = row) do
    %{
      "provider" => row.provider,
      "client_id" => row.client_id,
      "client_secret" => row.client_secret,
      "updated_at" => DateTime.to_unix(row.updated_at, :second)
    }
  end

  defp from_record(scope, record) do
    %Row{
      scope: scope,
      provider: record["provider"],
      client_id: record["client_id"] || "",
      client_secret: record["client_secret"] || "",
      updated_at: DateTime.from_unix!((record["updated_at"] || 0) * 1_000_000, :microsecond)
    }
  end
end
