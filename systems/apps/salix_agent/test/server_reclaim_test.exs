defmodule SalixAgent.ServerReclaimTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{AgentActor, Fleet, InternalSessionActor, InternalSessionFleet, Server}
  alias SalixStore.{Agent, Ids, Repo, S3}

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous = SystemsRuntime.fetch_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      case previous do
        {:ok, value} -> SystemsRuntime.put_env(:salix_store, :s3_backend, value)
        :error -> SystemsRuntime.delete_env(:salix_store, :s3_backend)
      end
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    %{agent: agent, session: Ids.new_session_id()}
  end

  test "a fresh claim accepts one input into a Session left resident by normal Server passivation",
       %{agent: agent, session: session} do
    {:ok, first} =
      Fleet.ensure_started(agent, startup_mode: :passive, park_ms: 20)

    assert {:parked, first_owner} = Server.info(first)

    assert {:ok, :committed} =
             InternalSessionFleet.stage_control(agent, session, %{
               source_message_id: "create:" <> session,
               payload: %{kind: "session_create", session_id: session}
             })

    key = InternalSessionActor.key(agent, session)
    assert [{old_actor, %{runtime_epoch: old_epoch}}] = Registry.lookup(SalixAgent.Registry, key)
    assert old_epoch == first_owner.epoch
    monitor = SystemsRuntime.Proc.monitor(first)
    settle_receive({:DOWN, ^monitor, :process, ^first, :normal})
    assert SystemsRuntime.Proc.alive?(old_actor)
    assert {:ok, %{owner_node: nil}} = Agent.peek(agent)

    handler = {__MODULE__, make_ref()}
    test = self()

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, metadata, _ ->
          if String.contains?(metadata.query, "owner_epoch = owner_epoch + 1") and
               List.first(metadata.params) == agent do
            send(test, {:claim_committed, self()})
            receive do: (:finish_claim -> :ok)
          end
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    {:ok, replacement} = Fleet.ensure_started(agent, startup_mode: :passive, park_ms: 20)
    settle_receive({:claim_committed, ^replacement})

    control =
      SystemsRuntime.Task.async(fn ->
        InternalSessionFleet.stage_control(agent, session, %{
          source_message_id: "rename:" <> session,
          payload: %{kind: "session_update", session_id: session, name: "Continued"}
        })
      end)

    entry = %{
      source_message_id: "after-passivation:" <> session,
      payload: %{
        session_id: session,
        role: "user",
        content: "Continue the same Session after its Server passivated.",
        no_wake: true
      }
    }

    delivery =
      SystemsRuntime.Task.async(fn ->
        InternalSessionFleet.stage_delivery(agent, session, entry, process_on_init: false)
      end)

    {control_admission, delivery_admission, expired_admission} =
      try do
        {await_command_admission(control), await_command_admission(delivery),
         Fleet.await_ownership_installed(agent, 0)}
      after
        send(replacement, :finish_claim)
      end

    assert control_admission == :waiting_for_claim
    assert delivery_admission == :waiting_for_claim
    assert expired_admission == {:error, :unavailable}
    assert {:ok, :committed} = settled_await(control)
    assert {:ok, :committed} = settled_await(delivery)
    assert {:ok, current_epoch} = SalixAgent.OwnershipCell.fetch(agent)
    assert current_epoch > old_epoch

    assert {:ok, :duplicate} =
             AgentActor.stage_delivery(agent, entry, process_on_init: false)

    refute SystemsRuntime.Proc.alive?(old_actor)

    assert [{current_actor, %{runtime_epoch: ^current_epoch}}] =
             Registry.lookup(SalixAgent.Registry, key)

    assert current_actor != old_actor

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM salix_session_inputs WHERE agent_id=$1 AND session_id=$2",
               [agent, session]
             ).rows
  end

  # The query barrier holds the registered Root after its durable claim.
  # Run the real command until it either completes or waits at startup
  # admission, without driving its existing wait budget to expiry.
  defp await_command_admission(task) do
    case SystemsRuntime.Task.yield(task, 0) do
      nil ->
        stack =
          case Process.info(task.pid, :current_stacktrace) do
            {:current_stacktrace, stack} -> stack
            nil -> []
          end

        if Enum.any?(stack, &match?({Fleet, :await_ownership_loop, _, _}, &1)) do
          :waiting_for_claim
        else
          :erlang.yield()
          await_command_admission(task)
        end

      result ->
        {:completed, result}
    end
  end
end
