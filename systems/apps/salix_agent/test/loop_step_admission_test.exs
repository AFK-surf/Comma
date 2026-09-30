defmodule SalixAgent.LoopStepAdmissionTest do
  use ExUnit.Case, async: true

  alias SalixAgent.InternalSession

  # The kernel loop admits host events only in the phase that asked for them,
  # and it commits host-built events only when none of them retires input,
  # advances the archive, or stamps the session. A rejected step raises, so
  # the host receives no commit effect.

  @sid "ses1_0000000000000000996"

  setup do
    session = InternalSession.new("agent", @sid)
    next = InternalSession.next_message_id(session)

    facts = %{"id_snapshot" => next, "guard" => :clean, "vphase" => :clean, "nonce" => 1}
    %{session: session, next: next, facts: facts}
  end

  describe "results_stored" do
    test "is out of order before a round and outside a results phase", ctx do
      stored = {:results_stored, [], nil, ctx.next, []}

      assert_raise RuntimeError, "verified kernel: {:loop_order, [nil]}", fn ->
        step(ctx.session, nil, stored)
      end

      {machine, _record} = tool_turn(ctx)
      assert machine["phase"] == "intent"

      assert_raise RuntimeError, ~s(verified kernel: {:loop_order, ["intent"]}), fn ->
        step(ctx.session, machine, stored)
      end
    end

    test "commits a results batch only without retiring kinds", ctx do
      {machine, [{:store_results, _pending, []}]} =
        step(ctx.session, nil, {:commit_results, pending(ctx), [], ctx.facts})

      assert machine["phase"] == "results_only"

      assert {_, [{:commit, [], [], nil}, {:notify, :timers, _}, {:stop, :committed}]} =
               step(ctx.session, machine, {:results_stored, [], nil, ctx.next, []})

      ack = %{"type" => "queue_ack", "session_id" => @sid, "queue_ack_id" => 1}

      assert_raise RuntimeError, ~s(verified kernel: {:invalid_host_event, ["queue_ack"]}), fn ->
        step(ctx.session, machine, {:results_stored, [ack], nil, ctx.next, []})
      end
    end
  end

  describe "host-built records" do
    test "a tool-turn intent commits ordinary events and rejects retiring kinds", ctx do
      {machine, record} = tool_turn(ctx)

      assert {%{"phase" => "tools"}, [{:commit, [_assistant], _, _} | _]} =
               step(ctx.session, machine, {:record, record})

      consume = %{"type" => "queue_consume", "session_id" => @sid, "queue_id" => 1}

      assert_raise RuntimeError,
                   ~s(verified kernel: {:invalid_host_event, ["queue_consume"]}),
                   fn ->
                     step(
                       ctx.session,
                       machine,
                       {:record, Map.update!(record, "intent", &(&1 ++ [consume]))}
                     )
                   end

      # Atom keys convert to `type` like string keys do.
      admission = %{"events" => [%{type: "session_stamp"}], "hwm" => ctx.next}

      assert_raise RuntimeError,
                   ~s(verified kernel: {:invalid_host_event, ["session_stamp"]}),
                   fn ->
                     step(
                       ctx.session,
                       machine,
                       {:record, Map.put(record, "admission", admission)}
                     )
                   end
    end

    test "a final output rejects retiring kinds in its leading events", ctx do
      {machine, _} = step(ctx.session, nil, {:model_response, {:final, "done"}, ctx.facts})

      {machine, [{:build_record, %{"mode" => "final"}}]} =
        step(ctx.session, machine, :continue)

      record = %{
        "leading" => [%{"type" => "archive_advance", "session_id" => @sid}],
        "assistant" => assistant(ctx.next, []),
        "aid" => ctx.next,
        "base" => ctx.next
      }

      assert_raise RuntimeError,
                   ~s(verified kernel: {:invalid_host_event, ["archive_advance"]}),
                   fn -> step(ctx.session, machine, {:record, record}) end
    end
  end

  defp step(session, machine, event),
    do: InternalSession.query(session, :loop_step, {machine, event})

  defp pending(ctx),
    do: %{"calls" => [], "aid" => ctx.next, "track" => false, "checkpoint" => nil}

  defp assistant(aid, calls) do
    %{
      "type" => "assistant",
      "session_id" => @sid,
      "message_id" => aid,
      "content" => "",
      "tool_calls" => calls
    }
  end

  # Drives a model response with one ordinary call to the tool-turn record request.
  defp tool_turn(ctx) do
    calls = [%{id: "call-1", name: "call", args: %{}}]
    response = {:assistant, "", calls}
    {machine, _} = step(ctx.session, nil, {:model_response, response, ctx.facts})

    {machine, [_draft, {:build_record, %{"mode" => "tools"}}]} =
      step(ctx.session, machine, :continue)

    record = %{
      "intent" => [assistant(ctx.next, calls)],
      "aid" => ctx.next,
      "base" => ctx.next,
      "admission" => nil,
      "speculative" => false
    }

    {machine, record}
  end
end
