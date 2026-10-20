defmodule SalixAgent.FleetStopTest do
  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.Fleet

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_s3)
    end)

    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  test "stopping an agent drains a session wake already in its coordinator", %{agent: a} do
    SalixAgent.TestSupport.create_control_agent!(a)
    session_id = "ses1_0000000000000000930"
    {:ok, _} = SalixAgent.InternalSessionStore.prepare_create(a, session_id, %{})
    {:ok, server} = Fleet.ensure_started(a, create: false, startup_mode: :passive)

    {:ok, _} =
      SalixAgent.InternalSessionFleet.ensure_started(a, session_id, process_on_init: false)

    test_pid = SystemsRuntime.Proc.self()

    # Hold the real coordinator inside a callback. Its last in-flight wake
    # recreates the real session actor if cleanup ran before coordinator stop.
    callback =
      SystemsRuntime.Task.async(fn ->
        :sys.replace_state(
          server,
          fn state ->
            SystemsRuntime.Proc.send(test_pid, :coordinator_held)

            SystemsClock.vreceive do
              :finish_wake ->
                {:ok, session} =
                  SalixAgent.InternalSessionFleet.ensure_started(a, session_id,
                    process_on_init: false
                  )

                SystemsRuntime.Proc.send(test_pid, {:woken_session, session})
                state
            after
              5_000 -> raise "coordinator test barrier was not released"
            end
          end,
          :infinity
        )
      end)

    settle_receive(:coordinator_held)

    stopper =
      SystemsRuntime.Task.async(fn -> Fleet.stop_existing(a, reason: :normal, timeout: 5_000) end)

    try do
      # Observe the queued stop, not a scheduling delay. No process is killed
      # until the coordinator has finished the wake above.
      assert eventually(fn ->
               case Process.info(server, :messages) do
                 {:messages, messages} ->
                   Enum.any?(messages, fn
                     {:system, _, {:terminate, :normal}} -> true
                     _ -> false
                   end)

                 _ ->
                   false
               end
             end)
    after
      SystemsRuntime.Proc.send(server, :finish_wake)
    end

    settled_await(callback)
    assert :ok = settled_await(stopper)
    settle_receive({:woken_session, session})
    refute SystemsRuntime.Proc.alive?(session)

    assert eventually(fn ->
             Registry.lookup(SalixAgent.Registry, a) == [] and
               Registry.lookup(SalixAgent.Registry, SalixAgent.AgentActor.key(a)) == [] and
               Registry.lookup(
                 SalixAgent.Registry,
                 SalixAgent.InternalSessionActor.key(a, session_id)
               ) == []
           end)
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)
end
