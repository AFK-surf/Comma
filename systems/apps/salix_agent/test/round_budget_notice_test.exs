defmodule SalixAgent.RoundBudgetNoticeTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{ContextProviders, InternalSessionStore, RoundBudgetNotice}

  @session_id "ses1_0000000000000000779"

  setup do
    prev_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_cap = SystemsRuntime.get_env(:salix_agent, :input_round_cap)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :input_round_cap, 8)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      restore(:salix_store, :s3_backend, prev_store)
      restore(:salix_agent, :input_round_cap, prev_cap)
    end)

    {:ok, agent_id: SalixAgent.TestSupport.new_agent_id()}
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp input(id) do
    %{
      "type" => "delivery",
      "session_id" => @session_id,
      "from_queue" => true,
      "message_id" => id,
      "role" => "user",
      "source_message_id" => "src-#{id}",
      "content" => "input #{id}"
    }
  end

  defp assistant(id),
    do: %{
      "type" => "assistant",
      "session_id" => @session_id,
      "message_id" => id,
      "content" => "r#{id}"
    }

  defp commit!(agent_id, events) do
    {:ok, _} = InternalSessionStore.prepare_commit(agent_id, @session_id, events)
    {:ok, session} = InternalSessionStore.read(agent_id, @session_id)
    session
  end

  test "warns once per input at three quarters of the cap, and fresh input re-arms it", %{
    agent_id: agent_id
  } do
    assert RoundBudgetNotice.warning_line(8) == 6

    session =
      commit!(agent_id, [
        %{"type" => "session_created", "session_id" => @session_id},
        input(1) | Enum.map(2..6, &assistant/1)
      ])

    assert {[], %{}} = RoundBudgetNotice.prepare(session, %{})

    session = commit!(agent_id, [assistant(7)])
    assert {[message], %{"warned" => true} = state} = RoundBudgetNotice.prepare(session, %{})
    assert message["runtime_message_type"] == "round_budget"
    assert message["content_kind"] == "model_context"
    assert message["content"] =~ "6 of the 8 model rounds"
    assert message["content"] =~ "2 remain"

    # Adopted once, silent afterwards while the same input keeps running.
    known = %{"round_budget" => state}
    assert {[], ^state} = RoundBudgetNotice.prepare(session, known)
    session = commit!(agent_id, [assistant(8)])
    assert {[], ^state} = RoundBudgetNotice.prepare(session, known)

    # Fresh input starts the count over and clears the adopted state.
    session = commit!(agent_id, [input(9)])
    assert {[], %{}} = RoundBudgetNotice.prepare(session, known)
  end
end
