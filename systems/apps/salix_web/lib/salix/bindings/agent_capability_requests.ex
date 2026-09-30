defmodule Salix.Bindings.AgentCapabilityRequests do
  @moduledoc false

  @behaviour SalixAgent.CapabilityRequests

  @impl true
  def notify_capability_request(%{"group_id" => group_id, "request_id" => request_id} = request) do
    if Process.whereis(SalixWeb.PubSub) do
      Phoenix.PubSub.broadcast(
        SalixWeb.PubSub,
        SalixAgent.CapabilityRequests.topic(group_id),
        {:capability_request_event, group_id, request_id}
      )
    end

    surface(request)

    :ok
  end

  def notify_capability_request(_request), do: :ok

  # An information-flow transfer is a question for one person, in the place
  # they are already talking to the bot, so it gets a card there as well as a
  # dashboard row (docs/verification.md). Which place
  # that is follows from the requester's own provider. Every other request type
  # keeps the dashboard as its only surface.
  defp surface(%{"request_type" => "ifc_declassify", "status" => status} = request)
       when status in [nil, "pending"],
       do: SalixIM.IFC.Confirmation.post(request)

  defp surface(_request), do: :ok
end
