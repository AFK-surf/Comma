defmodule CommaWeb.TaskExecutionOwnerTest do
  use ExUnit.Case, async: false

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias SalixStore.{CasRecord, Ids, Keys}
  alias CommaWeb.TaskExecutionOwner

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    SalixStore.RepoTestSetup.ensure!()
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()
    old_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      Application.put_env(:salix_store, :s3_backend, old_backend)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(group), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, group_record} =
      CasRecord.update(
        Keys.ctl_group(group),
        &Map.merge(&1, %{"router_agent_id" => router["agent_id"], "ifc" => %{"mode" => "enforce"}})
      )

    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "task-#{System.unique_integer([:positive])}@comma.test"
      })

    workspace =
      Comma.Repo.insert!(
        Workspace.changeset(%Workspace{}, %{
          id: "wsp_task_#{System.unique_integer([:positive])}",
          owner_user_id: user["id"],
          salix_tenant_id: tenant,
          salix_group_id: group,
          group_generation: "test",
          salix_router_agent_id: router["agent_id"],
          salix_worker_agent_id: Ids.new_agent_id(group),
          billing_owner_id: "task-test",
          name: "Task",
          status: "active"
        })
      )

    membership =
      Comma.Repo.insert!(
        WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
          workspace_id: workspace.id,
          user_id: user["id"],
          role: "owner",
          status: "active"
        })
      )

    connect = Ids.new_connect_id()

    {:ok, _} =
      CasRecord.create(Keys.ctl_im_connect(group, connect), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "connect_id" => connect,
        "provider" => "telegram",
        "status" => "connected",
        "bot_token" => "test-token",
        "bot_user_id" => "bot1",
        "managed_by" => "comma_product",
        "managed_peer_id" => "123"
      })

    %{
      group: group,
      tenant: tenant,
      chat: group_record["router_conversation_id"],
      user: user,
      workspace: workspace,
      membership: membership,
      connect: connect,
      principal: "comma_user|" <> user["id"]
    }
  end

  test "first IFC lookup loads the Comma owner adapter and uses current ownership", f do
    :code.purge(TaskExecutionOwner)
    :code.delete(TaskExecutionOwner)
    refute function_exported?(TaskExecutionOwner, :conversation_members, 3)
    atom = "conversation|" <> f.chat

    request = %{
      "tenant_id" => f.tenant,
      "group_id" => f.group,
      "requester" => f.principal,
      "atoms" => [atom],
      "destination" => %{"kind" => "pending_task", "tool_call_id" => "one"}
    }

    assert {:ok, facts} = SalixIM.IFC.Facts.resolve(request)
    assert get_in(facts, ["membership", atom, "members"]) == [f.principal]
    assert TaskExecutionOwner.conversation_members(f.group, "other", f.principal) == nil
    Comma.Repo.delete!(f.membership)
    assert {:error, _} = TaskExecutionOwner.authorize_owner(f.group, f.user["id"])
    assert {:ok, facts} = SalixIM.IFC.Facts.resolve(request)
    refute Map.has_key?(facts["membership"], atom)
  end

  test "only a verified current product Telegram link aliases the owner's private audience", f do
    assert TaskExecutionOwner.direct_members(f.group, f.connect, ["123"], f.principal) == nil
    {:ok, _, claim} = Comma.TelegramLinks.create_claim(f.user, %{}, f.workspace.id)
    {:ok, %{claim: proof}} = Comma.TelegramLinks.take_claim(claim.code)

    assert {:ok, _} =
             Comma.TelegramLinks.put_link(
               f.user["id"],
               f.workspace.id,
               %{"id" => "123"},
               f.connect,
               proof
             )

    assert TaskExecutionOwner.direct_members(f.group, f.connect, ["123"], f.principal) == [
             f.principal
           ]

    assert TaskExecutionOwner.direct_members(f.group, f.connect, ["999"], f.principal) == nil

    assert TaskExecutionOwner.direct_members(f.group, f.connect, ["123", "999"], f.principal) ==
             nil

    assert TaskExecutionOwner.direct_members(f.group, "another-connect", ["123"], f.principal) ==
             nil

    assert TaskExecutionOwner.direct_members(f.group, f.connect, ["123"], "comma_user|stranger") ==
             nil

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_im_connect(f.group, f.connect),
        &Map.put(&1, "managed_peer_id", "999")
      )

    assert TaskExecutionOwner.direct_members(f.group, f.connect, ["123"], f.principal) == nil

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_im_connect(f.group, f.connect),
        &Map.put(&1, "managed_peer_id", "123")
      )

    assert {:ok, _, true} = Comma.TelegramLinks.delete(f.user, %{}, f.workspace.id)
    assert TaskExecutionOwner.direct_members(f.group, f.connect, ["123"], f.principal) == nil
  end
end
