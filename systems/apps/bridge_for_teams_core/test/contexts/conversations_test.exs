defmodule BridgeForTeams.ConversationsTest do
  use BridgeForTeams.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.BridgeForTeams"]

  alias BridgeForTeams.{
    Accounts,
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:task_schedule, :put, group_id, conversation_id, attrs}
      )

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
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:task_schedule, :delete, group_id, conversation_id}
      )

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
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:task_schedule_read, schedule_id})

      SystemsRuntime.get_env(
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

      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:project_conversation_participant, group_id, conversation_id, attrs}
      )

      {:ok, Map.put(attrs, "participant_id", participant_id)}
    end

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      {^group_id, ^conversation_id, participant_id} = Process.get(:bft_participant_ensured)
      ^participant_id = attrs["participant_id"]
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:project_conversation_message, attrs})

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
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:snapshot_read, group_id, conversation_id, opts}
      )

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
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:participant_list_read, group_id, conversation_id, opts}
      )

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
      SystemsRuntime.delete_env(:bridge_for_teams_core, :test_task_schedule_read_result)
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

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :test_task_schedule_read_result,
      {:ok, schedule}
    )

    assert {:ok, ^schedule} =
             Conversations.get_project_task_schedule(project, "cnv1_task", "sch1_task")

    assert_received {:task_schedule_read, "sch1_task"}

    foreign = put_in(schedule, ["payload", "conversation_id"], "cnv1_other_task")

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :test_task_schedule_read_result,
      {:ok, foreign}
    )

    assert {:error, :not_found} =
             Conversations.get_project_task_schedule(project, "cnv1_task", "sch1_task")

    foreign_group = put_in(schedule, ["payload", "agent_group_id"], "grp1_other")

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :test_task_schedule_read_result,
      {:ok, foreign_group}
    )

    assert {:error, :not_found} =
             Conversations.get_project_task_schedule(project, "cnv1_task", "sch1_task")
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

  defp with_client(mod) do
    prev = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, mod)
    on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev) end)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
