defmodule SalixAgent.PresentationBoundaryTest do
  use ExUnit.Case, async: false
  alias SalixAgent.{InternalSession, VisibleReplyPolicy}

  defmodule UnavailableAuthority do
    def authorize(_agent_id, _scope), do: raise("authority unavailable")
  end

  test "an authority exception becomes a retryable observation without crossing the state schema" do
    previous = Application.get_env(:salix_agent, :visible_reply_mod)
    Application.put_env(:salix_agent, :visible_reply_mod, UnavailableAuthority)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:salix_agent, :visible_reply_mod),
        else: Application.put_env(:salix_agent, :visible_reply_mod, previous)
    end)

    origin = %{
      "provider" => "internal",
      "conversation_kind" => "user_chat",
      "source_actor_type" => "user",
      "agent_group_id" => "group",
      "conversation_id" => "conversation",
      "participant_id" => "participant",
      "message_id" => "message"
    }

    session =
      InternalSession.new("agent", "session")
      |> InternalSession.export()
      |> Map.put(:messages, [
        %{id: 1, role: "user", source_message_id: "source", trusted_origin: origin}
      ])
      |> InternalSession.open()

    revision = %SalixAgent.InternalSessionStore.Revision{
      cursor: InternalSession.start_revision(session, "observed"),
      state: session,
      etag: "observed"
    }

    assert {{:error,
             {:visible_reply_authorization_retry, {:visible_reply_port_error, diagnostic}}},
            returned, nil} =
             InternalSession.Command.run(
               "agent",
               "session",
               revision,
               :activate,
               {[], 0, nil, false}
             )

    assert diagnostic =~ "authority unavailable"
    assert InternalSession.export(returned.state) == InternalSession.export(session)
  end

  test "public summaries retain the same grapheme boundary and key convention" do
    for summary <- [
          String.duplicate("á", 513),
          String.duplicate("👩‍👩‍👧‍👦", 513),
          String.duplicate("中", 513),
          <<255>> <> String.duplicate("á", 513)
        ],
        keys <- [:atom, :string] do
      result = %{
        status: "error",
        diagnostic_visibility: "user_reportable",
        public_summary: summary
      }

      result =
        if keys == :string, do: Map.new(result, fn {k, v} -> {to_string(k), v} end), else: result

      key = if keys == :atom, do: :public_summary, else: "public_summary"

      assert VisibleReplyPolicy.label_result(result) ==
               Map.put(result, key, String.slice(summary, 0, 512))
    end
  end

  test "private diagnostics keep only their failure state and remove matching tool arguments, but not IFC refusals" do
    messages = [
      %{
        role: "assistant",
        content: "private context",
        provider_meta: %{private: "secret"},
        tool_calls: [
          %{id: "private", name: "call", args: %{secret: "secret"}},
          %{id: "public", name: "call", args: %{safe: "safe"}}
        ]
      },
      %{
        role: "tool",
        tool_call_id: "private",
        content: "secret",
        diagnostic_visibility: "model_only",
        source_refs: ["private"],
        failed_tool_calls: ["private"],
        output: "secret"
      },
      %{role: "tool", tool_call_id: "public", content: "safe"},
      %{
        role: "tool",
        tool_call_id: "refused",
        content: "must acquire permission",
        diagnostic_visibility: "model_only",
        guidance_reason: "information_flow"
      },
      %{role: "runtime", type: "runtime_failed", content: "secret"}
    ]

    [assistant, private, public, refusal, runtime] =
      VisibleReplyPolicy.sanitize_context(messages, :clean)

    assert assistant.content == ""
    refute Map.has_key?(assistant, :provider_meta)
    assert [hidden, untouched] = assistant.tool_calls
    assert hidden.args == %{"repair_context" => "redacted"}
    assert untouched.args == %{safe: "safe"}
    assert Jason.decode!(private.content) == %{"status" => "failed", "detail" => "redacted"}
    refute Map.has_key?(private, :output)
    refute Map.has_key?(private, :source_refs)
    assert public.content == "safe"
    assert refusal == Enum.at(messages, 3)

    assert Jason.decode!(runtime.content) == %{
             "status" => "failed",
             "type" => "runtime_failed",
             "detail" => "redacted"
           }

    refute inspect([private, runtime]) =~ "secret"
    assert VisibleReplyPolicy.sanitize_context(messages, {:repair_required, 1}) == messages
  end

  test "pending results preserve repair, successful results complete it, and failures spend the configured budget" do
    previous = Application.get_env(:salix_agent, :visible_reply_repair_budget)
    Application.put_env(:salix_agent, :visible_reply_repair_budget, 2)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:salix_agent, :visible_reply_repair_budget),
        else: Application.put_env(:salix_agent, :visible_reply_repair_budget, previous)
    end)

    assert VisibleReplyPolicy.transition(:clean, [%{diagnostic_visibility: "model_only"}]) ==
             {:required, 0}

    assert VisibleReplyPolicy.transition({:repair_required, 1}, [%{status: "async_running"}]) ==
             {:required, 1}

    assert VisibleReplyPolicy.transition({:repair_required, 1}, [%{status: "completed"}]) ==
             :completed

    assert VisibleReplyPolicy.transition({:repair_required, 1}, [%{status: "error"}]) ==
             {:exhausted, 2}
  end

  test "an unsuccessful async result advances the diagnostic revision without exhausting unrelated pending work" do
    session =
      InternalSession.new("agent", "session")
      |> InternalSession.export()
      |> Map.merge(%{
        next_message_id: 8,
        visible_reply_repair: %{
          "status" => "required",
          "attempts" => 1,
          "revision" => 4,
          "diagnostic_hwm" => 6
        }
      })
      |> InternalSession.open()

    result = %{id: "call", status: "error", error: true}
    [event] = VisibleReplyPolicy.async_completion_events([], session, result, diagnostic_hwm: 9)
    assert event["status"] == "required"
    assert event["attempts"] == 1
    assert event["revision"] == 5
    assert event["diagnostic_hwm"] == 9
  end
end
