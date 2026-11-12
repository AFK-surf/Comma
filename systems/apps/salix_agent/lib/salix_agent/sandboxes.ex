defmodule SalixAgent.Sandboxes do
  @moduledoc """
  Whether this deployment has Task sandboxes set up, and whether a Group's
  Cloud VM is retired.

  `enabled?/0`: an L4ES sandbox of a Task's own is a place to offer
  (`docs/compute-devices.md#coding-sandboxes`). The product answers through
  the port `config :salix_agent, :sandboxes_mod`, a module with `enabled?/0`
  (`SalixWeb.L4ES`); without one, no.

  `cloud_vm_retired?/1`: the Group's Cloud VM is retired, for one of two reasons:

    * the Group was created where sandboxes are set up: its record has
      `cloud_vm_retired` (`Salix.Control.Groups`). A new Workspace or Project
      never has a Cloud VM;
    * the deployment retires every Group's Cloud VM
      (`config :salix_agent, :cloud_vm_retired`, from `SALIX_CLOUD_VM_RETIRED`:
      the cutover release turns it on).

  Retirement holds when L4ES configuration or its signer is missing.
  Then the Group's Cloud VM is no place to run Tasks: a Task, a Worker binding
  or a Group default that names it is refused (`:cloud_vm_retired`), and a
  sandbox takes its place in automatic placement (`SalixIM.TaskPlacement`).
  Elsewhere the Cloud VM works as before, and a sandbox is offered beside it.
  """

  alias SalixStore.{CasRecord, Ids, Keys}

  @field "cloud_vm_retired"

  @doc "The Group record field that retires its Cloud VM, written when the Group is created."
  def field, do: @field

  @spec enabled?() :: boolean()
  def enabled? do
    case SystemsRuntime.get_env(:salix_agent, :sandboxes_mod) do
      nil -> false
      mod -> mod.enabled?() == true
    end
  rescue
    _ -> false
  end

  @doc """
  Whether the Cloud VM of `group` is retired: a Group id, a Group record
  already read, or nil for no Group (then only the deployment decides).
  """
  @spec cloud_vm_retired?(String.t() | map() | nil) :: boolean()
  def cloud_vm_retired?(group),
    do: deployment_retired?() or group_retired?(group)

  defp deployment_retired?, do: SystemsRuntime.get_env(:salix_agent, :cloud_vm_retired) == true

  defp group_retired?(%{} = group), do: group[@field] == true

  defp group_retired?(group_id) when is_binary(group_id) do
    Ids.valid_group_id?(group_id) and
      match?({:ok, %{@field => true}}, CasRecord.get(Keys.ctl_group(group_id)))
  end

  defp group_retired?(_none), do: false

  @doc """
  Whether the Group's own VM (`dev-cloudvm-<group>`) is a retired Cloud VM:
  retired (`cloud_vm_retired?/1`) and not on an Agent VMM Host
  (`SalixStore.ComputeGroupStation.group_vm_on_vmm_host/1`), whose VM is not
  retired. What Salix tells about that VM, not which place it refuses.
  """
  @spec group_vm_retired?(String.t()) :: boolean()
  def group_vm_retired?(group_id) when is_binary(group_id),
    do:
      cloud_vm_retired?(group_id) and
        SalixStore.ComputeGroupStation.group_vm_on_vmm_host(group_id) != {:ok, true}

  @doc """
  Whether people are shown the Group's Cloud VM: where it is not retired,
  and, where it is, while the Group still has a Cloud VM Workload that is not
  archived (`SalixStore.Compute.group_workload/1`): someone stops it or
  removes its runner there; nothing new is placed on it.
  """
  @spec cloud_vm_shown?(String.t()) :: boolean()
  def cloud_vm_shown?(group_id) do
    not cloud_vm_retired?(group_id) or
      match?(
        {:ok, %{"status" => status}} when status != "archived",
        SalixStore.Compute.group_workload(group_id)
      )
  end

  @doc """
  The answers for Group `group_id` in one map, for a product that asks over
  RPC: the three above, and `cloud_vm_available`, whether the Group can have
  a Cloud VM (`SalixAgent.CloudVM.available?/2`).
  """
  @spec status(String.t()) :: %{String.t() => boolean()}
  def status(group_id) do
    %{
      "sandboxes" => enabled?(),
      "cloud_vm_retired" => cloud_vm_retired?(group_id),
      "cloud_vm_shown" => cloud_vm_shown?(group_id),
      "cloud_vm_available" => cloud_vm_available?(group_id)
    }
  end

  defp cloud_vm_available?(group_id) when is_binary(group_id) do
    case Ids.valid_group_id?(group_id) and CasRecord.get(Keys.ctl_group(group_id)) do
      {:ok, %{"tenant_id" => tenant_id}} -> SalixAgent.CloudVM.available?(tenant_id, group_id)
      _ -> false
    end
  end

  defp cloud_vm_available?(_group_id), do: false
end
