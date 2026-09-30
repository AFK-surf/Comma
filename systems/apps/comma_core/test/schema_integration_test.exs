defmodule Comma.SchemaIntegrationTest do
  use ExUnit.Case, async: false

  alias Comma.Data.{
    ExternalOperation,
    Session,
    User,
    Workspace,
    WorkspaceMembership
  }

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "the additive schema exposes bounded indexes but fails readiness without release marker" do
    refute Comma.Schema.ready?()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(Comma.Repo, """
      SELECT indexname
      FROM pg_indexes
      WHERE schemaname = current_schema()
        AND tablename IN (
          'comma_workspace_memberships',
          'comma_external_operations'
        )
      """)

    indexes = MapSet.new(rows, fn [name] -> name end)

    for required <- [
          "comma_workspace_memberships_user_id_status_workspace_id_index",
          "comma_operation_claim_idx"
        ] do
      assert required in indexes
    end
  end

  test "normalized email and token hash constraints are database-authoritative" do
    id = unique("usr")
    assert {:ok, _} = Comma.Repo.insert(User.changeset(%User{}, user_attrs(id, " Owner@Comma.Test ")))

    assert {:error, changeset} =
             Comma.Repo.insert(User.changeset(%User{}, user_attrs(unique("usr"), "owner@comma.test")))

    assert "has already been taken" in errors_on(changeset).normalized_email

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    hash = :crypto.hash(:sha256, "legacy-bearer")

    assert {:ok, _} =
             Comma.Repo.insert(
               Session.changeset(%Session{}, %{
                 id: unique("ses"),
                 token_hash: hash,
                 user_id: id,
                 expires_at: DateTime.add(now, 3600),
                 status: "active",
                 restricted: false
               })
             )

    assert {:error, duplicate} =
             Comma.Repo.insert(
               Session.changeset(%Session{}, %{
                 id: unique("ses"),
                 token_hash: hash,
                 user_id: id,
                 expires_at: DateTime.add(now, 3600),
                 status: "active",
                 restricted: false
               })
             )

    assert "has already been taken" in errors_on(duplicate).token_hash
    refute :token in Session.__schema__(:fields)
  end

  test "imported Workspace statuses remain valid through the serving schema" do
    user = insert_user!()
    imported = insert_workspace!(user.id)

    assert imported.status == "active"

    serving = Comma.Repo.get!(Workspace, imported.id)

    assert {:ok, renamed} =
             serving
             |> Workspace.changeset(%{
               name: "Renamed imported Workspace",
               status: "active"
             })
             |> Comma.Repo.update()

    assert renamed.name == "Renamed imported Workspace"
    assert renamed.status == "active"

    for status <- ~w(provisioning provisioning_failed active suspended failed deleted) do
      assert Workspace.changeset(imported, %{status: status}).valid?
    end

    refute Workspace.changeset(imported, %{status: "unknown"}).valid?
  end

  test "membership and operation generation are unique" do
    user = insert_user!()
    workspace = insert_workspace!(user.id)

    cases = [
      {
        WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
          workspace_id: workspace.id,
          user_id: user.id,
          role: "owner",
          status: "active"
        }),
        fn ->
          WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
            workspace_id: workspace.id,
            user_id: user.id,
            role: "member",
            status: "active"
          })
        end
      },
      {
        ExternalOperation.changeset(%ExternalOperation{}, operation_attrs("op-a", workspace.id)),
        fn ->
          ExternalOperation.changeset(
            %ExternalOperation{},
            operation_attrs("op-b", workspace.id)
          )
        end
      }
    ]

    for {first, duplicate} <- cases do
      assert {:ok, _} = Comma.Repo.insert(first)
      assert {:error, _changeset} = Comma.Repo.insert(duplicate.())
    end
  end

  test "two independent Repo pools enforce every cross-writer identity invariant" do
    {repo_a, repo_b} = start_independent_repos()

    user =
      insert_on!(
        repo_a,
        User.changeset(%User{}, user_attrs(unique("usr"), "#{unique("email")}@comma.test"))
      )

    workspace = insert_workspace_on!(repo_a, user.id)

    email = "#{unique("race")}@comma.test"

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(
        repo_a,
        "DELETE FROM comma_external_operations WHERE owner_id = $1",
        [workspace.id]
      )

      Ecto.Adapters.SQL.query!(repo_a, "DELETE FROM comma_workspaces WHERE id = $1", [workspace.id])

      Ecto.Adapters.SQL.query!(
        repo_a,
        "DELETE FROM comma_users WHERE id = $1 OR normalized_email = $2",
        [user.id, String.downcase(email)]
      )
    end)

    races = [
      {
        User.changeset(%User{}, user_attrs(unique("usr"), email)),
        User.changeset(%User{}, user_attrs(unique("usr"), String.upcase(email)))
      },
      {
        WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
          workspace_id: workspace.id,
          user_id: user.id,
          role: "owner",
          status: "active"
        }),
        WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
          workspace_id: workspace.id,
          user_id: user.id,
          role: "member",
          status: "active"
        })
      },
      {
        ExternalOperation.changeset(
          %ExternalOperation{},
          operation_attrs(unique("op"), workspace.id)
        ),
        ExternalOperation.changeset(
          %ExternalOperation{},
          operation_attrs(unique("op"), workspace.id)
        )
      }
    ]

    for {left, right} <- races do
      results = concurrent_insert(repo_a, left, repo_b, right)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 1
    end
  end

  defp insert_user! do
    attrs = user_attrs(unique("usr"), "#{unique("email")}@comma.test")
    Comma.Repo.insert!(User.changeset(%User{}, attrs))
  end

  defp insert_workspace!(user_id) do
    id = unique("wsp")

    Comma.Repo.insert!(
      Workspace.changeset(%Workspace{}, %{
        id: id,
        owner_user_id: user_id,
        salix_tenant_id: unique("ten"),
        salix_group_id: unique("grp"),
        group_generation: unique("generation"),
        salix_router_agent_id: unique("agt"),
        salix_worker_agent_id: unique("agt"),
        billing_owner_id: "comma-ba-#{id}",
        status: "active"
      })
    )
  end

  defp insert_workspace_on!(repo, user_id) do
    id = unique("wsp")

    insert_on!(
      repo,
      Workspace.changeset(%Workspace{}, %{
        id: id,
        owner_user_id: user_id,
        salix_tenant_id: unique("ten"),
        salix_group_id: unique("grp"),
        group_generation: unique("generation"),
        salix_router_agent_id: unique("agt"),
        salix_worker_agent_id: unique("agt"),
        billing_owner_id: "comma-ba-#{id}",
        status: "active"
      })
    )
  end

  defp operation_attrs(id, owner_id) do
    %{
      operation_id: id,
      operation_type: "assistant_chat",
      owner_type: "workspace",
      owner_id: owner_id,
      generation: 1,
      status: "pending",
      attempt: 0,
      external_idempotency_key: "#{id}-external"
    }
  end

  defp user_attrs(id, email) do
    %{id: id, normalized_email: email, status: "active", profile: %{}}
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp start_independent_repos do
    opts = [name: nil, pool: DBConnection.ConnectionPool, pool_size: 1]
    {:ok, repo_a} = Comma.Repo.start_link(opts)
    {:ok, repo_b} = Comma.Repo.start_link(opts)
    Process.unlink(repo_a)
    Process.unlink(repo_b)

    on_exit(fn ->
      for repo <- [repo_a, repo_b], Process.alive?(repo) do
        Supervisor.stop(repo)
      end
    end)

    {repo_a, repo_b}
  end

  defp concurrent_insert(repo_a, left, repo_b, right) do
    parent = self()
    ref = make_ref()

    tasks =
      for {repo, changeset} <- [{repo_a, left}, {repo_b, right}] do
        Task.async(fn ->
          send(parent, {ref, :ready, self()})
          receive do: ({^ref, :go} -> insert_on(repo, changeset))
        end)
      end

    for task <- tasks, do: assert_receive({^ref, :ready, task_pid} when task_pid == task.pid)
    for task <- tasks, do: send(task.pid, {ref, :go})
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp insert_on!(repo, changeset) do
    {:ok, row} = insert_on(repo, changeset)
    row
  end

  defp insert_on(repo, changeset) do
    previous = Comma.Repo.get_dynamic_repo()
    Comma.Repo.put_dynamic_repo(repo)

    try do
      Comma.Repo.insert(changeset)
    after
      Comma.Repo.put_dynamic_repo(previous)
    end
  end

  defp unique(prefix) do
    "#{prefix}_#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
  end
end
