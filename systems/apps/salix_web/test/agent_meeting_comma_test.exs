defmodule Salix.Bindings.AgentMeetingCommaTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias Salix.Bindings.AgentMeeting
  alias SalixIM.{Conversations, RouterConversationInput}
  alias SalixStore.{Ids, S3}

  defmodule RuntimeDriver do
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def join(doc), do: Agent.update(__MODULE__, &[doc | &1])
    def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)
  end

  setup do
    envs = [
      {:salix_store, :s3_backend, S3.Fake},
      {:salix_meet, :runtime_driver, RuntimeDriver},
      {:salix_meet, :agent_runtime_mod, SalixMeet.TestAgentRuntime}
    ]

    previous =
      Enum.map(envs, fn {app, key, value} ->
        old = SystemsRuntime.fetch_env(app, key)
        SystemsRuntime.put_env(app, key, value)
        {app, key, old}
      end)

    SalixAgent.TestSupport.configure_control_fixtures!()

    if is_nil(SystemsRuntime.Proc.whereis(S3.Fake)), do: start_supervised!(S3.Fake)
    S3.Fake.reset()
    SalixAgent.TestSupport.stop_all_agents()
    start_supervised!(RuntimeDriver)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(previous, fn
        {app, key, {:ok, value}} -> SystemsRuntime.put_env(app, key, value)
        {app, key, :error} -> SystemsRuntime.delete_env(app, key)
      end)
    end)

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    router_id = Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(router_id, %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "name" => "Router",
      "role" => "router"
    })

    SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => router_id})
    {:ok, conversation} = RouterConversationInput.ensure(group_id)

    %{
      workspace: %{"default_group_id" => group_id, "salix_tenant_id" => tenant_id},
      conversation_id: conversation["conversation_id"],
      router_id: router_id
    }
  end

  test "the Router joins the Meet a person sends in Home and the chat hears the status from it",
       %{workspace: workspace, conversation_id: conversation_id, router_id: router_id} do
    group_id = workspace["default_group_id"]
    message_id = append_user_message(group_id, "usr_sender", "zh-CN")
    context = router_context(group_id, router_id, conversation_id, message_id)

    assert {:ok, %{"meeting_id" => meeting_id, "provider" => "comma"}} =
             AgentMeeting.join(group_id, %{}, context)

    assert {:ok, %{"status" => "already_active"}} = AgentMeeting.join(group_id, %{}, context)
    assert [%{"id" => ^meeting_id, "state" => state}] = RuntimeDriver.calls()
    assert state["comma_ref"]["user_id"] == "usr_sender"
    assert state["runtime_policy"]["join_as"] == "guest"

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id)

    assert [notice] = Enum.filter(messages, &(&1["actor_type"] == "agent"))
    assert notice["agent_id"] == router_id
    assert [%{"text" => "正在以访客身份加入 Google Meet…"}] = notice["content"]
  end

  test "only the Router, answering a person's own message, can join",
       %{workspace: workspace, conversation_id: conversation_id, router_id: router_id} do
    group_id = workspace["default_group_id"]
    message_id = append_user_message(group_id, "usr_sender", "en")
    context = router_context(group_id, router_id, conversation_id, message_id)

    assert {:error, :router_current_human_request_required} =
             AgentMeeting.join(group_id, %{}, %{context | "role" => "worker"})

    forged = put_in(context, ["trusted_origin", "source_actor_type"], "agent")

    assert {:error, :router_current_human_request_required} =
             AgentMeeting.join(group_id, %{}, forged)

    assert RuntimeDriver.calls() == []
  end

  defp router_context(group_id, router_id, conversation_id, message_id) do
    %{
      "agent_id" => router_id,
      "group_id" => group_id,
      "role" => "router",
      "trusted_origin" => %{
        "provider" => "internal",
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "conversation_kind" => "user_chat",
        "message_id" => message_id,
        "source_actor_type" => "user"
      }
    }
  end

  defp append_user_message(group_id, user_id, locale) do
    {:ok, result} =
      RouterConversationInput.append_user_message(group_id, %{
        "client_request_id" => "meet-#{SystemsRuntime.Proc.unique_integer([:positive])}",
        "actor_type" => "user",
        "user_id" => user_id,
        "metadata" => %{"locale" => locale},
        "content" => "please join https://meet.google.com/abc-defg-hij"
      })

    result["message_id"]
  end
end
