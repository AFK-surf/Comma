defmodule SalixIM.Sandboxes do
  @moduledoc """
  Whether this deployment has Task sandboxes set up, and whether a Group's
  Cloud VM is retired, as `SalixAgent.Sandboxes` answers them for the agent
  runtime. The product sets the port `config :salix_im, :sandboxes_mod` to
  that module (one with `enabled?/0`, `cloud_vm_retired?/1` and
  `group_vm_retired?/1`); without one, no to each.

  Where a Group's Cloud VM is retired, its Workers may create sandbox Tasks
  for work that needs a machine (`SalixIM.Provider.Internal`,
  `internal.task.create`), in place of the Cloud VM their `env.exec` reached.
  Elsewhere only a Router creates Tasks.
  """

  @spec enabled?() :: boolean()
  def enabled?, do: ask(:enabled?, [])

  @spec cloud_vm_retired?(String.t()) :: boolean()
  def cloud_vm_retired?(group_id), do: ask(:cloud_vm_retired?, [group_id])

  @doc "Whether the Group's own VM is a retired Cloud VM: retired, and not on an Agent VMM Host."
  @spec group_vm_retired?(String.t()) :: boolean()
  def group_vm_retired?(group_id), do: ask(:group_vm_retired?, [group_id])

  defp ask(question, args) do
    case SystemsRuntime.get_env(:salix_im, :sandboxes_mod) do
      nil -> false
      mod -> apply(mod, question, args) == true
    end
  rescue
    _ -> false
  end
end
