defmodule SalixAgent.FleetStopTest do
  use ExUnit.Case, async: false

  alias SalixAgent.Fleet

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, previous_s3)
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

    test_pid = self()

    # Hold the real coordinator inside a callback. Its last in-flight wake
    # recreates the real session actor if cleanup ran before coordinator stop.
    callback =
      Task.async(fn ->
        :sys.replace_state(server, fn state ->
          send(test_pid, :coordinator_held)

          receive do
            :finish_wake ->
              {:ok, session} =
                SalixAgent.InternalSessionFleet.ensure_started(a, session_id,
                  process_on_init: false
                )

              send(test_pid, {:woken_session, session})
              state
          after
            5_000 -> raise "coordinator test barrier was not released"
          end
        end)
      end)

    assert_receive :coordinator_held, 1_000
    stopper = Task.async(fn -> Fleet.stop_existing(a, reason: :normal, timeout: 5_000) end)

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
      send(server, :finish_wake)
    end

    Task.await(callback)
    assert :ok = Task.await(stopper)
    assert_receive {:woken_session, session}
    refute Process.alive?(session)

    assert eventually(fn ->
             Registry.lookup(SalixAgent.Registry, a) == [] and
               Registry.lookup(SalixAgent.Registry, SalixAgent.AgentActor.key(a)) == [] and
               Registry.lookup(
                 SalixAgent.Registry,
                 SalixAgent.InternalSessionActor.key(a, session_id)
               ) == []
           end)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
