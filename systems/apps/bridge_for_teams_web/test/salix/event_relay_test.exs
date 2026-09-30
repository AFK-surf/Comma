defmodule BridgeForTeams.Salix.EventRelayTest do
  @moduledoc """
  The event relay bridges `{:salix_agent_event, agent_id, event}` broadcasts
  from the (co-resident) Salix PubSub onto per-org BridgeForTeams topics, with
  lazy interest-scoped subscriptions and graceful absence when the Salix
  PubSub isn't running locally.

  Pure PubSub — no DB. Each test gets its own Salix-side PubSub and relay
  instance; the BridgeForTeams side reuses the app's running
  `BridgeForTeamsWeb.PubSub`.
  """
  use ExUnit.Case, async: true

  alias BridgeForTeams.Salix.EventRelay

  @bft_pubsub BridgeForTeamsWeb.PubSub

  defp start_relay(opts) do
    salix_pubsub = :"salix_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: salix_pubsub})

    relay =
      start_supervised!(
        {EventRelay,
         Keyword.merge(
           [
             name: :"event_relay_#{System.unique_integer([:positive])}",
             salix_pubsub: salix_pubsub,
             bft_pubsub: @bft_pubsub,
             agent_resolver: fn _org_id -> [] end
           ],
           opts
         )}
      )

    %{salix_pubsub: salix_pubsub, relay: relay}
  end

  defp emit(salix_pubsub, agent_id, event) do
    Phoenix.PubSub.broadcast(
      salix_pubsub,
      "agent:" <> agent_id,
      {:salix_agent_event, agent_id, event}
    )
  end

  # Watches from a separate process (so watcher lifecycle can be exercised)
  # and returns its pid; the process idles until told to stop.
  defp watch_from_other_process(org_id, relay) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:watched, EventRelay.watch(org_id, relay)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:watched, :ok}
    pid
  end

  test "watch subscribes the org's agents and rebroadcasts their events" do
    %{salix_pubsub: salix_pubsub, relay: relay} =
      start_relay(agent_resolver: fn "org-1" -> ["agent_a", "agent_b"] end)

    :ok = Phoenix.PubSub.subscribe(@bft_pubsub, EventRelay.topic("org-1"))
    assert :ok = EventRelay.watch("org-1", relay)
    assert EventRelay.available?(relay)

    emit(salix_pubsub, "agent_a", {:session_updated, "s1"})
    assert_receive {:agent_event, "org-1", "agent_a", {:session_updated, "s1"}}

    emit(salix_pubsub, "agent_a", {:conversation_upsert, "task-1"})
    assert_receive {:agent_event, "org-1", "agent_a", {:conversation_upsert, "task-1"}}

    emit(salix_pubsub, "agent_b", {:settled, %{}})
    assert_receive {:agent_event, "org-1", "agent_b", {:settled, %{}}}
  end

  test "events for agents outside any watched org are dropped" do
    %{salix_pubsub: salix_pubsub, relay: relay} =
      start_relay(agent_resolver: fn "org-1" -> ["agent_a"] end)

    :ok = Phoenix.PubSub.subscribe(@bft_pubsub, EventRelay.topic("org-1"))
    assert :ok = EventRelay.watch("org-1", relay)

    emit(salix_pubsub, "agent_other", {:session_updated, "s1"})
    refute_receive {:agent_event, _org, _agent, _event}, 100
  end

  test "a later watch picks up agents provisioned since the first" do
    {:ok, roster} = Agent.start_link(fn -> ["agent_a"] end)

    %{salix_pubsub: salix_pubsub, relay: relay} =
      start_relay(agent_resolver: fn "org-1" -> Agent.get(roster, & &1) end)

    :ok = Phoenix.PubSub.subscribe(@bft_pubsub, EventRelay.topic("org-1"))
    assert :ok = EventRelay.watch("org-1", relay)

    # A new agent lands on the roster after the first watcher subscribed…
    Agent.update(roster, fn _ -> ["agent_a", "agent_new"] end)
    emit(salix_pubsub, "agent_new", {:settled, %{}})
    refute_receive {:agent_event, _org, "agent_new", _event}, 100

    # …the next watcher's re-resolution subscribes it.
    _other = watch_from_other_process("org-1", relay)
    emit(salix_pubsub, "agent_new", {:settled, %{}})
    assert_receive {:agent_event, "org-1", "agent_new", {:settled, %{}}}
  end

  test "unwatch by the last watcher drops the org's subscriptions" do
    %{salix_pubsub: salix_pubsub, relay: relay} =
      start_relay(agent_resolver: fn "org-1" -> ["agent_a"] end)

    :ok = Phoenix.PubSub.subscribe(@bft_pubsub, EventRelay.topic("org-1"))
    assert :ok = EventRelay.watch("org-1", relay)
    assert :ok = EventRelay.unwatch("org-1", relay)

    emit(salix_pubsub, "agent_a", {:session_updated, "s1"})
    refute_receive {:agent_event, _org, _agent, _event}, 100
  end

  test "a dying watcher is cleaned up; the org unsubscribes with the last one" do
    %{salix_pubsub: salix_pubsub, relay: relay} =
      start_relay(agent_resolver: fn "org-1" -> ["agent_a"] end)

    :ok = Phoenix.PubSub.subscribe(@bft_pubsub, EventRelay.topic("org-1"))

    first = watch_from_other_process("org-1", relay)
    second = watch_from_other_process("org-1", relay)

    # One of two watchers dies: still relaying for the survivor.
    send(first, :stop)
    wait_until_processed(relay, first)

    emit(salix_pubsub, "agent_a", {:session_updated, "s1"})
    assert_receive {:agent_event, "org-1", "agent_a", {:session_updated, "s1"}}

    # The last watcher dies: the relay lets go of the org.
    send(second, :stop)
    wait_until_processed(relay, second)

    emit(salix_pubsub, "agent_a", {:session_updated, "s2"})
    refute_receive {:agent_event, _org, _agent, _event}, 100
  end

  test "watch reports unavailable when the Salix PubSub is absent" do
    relay =
      start_supervised!(
        {EventRelay,
         name: :"event_relay_#{System.unique_integer([:positive])}",
         salix_pubsub: :absent_salix_pubsub,
         bft_pubsub: @bft_pubsub,
         agent_resolver: fn _org_id -> ["agent_a"] end}
      )

    refute EventRelay.available?(relay)
    assert {:error, :unavailable} = EventRelay.watch("org-1", relay)
  end

  test "a raising agent resolver costs the subscription, not the relay" do
    %{salix_pubsub: salix_pubsub, relay: relay} =
      start_relay(agent_resolver: fn _org_id -> raise "db down" end)

    :ok = Phoenix.PubSub.subscribe(@bft_pubsub, EventRelay.topic("org-1"))
    assert :ok = EventRelay.watch("org-1", relay)
    assert Process.alive?(relay)

    emit(salix_pubsub, "agent_a", {:session_updated, "s1"})
    refute_receive {:agent_event, _org, _agent, _event}, 100
  end

  # The relay processes the watcher's DOWN before we assert on the outcome —
  # wait until the dead pid has left its state.
  defp wait_until_processed(relay, pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    wait_until(fn ->
      state = :sys.get_state(relay)
      Enum.all?(state.watchers, fn {_org, pids} -> not Map.has_key?(pids, pid) end)
    end)
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
