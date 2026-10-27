defmodule CommaWeb.Coding.MembersTest do
  use ExUnit.Case, async: false

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.Repo
  alias CommaWeb.Coding.Members

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp user(name) do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{name}-#{suffix}@example.com"})
    user
  end

  defp join(workspace, user, role, status \\ "active") do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace["id"],
      user_id: user["id"],
      role: role,
      status: status
    })
    |> Repo.insert!()
  end

  defp status(workspace, status),
    do:
      Repo.get!(Workspace, workspace["id"])
      |> Ecto.Changeset.change(status: status)
      |> Repo.update!()

  test "an active Workspace's members but viewers are its L4ES members, by user id and email" do
    ann = user("ann")
    {:ok, ws} = Comma.Workspaces.create_for_user(ann["id"])
    bo = user("bo")
    join(ws, bo, "member")
    join(ws, user("vi"), "viewer")
    join(ws, user("gone"), "member", "removed")
    group = {ws["salix_tenant_id"], ws["default_group_id"]}
    status(ws, "active")

    assert {:ok, members} = Members.members(elem(group, 0), elem(group, 1))

    assert members == [
             %{subject: ann["id"], email: ann["email"]},
             %{subject: bo["id"], email: bo["email"]}
           ]

    status(ws, "suspended")
    assert Members.members(elem(group, 0), elem(group, 1)) == {:ok, []}
  end
end
