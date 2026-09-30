defmodule BridgeForTeams.TaskDelegationTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Artifacts,
    Memberships,
    Orgs,
    TaskDelegation,
    WorkspaceItems
  }

  defmodule ScriptedClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false

    def get_group(group_id) do
      {:ok,
       %{
         "group_id" => group_id,
         "router_agent_id" =>
           Application.fetch_env!(:bridge_for_teams_core, :test_td_router_agent_id)
       }}
    end

    def create_task_conversation(group_id, delegator_agent_id, worker_agent_id, attrs) do
      calls = Application.get_env(:bridge_for_teams_core, :test_td_task_creates, [])

      Application.put_env(:bridge_for_teams_core, :test_td_task_creates, [
        {group_id, delegator_agent_id, worker_agent_id, attrs} | calls
      ])

      case Application.get_env(:bridge_for_teams_core, :test_td_create_result, :ok) do
        {:error, _reason} = error -> error
        :ok -> create_task(group_id, delegator_agent_id, worker_agent_id, attrs)
      end
    end

    defp create_task(group_id, delegator_agent_id, worker_agent_id, attrs) do
      conversation_id = SalixStore.Ids.new_conversation_id()

      conversation = %{
        "conversation_id" => conversation_id,
        "kind" => "agent_task",
        "title" => attrs["title"],
        "status" => "active",
        "owner_user_id" => attrs["owner_user_id"],
        "metadata" => attrs["conversation_metadata"] || %{},
        "source_refs" => attrs["source_refs"] || %{},
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => delegator_agent_id,
            "role_label" => "delegator"
          },
          %{"actor_type" => "agent", "agent_id" => worker_agent_id, "role_label" => "worker"}
        ]
      }

      conversations =
        Application.get_env(:bridge_for_teams_core, :test_td_conversation_store, %{})

      Application.put_env(
        :bridge_for_teams_core,
        :test_td_conversation_store,
        Map.put(conversations, {group_id, conversation_id}, conversation)
      )

      {:ok, %{"conversation_id" => conversation_id, "inserted" => true}}
    end

    def list_group_conversations(group_id, _opts) do
      conversations =
        Application.get_env(:bridge_for_teams_core, :test_td_conversation_store, %{})

      {:ok,
       conversations
       |> Enum.filter(fn {{stored_group_id, _conversation_id}, _conversation} ->
         stored_group_id == group_id
       end)
       |> Enum.map(&elem(&1, 1))}
    end

    def get_group_conversation(group_id, conversation_id) do
      conversations =
        Application.get_env(:bridge_for_teams_core, :test_td_conversation_store, %{})

      case Map.fetch(conversations, {group_id, conversation_id}) do
        {:ok, conversation} -> {:ok, conversation}
        :error -> {:error, :not_found}
      end
    end

    def update_group_conversation(group_id, conversation_id, attrs) do
      conversations =
        Application.get_env(:bridge_for_teams_core, :test_td_conversation_store, %{})

      case Map.fetch(conversations, {group_id, conversation_id}) do
        {:ok, conversation} ->
          updated = Map.merge(conversation, attrs)

          Application.put_env(
            :bridge_for_teams_core,
            :test_td_conversation_store,
            Map.put(conversations, {group_id, conversation_id}, updated)
          )

          {:ok, updated}

        :error ->
          {:error, :not_found}
      end
    end

    def ensure_group_conversation_provider_participant(_group_id, _conversation_id, attrs),
      do: {:ok, Map.put(attrs, "participant_id", "ptp1_1000000000000000001")}

    def append_group_conversation_message(group_id, conversation_id, attrs) do
      calls = Application.get_env(:bridge_for_teams_core, :test_td_messages, [])

      Application.put_env(:bridge_for_teams_core, :test_td_messages, [
        {group_id, conversation_id, attrs} | calls
      ])

      Application.get_env(
        :bridge_for_teams_core,
        :test_td_append_result,
        {:ok,
         %{
           "conversation_id" => conversation_id,
           "message_id" => SalixStore.Ids.new_message_id(),
           "delivery_status" => "queued",
           "inserted" => true
         }}
      )
    end
  end

  setup do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ScriptedClient)

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_core, :test_td_conversations)
      Application.delete_env(:bridge_for_teams_core, :test_td_task_creates)
      Application.delete_env(:bridge_for_teams_core, :test_td_create_result)
      Application.delete_env(:bridge_for_teams_core, :test_td_router_agent_id)
      Application.delete_env(:bridge_for_teams_core, :test_td_conversation_store)
      Application.delete_env(:bridge_for_teams_core, :test_td_messages)
      Application.delete_env(:bridge_for_teams_core, :test_td_append_result)
    end)

    {:ok, user} = Accounts.create_user(%{"email" => "delegator@example.com", "name" => "Del"})
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-delegation"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Acme", "slug" => "acme"},
        creator_user_id: user.id
      )

    router = project.id |> Agents.list_agents() |> List.first()

    {:ok, worker} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        "name" => "Worker",
        "role" => "worker"
      })

    Application.put_env(
      :bridge_for_teams_core,
      :test_td_router_agent_id,
      router.salix_agent_id
    )

    %{user: user, org: org, project: project, router: router, worker: worker}
  end

  defp task_fixture(user, org, project, attrs \\ %{}) do
    {:ok, [task]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        Map.merge(
          %{
            "title" => "Draft a reply to the founder intro",
            "description" => "Keep it short",
            "category" => "email_drafts",
            "platform" => "gmail",
            "status" => "accepted",
            "source" => "onboarding"
          },
          attrs
        )
      ])

    task
  end

  defp task_creates, do: Application.get_env(:bridge_for_teams_core, :test_td_task_creates, [])
  defp messages, do: Application.get_env(:bridge_for_teams_core, :test_td_messages, [])

  test "dispatch materializes the workspace conversation before sending work", %{
    user: user,
    org: org,
    project: project,
    router: router,
    worker: worker
  } do
    task = task_fixture(user, org, project)
    Application.put_env(:bridge_for_teams_core, :test_td_task_creates, [])
    assert is_nil(task.salix_conversation_id)

    assert {:ok, updated} = TaskDelegation.dispatch(task, actor_user_id: user.id)

    assert updated.status == "in_progress"
    assert SalixStore.Ids.valid_conversation_id?(updated.salix_conversation_id)
    assert updated.salix_agent_id == worker.salix_agent_id
    refute Map.has_key?(updated.payload, "delegation_error")

    assert [{group_id, delegator_id, worker_id, create_attrs}] = task_creates()
    assert group_id == project.salix_group_id
    assert delegator_id == router.salix_agent_id
    assert worker_id == worker.salix_agent_id
    assert create_attrs["client_request_id"] == "workspace-item-conversation:#{task.id}"
    assert create_attrs["workflow"] == nil
    assert create_attrs["conversation_metadata"]["workspace_category"] == "email_drafts"
    assert create_attrs["conversation_metadata"]["platform"] == "gmail"

    prompt = create_attrs["content"]
    assert prompt =~ task.title
    assert prompt =~ "Keep it short"
    assert prompt =~ "email_drafts"
    assert messages() == []
  end

  test "dispatching an artifact-category task embeds the owning user's artifact slug", %{
    user: user,
    org: org,
    project: project
  } do
    task =
      task_fixture(user, org, project, %{
        "title" => "Summarize the launch retro",
        "category" => "general",
        "platform" => "comma"
      })

    assert {:ok, _updated} = TaskDelegation.dispatch(task, actor_user_id: user.id)

    # The prompt's task data names the concrete per-user slug the artifact
    # contract points at — computed from the task title and the owning user.
    assert [{_group, _delegator, _worker, create_attrs}] = task_creates()
    prompt = create_attrs["content"]
    assert prompt =~ ~s("artifact_slug":"#{Artifacts.slug(task.title, user.id)}")
  end

  test "an actor without membership on the item's swarm cannot dispatch", %{
    user: user,
    org: org,
    project: project
  } do
    task = task_fixture(user, org, project)
    {:ok, stranger} = Accounts.create_user(%{"email" => "stranger@example.com", "name" => "S"})

    assert {:error, :not_project_member} =
             TaskDelegation.dispatch(task, actor_user_id: stranger.id)

    assert {:ok, kept} = WorkspaceItems.get_task(user.id, task.id, project_id: project.id)
    assert kept.status == "accepted"
    assert kept.payload["delegation_error"]["reason"] == "not_project_member"

    :ok = Memberships.remove_project_member(project.id, user.id)
    assert {:error, :not_project_member} = TaskDelegation.dispatch(task)

    assert messages() == []
  end

  test "a failed prompt delivery keeps the item accepted with the error noted", %{
    user: user,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :test_td_create_result, {:error, :timeout})
    task = task_fixture(user, org, project)

    task_fixture(user, org, project, %{"title" => "Another workspace task"})

    assert {:error, :timeout} = TaskDelegation.dispatch(task)

    assert {:ok, kept} = WorkspaceItems.get_task(user.id, task.id, project_id: project.id)
    assert kept.status == "accepted"
    assert kept.payload["delegation_error"]["reason"] == "timeout"
  end
end
