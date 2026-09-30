defmodule SalixAgent.NotifierTest do
  use ExUnit.Case, async: false

  @pid_key {__MODULE__, :pid}

  def send_event(kind, agent_id, event) do
    case :persistent_term.get(@pid_key, nil) do
      nil -> :ok
      pid -> send(pid, {:notifier, kind, agent_id, event})
    end

    :ok
  end

  defmodule LegacyNotifier do
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event), do: SalixAgent.NotifierTest.send_event(:legacy, agent_id, event)
  end

  defmodule RaisingNotifier do
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(_agent_id, _event), do: raise("notifier failed")
  end

  defmodule CommaNotifier do
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event), do: SalixAgent.NotifierTest.send_event(:comma, agent_id, event)
  end

  defmodule SalixNotifier do
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event), do: SalixAgent.NotifierTest.send_event(:salix, agent_id, event)
  end

  setup do
    prev_notifier = Application.get_env(:salix_agent, :notifier)
    prev_notifiers = Application.get_env(:salix_agent, :notifiers)

    :persistent_term.put(@pid_key, self())

    on_exit(fn ->
      :persistent_term.erase(@pid_key)
      restore(:notifier, prev_notifier)
      restore(:notifiers, prev_notifiers)
    end)

    :ok
  end

  test "notifier fan-out preserves legacy notifier and continues after a bad subscriber" do
    Application.put_env(:salix_agent, :notifier, LegacyNotifier)
    Application.put_env(:salix_agent, :notifiers, [RaisingNotifier, CommaNotifier, SalixNotifier])

    assert :ok = SalixAgent.Notifier.notify("agent-1", {:delta, "main", "hi"})

    assert_receive {:notifier, :legacy, "agent-1", {:delta, "main", "hi"}}
    assert_receive {:notifier, :comma, "agent-1", {:delta, "main", "hi"}}
    assert_receive {:notifier, :salix, "agent-1", {:delta, "main", "hi"}}
  end

  defp restore(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore(key, value), do: Application.put_env(:salix_agent, key, value)
end
