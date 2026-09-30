defmodule BridgeForTeams.ConversationsTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Conversations,
    Memberships,
    Observability,
    Orgs
  }

  defmodule RejectingListClient do
    @moduledoc false

    def list_group_conversations(_group_id, _opts), do: {:error, :unavailable}
  end

  defmodule AcceptingListClient do
    @moduledoc false

    def list_group_conversations(_group_id, _opts) do
      {:ok,
       [
         %{
           "conversation_id" => "conv-ok",
           "title" => "Private launch support"
         }
       ]}
    end
  end

  defmodule RejectingConversationClient do
    @moduledoc false

    def create_group_conversation(_group_id, _attrs), do: {:error, :unavailable}
  end

  defmodule TaskScheduleClient do
    @moduledoc false

    def update_task_schedule(group_id, conversation_id, attrs) when is_map(attrs) do
      send(self(), {:task_schedule, :put, group_id, conversation_id, attrs})

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "kind" => "agent_task",
         "schedule" => %{
           "schedule_id" => "schedule-#{conversation_id}",
           "command" => "Inspect the task."
         }
       }}
    end

    def update_task_schedule(group_id, conversation_id, nil) do
      send(self(), {:task_schedule, :delete, group_id, conversation_id})

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "kind" => "agent_task",
         "schedule" => %{
           "schedule_id" => nil,
           "command" => "Inspect the task."
         }
       }}
    end
  end

  defmodule TaskScheduleReadClient do
    @moduledoc false

    def get_schedule(schedule_id) do
      send(self(), {:task_schedule_read, schedule_id})

      Application.get_env(
        :bridge_for_teams_core,
        :test_task_schedule_read_result,
        {:error, :not_found}
      )
    end
  end

  defmodule AcceptingMessageClient do
    @moduledoc false

    def ensure_group_conversation_provider_participant(group_id, conversation_id, attrs) do
      participant_id = "ptp1_1000000000000000001"
      Process.put(:bft_participant_ensured, {group_id, conversation_id, participant_id})
      send(self(), {:project_conversation_participant, group_id, conversation_id, attrs})
      {:ok, Map.put(attrs, "participant_id", participant_id)}
    end

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      {^group_id, ^conversation_id, participant_id} = Process.get(:bft_participant_ensured)
      ^participant_id = attrs["participant_id"]
      send(self(), {:project_conversation_message, attrs})

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "message_id" => attrs["client_request_id"],
         "delivery_status" => "queued",
         "inserted" => true
       }}
    end
  end

  defmodule AcceptingDeliveryStatusClient do
    @moduledoc false

    def group_conversation_delivery_status(group_id, conversation_id, opts) do
      {:ok,
       %{
         "agent_group_id" => group_id,
         "conversation_id" => conversation_id,
         "participant_id" => Keyword.fetch!(opts, :participant_id),
         "message_id" => Keyword.get(opts, :message_id),
         "deliveries" => [
           %{
             "message_id" => "msg-1",
             "participant_id" => "worker",
             "participant_agent_id" => "agent-worker",
             "participant_payload" => %{"session_id" => "im-task-1"},
             "status" => "delivered",
             "session" => %{"exists" => true, "status" => "ready"}
           }
         ],
         "limit" => Keyword.fetch!(opts, :limit)
       }}
    end
  end

  defmodule ParticipantStatusesClient do
    @moduledoc false

    def group_conversation_participant_statuses(_group_id, "task-1", _participants) do
      {:ok,
       %{
         "worker" => %{
           "activity" => %{"kind" => "running", "description" => "handling task"}
         }
       }}
    end
  end

  defmodule RouterProjectionClient do
    @moduledoc false

    def get_agent_projection(agent_id, _tenant_id) do
      {:ok,
       %{
         "agent_id" => agent_id,
         "role" => "router",
         "router_session_id" => "ses1_0000000000000000001"
       }}
    end
  end

  defmodule WorkerProjectionClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def get_group_conversation(_group_id, conversation_id) do
      agent_id = Process.get(:conversation_session_worker_agent_id)

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participants" => [
           %{
             "participant_id" => "worker",
             "actor_type" => "agent",
             "agent_id" => agent_id,
             "payload" => %{"session_id" => "ses1_0000000000000000002"}
           }
         ]
       }}
    end
  end

  defmodule RejectingMessageClient do
    @moduledoc false

    def ensure_group_conversation_provider_participant(_group_id, _conversation_id, attrs),
      do: {:ok, Map.put(attrs, "participant_id", "ptp1_1000000000000000001")}

    def append_group_conversation_message(_group_id, _conversation_id, _attrs),
      do: {:error, :unavailable}
  end

  defmodule UnexpectedMessageClient do
    @moduledoc false

    def ensure_group_conversation_provider_participant(_group_id, _conversation_id, _attrs) do
      raise "revoked actor reached the conversation backend"
    end

    def append_group_conversation_message(_group_id, _conversation_id, _attrs) do
      raise "revoked actor reached the conversation backend"
    end
  end

  defmodule SnapshotClient do
    @moduledoc false

    def get_group_conversation_with_messages(group_id, conversation_id, opts) do
      send(self(), {:snapshot_read, group_id, conversation_id, opts})

      {:ok,
       %{
         "conversation" => %{"conversation_id" => conversation_id, "title" => "Snapshot"},
         "messages" => [%{"message_id" => "msg-snapshot"}]
       }}
    end
  end

  defmodule ParticipantListClient do
    @moduledoc false

    def list_group_conversation_participants(group_id, conversation_id, opts) do
      send(self(), {:participant_list_read, group_id, conversation_id, opts})

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participants" => [%{"participant_id" => "worker"}]
       }}
    end
  end

  setup do
    SalixStore.S3.Fake.reset()

    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-conversations"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Acme",
        "slug" => "acme"
      })

    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "helper",
        "role" => "worker"
      })

    %{org: org, project: project, agent: agent}
  end

  test "manages Task Schedule through Salix without auditing command content", %{
    org: org,
    project: project
  } do
    with_client(TaskScheduleClient)
    conversation_id = "cnv1_task_schedule"

    assert {:ok, scheduled} =
             Conversations.put_project_task_schedule(
               project,
               conversation_id,
               %{"interval_minutes" => 60}
             )

    assert scheduled["schedule"]["schedule_id"] == "schedule-cnv1_task_schedule"

    assert_received {:task_schedule, :put, group_id, ^conversation_id,
                     %{"interval_minutes" => 60}}

    assert group_id == project.salix_group_id

    assert {:ok, one_shot} =
             Conversations.delete_project_task_schedule(project, conversation_id)

    assert one_shot["schedule"]["schedule_id"] == nil

    audits =
      Observability.list_audit_logs(org.id,
        resource_id: conversation_id,
        limit: 10
      )

    assert Enum.sort(Enum.map(audits, & &1.action)) ==
             Enum.sort(~w(project_task_schedule.put project_task_schedule.delete))

    refute inspect(Enum.map(audits, & &1.metadata)) =~ "msg-command"
  end

  test "reads only the Schedule bound to the project's Task", %{project: project} do
    with_client(TaskScheduleReadClient)

    on_exit(fn ->
      Application.delete_env(:bridge_for_teams_core, :test_task_schedule_read_result)
    end)

    schedule = %{
      "id" => "sch1_task",
      "receiver" => "task",
      "payload" => %{
        "agent_group_id" => project.salix_group_id,
        "conversation_id" => "cnv1_task"
      },
      "interval_minutes" => 60
    }

    Application.put_env(:bridge_for_teams_core, :test_task_schedule_read_result, {:ok, schedule})

    assert {:ok, ^schedule} =
             Conversations.get_project_task_schedule(project, "cnv1_task", "sch1_task")

    assert_received {:task_schedule_read, "sch1_task"}

    foreign = put_in(schedule, ["payload", "conversation_id"], "cnv1_other_task")

    Application.put_env(:bridge_for_teams_core, :test_task_schedule_read_result, {:ok, foreign})

    assert {:error, :not_found} =
             Conversations.get_project_task_schedule(project, "cnv1_task", "sch1_task")

    foreign_group = put_in(schedule, ["payload", "agent_group_id"], "grp1_other")

    Application.put_env(
      :bridge_for_teams_core,
      :test_task_schedule_read_result,
      {:ok, foreign_group}
    )

    assert {:error, :not_found} =
             Conversations.get_project_task_schedule(project, "cnv1_task", "sch1_task")
  end

  test "records an Operations diagnostic when Salix conversation listing is unreachable", %{
    org: org,
    project: project
  } do
    with_client(RejectingListClient)

    assert {:error, :unavailable} = Conversations.list_project_conversations(project, limit: 25)
    assert {:error, :unavailable} = Conversations.list_project_conversations(project, limit: 25)

    assert [event] =
             Observability.list_events(org.id,
               event_type: "project.conversations.unavailable",
               limit: 10
             )

    assert event.domain == "conversation"
    assert event.project_id == project.id
    assert event.resource_type == "project_conversation_index"
    assert event.resource_id == project.id
    assert event.source == "salix.conversation"
    assert event.severity == "warning"
    assert event.status == "unavailable"
    assert event.reason_class == "unavailable"
    assert event.correlation_id == "project:#{project.id}:conversations:index"
    assert event.evidence["surface"] == "project_conversations"
    assert event.evidence["list_limit"] == 25
    refute inspect(event.evidence) =~ "Private launch support"
  end

  test "does not record an Operations diagnostic for successful conversation reads", %{
    org: org,
    project: project
  } do
    with_client(AcceptingListClient)

    assert {:ok, [%{"conversation_id" => "conv-ok"}]} =
             Conversations.list_project_conversations(project)

    assert [] =
             Observability.list_events(org.id,
               event_type: "project.conversations.unavailable",
               limit: 10
             )
  end

  test "reads conversation detail and messages through one Salix snapshot call", %{
    project: project
  } do
    with_client(SnapshotClient)

    assert {:ok, %{conversation: conversation, messages: messages}} =
             Conversations.get_project_conversation_with_messages(project, "conv-snapshot",
               limit: 7
             )

    assert conversation["conversation_id"] == "conv-snapshot"
    assert [%{"message_id" => "msg-snapshot"}] = messages

    assert_received {:snapshot_read, group_id, "conv-snapshot", [limit: 7]}
    assert group_id == project.salix_group_id

    assert {:ok, _snapshot} =
             Conversations.get_project_conversation_with_messages(project, "conv-snapshot",
               limit: 5,
               after_id: "msg-previous",
               tail: 2,
               ignored: true
             )

    assert_received {:snapshot_read, ^group_id, "conv-snapshot",
                     [limit: 5, after_id: "msg-previous", tail: 2]}
  end

  test "lists conversation participants through the explicit Salix participant API", %{
    project: project
  } do
    with_client(ParticipantListClient)

    assert {:ok, [%{"participant_id" => "worker"}]} =
             Conversations.list_project_conversation_participants(
               project,
               "conv-participants",
               limit: 25
             )

    assert_received {:participant_list_read, group_id, "conv-participants", [limit: 25]}
    assert group_id == project.salix_group_id
  end

  test "records failed conversation create attempts without title content", %{
    org: org,
    project: project,
    agent: agent
  } do
    with_client(RejectingConversationClient)

    assert {:error, :unavailable} =
             Conversations.create_project_conversation(
               project,
               agent,
               %{"title" => "Private launch support"},
               actor_label: "admin@example.test",
               request_id: "req-conversation-fail"
             )

    [event] = Observability.list_events(org.id, domain: "conversation", status: "failed")
    assert event.event_type == "conversation.created"
    assert event.severity == "error"
    assert event.reason_class == "unavailable"
    assert event.resource_type == "project_conversation"
    assert event.evidence["agent_id"] == agent.id
    assert event.evidence["request_id"] == "req-conversation-fail"
    refute inspect(event) =~ "Private launch support"

    [audit] =
      Observability.list_audit_logs(org.id,
        action: "project_conversation.created",
        result: "failed"
      )

    assert audit.reason_class == "unavailable"
    assert audit.resource_type == "project_conversation"
    assert audit.metadata["project_id"] == project.id
    assert audit.metadata["agent_id"] == agent.id
    assert audit.metadata["request_id"] == "req-conversation-fail"
    refute inspect(audit) =~ "Private launch support"
  end

  test "records dashboard message sends without message content", %{org: org, project: project} do
    with_client(AcceptingMessageClient)

    assert {:ok, result} =
             Conversations.send_project_conversation_message(
               project,
               "conv-sensitive",
               "Please summarize the private launch plan",
               actor_label: "admin@example.test",
               request_id: "req-message-send"
             )

    assert result["message_id"] == "dash-req-message-send"

    [event] =
      Observability.list_events(org.id,
        domain: "conversation",
        event_type: "conversation.message.sent"
      )

    assert event.status == "ok"
    assert event.resource_type == "project_conversation"
    assert event.resource_id == "conv-sensitive"
    assert event.correlation_id == "req-message-send"
    assert event.evidence["message_id"] == "dash-req-message-send"
    assert event.evidence["delivery_status"] == "queued"
    assert event.evidence["request_id"] == "req-message-send"
    refute inspect(event) =~ "private launch plan"

    [audit] =
      Observability.list_audit_logs(org.id,
        action: "project_conversation.message_sent",
        result: "ok"
      )

    assert audit.resource_id == "conv-sensitive"
    assert audit.metadata["message_id"] == "dash-req-message-send"
    assert audit.metadata["delivery_status"] == "queued"
    assert audit.metadata["request_id"] == "req-message-send"
    refute inspect(audit) =~ "private launch plan"

    group_id = project.salix_group_id

    assert_received {:project_conversation_participant, ^group_id, "conv-sensitive", participant}

    assert participant == %{
             "actor_type" => "provider",
             "provider" => "bft",
             "target_key" => "bft",
             "role_label" => "bridge_for_teams",
             "state" => "active",
             "notification_filter" => %{"messages" => "none", "statuses" => "none"}
           }

    assert_received {:project_conversation_message, attrs}
    assert attrs["actor_type"] == "provider_system"
    assert attrs["provider"] == "bft"
    assert attrs["participant_id"] == "ptp1_1000000000000000001"
    refute Map.has_key?(attrs, "provider_participant")
  end

  test "uses the authorized dashboard user as the BFT provider sender", %{project: project} do
    with_client(AcceptingMessageClient)

    {:ok, actor} = Accounts.create_user(%{"email" => "task-steering-user@example.com"})
    {:ok, _membership} = Memberships.put_project_member(project.id, actor.id, "user")

    assert {:ok, _result} =
             Conversations.send_project_conversation_message(
               project,
               "conv-task-steering",
               "Prioritize the failing test.",
               actor_user_id: actor.id,
               request_id: "req-task-steering"
             )

    group_id = project.salix_group_id

    assert_received {:project_conversation_participant, ^group_id, "conv-task-steering",
                     participant}

    refute Map.has_key?(participant, "user_id")
    refute Map.has_key?(participant, "user_name")

    assert_received {:project_conversation_message, attrs}
    assert attrs["actor_type"] == "provider_user"
    assert attrs["provider"] == "bft"
    assert attrs["user_id"] == actor.id
    assert attrs["user_name"] == actor.email
    assert attrs["display_name"] == actor.email

    assert attrs["participant_id"] == "ptp1_1000000000000000001"
    refute Map.has_key?(attrs, "provider_participant")
  end

  test "refuses a message before Salix when the actor lost project access", %{
    project: project
  } do
    with_client(UnexpectedMessageClient)

    {:ok, actor} =
      Accounts.create_user(%{"email" => "revoked-conversation-actor@example.com"})

    {:ok, _membership} = Memberships.put_project_member(project.id, actor.id, "user")
    :ok = Memberships.remove_project_member(project.id, actor.id)

    assert {:error, :forbidden} =
             Conversations.send_project_conversation_message(
               project,
               "conv-revoked",
               "This must not reach Salix",
               actor_user_id: actor.id
             )
  end

  test "records failed dashboard message sends without message content", %{
    org: org,
    project: project
  } do
    with_client(RejectingMessageClient)

    assert {:error, :unavailable} =
             Conversations.send_project_conversation_message(
               project,
               "conv-sensitive",
               "Send the private deployment status",
               actor_label: "admin@example.test",
               request_id: "req-message-fail"
             )

    [event] =
      Observability.list_events(org.id,
        domain: "conversation",
        event_type: "conversation.message.sent",
        status: "failed"
      )

    assert event.severity == "error"
    assert event.reason_class == "unavailable"
    assert event.resource_id == "conv-sensitive"
    assert event.correlation_id == "req-message-fail"
    assert event.evidence["client_request_id"] == "dash-req-message-fail"
    refute Map.has_key?(event.evidence, "message_id")
    refute inspect(event) =~ "private deployment status"

    [audit] =
      Observability.list_audit_logs(org.id,
        action: "project_conversation.message_sent",
        result: "failed"
      )

    assert audit.reason_class == "unavailable"
    assert audit.resource_id == "conv-sensitive"
    assert audit.metadata["client_request_id"] == "dash-req-message-fail"
    refute Map.has_key?(audit.metadata, "message_id")
    assert audit.metadata["request_id"] == "req-message-fail"
    refute inspect(audit) =~ "private deployment status"
  end

  test "reads project conversation participant delivery diagnostics through the Salix client", %{
    project: project
  } do
    with_client(AcceptingDeliveryStatusClient)

    assert {:ok, status} =
             Conversations.project_conversation_delivery_status(project, "task-1",
               participant_id: "worker",
               message_id: "msg-1",
               limit: 7
             )

    assert status["agent_group_id"] == project.salix_group_id
    assert status["conversation_id"] == "task-1"
    assert status["participant_id"] == "worker"
    assert status["message_id"] == "msg-1"
    assert status["limit"] == 7

    assert [%{"participant_agent_id" => "agent-worker", "session" => %{"status" => "ready"}}] =
             status["deliveries"]
  end

  test "projects already-loaded participant statuses", %{project: project} do
    with_client(ParticipantStatusesClient)

    assert {:ok, %{"worker" => status}} =
             Conversations.project_conversation_participant_statuses(
               project,
               "task-1",
               [%{"participant_id" => "worker", "actor_type" => "agent"}]
             )

    assert status["activity"]["kind"] == "running"
  end

  # Worker conversations use their participant session; routers use their one
  # persisted group session regardless of conversation.
  test "conversation_session_ids covers the worker and router session shapes", %{
    project: project,
    agent: agent
  } do
    Process.put(:conversation_session_worker_agent_id, agent.salix_agent_id)
    with_client(WorkerProjectionClient)

    assert Conversations.conversation_session_ids(project, agent, "conv-1") == [
             "ses1_0000000000000000002"
           ]

    assert Conversations.conversation_session_ids(project, nil, "conv-1") == [
             "ses1_0000000000000000002"
           ]

    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))
    with_client(RouterProjectionClient)

    assert Conversations.conversation_session_ids(project, router, "conv-1") ==
             ["ses1_0000000000000000001"]

    assert Conversations.conversation_session_ids(project, agent, nil) == []
  end

  defmodule ActivitySurfaceClient do
    @moduledoc false
    def list_agent_activities(_agent_id),
      do:
        {:ok,
         [
           %{
             "session_id" => "ses1_0000000000000000003",
             "phase" => "thinking",
             "summary" => "Pondering"
           }
         ]}
  end

  # The connect-time status seed is best-effort: a client exposing the surface
  # read serves it; one without it (older node, minimal test client) degrades
  # to [] instead of raising.
  test "list_agent_activities reads the surface and degrades without it", %{agent: agent} do
    with_client(ActivitySurfaceClient)
    assert [%{"summary" => "Pondering"}] = Conversations.list_agent_activities(agent)

    with_client(RejectingListClient)
    assert Conversations.list_agent_activities(agent) == []
    assert Conversations.list_agent_activities(nil) == []
  end

  defp with_client(mod) do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, mod)
    on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev) end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
