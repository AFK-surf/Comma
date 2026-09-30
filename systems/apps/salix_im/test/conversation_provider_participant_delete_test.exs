defmodule SalixIM.ConversationProviderParticipantDeleteTest do
  use ExUnit.Case, async: false

  alias SalixIM.{
    ConversationParticipantActor,
    ConversationFleet,
    ConversationInput,
    ConversationServer,
    Conversations
  }

  alias SalixStore.{CasRecord, Ids, Keys, S3}

  defmodule ProviderDeliveryProbe do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      if pid = Application.get_env(:salix_im, :cold_delete_provider_probe_pid) do
        send(pid, {:provider_delivery_invoked, conn.request_path, body})
      end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{"ok" => true, "channel" => "C-cold-delete", "ts" => "1.1"})
      )
    end
  end

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_placement = Application.get_env(:salix_im, :conversation_placement)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    Application.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      try do
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        restore(:salix_store, :s3_backend, previous_backend)
        restore(:salix_im, :conversation_placement, previous_placement)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "name" => "Meeting research provider migration"
    })

    {:ok, tenant_id: tenant_id, group_id: group_id}
  end

  test "destructive provider deletion starts a cold owner without recovery delivery", %{
    group_id: group_id
  } do
    previous_slack_api_base_url = Application.get_env(:salix_im, :slack_api_base_url)

    on_exit(fn ->
      restore(:salix_im, :slack_api_base_url, previous_slack_api_base_url)
      Application.delete_env(:salix_im, :cold_delete_provider_probe_pid)
    end)

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port ->
        {Bandit, plug: ProviderDeliveryProbe, port: port}
      end)

    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    Application.put_env(:salix_im, :cold_delete_provider_probe_pid, self())

    {_plan_id, conversation_id} = create_meeting_plan!(group_id, "cold-delete")
    provider = add_provider!(group_id, conversation_id, "cold-delete")

    connect_id = get_in(provider, ["payload", "connect_id"])
    seed_slack_connect!(group_id, connect_id)

    participant_id = provider["participant_id"]

    assert [{participant_owner, _value}] =
             Registry.lookup(
               SalixIM.ConversationRegistry,
               ConversationParticipantActor.key(group_id, conversation_id, participant_id)
             )

    append_pending!(group_id, conversation_id, participant_id, participant_owner)
    refute_receive {:provider_delivery_invoked, _path, _body}

    SalixIM.TestSupport.Fleet.stop_all!()

    refute ConversationFleet.running?(group_id, conversation_id)
    S3.Fake.reset_read_log()

    assert {:ok, %{"state" => "deleted"}} =
             ConversationServer.delete_group_conversation_provider_participant(
               group_id,
               conversation_id,
               participant_id
             )

    refute_receive {:provider_delivery_invoked, _path, _body}, 100

    assert {:error, :not_found} =
             Conversations.get_group_conversation_participant(
               group_id,
               conversation_id,
               participant_id
             )
  end

  test "a newly attached provider participant starts at the conversation tail", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    {_plan_id, conversation_id} = create_meeting_plan!(group_id, "tail-cursor")

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Historical Research Worker",
        "role" => "worker"
      })

    assert {:ok, _participant} =
             ConversationInput.ensure_group_conversation_agent_participant(
               group_id,
               conversation_id,
               %{
                 "agent_id" => agent["agent_id"],
                 "role_label" => "worker",
                 "notification_filter" => %{"messages" => "none", "statuses" => "none"}
               }
             )

    assert {:ok, %{"seq" => historical_seq}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               agent["agent_id"],
               %{
                 "client_request_id" => "historical-before-provider",
                 "content" => "This message predates the Slack thread."
               }
             )

    provider = add_provider!(group_id, conversation_id, "tail-cursor")

    assert provider["notification_filter"]["messages"] == "all"
    assert provider["delivery_cursor_seq"] == historical_seq
  end

  test "deactivation cancels queued provider delivery without provider IO", %{
    group_id: group_id
  } do
    previous_slack_api_base_url = Application.get_env(:salix_im, :slack_api_base_url)

    on_exit(fn ->
      restore(:salix_im, :slack_api_base_url, previous_slack_api_base_url)
      Application.delete_env(:salix_im, :cold_delete_provider_probe_pid)
    end)

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port ->
        {Bandit, plug: ProviderDeliveryProbe, port: port}
      end)

    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    Application.put_env(:salix_im, :cold_delete_provider_probe_pid, self())

    {_plan_id, conversation_id} = create_meeting_plan!(group_id, "deactivate")
    provider = add_provider!(group_id, conversation_id, "deactivate")
    participant_id = provider["participant_id"]
    seed_slack_connect!(group_id, get_in(provider, ["payload", "connect_id"]))

    assert [{participant_owner, _value}] =
             Registry.lookup(
               SalixIM.ConversationRegistry,
               ConversationParticipantActor.key(group_id, conversation_id, participant_id)
             )

    pending = append_pending!(group_id, conversation_id, participant_id, participant_owner)

    assert {:ok, %{"state" => "inactive"}} =
             ConversationServer.deactivate_group_conversation_participant(
               group_id,
               conversation_id,
               participant_id
             )

    :ok = S3.Fake.clear_blackhole()
    :ok = ConversationServer.wake_participant(group_id, conversation_id, participant_id)

    assert eventually(fn ->
             case Conversations.get_group_conversation_participant(
                    group_id,
                    conversation_id,
                    participant_id
                  ) do
               {:ok, participant} ->
                 (participant["delivery_log_cursor_seq"] || 0) >= pending["seq"]

               _ ->
                 false
             end
           end)

    refute_receive {:provider_delivery_invoked, _path, _body}, 100
  end

  test "cold recovery retires legacy triage Slack thread delivery before replay", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    previous_slack_api_base_url = Application.get_env(:salix_im, :slack_api_base_url)

    on_exit(fn ->
      restore(:salix_im, :slack_api_base_url, previous_slack_api_base_url)
      Application.delete_env(:salix_im, :cold_delete_provider_probe_pid)
    end)

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port ->
        {Bandit, plug: ProviderDeliveryProbe, port: port}
      end)

    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    Application.put_env(:salix_im, :cold_delete_provider_probe_pid, self())

    {_plan_id, conversation_id} = create_meeting_plan!(group_id, "legacy-triage")

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Historical Research Worker",
        "role" => "worker"
      })

    assert {:ok, _participant} =
             ConversationInput.ensure_group_conversation_agent_participant(
               group_id,
               conversation_id,
               %{
                 "agent_id" => agent["agent_id"],
                 "role_label" => "worker",
                 "notification_filter" => %{"messages" => "none", "statuses" => "none"}
               }
             )

    assert {:ok, %{"seq" => historical_seq}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               agent["agent_id"],
               %{
                 "client_request_id" => "legacy-triage-historical-message",
                 "content" => "This historical message must never reach a newly attached thread."
               }
             )

    provider = add_provider!(group_id, conversation_id, "legacy-triage")
    participant_id = provider["participant_id"]
    seed_slack_connect!(group_id, get_in(provider, ["payload", "connect_id"]))

    assert [{participant_owner, _value}] =
             Registry.lookup(
               SalixIM.ConversationRegistry,
               ConversationParticipantActor.key(group_id, conversation_id, participant_id)
             )

    pending = append_pending!(group_id, conversation_id, participant_id, participant_owner)

    SalixIM.TestSupport.Fleet.stop_all!()

    participant_key =
      Keys.ctl_group_conversation_participant_state(
        group_id,
        conversation_id,
        participant_id
      )

    assert {:ok, %{body: participant_body, etag: participant_etag}} = S3.get(participant_key)

    legacy_participant =
      participant_body
      |> Jason.decode!()
      |> Map.put("role_label", "slack_thread")
      |> Map.put("state", "active")
      |> Map.put("delivery_cursor_seq", 0)
      |> Map.put("notification_filter", %{"messages" => "all", "statuses" => "none"})
      |> update_in(["payload"], fn payload ->
        Map.put(payload, "triage_authority_generation", "legacy-triage-generation")
      end)

    assert {:ok, _result} =
             S3.put(participant_key, Jason.encode!(legacy_participant),
               if_match: participant_etag
             )

    assert :ok =
             ConversationServer.wake_participant(group_id, conversation_id, participant_id)

    assert eventually(fn ->
             with {:ok, %{body: body}} <- S3.get(participant_key),
                  {:ok,
                   %{
                     "state" => "inactive",
                     "notification_filter" => %{"messages" => "none", "statuses" => "none"},
                     "delivery_log_cursor_seq" => cursor
                   }} <- Jason.decode(body) do
               cursor >= historical_seq and cursor >= pending["seq"]
             else
               _other -> false
             end
           end)

    refute_receive {:provider_delivery_invoked, _path, _body}, 100
  end

  test "provider deletion cannot remove an agent participant", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    {_plan_id, conversation_id} = create_meeting_plan!(group_id, "agent-boundary")

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Research Worker",
        "role" => "worker"
      })

    assert {:ok, participant} =
             ConversationInput.ensure_group_conversation_agent_participant(
               group_id,
               conversation_id,
               %{
                 "agent_id" => agent["agent_id"],
                 "role_label" => "worker",
                 "notification_filter" => %{"messages" => "mentioned", "statuses" => "none"}
               }
             )

    assert {:error, :provider_participant_required} =
             ConversationServer.delete_group_conversation_provider_participant(
               group_id,
               conversation_id,
               participant["participant_id"]
             )

    assert {:ok, %{"actor_type" => "agent", "state" => "active"}} =
             Conversations.get_group_conversation_participant(
               group_id,
               conversation_id,
               participant["participant_id"]
             )
  end

  defp append_pending!(group, conversation, participant, owner) do
    {:ok, sender} =
      ConversationServer.ensure_group_conversation_user_participant(group, conversation, %{
        "user_id" => "delivery-fixture"
      })

    :ok = :sys.suspend(owner)

    {:ok, message} =
      ConversationServer.append_group_conversation_message(group, conversation, %{
        "participant_id" => sender["participant_id"],
        "actor_type" => "user",
        "user_id" => "delivery-fixture",
        "content" => "must not be sent after removal",
        "delivery_filter" => %{"participant_ids" => [participant]}
      })

    id = Enum.join([group, conversation, message["message_id"], participant], ":")

    key =
      Keys.ctl_group_conversation_participant_delivery_state(group, conversation, participant, id)

    :ok = S3.Fake.blackhole({:fail, 503, :put, key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)
    :ok = :sys.resume(owner)
    message
  end

  defp create_meeting_plan!(group_id, label) do
    plan_id = Ids.new_meeting_plan_id()

    assert {:ok, %{"conversation_id" => conversation_id}} =
             ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_task",
               "title" => "#{label} meeting research",
               "source_refs" => %{"meeting_plan_id" => plan_id}
             })

    put_plan!(group_id, plan_id, conversation_id, label)
    {plan_id, conversation_id}
  end

  defp put_plan!(group_id, plan_id, conversation_id, status) do
    plan = %{
      "meeting_plan_id" => plan_id,
      "group_id" => group_id,
      "conversation_id" => conversation_id,
      "status" => status
    }

    assert {:ok, _} =
             S3.put(
               Keys.ctl_meeting_plan(group_id, plan_id),
               Jason.encode!(plan),
               if_none_match: "*"
             )
  end

  defp add_provider!(group_id, conversation_id, suffix) do
    assert {:ok, provider} =
             ConversationServer.ensure_group_conversation_provider_participant(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "provider",
                 "provider" => "slack",
                 "target_key" => "meeting-calendar-target-#{suffix}",
                 "role_label" => "meeting_calendar_delivery",
                 "payload" => %{
                   "connect_id" => "meeting-calendar-connect-#{suffix}",
                   "channel_id" => "C-#{suffix}"
                 },
                 "state" => "active",
                 "notification_filter" => %{"messages" => "all", "statuses" => "none"}
               }
             )

    provider
  end

  defp seed_slack_connect!(group_id, connect_id) do
    now = System.system_time(:millisecond)

    assert {:ok, _connect} =
             CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
               "tenant_id" => Ids.tenant_id_from_group!(group_id),
               "group_id" => group_id,
               "connect_id" => connect_id,
               "provider" => "slack",
               "app_id" => "A-cold-delete",
               "workspace_id" => "T-cold-delete",
               "bot_token" => "xoxb-cold-delete",
               "oauth_completed_at" => now,
               "created_at" => now,
               "updated_at" => now
             })
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
