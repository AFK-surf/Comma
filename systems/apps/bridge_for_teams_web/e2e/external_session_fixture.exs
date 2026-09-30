defmodule BridgeForTeamsWeb.E2E.ExternalSessionFixture do
  @moduledoc false

  alias SalixAgent.{ExternalSessionActor, ExternalSessionStore, Waits}

  def accept_activation_and_wait!(agent_id, session_id, tenant_id, runtime, wait_id) do
    # Delivery or recovery can already own this Session. Reuse that owner and
    # drain its dispatch below instead of opening a stop/start registration race.
    {:ok, actor} =
      SalixAgent.Fleet.start_session_actor(ExternalSessionActor,
        agent_id: agent_id,
        session_id: session_id,
        process_on_init: false
      )

    {:ok, %{"input_message_queue" => queue_snapshot}} =
      ExternalSessionStore.get_session_record(agent_id, session_id)

    {:ok, binding} = ExternalSessionActor.begin_session(actor, tenant_id, runtime)

    {:ok, :accepted, _state} =
      ExternalSessionActor.accept_session(actor, %{
        "token_hash" => get_in(binding, ["runtime_capability", "token_hash"]),
        "queue_snapshot" => queue_snapshot
      })

    wait_for_dependency!(actor, session_id, wait_id)
  end

  # Called only after the fixture has accepted all activation input.
  def wait_for_dependency!(actor, session_id, wait_id, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_idle!(actor, session_id, deadline)
    {:ok, _state} = ExternalSessionActor.complete_session(actor, %{})

    # Longer than the 20-minute CI job; survives the seed/dashboard VM restart.
    wait =
      Waits.build("External Session fixture awaiting dependency", 1_800, "dashboard_e2e", %{
        "wait_id" => wait_id
      })

    ExternalSessionActor.commit_session_events(actor, [Waits.event(session_id, wait)])
  end

  defp await_idle!(actor, session_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      raise "External fixture session #{session_id} exceeded dispatch deadline (activity=busy)"
    end

    if ExternalSessionActor.busy?(actor, min(remaining, 100)) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)
      Process.sleep(min(remaining, 25))
      await_idle!(actor, session_id, deadline)
    end
  end
end
