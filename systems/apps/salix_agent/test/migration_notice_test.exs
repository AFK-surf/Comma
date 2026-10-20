defmodule SalixAgent.MigrationNoticeTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.{ContextProviders, MigrationNotice}

  test "migration notices are delivered and adopted once for new and current sessions" do
    current_version = MigrationNotice.version()

    for previous_version <- [0, current_version - 1] do
      notices = MigrationNotice.payloads_since(previous_version)
      assert notices != []
      assert List.last(notices)["version"] == current_version
      assert Enum.all?(notices, &(&1["wake"] == false))

      session = %{
        "context_provider_states" => %{
          "migration_notice" => %{"version" => previous_version}
        }
      }

      assert {:delta, delta} =
               ContextProviders.prepare_activation_delta(adopted_context(session), %{})

      assert [message] = ContextProviders.model_messages(delta)
      for notice <- notices, do: assert(message.content =~ notice["content"])

      assert {[event], 1} = ContextProviders.activation_commit_events("session", delta, 1)
      assert event["runtime_message_type"] == "migration_notice"
      assert event["no_wake"] == true
      assert event["content"] == message.content

      assert ContextProviders.adopted_provider_state(delta)["migration_notice"] ==
               %{"version" => current_version}

      updated = %{
        session
        | "context_provider_states" => ContextProviders.adopted_provider_state(delta)
      }

      assert :none = ContextProviders.prepare_activation_delta(adopted_context(updated), %{})
    end

    assert MigrationNotice.payloads_since(current_version) == []
  end

  test "a disclosure revision names the authoritative current callable tools" do
    session = %{
      "context_provider_states" => %{
        "migration_notice" => %{"version" => MigrationNotice.version()},
        "tool_disclosure" => %{"revision" => "old"}
      }
    }

    config = %{
      tool_disclosure_revision: "current",
      tool_disclosure: %{
        "revision" => "current",
        "tools" => [
          %{"name" => "im_api.internal.task.list", "callable" => true},
          %{"name" => "external.only", "callable" => false},
          %{
            "name" => "mcp.private_server.hidden_op",
            "callable" => true,
            "prompt_visibility" => "hidden"
          },
          %{"name" => "calendar.list_items", "callable" => true, "prompt_visibility" => "hidden"}
        ]
      }
    }

    assert {:delta, delta} =
             ContextProviders.prepare_activation_delta(adopted_context(session), config)

    assert [message] = ContextProviders.model_messages(delta)
    assert message.type == "runtime_guidance"
    assert message.content =~ "im_api.internal.task.list"
    refute message.content =~ "external.only"
    refute message.content =~ "mcp.private_server.hidden_op"
    refute message.content =~ "calendar.list_items"

    assert {:delta, baseline} = ContextProviders.prepare_activation_delta(session, config)

    for message <- ContextProviders.model_messages(baseline) do
      refute message.content =~ "mcp.private_server.hidden_op"
      refute message.content =~ "calendar.list_items"
    end
  end

  # These tests cover changes after the current representation was adopted.
  # Legacy representation repair is covered by TimeContextTest.
  defp adopted_context(session) do
    states = session["context_provider_states"] || %{}

    states =
      states
      |> Map.put("model_context", %{"version" => 1})
      |> Map.put("time_context", %{
        "sampled_at" => SystemsClock.system_time(:second),
        "source_cursor" => nil,
        "session_id" => nil
      })

    Map.put(session, "context_provider_states", states)
  end
end
