defmodule BridgeForTeams.CommaBftSharedStorageContractTest do
  @moduledoc """
  Executable Comma/BFT convergence contract for one shared Salix bucket.

  The test provisions real product mappings on both sides, writes the shared
  Conversation/Task/Schedule/VFS/OAuth/Plugin primitives, proves product-scope
  negative reads, then restores the complete fake bucket into an empty store.
  """

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    Agents,
    AssistantChats,
    Memberships,
    Orgs,
    Projects,
    Workspace
  }

  alias BridgeForTeams.Conversations, as: BftConversations
  alias Comma.Data.ExternalOperation
  alias Comma.Workers.WorkspaceConvergence
  alias Salix.Control.{OAuthBindings, Plugins}
  alias SalixAgent.AgentWorkspace
  alias SalixCluster.TaskSchedules
  alias SalixIM.Conversations, as: SalixConversations
  alias SalixStore.S3.Fake

  defmodule NoopAgentDelivery do
    @behaviour SalixIM.Ports.AgentDelivery

    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(_agent_id, _payload, _opts), do: {:ok, :created}

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_found}

    @impl true
    def get_session_activity(_agent_id, _session_id), do: {:error, :not_found}

    @impl true
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_found}
  end

  setup do
    comma_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)

    previous = %{
      bft_client: Application.get_env(:bridge_for_teams_core, :salix_client),
      comma_client: Application.get_env(:comma_core, :salix_client),
      delivery: Application.get_env(:salix_im, :agent_delivery_mod),
      s3: Application.get_env(:salix_store, :s3_backend)
    }

    Application.put_env(:salix_store, :s3_backend, Fake)
    Application.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    Application.put_env(:bridge_for_teams_core, :salix_client, BridgeForTeams.Salix.Erpc)
    Application.put_env(:salix_im, :agent_delivery_mod, NoopAgentDelivery)

    SalixAgent.TestSupport.stop_all_agents()
    Fake.reset()

    on_exit(fn ->
      try do
        SalixAgent.TestSupport.stop_all_agents()
        restore_env(:salix_store, :s3_backend, previous.s3)
        restore_env(:comma_core, :salix_client, previous.comma_client)
        restore_env(:bridge_for_teams_core, :salix_client, previous.bft_client)
        restore_env(:salix_im, :agent_delivery_mod, previous.delivery)
        Fake.reset()
      after
        Ecto.Adapters.SQL.Sandbox.stop_owner(comma_owner)
      end
    end)

    :ok
  end

  test "Comma and BFT coexist, remain isolated, and restore from one Salix bucket" do
    suffix = Ecto.UUID.generate()

    {:ok, comma_user} =
      Comma.Accounts.create_user(%{"email" => "comma-shared-#{suffix}@example.com"})

    {:ok, comma_workspace} =
      Comma.Workspaces.create_for_user(comma_user["id"], %{
        "name" => "Comma",
        "vm" => %{"enabled" => false}
      })

    workspace_operation =
      Comma.Repo.get_by!(ExternalOperation,
        operation_type: "workspace_convergence",
        owner_id: comma_workspace["id"]
      )

    assert {:ok, %{status: "succeeded"}} =
             WorkspaceConvergence.run(workspace_operation.operation_id)

    assert {:ok, comma_workspace} = Comma.Workspaces.get(comma_workspace["id"])
    assert :ok = issue_comma_billing_grant(comma_workspace)

    {:ok, bft_user} =
      Accounts.create_user(%{"email" => "bft-shared-#{suffix}@example.com", "name" => "BFT"})

    {:ok, bft_org} = Orgs.create_org(%{name: "Shared Bucket BFT", slug: "shared-bucket-bft"})
    {:ok, _membership} = Memberships.put_org_member(bft_org.id, bft_user.id, "owner")

    {:ok, bft_project} =
      Projects.create_project(
        bft_org.id,
        %{"name" => "Shared Bucket Swarm", "slug" => "shared-bucket-swarm"},
        creator_user_id: bft_user.id
      )

    {:ok, _worker} =
      Agents.create_agent(bft_project.id, %{
        "name" => "Shared Bucket Worker",
        "role" => "worker",
        "slot" => "worker"
      })

    assert :ok = drain_bft_reconciliation()

    bft_agents = Agents.list_agents(bft_project.id)
    bft_router = Enum.find(bft_agents, &(&1.role == "router"))
    bft_worker = Enum.find(bft_agents, &(&1.role == "worker"))

    assert is_binary(bft_router.salix_agent_id)
    assert is_binary(bft_worker.salix_agent_id)
    refute comma_workspace["salix_tenant_id"] == bft_org.salix_tenant_id
    refute comma_workspace["default_group_id"] == bft_project.salix_group_id

    assert {:ok, comma_chat} =
             Comma.AssistantChats.ensure_chat(
               comma_user,
               %{},
               comma_workspace["default_group_id"]
             )

    assert {:ok, %{binding: bft_chat}} =
             AssistantChats.ensure_chat(bft_user.id, bft_org.id, bft_project)

    assert comma_chat["kind"] == "user_chat"

    comma_salix_chat_id = comma_chat["id"]

    assert {:ok, %{"participants" => comma_chat_participants}} =
             SalixConversations.list_group_conversation_participants(
               comma_workspace["default_group_id"],
               comma_salix_chat_id
             )

    assert Enum.any?(comma_chat_participants, fn participant ->
             participant["actor_type"] == "agent" and
               participant["agent_id"] == comma_workspace["router_agent_id"]
           end)

    assert {:ok, %{"kind" => "user_chat"}} =
             BftConversations.get_project_conversation(bft_project, bft_chat.conversation_id)

    assert {:ok, %{"participants" => bft_chat_participants}} =
             SalixConversations.list_group_conversation_participants(
               bft_project.salix_group_id,
               bft_chat.conversation_id
             )

    assert Enum.any?(bft_chat_participants, fn participant ->
             participant["actor_type"] == "agent" and
               participant["agent_id"] == bft_router.salix_agent_id
           end)

    assert {:ok, comma_chat_after_send} =
             Comma.Conversations.send_message(
               comma_user,
               %{},
               comma_workspace["default_group_id"],
               comma_chat["id"],
               %{
                 "client_request_id" => "comma-shared-chat-message",
                 "message" => %{"type" => "text", "text" => "Comma-only chat message"}
               }
             )

    assert Enum.any?(comma_chat_after_send["messages"], fn message ->
             message["content"] == [%{"type" => "text", "text" => "Comma-only chat message"}]
           end)

    assert {:ok, _bft_chat_message} =
             BftConversations.send_project_conversation_message(
               bft_project,
               bft_chat.conversation_id,
               "BFT-only chat message",
               actor_user_id: bft_user.id,
               request_id: "bft-shared-chat-message"
             )

    assert {:ok, comma_task} =
             TaskSchedules.create_task_conversation(
               comma_workspace["default_group_id"],
               comma_workspace["router_agent_id"],
               comma_workspace["default_worker_agent_id"],
               %{
                 "title" => "Comma scheduled task",
                 "content" => "Run the Comma task",
                 "client_request_id" => "comma-shared-task",
                 "schedule" => %{"interval_minutes" => 5}
               }
             )

    assert {:ok, bft_task} =
             TaskSchedules.create_task_conversation(
               bft_project.salix_group_id,
               bft_router.salix_agent_id,
               bft_worker.salix_agent_id,
               %{
                 "title" => "BFT scheduled task",
                 "content" => "Run the BFT task",
                 "client_request_id" => "bft-shared-task",
                 "schedule" => %{"interval_minutes" => 10}
               }
             )

    assert %{"schedule_id" => comma_schedule_id} = comma_task["schedule"]
    assert %{"schedule_id" => bft_schedule_id} = bft_task["schedule"]
    refute comma_schedule_id == bft_schedule_id

    assert {:ok, comma_public} =
             Comma.Conversations.get(
               comma_user,
               %{},
               comma_workspace["default_group_id"],
               comma_task["conversation_id"]
             )

    assert comma_public["kind"] == "agent_task"
    assert comma_public["id"] == comma_task["conversation_id"]

    seed_workspace_file(comma_workspace["router_agent_id"], "/comma.txt", "comma-only")
    seed_workspace_file(bft_router.salix_agent_id, "/bft.txt", "bft-only")

    assert {:ok, "bft-only"} =
             Workspace.read_file(bft_project, "/bft.txt",
               salix_agent_id: bft_router.salix_agent_id
             )

    assert {:error, :agent_not_found} =
             Workspace.read_file(bft_project, "/comma.txt",
               salix_agent_id: comma_workspace["router_agent_id"]
             )

    comma_connection = seed_oauth(comma_workspace["salix_tenant_id"], "comma")
    bft_connection = seed_oauth(bft_org.salix_tenant_id, "bft")

    assert {:ok, comma_binding, nil} =
             OAuthBindings.put(
               comma_workspace["salix_tenant_id"],
               comma_workspace["default_group_id"],
               "github",
               "comma",
               comma_connection
             )

    assert {:ok, bft_binding, nil} =
             OAuthBindings.put(
               bft_org.salix_tenant_id,
               bft_project.salix_group_id,
               "github",
               "bft",
               bft_connection
             )

    assert {:error, :not_found} =
             OAuthBindings.get(bft_project.salix_group_id, comma_binding["binding_id"])

    assert {:error, :not_found} =
             OAuthBindings.get(comma_workspace["default_group_id"], bft_binding["binding_id"])

    assert {:ok, comma_plugin} =
             Plugins.create_definition(
               comma_workspace["salix_tenant_id"],
               comma_workspace["default_group_id"],
               plugin_attrs("Comma private plugin")
             )

    assert {:ok, bft_plugin} =
             Plugins.create_definition(
               bft_org.salix_tenant_id,
               bft_project.salix_group_id,
               plugin_attrs("BFT private plugin")
             )

    assert {:error, :not_found} =
             Plugins.get_definition(
               comma_workspace["salix_tenant_id"],
               comma_workspace["default_group_id"],
               bft_plugin["plugin_id"]
             )

    assert {:error, :not_found} =
             Plugins.get_definition(
               bft_org.salix_tenant_id,
               bft_project.salix_group_id,
               comma_plugin["plugin_id"]
             )

    assert {:error, cross_scope_reason} =
             Comma.Conversations.get(
               comma_user,
               %{},
               comma_workspace["default_group_id"],
               bft_task["conversation_id"]
             )

    assert cross_scope_reason in [:cross_scope, :not_found]

    assert {:error, :not_found} =
             BftConversations.get_project_conversation(bft_project, comma_task["conversation_id"])

    assert {:ok, bft_list} = BftConversations.list_project_conversations(bft_project)
    refute Enum.any?(bft_list, &(&1["conversation_id"] == comma_task["conversation_id"]))

    assert {:ok, comma_list} =
             Comma.Conversations.list(comma_user, %{}, comma_workspace["default_group_id"])

    refute Enum.any?(comma_list, &(&1["id"] == bft_task["conversation_id"]))

    backup = Fake.dump()
    assert map_size(backup) > 0

    SalixAgent.TestSupport.stop_all_agents()
    Fake.reset()
    assert {:error, :not_found} = Salix.Control.Tenants.get(comma_workspace["salix_tenant_id"])
    assert :ok = restore_bucket(backup)

    assert {:ok, _} = Salix.Control.Tenants.get(comma_workspace["salix_tenant_id"])
    assert {:ok, _} = Salix.Control.Tenants.get(bft_org.salix_tenant_id)

    assert {:ok, %{"kind" => "agent_task"}} =
             SalixConversations.get_group_conversation(
               comma_workspace["default_group_id"],
               comma_task["conversation_id"]
             )

    assert {:ok, %{"kind" => "agent_task"}} =
             BftConversations.get_project_conversation(
               bft_project,
               bft_task["conversation_id"]
             )

    assert {:ok, %{"messages" => restored_comma_chat_messages}} =
             SalixConversations.get_group_conversation_with_messages(
               comma_workspace["default_group_id"],
               comma_salix_chat_id
             )

    assert Enum.any?(restored_comma_chat_messages, fn message ->
             message["content"] == [%{"type" => "text", "text" => "Comma-only chat message"}]
           end)

    assert {:ok, %{"messages" => restored_bft_chat_messages}} =
             SalixConversations.get_group_conversation_with_messages(
               bft_project.salix_group_id,
               bft_chat.conversation_id
             )

    assert Enum.any?(restored_bft_chat_messages, fn message ->
             message["content"] == [%{"type" => "text", "text" => "BFT-only chat message"}]
           end)

    assert {:ok, "comma-only"} =
             AgentWorkspace.read(comma_workspace["router_agent_id"], "/comma.txt")

    assert {:ok, "bft-only"} = AgentWorkspace.read(bft_router.salix_agent_id, "/bft.txt")
    assert {:ok, %{"tenant" => comma_tenant}} = SalixStore.OAuth.get(comma_connection)
    assert comma_tenant == comma_workspace["salix_tenant_id"]
    assert {:ok, _} = SalixCluster.Schedules.get(comma_schedule_id)
    assert {:ok, _} = SalixCluster.Schedules.get(bft_schedule_id)
  end

  defp drain_bft_reconciliation, do: drain_bft_reconciliation(10)

  defp drain_bft_reconciliation(0), do: {:error, :reconciliation_not_drained}

  defp drain_bft_reconciliation(rounds_remaining) do
    case BridgeForTeams.Salix.Reconciler.drain_once(limit: 100) do
      {:ok, 0} -> :ok
      {:ok, _count} -> drain_bft_reconciliation(rounds_remaining - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_workspace_file(agent_id, path, body) do
    assert {:ok, event} = AgentWorkspace.prepare_write(agent_id, path, body)

    assert {:ok, _result} =
             AgentWorkspace.seed_operation(
               agent_id,
               "shared-storage:" <> path,
               %{"path" => path},
               [event]
             )
  end

  defp seed_oauth(tenant_id, suffix) do
    connection_id = "shared-oauth-" <> suffix

    assert :ok =
             SalixStore.OAuth.put(connection_id, %{
               "connection_id" => connection_id,
               "tenant" => tenant_id,
               "provider" => "github",
               "access_token" => "secret-" <> suffix,
               "status" => "active"
             })

    connection_id
  end

  defp issue_comma_billing_grant(%{"billing_account_id" => account_id, "id" => workspace_id}) do
    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace_id
      })

    case BillingCore.Credits.issue_grant(%{
           repo: BillingCore.Repo,
           billing_account_id: account_id,
           credits: 100,
           valid_from: ~U[2026-06-17 00:00:00Z],
           expires_at: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second),
           source_type: "shared_storage_contract",
           source_id: "shared-storage:#{workspace_id}",
           source_event_id: "shared-storage:#{workspace_id}",
           idempotency_key: "shared-storage:#{workspace_id}:chat"
         }) do
      {:ok, _grant} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp plugin_attrs(name) do
    %{
      "owner_scope" => "group",
      "name" => name,
      "refs" => %{"tool_refs" => ["help"]}
    }
  end

  defp restore_bucket(backup) do
    Enum.reduce_while(backup, :ok, fn {key, object}, :ok ->
      case Fake.put(key, object.body, meta: object.meta) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {key, reason}}}
      end
    end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
