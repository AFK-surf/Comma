defmodule SalixAgent.SSH do
  @moduledoc """
  Outbound SSH for Agents (`ssh.*` tools, `SalixAgent.Tools.SSH`).

  Group-owned durable data: the SSH client key (`SalixAgent.SSH.Identity`)
  and the trust-on-first-use host keys (`SalixAgent.SSH.KnownHosts`), both
  under `SalixStore.Keys.ctl_group_ssh_prefix/1`. Sessions
  (`SalixAgent.SSH.Sessions`) are node-local and not durable.
  """

  alias SalixStore.{Keys, S3}

  @doc """
  Delete the Group's SSH key and trusted host keys. Called before the Group
  record is deleted, so a failure leaves the Group in place for a retry.
  """
  @spec delete_group_data(String.t()) :: :ok | {:error, term()}
  def delete_group_data(group_id) when is_binary(group_id) and group_id != "" do
    [Keys.ctl_group_ssh_identity(group_id), Keys.ctl_group_ssh_known_hosts(group_id)]
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case S3.delete(key) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:ssh_group_data_delete_failed, reason}}}
      end
    end)
  end
end
