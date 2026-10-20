defmodule SalixCluster.SessionWorkNotificationListenerTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixCluster.SessionWorkNotificationListener
  alias SalixStore.SessionWorkNotifications

  defmodule FakeNotifications do
    @moduledoc false

    def start_link(opts) do
      owner = Keyword.fetch!(opts, :test_owner)
      {:ok, pid} = Agent.start_link(fn -> %{listener: nil, ref: nil, owner: owner} end)
      SystemsRuntime.Proc.send(owner, {:fake_notifications_started, pid})
      {:ok, pid}
    end

    def listen(pid, channel) do
      listener = SystemsRuntime.Proc.self()
      ref = SystemsRuntime.Proc.make_ref()

      owner =
        Agent.get_and_update(pid, fn state ->
          {state.owner, %{state | listener: listener, ref: ref}}
        end)

      # This function executes in the listener process. Its message and the
      # injected catch-up message therefore prove subscribe-before-catch-up by
      # ordinary BEAM sender ordering.
      SystemsRuntime.Proc.send(owner, {:fake_notifications_listened, pid, channel})
      {:ok, ref}
    end

    def notify(pid, channel, payload) do
      %{listener: listener, ref: ref} = Agent.get(pid, & &1)
      SystemsRuntime.Proc.send(listener, {:notification, pid, ref, channel, payload})
      :ok
    end
  end

  test "subscribes before catch-up, dispatches only on the ring owner, and catches up after reconnect" do
    owner = SystemsRuntime.Proc.self()
    ownership = start_supervised!({Agent, fn -> node() end})

    listener =
      start_supervised!(
        {SessionWorkNotificationListener,
         name: nil,
         notifications_mod: FakeNotifications,
         connection_opts: [test_owner: owner],
         reconnect_backoff_ms: 10,
         owner_node_fn: fn _agent_id -> Agent.get(ownership, & &1) end,
         catch_up_fn: fn ->
           SystemsRuntime.Proc.send(owner, :notification_listener_catch_up)
           :ok
         end,
         wake_fn: fn agent_id, target, candidate_token ->
           SystemsRuntime.Proc.send(
             owner,
             {:notification_listener_wake, agent_id, target, candidate_token}
           )

           :ok
         end}
      )

    assert SystemsRuntime.Proc.is_process(listener)
    settle_receive({:fake_notifications_started, connection})
    settle_receive({:fake_notifications_listened, ^connection, channel})
    assert channel == SessionWorkNotifications.channel()
    settle_receive(:notification_listener_catch_up)

    payload =
      SessionWorkNotifications.encode!(%{
        "token" => "candidate-one",
        "agent_id" => "agent-one",
        "runtime_kind" => "internal",
        "session_id" => "session-one"
      })

    assert :ok = FakeNotifications.notify(connection, channel, payload)

    settle_receive(
      {:notification_listener_wake, "agent-one", %{runtime: :internal, session_id: "session-one"},
       "candidate-one"}
    )

    Agent.update(ownership, fn _ -> :another@node end)
    assert :ok = FakeNotifications.notify(connection, channel, payload)
    settle_refute_receive({:notification_listener_wake, _, _, _}, 50)
    assert :ok = FakeNotifications.notify(connection, channel, "not-json")
    settle_refute_receive({:notification_listener_wake, _, _, _}, 50)
    SystemsRuntime.Proc.exit(connection, :database_lost)

    settle_receive({:fake_notifications_started, replacement})
    refute replacement == connection
    settle_receive({:fake_notifications_listened, ^replacement, ^channel})
    settle_receive(:notification_listener_catch_up)
  end
end
