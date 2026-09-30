defmodule Salix.Bindings.IMAgentControlTest do
  @moduledoc """
  The IM control port's binding. Its whole job beyond delegation is turning
  `SalixAgent.Runtime`'s shared HTTP-shaped refusal into a typed reason the
  chat surface can word for a person, so that translation is what this pins.
  """
  use ExUnit.Case, async: false

  alias Salix.Bindings.IMAgentControl

  @session_id "ses1_0000000000000007001"

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      case previous do
        nil -> Application.delete_env(:salix_store, :s3_backend)
        backend -> Application.put_env(:salix_store, :s3_backend, backend)
      end
    end)

    :ok
  end

  # `Runtime` refuses a non-internal agent with `{:bad_request, "operation is
  # only available for internal runtime agents"}` — the same term it uses for
  # a malformed request. Rendered into a chat that reads as though the SENDER
  # erred, which is why the binding, not the chat surface, translates it.
  test "an external-runtime agent is refused as :internal_runtime_only" do
    agent_id = external_router!()

    assert {:error, :internal_runtime_only} = IMAgentControl.session_status(agent_id, @session_id)

    assert {:error, :internal_runtime_only} =
             IMAgentControl.compact_session(agent_id, @session_id)

    assert {:error, :internal_runtime_only} =
             IMAgentControl.emergency_compact_session(agent_id, @session_id)
  end

  # Only that refusal is translated: a missing session must stay recognisable
  # as a missing session, not be relabelled a runtime-kind problem.
  test "other errors pass through untranslated" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    assert {:error, reason} = IMAgentControl.session_status(agent_id, @session_id)
    refute reason == :internal_runtime_only
  end

  test "client clear uses the real dashboard switch and preserves the retired session" do
    previous_control = Application.get_env(:salix_im, :agent_control_mod)
    previous_execution = Application.get_env(:salix_im, :control_command_execution)
    Application.put_env(:salix_im, :agent_control_mod, IMAgentControl)
    Application.put_env(:salix_im, :control_command_execution, :sync)

    on_exit(fn ->
      Application.put_env(:salix_im, :agent_control_mod, previous_control)

      if previous_execution == nil,
        do: Application.delete_env(:salix_im, :control_command_execution),
        else: Application.put_env(:salix_im, :control_command_execution, previous_execution)
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
    refute Process.alive?(old_actor)
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

  defp external_router!() do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    device_id = "test-device"
    runtime_id = "test-runtime"

    SalixAgent.TestSupport.create_control_agent!(agent_id, %{
      "role" => "router",
      "runtime_config" => %{
        "kind" => "external",
        "provider" => "codex",
        "device_id" => device_id,
        "runtime_id" => runtime_id,
        "device_runtime_id" =>
          SalixStore.RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)
      }
    })

    agent_id
  end
end
