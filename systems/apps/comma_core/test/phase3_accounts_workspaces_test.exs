defmodule Comma.Phase3AccountsWorkspacesTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma"]
  alias Comma.Accounts.AuthSession
  alias Comma.Data.{Workspace, WorkspaceMembership}

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "accounts and workspace authorization use typed PostgreSQL facts" do
    email = "#{unique("user")}@comma.test"
    assert {:ok, user} = Comma.Accounts.create_user(%{"email" => String.upcase(email)})
    assert {:ok, ^user} = Comma.Accounts.get_user_by_email(email)

    assert {:ok, session} =
             Comma.Accounts.create_session(user["id"])

    stored_session =
      Comma.Repo.get_by!(AuthSession, token_hash: :crypto.hash(:sha256, session["token"]))

    refute :token in AuthSession.__schema__(:fields)
    refute inspect(stored_session) =~ session["token"]

    workspace = insert_workspace!(user["id"], vm: %{"enabled" => true, "provider" => "sprites"})
    insert_membership!(workspace.id, user["id"], "owner")

    assert {:ok, [listed]} = Comma.Workspaces.list_for_user(user["id"])
    assert listed["id"] == workspace.id
    assert listed["members"] == [%{"role" => "owner", "user_id" => user["id"]}]
    assert listed["vm"] == %{"enabled" => true, "provider" => "sprites"}
    assert {:ok, authorized} = Comma.Workspaces.authorize(user, session, workspace.id)
    assert authorized["id"] == workspace.id
  end

  test "two independent Repo clients converge email, membership, update, and budget races" do
    {repo_a, repo_b} = start_independent_repos()
    email = "#{unique("race")}@comma.test"

    email_results =
      concurrent(repo_a, repo_b, fn ->
        Comma.Accounts.get_or_create_user_by_email(String.upcase(email))
      end)

    assert Enum.all?(email_results, &match?({:ok, _}, &1))

    assert email_results |> Enum.map(fn {:ok, user} -> user["id"] end) |> Enum.uniq() |> length() ==
             1

    {:ok, user} = hd(email_results)
    on_exit(fn -> Comma.WorkspaceTestSupport.cleanup_committed_user!(repo_a, user["id"]) end)

    workspace = insert_workspace_on!(repo_a, user["id"])

    membership_changeset = fn ->
      WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
        workspace_id: workspace.id,
        user_id: user["id"],
        role: "owner",
        status: "active"
      })
    end

    membership_results =
      concurrent(repo_a, repo_b, fn -> Comma.Repo.insert(membership_changeset.()) end)

    assert Enum.count(membership_results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(membership_results, &match?({:error, _}, &1)) == 1

    update_results =
      concurrent_with_values(repo_a, "Renamed A", repo_b, "Renamed B", fn name ->
        Comma.Workspaces.update(user, %{}, workspace.id, %{"name" => name})
      end)

    assert Enum.all?(update_results, &match?({:ok, _}, &1))

    final_workspace = on_repo(repo_a, fn -> Comma.Repo.get!(Workspace, workspace.id) end)
    assert final_workspace.name in ["Renamed A", "Renamed B"]
    assert final_workspace.lock_version == 3

    {:ok, restricted} =
      on_repo(repo_a, fn ->
        Comma.Accounts.create_session(user["id"],
          restricted: true,
          session_source: "ops_api",
          interaction_budget_remaining: 1
        )
      end)

    budget_results =
      concurrent(repo_a, repo_b, fn ->
        Comma.Accounts.consume_budget(restricted, "same-command")
      end)

    assert Enum.all?(budget_results, &match?({:ok, %{"interaction_budget_remaining" => 0}}, &1))

    stored_session =
      on_repo(repo_a, fn ->
        Comma.Repo.get_by!(
          AuthSession,
          token_hash: :crypto.hash(:sha256, restricted["token"])
        )
      end)

    assert map_size(stored_session.consumed_interaction_ids) == 1

    assert {:error, :budget_exhausted} =
             on_repo(repo_b, fn ->
               Comma.Accounts.consume_budget(restricted, "different-command")
             end)
  end

  defp insert_workspace!(user_id, opts) do
    Comma.Repo.insert!(Workspace.changeset(%Workspace{}, workspace_attrs(user_id, opts)))
  end

  defp insert_workspace_on!(repo, user_id) do
    on_repo(repo, fn ->
      Comma.Repo.insert!(Workspace.changeset(%Workspace{}, workspace_attrs(user_id, [])))
    end)
  end

  defp insert_membership!(workspace_id, user_id, role) do
    Comma.Repo.insert!(
      WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
        workspace_id: workspace_id,
        user_id: user_id,
        role: role,
        status: "active"
      })
    )
  end

  defp workspace_attrs(user_id, opts) do
    id = unique("wsp")

    %{
      id: id,
      owner_user_id: user_id,
      salix_tenant_id: unique("ten"),
      salix_group_id: unique("grp"),
      group_generation: unique("generation"),
      salix_router_agent_id: unique("router"),
      salix_worker_agent_id: unique("worker"),
      billing_owner_id: "comma-ba-#{id}",
      name: "Workspace",
      vm: opts[:vm],
      status: "active"
    }
  end

  defp start_independent_repos do
    opts = [name: nil, pool: DBConnection.ConnectionPool, pool_size: 1]
    {:ok, repo_a} = Comma.Repo.start_link(opts)
    {:ok, repo_b} = Comma.Repo.start_link(opts)
    SystemsRuntime.Proc.unlink(repo_a)
    SystemsRuntime.Proc.unlink(repo_b)

    on_exit(fn ->
      for repo <- [repo_a, repo_b], SystemsRuntime.Proc.alive?(repo), do: Supervisor.stop(repo)
    end)

    {repo_a, repo_b}
  end

  defp concurrent(repo_a, repo_b, fun) do
    concurrent_with_values(repo_a, nil, repo_b, nil, fn _ -> fun.() end)
  end

  defp concurrent_with_values(repo_a, value_a, repo_b, value_b, fun) do
    parent = SystemsRuntime.Proc.self()
    ref = SystemsRuntime.Proc.make_ref()

    tasks =
      for {repo, value} <- [{repo_a, value_a}, {repo_b, value_b}] do
        SystemsRuntime.Task.async(fn ->
          SystemsRuntime.Proc.send(parent, {ref, :ready, SystemsRuntime.Proc.self()})
          SystemsRuntime.Proc.receive(do: ({^ref, :go} -> on_repo(repo, fn -> fun.(value) end)))
        end)
      end

    for task <- tasks, do: settle_receive({^ref, :ready, pid} when pid == task.pid)
    for task <- tasks, do: SystemsRuntime.Proc.send(task.pid, {ref, :go})
    Enum.map(tasks, &settled_await/1)
  end

  defp on_repo(repo, fun) do
    previous = Comma.Repo.get_dynamic_repo()
    Comma.Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Comma.Repo.put_dynamic_repo(previous)
    end
  end

  defp unique(prefix),
    do: prefix <> "_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(9), padding: false)
end
