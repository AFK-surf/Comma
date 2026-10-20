defmodule Comma.Devices.DuplicateCleanup do
  @moduledoc """
  One-time removal of the duplicate devices the desktop app made from
  2026-10-08 to 2026-10-09, when it did not keep its device id and each
  credential mint started a new device (Comma migration 20261019130000).

  For each Workspace's Group, `SalixEnv.ConnectorTokens.remove_superseded_devices/2`
  removes an offline device when the same user has a more recently active
  device of the same machine (client, hostname, OS and architecture). Online
  devices and each machine's most recently active device stay. A removal
  revokes the device's credentials first, as Settings device removal does.

  Workspaces are read in pages of 500 through the caller's repo. A device or
  Group that cannot be read or removed is kept and counted in `failed`; the
  pass never stops on one. When Comma has no Workspace, Salix is not started.
  """

  import Ecto.Query

  require Logger

  alias Comma.Data.Workspace

  @page 500

  @type summary :: %{
          groups: non_neg_integer(),
          removed: non_neg_integer(),
          failed: non_neg_integer()
        }

  @spec run(module()) :: {:ok, summary()}
  def run(repo) do
    if repo.exists?(scoped_workspaces()) do
      {:ok, _} = Application.ensure_all_started(:salix_store)
      pass(repo, nil, %{groups: 0, removed: 0, failed: 0})
    else
      {:ok, %{groups: 0, removed: 0, failed: 0}}
    end
  end

  defp pass(repo, after_id, summary) do
    rows =
      scoped_workspaces()
      |> then(fn query -> if after_id, do: where(query, [w], w.id > ^after_id), else: query end)
      |> order_by([w], asc: w.id)
      |> limit(@page)
      |> select([w], {w.id, w.salix_tenant_id, w.salix_group_id})
      |> repo.all()

    summary = Enum.reduce(rows, summary, &clean_group/2)

    case List.last(rows) do
      {last_id, _tenant, _group} when length(rows) == @page -> pass(repo, last_id, summary)
      _ -> finish(summary)
    end
  end

  defp clean_group({workspace_id, tenant_id, group_id}, summary) do
    summary = %{summary | groups: summary.groups + 1}

    case SalixEnv.ConnectorTokens.remove_superseded_devices(tenant_id, group_id) do
      {:ok, %{removed: removed, failed: failed}} ->
        Enum.each(failed, fn {device_id, reason} ->
          Logger.warning(
            "duplicate device kept: workspace=#{workspace_id} device=#{device_id} reason=#{inspect(reason)}"
          )
        end)

        %{
          summary
          | removed: summary.removed + length(removed),
            failed: summary.failed + length(failed)
        }

      {:error, reason} ->
        Logger.warning(
          "duplicate devices not read: workspace=#{workspace_id} reason=#{inspect(reason)}"
        )

        %{summary | failed: summary.failed + 1}
    end
  end

  defp finish(summary) do
    Logger.info("duplicate device cleanup: #{inspect(summary)}")
    {:ok, summary}
  end

  defp scoped_workspaces do
    from(w in Workspace,
      where: not is_nil(w.salix_tenant_id) and not is_nil(w.salix_group_id)
    )
  end
end
