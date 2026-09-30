defmodule SalixAgent.Notifier do
  @moduledoc """
  Decoupling seam for the `agent.stream:*` PubSub subjects. The runtime emits
  lightweight events; the web/cluster layer configures an implementation that
  fans them out over `Phoenix.PubSub`.

  Default is a no-op so `salix_agent` carries no PubSub dependency. Events are
  message *references* / summaries, not bodies — consumers hydrate from the
  owner/cache (the Go reference pattern, preserved).
  """

  @callback notify(agent_id :: String.t(), event :: term()) :: :ok

  @spec notify(String.t(), term()) :: :ok
  def notify(agent_id, event) do
    Enum.each(impls(), &safe_notify(&1, agent_id, event))
    :ok
  end

  defp safe_notify(impl, agent_id, event) do
    impl.notify(agent_id, event)
  rescue
    # Notifications are best-effort hints; never let one break a round or
    # prevent another subscriber from receiving the same hint.
    _ -> :ok
  end

  defp impls do
    notifiers =
      :salix_agent
      |> Application.get_env(:notifiers, [])
      |> List.wrap()

    case Application.get_env(:salix_agent, :notifier) do
      nil -> if(notifiers == [], do: [__MODULE__.Noop], else: notifiers)
      notifier -> Enum.uniq([notifier | notifiers])
    end
  end

  defmodule Noop do
    @moduledoc false
    @behaviour SalixAgent.Notifier
    @impl true
    def notify(_agent_id, _event), do: :ok
  end
end
