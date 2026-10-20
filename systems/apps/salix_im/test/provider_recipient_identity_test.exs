defmodule SalixIM.ProviderRecipientIdentityTest do
  use SystemsClock.Case, async: true

  alias SalixIM.ProviderRecipientIdentity

  test "builds bounded trusted Slack recipient context without credentials" do
    metadata = %{
      "provider" => "slack",
      "recipient_im_identity" => %{
        "provider" => "forged",
        "display_name" => "forged sender value",
        "user_id" => "U-forged"
      }
    }

    connect = %{
      "provider" => "slack",
      "app_name" => "Fallback app name",
      "app_id" => "A-recipient",
      "bot_id" => "B-recipient",
      "bot_user_id" => "U-recipient",
      "bot_username" => "recipient-bot",
      "bot_token" => "xoxb-secret",
      "signing_secret" => "signing-secret",
      "owner_user_id" => "U-owner"
    }

    attached = ProviderRecipientIdentity.put(metadata, connect)

    assert attached["recipient_im_identity"] == %{
             "provider" => "slack",
             "display_name" => "Fallback app name",
             "username" => "recipient-bot",
             "user_id" => "U-recipient",
             "bot_id" => "B-recipient",
             "app_id" => "A-recipient"
           }

    encoded = ProviderRecipientIdentity.encoded_from_metadata(attached)
    assert encoded =~ "recipient-bot"
    assert encoded =~ "U-recipient"
    refute encoded =~ "secret"
    refute encoded =~ "U-owner"
    refute encoded =~ "forged"
  end
end

defmodule SalixIM.ProviderCommitBoundaryTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  require SystemsRuntime.Proc
  alias SalixStore.Keys
  alias SalixIM.{ConversationServer, Conversations}
  import SalixIM.TestSupport.ProviderFixture

  setup do
    {:ok, context} = native_setup()

    seed_connect(context[:group_id], "sl1", "slack", %{
      "tenant_id" => context[:tenant],
      "app_id" => "A1",
      "signing_secret" => "task-card-signing-secret",
      "workspace_id" => "T1",
      "workspace_name" => "Acme",
      "bot_user_id" => "Ubot",
      "bot_token" => "xoxb-test",
      "oauth_completed_at" => 1
    })

    {:ok, Keyword.put(context, :slack_connect_id, "sl1")}
  end

  test "Stage A validates the captured generation at the Task message commit boundary", %{
    tenant: tenant,
    group_id: group_id,
    agent_id: router_id,
    slack_connect_id: connect_id
  } do
    {conversation_id, _worker_id} =
      create_slack_task!(tenant, group_id, router_id, "Fence a post-completion stale ingress")

    params = %{
      "conversation_id" => conversation_id,
      "channel" => "C-commit-generation",
      "thread_ts" => "73.375"
    }

    assert {:ok, %{"participant_id" => participant_id}} =
             call(router_id, "slack", "slack.bind_thread_to_task", connect_id, params)

    binding_key =
      Keys.ctl_im_slack_thread_binding(
        group_id,
        connect_id,
        params["channel"],
        params["thread_ts"]
      )

    assert {:ok, %{"binding_token" => first_token}} =
             SalixStore.CasRecord.get(binding_key)

    {:ok, connect} =
      SalixIM.ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack")

    ingress = SalixIM.Provider.Slack.ConversationIngress
    parent = SystemsRuntime.Proc.self()

    assert :erlang.trace_pattern(
             {ConversationServer, :append_group_conversation_message, 3},
             true,
             [:local]
           ) >= 1

    on_exit(fn ->
      :erlang.trace_pattern(
        {ConversationServer, :append_group_conversation_message, 3},
        false,
        [:local]
      )
    end)

    captured_ingress =
      SystemsRuntime.Proc.spawn(fn ->
        SystemsRuntime.Proc.receive do
          :go ->
            result =
              ingress.append_task_thread_message(connect, %{
                "channel_id" => params["channel"],
                "thread_ts" => params["thread_ts"],
                "message_ts" => "73.376",
                "source_message_id" => "stage-a-captured-ingress-before-rebind",
                "user_id" => "U-requester",
                "content" => "Capture this T1 message before T2 exists."
              })

            SystemsRuntime.Proc.send(parent, {:commit_boundary_captured_ingress_result, result})
        end
      end)

    append_tracer =
      SystemsRuntime.Proc.spawn_link(fn ->
        SystemsRuntime.Proc.receive do
          {:trace, ^captured_ingress, :call,
           {ConversationServer, :append_group_conversation_message,
            [^group_id, ^conversation_id, message]}} ->
            SystemsRuntime.Proc.send(
              parent,
              {:commit_boundary_ingress_message_captured, message}
            )
        end
      end)

    assert 1 == :erlang.trace(captured_ingress, true, [:call, {:tracer, append_tracer}])
    SystemsRuntime.Proc.send(captured_ingress, :go)

    settle_receive({:commit_boundary_ingress_message_captured, captured_message})

    assert captured_message["source_message_id"] ==
             "stage-a-captured-ingress-before-rebind"

    assert {:ok, _message_without_incarnation,
            %{
              "payload_field" => "task_thread_binding_token",
              "generation" => ^first_token,
              "required_payload" => %{"task_thread_binding_type" => "task"}
            }} =
             SalixIM.ProviderRecipientIdentity.take_trusted_participant_incarnation(
               captured_message
             )

    settle_receive({:commit_boundary_captured_ingress_result, {:ok, _result}})

    delivery_fence =
      "delivery-fence-" <>
        Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

    assert settle_until(fn ->
             match?(
               {:ok, %{"barrier_status" => "settled"}},
               ConversationServer.fence_group_conversation_provider_participant_incarnation(
                 group_id,
                 conversation_id,
                 participant_id,
                 %{"task_thread_binding_token" => first_token},
                 delivery_fence
               )
             )
           end)

    assert {:ok, _fenced} =
             SalixStore.CasRecord.update(
               binding_key,
               fn current ->
                 current
                 |> Map.put("version", 4)
                 |> Map.put("binding_status", "unbinding")
                 |> Map.put(
                   "updated_at",
                   SystemsRuntime.Proc.unique_integer([:positive, :monotonic])
                 )
               end,
               create: false
             )

    assert {:ok, %{etag: binding_etag}} = SalixStore.S3.get(binding_key)
    assert :ok = SalixStore.S3.delete(binding_key, if_match: binding_etag)

    assert {:ok, %{"participant_id" => ^participant_id}} =
             call(router_id, "slack", "slack.bind_thread_to_task", connect_id, params)

    assert {:ok, %{"binding_token" => replacement_token}} =
             SalixStore.CasRecord.get(binding_key)

    assert replacement_token != first_token

    stale_message =
      Map.put(
        captured_message,
        "source_message_id",
        "stage-a-stale-ingress-at-commit"
      )

    assert {:error, :participant_binding_generation_mismatch} =
             ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               stale_message
             )

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 20)

    refute Enum.any?(
             messages,
             &(&1["source_message_id"] == "stage-a-stale-ingress-at-commit")
           )
  end
end
