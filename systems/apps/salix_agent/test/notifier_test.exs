defmodule SalixAgent.NotifierTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  @pid_key {__MODULE__, :pid}

  def send_event(kind, agent_id, event) do
    case SystemsRuntime.PersistentTerm.get(@pid_key, nil) do
      nil -> :ok
      pid -> SystemsRuntime.Proc.send(pid, {:notifier, kind, agent_id, event})
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
    prev_notifier = SystemsRuntime.get_env(:salix_agent, :notifier)
    prev_notifiers = SystemsRuntime.get_env(:salix_agent, :notifiers)

    SystemsRuntime.PersistentTerm.put(@pid_key, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SystemsRuntime.PersistentTerm.erase(@pid_key)
      restore(:notifier, prev_notifier)
      restore(:notifiers, prev_notifiers)
    end)

    :ok
  end

  test "notifier fan-out preserves legacy notifier and continues after a bad subscriber" do
    SystemsRuntime.put_env(:salix_agent, :notifier, LegacyNotifier)

    SystemsRuntime.put_env(:salix_agent, :notifiers, [
      RaisingNotifier,
      CommaNotifier,
      SalixNotifier
    ])

    assert :ok = SalixAgent.Notifier.notify("agent-1", {:delta, "main", "hi"})

    settle_receive({:notifier, :legacy, "agent-1", {:delta, "main", "hi"}})
    settle_receive({:notifier, :comma, "agent-1", {:delta, "main", "hi"}})
    settle_receive({:notifier, :salix, "agent-1", {:delta, "main", "hi"}})
  end

  defp restore(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)
end
