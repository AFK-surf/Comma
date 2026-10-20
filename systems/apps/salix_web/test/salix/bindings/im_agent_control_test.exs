defmodule Salix.Bindings.IMAgentControlTest do
  @moduledoc """
  The IM control port's binding: session status and compaction through
  `SalixAgent.Runtime`, and the Router session switch used by client clear.
  """
  use SystemsClock.Case, async: false

  alias Salix.Bindings.IMAgentControl

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      case previous do
        nil -> SystemsRuntime.delete_env(:salix_store, :s3_backend)
        backend -> SystemsRuntime.put_env(:salix_store, :s3_backend, backend)
      end
    end)

    :ok
  end

  test "client clear uses the real dashboard switch and preserves the retired session" do
    previous_control = SystemsRuntime.get_env(:salix_im, :agent_control_mod)
    previous_execution = SystemsRuntime.get_env(:salix_im, :control_command_execution)
    SystemsRuntime.put_env(:salix_im, :agent_control_mod, IMAgentControl)
    SystemsRuntime.put_env(:salix_im, :control_command_execution, :sync)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_im, :agent_control_mod, previous_control)

      if previous_execution == nil,
        do: SystemsRuntime.delete_env(:salix_im, :control_command_execution),
        else: SystemsRuntime.put_env(:salix_im, :control_command_execution, previous_execution)
    end)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    agent = SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => "router"})
    group_id = agent["group_id"]

    {:ok, _} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", agent_id)
      end)

    old_session_id = agent["router_session_id"]
    {:ok, _} = SalixAgent.InternalSessionStore.prepare_create(agent_id, old_session_id)

    {:ok, _} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, old_session_id, [
        %{
          "type" => "assistant",
          "session_id" => old_session_id,
          "message_id" => 1,
          "content" => "Keep this previous Router reply.",
          "created_at" => 1_000
        },
        %{"type" => "ack", "session_id" => old_session_id, "last_ack_message_id" => 1}
      ])

    {:ok, _} = SalixAgent.Placement.ensure_started(agent_id, create: false)

    {:ok, old_actor} =
      SalixAgent.InternalSessionFleet.ensure_started(
        agent_id,
        old_session_id,
        process_on_init: false
      )

    {:ok, old_session} = SalixAgent.TestSupport.SessionData.read(agent_id, old_session_id)

    attrs = %{
      "client_request_id" => "real-router-clear",
      "content" => [%{"type" => "text", "text" => "<salix-command>clear</salix-command>"}]
    }

    assert {:ok, first} = SalixIM.RouterConversationInput.append_user_message(group_id, attrs)
    assert {:ok, updated} = SalixIM.GroupDirectory.get_agent(agent_id)
    new_session_id = updated["router_session_id"]
    assert new_session_id != old_session_id
    refute SystemsRuntime.Proc.alive?(old_actor)
    assert {:ok, retired} = SalixAgent.TestSupport.SessionData.read(agent_id, old_session_id)
    assert old_session.messages != []
    assert retired.messages == old_session.messages
    assert {:ok, fresh} = SalixAgent.TestSupport.SessionData.read(agent_id, new_session_id)
    assert fresh.messages == []
    assert fresh.input_queue == []

    assert {:ok, retry} = SalixIM.RouterConversationInput.append_user_message(group_id, attrs)
    refute retry["inserted"]

    assert {:ok, %{"router_session_id" => ^new_session_id}} =
             SalixIM.GroupDirectory.get_agent(agent_id)

    assert {:ok, [command, reply]} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               first["conversation_id"],
               limit: 10
             )

    assert command["delivery_filter"] == %{"participant_ids" => []}
    assert reply["delivery_filter"] == %{"participant_ids" => []}
    assert hd(reply["content"])["text"] =~ new_session_id

    assert {:error, {:stale_router_session, ^new_session_id}} =
             IMAgentControl.switch_router_session(agent_id, agent["tenant_id"], old_session_id)
  end
end
