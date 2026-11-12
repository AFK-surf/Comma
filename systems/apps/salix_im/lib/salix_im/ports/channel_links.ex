defmodule SalixIM.Ports.ChannelLinks do
  @moduledoc """
  Channel links a Router started from the chat (`channel.link`), as Salix IM
  tells their owner that a channel it binds itself got connected. Salix IM
  cannot depend on the agent runtime or the product, so the product sets the
  module that implements this behaviour at start (`config :salix_im,
  :channel_links`). Without it, nothing waits and nothing is told.

  `signal_bound/1` takes the result of `SalixIM.SignalConnects.redeem_claim/4`:
  `tenant_id`, `group_id`, `connect_id` and the new `binding`.
  """

  @callback signal_bound(bound :: %{String.t() => term()}) :: :ok

  def signal_bound(%{"tenant_id" => _, "group_id" => _} = bound) do
    case SystemsRuntime.get_env(:salix_im, :channel_links) do
      nil -> :ok
      module -> module.signal_bound(bound)
    end
  end

  def signal_bound(_bound), do: :ok
end
