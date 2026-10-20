defmodule SalixStore.CondensedWorkspacesTest do
  use SystemsClock.Case, async: false

  alias SalixStore.CondensedWorkspaces

  @agent %{"kind" => "agent", "agent_id" => "a", "session_id" => "s"}

  setup do
    {:ok, group_id: SalixStore.Ids.new_tenant_id() |> SalixStore.Ids.new_group_id()}
  end

  test "a batch applies atomically; an unknown id changes nothing and returns the list", %{
    group_id: group_id
  } do
    assert {:ok, %{revision: 0, statements: []}} = CondensedWorkspaces.get(group_id)

    assert {:ok, %{revision: 1, statements: [%{"id" => "s1"}, %{"id" => "s2"}]}, []} =
             CondensedWorkspaces.apply_operations(
               group_id,
               [
                 %{"op" => "add", "text" => "Launch is Friday."},
                 %{"op" => "add", "text" => "Ana owns\nthe release."}
               ],
               @agent
             )

    assert {:ok, workspace, []} =
             CondensedWorkspaces.apply_operations(
               group_id,
               [
                 %{"op" => "replace", "id" => "s1", "text" => "Launch is Monday."},
                 %{"op" => "remove", "id" => "s2"},
                 %{"op" => "add", "text" => "Docs are frozen."}
               ],
               @agent
             )

    assert workspace.revision == 2

    assert CondensedWorkspaces.render(workspace.statements) ==
             "- [s1] Launch is Monday.\n- [s3] Docs are frozen."

    assert {:error, {:conflict, ["s2"], %{revision: 2}}} =
             CondensedWorkspaces.apply_operations(
               group_id,
               [
                 %{"op" => "add", "text" => "Not applied."},
                 %{"op" => "replace", "id" => "s2", "text" => "Gone."}
               ],
               @agent
             )

    assert {:ok, %{revision: 2, statements: [_, _]}} = CondensedWorkspaces.get(group_id)
  end
end
