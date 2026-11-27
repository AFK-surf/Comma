defmodule SalixAgent.IFCProjectionRequestTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.{InternalSession, IFC.ProjectionRequest}
  alias SalixAgent.InternalSession.State

  defmodule Facts do
    def mode(_, _), do: Process.get(:projection_mode, "enforce")

    def resolve(_) do
      Process.put(:projection_resolves, Process.get(:projection_resolves, 0) + 1)

      {:ok,
       %{
         "membership" => %{},
         "scopes" => %{},
         "placements" => %{},
         "policy" => %{},
         "receipts" => []
       }}
    end
  end

  defmodule PublicManual do
    def provider_manual(_), do: raise("tenant manuals must not be read")

    def builtin_provider_manual("slack") do
      {:ok,
       %{
         "apis" => [
           %{
             "name" => "slack.reply_message",
             "parameters" => %{
               "channel" => %{
                 "type" => "string",
                 "description" => "DESCRIPTION_SENTINEL",
                 "default" => "PRIVATE_DEFAULT"
               },
               "text" => "text"
             },
             "required_params" => ["channel", "text"]
           },
           %{
             "name" => "slack.tenant_secret",
             "parameters" => %{"SECRET_PLUGIN_FIELD" => "secret"}
           }
         ]
       }}
    end

    def builtin_provider_manual(_), do: {:error, :unsupported}
  end

  test "convergence contracts use only selected public field metadata" do
    old = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, PublicManual)
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :im_provider_mod, old) end)
    [spec] = SalixAgent.IFC.HardConvergence.tools([SalixAgent.TurnOutcome.spec()])

    contract =
      get_in(spec, ["input_schema", "properties", "reply", "description"])
      |> String.split("\n")
      |> List.last()
      |> Jason.decode!()

    assert Map.keys(contract) == ["im_api.slack.reply_message"]
    fields = contract["im_api.slack.reply_message"]["properties"]
    assert Map.has_key?(fields, "channel")
    assert Map.has_key?(fields, "connect_id")
    refute Jason.encode!(contract) =~ "SENTINEL"
    refute Jason.encode!(contract) =~ "PRIVATE_DEFAULT"
    refute Jason.encode!(contract) =~ "SECRET_PLUGIN_FIELD"
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_agent, :ifc_facts_mod)
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, Facts)
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, previous) end)
    :ok
  end

  defp input(id, channel) do
    source = "source-#{id}"

    %{
      id: id,
      role: "user",
      content: "body-#{channel}",
      source_message_id: source,
      trusted_origin: %{
        "provider" => "slack",
        "source_text" => "body-#{channel}",
        "source_actor_type" => "provider_user",
        "source_message_id" => source,
        "provider_context" => %{
          "connect_id" => "connect",
          "channel_id" => channel,
          "thread_ts" => "1.0"
        },
        "ifc" => %{
          "integrity" => "command",
          "principal" => "provider_user|connect|alice",
          "label" => ["scope|connect|#{channel}"]
        }
      }
    }
  end

  defp prepare(messages) do
    session =
      InternalSession.open(%State{
        agent_id: "agent",
        session_id: "session",
        messages: messages,
        next_message_id: length(messages) + 1
      })

    ProjectionRequest.prepare(
      session,
      %{messages: [%{content: "UNKNOWN_REMINDER"}]},
      %{tenant_id: "tenant", group_id: "group", ifc_static_prompt: "STATIC_PERSONA"},
      %{agent_id: "agent", session_id: "session", trusted_origin: nil}
    )
  end

  test "exact authenticated targets intersect and unlabelled reminders cannot enter" do
    one = prepare([input(1, "A")])
    assert [%{content: "body-A"}] = one.messages
    assert one.prompt == "STATIC_PERSONA"
    refute one.prompt =~ "source-1"
    refute one.prompt =~ "UNKNOWN_REMINDER"
    assert prepare([input(1, "A"), input(2, "B")]).messages == []
    unbound = put_in(input(1, "A"), [:trusted_origin, "source_message_id"], "forged")
    assert prepare([unbound]).messages == []
  end

  test "projection prefix is byte-stable across time and convergence transitions" do
    base = [input(1, "A")]

    failed = fn n ->
      [
        %{
          id: 2 * n,
          role: "assistant",
          ifc_view_label: ["scope|connect|A"],
          tool_calls: [
            %{
              id: "empty-#{n}",
              name: "call",
              args: %{
                "tool" => "history.search",
                "params" => %{"query" => "q#{n}"},
                "ifc" => %{"sources" => []}
              }
            }
          ]
        },
        %{
          id: 2 * n + 1,
          role: "tool",
          tool_call_id: "empty-#{n}",
          ifc_view_label: ["scope|connect|A"],
          ifc: %{"label" => ["scope|connect|A"]},
          content: ~s({"results":[]})
        }
      ]
    end

    first = prepare(base ++ Enum.flat_map(1..7, failed))
    capped = prepare(base ++ Enum.flat_map(1..8, failed))
    assert capped.finish_only
    refute first.finish_only
    assert first.prompt == capped.prompt
    assert prepare(base ++ Enum.flat_map(1..8, failed)).prompt == capped.prompt
  end

  test "off audit and easy bypass projection without resolving visibility facts" do
    for mode <- ["off", "audit", "easy"] do
      Process.put(:projection_mode, mode)
      assert prepare([input(1, "A")]) == nil
    end

    assert Process.get(:projection_resolves, 0) == 0
  end

  test "summary physical upper bound survives storage and cannot return to a lower domain" do
    labels = ["scope|connect|A", "scope|connect|B"]
    state = %State{agent_id: "agent", session_id: "session"}

    state =
      SalixAgent.TestSupport.SessionData.apply_event(state, %{
        "type" => "compaction",
        "summary" => "MIXED_SECRET",
        "compacted_through" => 0,
        "ifc_view_label" => labels
      })

    state = SalixAgent.TestSupport.SessionData.reload(state)
    assert state.summary_ifc_view_label == labels

    assert Enum.any?(
             SalixAgent.IFC.Context.build(InternalSession.open(state))["items"],
             &(&1["ref"] == "src:a-0" and &1["label"] == labels)
           )

    [summary] = InternalSession.query(InternalSession.open(state), :ifc_projection_input)
    {:ok, destination} = SalixIFC.Codec.decode_label(["scope|connect|A"])

    assert SalixAgent.IFC.ContextProjection.project(
             [summary],
             [destination],
             SalixIFC.Facts.new()
           ).messages == []
  end
end
