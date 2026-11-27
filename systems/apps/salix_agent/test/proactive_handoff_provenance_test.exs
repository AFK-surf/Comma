defmodule SalixAgent.ProactiveHandoffProvenanceTest do
  use ExUnit.Case, async: true

  alias SalixAgent.ToolCallProvenance

  @task_create %{name: "im_api.internal.task.create", args: %{"content" => "Look into the CI"}}

  @handoff %{
    "provider" => "internal",
    "source_actor_type" => "system",
    "principal_ref" => %{"subject_id" => "usr_owner"},
    "proactive_handoff" => true
  }

  @owner_message %{
    "provider" => "internal",
    "source_actor_type" => "user",
    "participant_id" => "usr_owner",
    "agent_group_id" => "grp_1",
    "source_message_id" => "msg_owner"
  }

  test "a background handoff alone does not delegate a Task" do
    assert {:error, "proactive_handoff_not_delegation"} =
             ToolCallProvenance.select(@task_create, %{trusted_origins: [@handoff]})
  end

  test "a person's message in the same activation admits only a Task that names it" do
    context = %{
      group_id: "grp_1",
      trusted_origins: [@handoff, @owner_message],
      source_message_ids: ["msg_owner"]
    }

    assert {:error, "proactive_handoff_not_delegation"} =
             ToolCallProvenance.select(@task_create, context)

    named = put_in(@task_create, [:args, "source_message_id"], "msg_owner")

    assert {:ok, %{trusted_origin: %{"source_actor_type" => "user"}}} =
             ToolCallProvenance.select(named, context)
  end

  test "a continuation of the handoff keeps its origin" do
    runtime = %{
      role: "runtime",
      trusted_origin_source_message_ids: ["router-input:check"],
      trusted_origins: [@handoff]
    }

    origins = ToolCallProvenance.message_origins(runtime, ["router-input:check"])

    assert {:error, "proactive_handoff_not_delegation"} =
             ToolCallProvenance.select(@task_create, %{trusted_origins: origins})
  end

  test "other internal system inputs keep their behavior" do
    system = Map.delete(@handoff, "proactive_handoff")
    assert {:ok, _context} = ToolCallProvenance.select(@task_create, %{trusted_origins: [system]})
  end

  describe "im_api.internal.send_message station delegation guard" do
    @station_send %{
      name: "im_api.internal.send_message",
      args: %{
        "conversation_id" => "station:stn_mini:CHAT/1795577429.312000",
        "content" => [%{"type" => "text", "text" => "Please add staging bot to PR #5590"}]
      }
    }

    @home_send %{
      name: "im_api.internal.send_message",
      args: %{
        "conversation_id" => "cnv1_home",
        "content" => [%{"type" => "text", "text" => "Alex asked about PR #5590."}]
      }
    }

    test "blocks sending to a station:* chat during a proactive_handoff activation while allowing Home replies" do
      assert {:error, "proactive_handoff_not_delegation"} =
               ToolCallProvenance.select(@station_send, %{trusted_origins: [@handoff]})

      assert {:ok, _context} =
               ToolCallProvenance.select(@home_send, %{trusted_origins: [@handoff]})

      # Continuations inherit proactive_handoff and stay blocked for station:* sends.
      runtime = %{
        role: "runtime",
        trusted_origin_source_message_ids: ["router-input:check"],
        trusted_origins: [@handoff]
      }

      origins = ToolCallProvenance.message_origins(runtime, ["router-input:check"])

      assert {:error, "proactive_handoff_not_delegation"} =
               ToolCallProvenance.select(@station_send, %{trusted_origins: origins})
    end

    test "in a mixed activation requires a valid admitted human source_message_id and rejects forged IDs" do
      context = %{
        group_id: "grp_1",
        trusted_origins: [@handoff, @owner_message],
        source_message_ids: ["msg_owner"]
      }

      assert {:error, "proactive_handoff_not_delegation"} =
               ToolCallProvenance.select(@station_send, context)

      forged = put_in(@station_send, [:args, "source_message_id"], "msg_forged")

      assert {:error, "task_source_unknown"} =
               ToolCallProvenance.select(forged, context)

      named = put_in(@station_send, [:args, "source_message_id"], "msg_owner")

      assert {:ok, %{trusted_origin: %{"source_actor_type" => "user"}}} =
               ToolCallProvenance.select(named, context)
    end

    test "pure owner turns (such as tapping a question card) may send to station:* directly" do
      context = %{
        group_id: "grp_1",
        trusted_origins: [@owner_message],
        source_message_ids: ["msg_owner"]
      }

      assert {:ok, _context} = ToolCallProvenance.select(@station_send, context)
    end
  end
end
