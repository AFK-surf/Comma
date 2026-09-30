defmodule SalixWeb.SalixFacadeTest do
  use ExUnit.Case, async: false

  alias Salix.Runtime.Placement

  defmodule FailingPlacement do
    @behaviour SalixAgent.Placement

    @impl true
    def ensure_started(_agent_id, _opts), do: {:error, :noconnection}

    @impl true
    def stop_existing(_agent_id, _opts), do: :ok
  end

  defmodule InertPlacement do
    @moduledoc """
    Returns a live but inert gen_statem: `deliver/3` exercises the full start +
    synchronous wake path, but no real `SalixAgent.Server` starts, so no round
    consumes the committed queue item out from under the ledger assertions.
    """
    @behaviour SalixAgent.Placement

    defmodule Server do
      @moduledoc false
      @behaviour :gen_statem

      @impl true
      def callback_mode, do: :handle_event_function

      @impl true
      def init(_opts), do: {:ok, :idle, %{}}

      @impl true
      def handle_event({:call, from}, :wake, _state, data) do
        {:keep_state, data, [{:reply, from, :ok}]}
      end

      def handle_event(:cast, :wake, _state, data), do: {:keep_state, data}
      def handle_event(_event_type, _event_content, _state, data), do: {:keep_state, data}
    end

    @impl true
    def ensure_started(_agent_id, _opts) do
      :gen_statem.start_link(Server, [], [])
    end

    @impl true
    def stop_existing(_agent_id, _opts), do: :ok
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_placement = Application.get_env(:salix_agent, :placement)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_fake_store()
    start_supervised!(SalixAgent.LLM.Mock)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, prev_backend)
      restore(:salix_agent, :llm, prev_llm)
      restore(:salix_agent, :placement, prev_placement)
    end)

    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  test "runtime deliver refuses cleanly when placement fails; same-id retry lands once",
       %{agent: agent} do
    session_id = SalixStore.Ids.new_session_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    Application.put_env(:salix_agent, :placement, FailingPlacement)

    # The staged contract ("durable fact survives a failed wake") retired with
    # the staged path: rpc acks only after the owner-side ledger commit, so a
    # placement failure means NO ack and NOTHING durable — the caller's retry
    # machinery owns redelivery, and the ledger dedupes it (plan §1.8).
    assert {:error, _placement} =
             Salix.Runtime.deliver(agent, %{content: "hello", session_id: session_id},
               source_message_id: "req-remote-down"
             )

    assert {:error, :not_found} = SalixAgent.InternalSessionStore.read(agent, session_id)

    # Placement recovers: the SAME source id retries and lands exactly once.
    Application.put_env(:salix_agent, :placement, InertPlacement)
    SalixAgent.LLM.Mock.script([{:final, "ok"}])

    assert {:ok, :created} =
             Salix.Runtime.deliver(agent, %{content: "hello", session_id: session_id},
               source_message_id: "req-remote-down"
             )

    {:ok, state} = SalixAgent.InternalSessionStore.read(agent, session_id)
    assert MapSet.member?(SalixAgent.InternalSession.get(state, :input_dedupe), "req-remote-down")
  end

  test "placement local owner delegates to configured placement seam", %{agent: agent} do
    assert Placement.owner(agent) == Node.self()
    assert Placement.local_owner?(agent)
    assert Placement.remote_boundary() == {:erpc, SalixAgent.Fleet, :ensure_started}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp start_fake_store do
    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end
end
