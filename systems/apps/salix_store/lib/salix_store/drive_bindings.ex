defmodule SalixStore.DriveBindings do
  @moduledoc """
  Postgres data access for Drive bindings: one row per agent group naming
  the Synchronicity org, network and space its agents reach as `/drive`, and
  the org API key they reach it with.

  `source` says who wrote the row: `"comma"` for a binding Comma's Workspace
  convergence minted, `"manual"` for one an operator entered in the Salix
  dashboard. `base_url` is optional: a blank one means the deployment's
  Drive setting (`SalixStore.DriveSettings`) applies. `retired_key_ids` are
  earlier Comma-minted keys whose revocation is not confirmed yet.

  The api_key is stored as the other provider credentials in this store are
  (`SalixStore.ComposioSettings`, `SalixStore.OAuthProviderApps`): in the
  row, never logged (`log: false`), never returned by a redacted view.
  """

  import Ecto.Query

  alias SalixStore.Repo

  @sources ~w(comma manual)

  @doc "The values `source` may take."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:group_id, :string, autogenerate: false}
    schema "drive_bindings" do
      field(:base_url, :string)
      field(:org_slug, :string)
      field(:network, :string)
      field(:space, :string)
      field(:api_key, :string, redact: true)
      field(:api_key_id, :string)
      field(:retired_key_ids, {:array, :string})
      field(:source, :string)
      field(:enabled, :boolean)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(group_id) when is_binary(group_id) do
    case Repo.get(Row, group_id) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  end

  @doc "Create or replace the binding of `group_id`."
  @spec put(String.t(), map()) :: {:ok, map()}
  def put(group_id, %{} = record) when is_binary(group_id) do
    row = from_record(group_id, record)

    {:ok, _} =
      Repo.insert(row,
        on_conflict:
          {:replace,
           [
             :base_url,
             :org_slug,
             :network,
             :space,
             :api_key,
             :api_key_id,
             :retired_key_ids,
             :source,
             :enabled,
             :updated_at
           ]},
        conflict_target: :group_id,
        # The row carries the org API key; keep it out of the Ecto query log
        # (which prints bind parameters at debug level).
        log: false
      )

    {:ok, to_record(row)}
  end

  @spec delete(String.t()) :: :ok
  def delete(group_id) when is_binary(group_id) do
    Row |> where([r], r.group_id == ^group_id) |> Repo.delete_all()
    :ok
  end

  defp to_record(%Row{} = row) do
    %{
      "group_id" => row.group_id,
      "base_url" => row.base_url || "",
      "org_slug" => row.org_slug,
      "network" => row.network,
      "space" => row.space,
      "api_key" => row.api_key,
      "api_key_id" => row.api_key_id || "",
      "retired_key_ids" => row.retired_key_ids || [],
      "source" => row.source,
      "enabled" => row.enabled,
      "updated_at" => DateTime.to_unix(row.updated_at, :second)
    }
  end

  defp from_record(group_id, record) do
    %Row{
      group_id: group_id,
      base_url: record["base_url"] || "",
      org_slug: record["org_slug"],
      network: record["network"],
      space: record["space"],
      api_key: record["api_key"],
      api_key_id: record["api_key_id"] || "",
      retired_key_ids: record["retired_key_ids"] || [],
      source: record["source"],
      enabled: record["enabled"] != false,
      updated_at: DateTime.from_unix!((record["updated_at"] || 0) * 1_000_000, :microsecond)
    }
  end
end
