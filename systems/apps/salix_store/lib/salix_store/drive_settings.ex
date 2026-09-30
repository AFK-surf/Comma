defmodule SalixStore.DriveSettings do
  @moduledoc """
  Postgres data access for Drive settings: where the Synchronicity control
  plane that serves the agents' `/drive` mount lives.

  One row per **scope**: a tenant id, or `default_scope/0` for the
  deployment-wide default. The shape follows `SalixStore.ComposioSettings`:
  string-keyed maps in and out, `updated_at` in epoch seconds, so
  `Salix.Control.DriveSettings` keeps its resolution and redaction logic and
  never sees Ecto.
  """

  import Ecto.Query

  alias SalixStore.Repo

  # Reserved scope for the deployment default. Tenant ids are generated
  # identifiers and never take this value.
  @default_scope "__drive_default__"

  @doc "The reserved scope under which the deployment default record is stored."
  @spec default_scope() :: String.t()
  def default_scope, do: @default_scope

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:scope, :string, autogenerate: false}
    schema "drive_settings" do
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
        on_conflict: {:replace, [:base_url, :enabled, :updated_at]},
        conflict_target: :scope
      )

    {:ok, to_record(row)}
  end

  @spec delete(String.t()) :: :ok
  def delete(scope) when is_binary(scope) do
    Row |> where([r], r.scope == ^scope) |> Repo.delete_all()
    :ok
  end

  defp to_record(%Row{} = row) do
    %{
      "base_url" => row.base_url,
      "enabled" => row.enabled,
      "updated_at" => DateTime.to_unix(row.updated_at, :second)
    }
  end

  defp from_record(scope, record) do
    %Row{
      scope: scope,
      base_url: record["base_url"] || "",
      enabled: record["enabled"] != false,
      updated_at: DateTime.from_unix!((record["updated_at"] || 0) * 1_000_000, :microsecond)
    }
  end
end
