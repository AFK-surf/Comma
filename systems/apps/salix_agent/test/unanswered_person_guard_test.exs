defmodule SalixAgent.UnansweredPersonGuardTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.{InternalSession, UnansweredPersonGuard}

  @session_id "ses1_0000000000000000931"

  @person %{
    "provider" => "feishu",
    "source_actor_type" => "provider_user",
    "source_message_id" => "person-1",
    "provider_context" => %{"connect_id" => "feishu-1", "chat_id" => "oc_1"}
  }

  defp session(origin, later \\ [], fields \\ %{}) do
    user = %{id: 1, role: "user", source_message_id: "person-1", trusted_origin: origin}

    InternalSession.open(
      Map.merge(
        %{
          InternalSession.export(InternalSession.new("agent", @session_id))
          | messages: [user | later],
            next_message_id: 2 + length(later)
        },
        fields
      )
    )
  end

  defp assistant(id, call),
    do: %{id: id, role: "assistant", content: "", tool_calls: [call]}

  defp end_turn(args), do: {:assistant, "", [%{id: "end", name: "end_turn", args: args}]}

  defp refused?(response, session, role \\ "router") do
    {:assistant, _, [call]} = UnansweredPersonGuard.guard(response, session, role)
    call[:guidance_reason] == "unanswered_person"
  end

  test "a Router's bare done is refused while its person got nothing" do
    done = end_turn(%{"outcome" => "done"})
    probe = assistant(2, %{"id" => "p", "name" => "call", "args" => %{"tool" => "env.exec"}})

    assert refused?(done, session(@person, [probe]))

    # The record keeps the model's own end_turn; dispatch runs the guidance.
    {:assistant, _, calls} = UnansweredPersonGuard.guard(done, session(@person), "router")

    assert [%{name: "end_turn", args: %{"outcome" => "done"}}] =
             UnansweredPersonGuard.model_calls(calls)

    # Declared silence, blocked, a carried reply, and a Worker settle.
    refute refused?(end_turn(%{"outcome" => "done", "no_reply" => true}), session(@person))
    refute refused?(end_turn(%{"outcome" => "blocked", "reason" => "x"}), session(@person))
    refute refused?(end_turn(%{"outcome" => "done", "reply" => %{}}), session(@person))
    refute refused?(done, session(@person), "worker")
  end

  test "an attempt to reach the person or hand the work on lets done settle" do
    done = end_turn(%{"outcome" => "done"})

    # A send counts whether it succeeded or IFC refused it.
    send = %{
      "id" => "s",
      "name" => "call",
      "args" => %{"tool" => "im_api.feishu.reply_text", "params" => %{}}
    }

    refute refused?(done, session(@person, [assistant(2, send)]))

    task = %{"id" => "t", "name" => "call", "args" => %{"tool" => "im_api.internal.task.create"}}
    refute refused?(done, session(@person, [assistant(2, task)]))

    wait = %{"id" => "w", "name" => "wait_for", "args" => %{"reason" => "Task"}}
    refute refused?(done, session(@person, [assistant(2, wait)]))

    running = %{"a" => %{"status" => "running", "tool_call_id" => "a"}}
    refute refused?(done, session(@person, [], %{async_tool_calls: running}))
  end

  test "a source with no person, or an activation compaction hides, is not guarded" do
    done = end_turn(%{"outcome" => "done"})
    schedule = %{"provider" => "schedule", "schedule_id" => "sch_1", "ifc" => %{}}

    refute refused?(done, session(schedule))
    refute refused?(done, session(@person, [], %{compacted_through: 1}))
  end
end
