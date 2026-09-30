defmodule SalixAgent.MigrationNoticeTest do
  use ExUnit.Case, async: true

  alias SalixAgent.{ContextProviders, MigrationNotice}

  test "migration notices are delivered and adopted once for new and current sessions" do
    for previous_version <- [0, 50, MigrationNotice.version() - 1] do
      notices = MigrationNotice.payloads_since(previous_version)
      assert notices != []

      session = %{
        "context_provider_states" => %{
          "migration_notice" => %{"version" => previous_version}
        }
      }

      assert {:delta, delta} =
               ContextProviders.prepare_activation_delta(adopted_context(session), %{})

      assert [message] = ContextProviders.model_messages(delta)
      for notice <- notices, do: assert(message.content =~ notice["content"])

      updated = %{
        session
        | "context_provider_states" => ContextProviders.adopted_provider_state(delta)
      }

      assert :none = ContextProviders.prepare_activation_delta(adopted_context(updated), %{})
    end
  end

  test "existing sessions receive the Slack split and source migration exactly once" do
    for previous_version <- [39, 45] do
      notices = MigrationNotice.payloads_since(previous_version)

      assert [notice] =
               Enum.filter(
                 notices,
                 &String.contains?(&1["content"], "im_api.slack.reply_message")
               )

      assert notice["wake"] == false
      assert notice["content"] =~ "im_api.slack.post_channel_message"
      assert notice["content"] =~ "task_reply_source"

      refute Enum.any?(
               MigrationNotice.payloads_since(notice["version"]),
               &(&1["version"] == notice["version"])
             )
    end
  end

  test "existing sessions receive the current Comma reply contract after script migration" do
    notices = MigrationNotice.payloads_since(47)
    assert [%{"version" => 48}, %{"version" => 50}, %{"version" => 52}] = notices
    assert Enum.all?(notices, &(&1["wake"] == false))

    assert [%{"version" => 50}, %{"version" => 52}] = MigrationNotice.payloads_since(48)
    assert [%{"version" => 50}, %{"version" => 52}] = MigrationNotice.payloads_since(49)
    assert [replacement] = MigrationNotice.payloads_since(50)
    assert [^replacement] = MigrationNotice.payloads_since(51)
    assert MigrationNotice.payloads_since(MigrationNotice.version()) == []
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
        "sampled_at" => System.system_time(:second),
        "source_cursor" => nil,
        "session_id" => nil
      })

    Map.put(session, "context_provider_states", states)
  end
end
