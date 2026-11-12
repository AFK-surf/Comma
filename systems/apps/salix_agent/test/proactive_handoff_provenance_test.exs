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
end
