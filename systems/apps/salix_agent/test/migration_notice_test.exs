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

  test "a fresh session adopts the current notice version without earlier notices" do
    session = %{
      "context_provider_states" => %{},
      "messages" => [%{"role" => "user", "content" => "hello"}]
    }

    assert {:delta, delta} = ContextProviders.prepare_activation_delta(session, %{})

    {events, _seq} = ContextProviders.activation_commit_events("session", delta, 1)
    refute Enum.any?(events, &(&1["runtime_message_type"] == "migration_notice"))

    for message <- ContextProviders.model_messages(delta),
        do: refute(message.content =~ List.first(MigrationNotice.payloads_since(0))["content"])

    assert ContextProviders.adopted_provider_state(delta)["migration_notice"] ==
             %{"version" => MigrationNotice.version()}

    updated = %{
      session
      | "context_provider_states" => ContextProviders.adopted_provider_state(delta)
    }

    assert :none = ContextProviders.prepare_activation_delta(updated, %{})
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

  test "a later disclosure revision shows the added and changed tools in full and names removed ones" do
    task_list = %{
      "name" => "im_api.internal.task.list",
      "callable" => true,
      "summary" => "List Tasks."
    }

    before = %{
      tool_disclosure_revision: "before",
      tool_disclosure: %{
        "revision" => "before",
        "tools" => [
          task_list,
          %{"name" => "old.tool", "callable" => true, "summary" => "Old."},
          %{"name" => "group.read_conversation", "callable" => true, "summary" => "Read a hit."}
        ]
      }
    }

    session = %{
      "context_provider_states" => %{
        "migration_notice" => %{"version" => MigrationNotice.version()}
      }
    }

    assert {:delta, adopt} =
             ContextProviders.prepare_activation_delta(adopted_context(session), before)

    session = %{
      session
      | "context_provider_states" => ContextProviders.adopted_provider_state(adopt)
    }

    search_summary =
      "Search Task conversations and non-private IM group chats across other authorized Groups in this tenant. " <>
        "Authorized target groups: modeljet (grp_1)."

    after_config = %{
      tool_disclosure_revision: "after",
      tool_disclosure: %{
        "revision" => "after",
        "tools" => [
          task_list,
          %{
            "name" => "group.search_conversations",
            "callable" => true,
            "prompt_visibility" => "summary",
            "summary" => search_summary,
            "manual" => search_summary
          },
          %{
            "name" => "group.read_conversation",
            "callable" => true,
            "summary" => "Read a hit by id."
          }
        ]
      }
    }

    assert {:delta, delta} =
             ContextProviders.prepare_activation_delta(adopted_context(session), after_config)

    assert [message] = ContextProviders.model_messages(delta)
    assert message.content =~ "Authorized target groups: modeljet (grp_1)."
    assert message.content =~ "- group.read_conversation: Read a hit by id."
    assert message.content =~ "No longer available: old.tool."
    refute message.content =~ "im_api.internal.task.list"

    session = %{
      session
      | "context_provider_states" => ContextProviders.adopted_provider_state(delta)
    }

    assert :none =
             ContextProviders.prepare_activation_delta(adopted_context(session), after_config)
  end

  test "a registry tool whose schema changed is shown, the unchanged ones are not" do
    base = SalixAgent.ToolDisclosure.materialize_static("router", :internal, %{})

    recomputed =
      base
      |> Map.delete("listed_fingerprints")
      |> SalixAgent.ToolDisclosure.listed_fingerprints()

    assert recomputed == base["listed_fingerprints"]

    schema = %{"type" => "object", "properties" => %{"needle" => %{"type" => "string"}}}

    tools =
      Enum.map(base["tools"], fn
        %{"name" => "web.search"} = tool -> Map.put(tool, "input_schema", schema)
        tool -> tool
      end)

    session = %{
      "context_provider_states" => %{
        "migration_notice" => %{"version" => MigrationNotice.version()},
        "tool_disclosure" => %{
          "revision" => base["revision"],
          "tools" => base["listed_fingerprints"]
        }
      }
    }

    config = %{
      tool_disclosure_revision: "changed",
      tool_disclosure: %{"revision" => "changed", "tools" => tools}
    }

    assert {:delta, delta} =
             ContextProviders.prepare_activation_delta(adopted_context(session), config)

    assert [message] = ContextProviders.model_messages(delta)
    assert message.content =~ "- web.search:"
    assert message.content =~ "needle"
    refute message.content =~ "- fs.read_file:"
  end

  test "a change to many tools shows one-line entries, and manual tools in full" do
    summary_tools =
      for n <- 1..9,
          do: %{"name" => "bulk.tool_#{n}", "callable" => true, "summary" => "Tool #{n}."}

    search = %{
      "name" => "group.search_conversations",
      "callable" => true,
      "prompt_visibility" => "manual",
      "summary" => "Search. Authorized target groups: modeljet (grp_1).",
      "input_schema" => %{"type" => "object"}
    }

    session = %{
      "context_provider_states" => %{
        "migration_notice" => %{"version" => MigrationNotice.version()},
        "tool_disclosure" => %{"revision" => "before", "tools" => "help=x"}
      }
    }

    config = %{
      tool_disclosure_revision: "after",
      tool_disclosure: %{"revision" => "after", "tools" => [search | summary_tools]}
    }

    assert {:delta, delta} =
             ContextProviders.prepare_activation_delta(adopted_context(session), config)

    assert [message] = ContextProviders.model_messages(delta)
    assert message.content =~ "Authorized target groups: modeljet (grp_1)."
    assert message.content =~ "- bulk.tool_9: Tool 9."
    assert message.content =~ "No longer available: help."
    assert length(String.split(message.content, "  schema:")) == 2
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
