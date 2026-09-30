defmodule SalixIM.Test.IFCCapabilityRequestsStub do
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
    Application.put_env(:salix_im, :capability_request_mod, __MODULE__)
    :persistent_term.put(@caller_key, self())
    :persistent_term.put(@request_key, request)
    :ok
  end

  @doc "Removes the stub and everything it held."
  def uninstall do
    Application.delete_env(:salix_im, :capability_request_mod)
    :persistent_term.erase(@caller_key)
    :persistent_term.erase(@request_key)
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

  defp request, do: :persistent_term.get(@request_key, nil)

  defp notify(message) do
    case :persistent_term.get(@caller_key, nil) do
      pid when is_pid(pid) -> send(pid, message)
      _none -> :ok
    end
  end
end
