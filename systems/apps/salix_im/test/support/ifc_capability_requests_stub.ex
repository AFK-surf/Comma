defmodule SalixIM.Test.IFCCapabilityRequestsStub do
  require SystemsRuntime.Proc

  @moduledoc """
  Stands in for `SalixAgent.CapabilityRequests` across the IM seam
  (`config :salix_im, :capability_request_mod`).

  The IM domain only reads a declassification request and reports the person's
  decision back; the receipt is written on the agent side. A test that drives
  a Slack card therefore needs the request to exist and the decision to be
  observable, not a real capability store.
  """

  @request_key :ifc_capability_stub_request
  @caller_key :ifc_capability_stub_caller

  @doc "Installs the stub and the request one card will be answered against."
  def install(request) do
    SystemsRuntime.put_env(:salix_im, :capability_request_mod, __MODULE__)
    SystemsRuntime.PersistentTerm.put(@caller_key, SystemsRuntime.Proc.self())
    SystemsRuntime.PersistentTerm.put(@request_key, request)
    :ok
  end

  @doc "Removes the stub and everything it held."
  def uninstall do
    SystemsRuntime.delete_env(:salix_im, :capability_request_mod)
    SystemsRuntime.PersistentTerm.erase(@caller_key)
    SystemsRuntime.PersistentTerm.erase(@request_key)
    :ok
  end

  def get(group_id, request_id, tenant_id) do
    notify({:ifc_stub_get, group_id, request_id, tenant_id})

    case request() do
      nil -> {:error, :not_found}
      request -> {:ok, request}
    end
  end

  def decide_declassification(group_id, request_id, attrs, tenant_id) do
    notify({:ifc_stub_decided, group_id, request_id, attrs, tenant_id})
    {:ok, request()}
  end

  defp request, do: SystemsRuntime.PersistentTerm.get(@request_key, nil)

  defp notify(message) do
    case SystemsRuntime.PersistentTerm.get(@caller_key, nil) do
      pid when SystemsRuntime.Proc.is_process(pid) -> SystemsRuntime.Proc.send(pid, message)
      _none -> :ok
    end
  end
end
