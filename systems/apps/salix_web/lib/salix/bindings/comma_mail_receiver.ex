defmodule Salix.Bindings.CommaMailReceiver do
  @moduledoc "Routes a Home mail occurrence to its configured owner adapter."
  def receive(payload, status, opts) when status in [:claimed, :exists] do
    Application.fetch_env!(:salix_agent, :proactive_mail_adapter).receive_schedule(payload, opts)
  end

  def receive(_payload, {:error, reason}, _opts), do: {:error, reason}
end
