defmodule Salix.Bindings.IMAgentControl do
  @moduledoc false

  @behaviour SalixIM.Ports.AgentControl

  # The same owner-routed, expected-session-fenced operation used by the BFT dashboard.
  @impl true
  def switch_router_session(agent_id, tenant_id, expected_session_id),
    do: SalixAgent.AgentActor.switch_router_session(agent_id, tenant_id, expected_session_id)

  # Through `SalixAgent.Runtime`, not `InternalAgentRuntime` directly: an
  # external-runtime Router is a legal configuration, and calling the internal
  # store for one returns a storage error instead of a reason anyone can act on.
  @impl true
  def session_status(agent_id, session_id) do
    agent_id |> SalixAgent.Runtime.session_status(session_id) |> normalize()
  end

  @impl true
  def compact_session(agent_id, session_id) do
    agent_id |> SalixAgent.Runtime.compact_session(session_id) |> normalize()
  end

  @impl true
  def emergency_compact_session(agent_id, session_id) do
    agent_id |> SalixAgent.Runtime.emergency_compact_session(session_id) |> normalize()
  end

  # `Runtime` refuses a non-internal agent with the HTTP-shaped `:bad_request`
  # it shares with every other operation. That term is meaningless in a chat —
  # it reads as though the SENDER did something wrong — and its message is not
  # written for end users. Translating it here, at the boundary that knows both
  # sides, keeps the port's reasons typed and lets the chat surface choose its
  # own wording.
  defp normalize({:error, {:bad_request, _message}}), do: {:error, :internal_runtime_only}
  defp normalize(other), do: other
end
