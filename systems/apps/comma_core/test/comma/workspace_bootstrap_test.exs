defmodule Comma.WorkspaceBootstrapTest do
  use Comma.DataCase, async: false

  alias Comma.Data.{ExternalOperation, Workspace, WorkspaceMembership}
  alias Comma.WorkspaceBootstrap

  test "bootstrap is idempotent and creates one durable convergence command" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("bootstrap")}@comma.test"})

    assert {:ok, first} = WorkspaceBootstrap.ensure_default(user["id"])
    assert {:ok, second} = WorkspaceBootstrap.ensure_default(user["id"])

    workspace_id = first["workspace"]["id"]
    assert first["status"] == "provisioning"
    assert first["workspace"]["status"] == "provisioning"
    assert second["workspace"]["id"] == workspace_id
    assert Repo.get!(Workspace, workspace_id).vm == %{"enabled" => true}

    assert Repo.aggregate(
             from(workspace in Workspace, where: workspace.owner_user_id == ^user["id"]),
             :count
           ) == 1

    assert Repo.aggregate(
             from(membership in WorkspaceMembership,
               where:
                 membership.workspace_id == ^workspace_id and
                   membership.user_id == ^user["id"] and membership.role == "owner"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(operation in ExternalOperation,
               where:
                 operation.owner_id == ^workspace_id and
                   operation.operation_type == "workspace_convergence"
             ),
             :count
           ) == 1

    operation_id =
      Repo.one!(
        from(operation in ExternalOperation,
          where:
            operation.owner_id == ^workspace_id and
              operation.operation_type == "workspace_convergence",
          select: operation.operation_id
        )
      )

    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "Comma.Workers.WorkspaceConvergence" and
                   fragment("?->>'operation_id'", job.args) == ^operation_id
             )
           )

    assert {:ok, []} = Comma.Workspaces.list_for_user(user["id"])

    assert {:error, :workspace_provisioning} =
             Comma.Workspaces.authorize(user, %{}, workspace_id)
  end

  test "invalid VM input is not treated as the default" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("invalid-vm")}@comma.test"})

    assert {:error, {:bad_request, "vm must be an object"}} =
             Comma.Workspaces.create_for_user(user["id"], %{"vm" => false})
  end

  test "explicit opt-out is preserved and bootstrap never enables existing Workspaces" do
    for vm <- [nil, %{"enabled" => false}] do
      {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("legacy-vm")}@comma.test"})

      {:ok, pending} =
        Comma.Workspaces.create_for_user(user["id"], %{"vm" => %{"enabled" => false}})

      workspace = Repo.get!(Workspace, pending["id"])
      assert workspace.vm == %{"enabled" => false}
      workspace |> Ecto.Changeset.change(vm: vm, status: "active") |> Repo.update!()

      assert {:ok, %{"status" => "ready"}} = WorkspaceBootstrap.ensure_default(user["id"])
      assert Repo.get!(Workspace, workspace.id).vm == vm
    end
  end

  test "bootstrap maps the canonical active state to the public ready contract" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("ready")}@comma.test"})
    assert {:ok, pending} = WorkspaceBootstrap.ensure_default(user["id"])
    workspace_id = pending["workspace"]["id"]

    workspace_id
    |> then(&Repo.get!(Workspace, &1))
    |> Ecto.Changeset.change(status: "active")
    |> Repo.update!()

    assert {:ok, ready} = WorkspaceBootstrap.ensure_default(user["id"])
    assert ready["status"] == "ready"
    assert ready["workspace"]["status"] == "ready"
    assert ready["workspace"]["id"] == workspace_id

    assert {:ok, [%{"id" => ^workspace_id}]} = Comma.Workspaces.list_for_user(user["id"])
    assert {:ok, %{"id" => ^workspace_id}} = Comma.Workspaces.authorize(user, %{}, workspace_id)
  end

  test "bootstrap fails closed when the canonical owner membership is not active owner" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique("membership")}@comma.test"})
    assert {:ok, pending} = WorkspaceBootstrap.ensure_default(user["id"])
    workspace_id = pending["workspace"]["id"]

    workspace_id
    |> then(&Repo.get_by!(WorkspaceMembership, workspace_id: &1, user_id: user["id"]))
    |> Ecto.Changeset.change(role: "member")
    |> Repo.update!()

    assert {:error, :workspace_invariant} = WorkspaceBootstrap.ensure_default(user["id"])
  end

  test "disabled accounts cannot create or recover a default Workspace" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "#{unique("disabled")}@comma.test",
        "status" => "disabled"
      })

    assert {:error, :disabled} = WorkspaceBootstrap.ensure_default(user["id"])
  end

  defp unique(prefix),
    do: prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
