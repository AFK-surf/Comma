defmodule Salix.Bindings.ProductEvents do
  @moduledoc """
  Delivers product events (a meeting's `meeting.completed`) to the Group's
  Background Loops subscribed with `loop.subscribe`
  (`SalixAgent.Loops.deliver_product_event/3`).
  """

  @behaviour SalixMeet.Ports.Events

  @impl true
  def publish(group_id, topic, event),
    do: SalixAgent.Loops.deliver_product_event(group_id, topic, event)
end
