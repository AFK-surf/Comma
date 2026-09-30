defmodule Comma.PluginInstallations do
  @moduledoc false

  import Ecto.Query

  alias Comma.Data.PluginInstallation
  alias Comma.Repo

  def installed_plugin_ids(workspace_id) do
    ids =
      Repo.all(
        from(installation in PluginInstallation,
          where: installation.workspace_id == ^workspace_id,
          select: installation.plugin_id
        )
      )

    {:ok, MapSet.new(ids)}
  rescue
    _error -> {:error, :plugins_unavailable}
  end

  def mark_installed(workspace_id, plugin_id) do
    now = DateTime.utc_now()

    %PluginInstallation{
      workspace_id: workspace_id,
      plugin_id: plugin_id,
      connected_observed_at: now,
      inserted_at: now,
      updated_at: now
    }
    |> Repo.insert(
      conflict_target: [:workspace_id, :plugin_id],
      on_conflict: {:replace, [:connected_observed_at, :updated_at]}
    )
    |> case do
      {:ok, _installation} -> :ok
      {:error, _changeset} -> {:error, :plugins_unavailable}
    end
  rescue
    _error -> {:error, :plugins_unavailable}
  end

  def mark_uninstalled(workspace_id, plugin_id) do
    from(installation in PluginInstallation,
      where:
        installation.workspace_id == ^workspace_id and
          installation.plugin_id == ^plugin_id
    )
    |> Repo.delete_all()

    :ok
  rescue
    _error -> {:error, :plugins_unavailable}
  end
end
