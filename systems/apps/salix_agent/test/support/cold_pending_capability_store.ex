defmodule SalixAgent.TestSupport.ColdPendingCapabilityStore do
  @moduledoc false

  def pending_capability_request?(_agent_id, _session_id, _tool_call_id), do: true

  def reconcile_capability_request(_agent_id, _session_id, tool_call_id, _result) do
    {:ok,
     %{
       "request_id" => "cold-" <> tool_call_id,
       "status" => "pending",
       "expires_at" => System.system_time(:second) + 600
     }}
  end
end
