defmodule BridgeForTeams.ProjectsQuotaConcurrencyTest do
  @moduledoc """
  Regression test for the member Agent Swarm quota under concurrency: two
  parallel `create_project/3` calls by the same ordinary member must not both
  pass the quota check. The quota serializes on a FOR UPDATE lock of the
  creator's org membership row, which only takes effect across *real* database
  transactions — so this test runs outside the SQL sandbox (`sandbox: false`,
  like release_migration_e2e_test) and cleans up its rows manually.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BridgeForTeams.{Accounts, Memberships, Projects, Repo}

  alias BridgeForTeams.Schema.{
    Agent,
    AuditLog,
    Organization,
    OrgMembership,
    ObservabilityEvent,
    Project,
    ProjectMembership,
    ReconcileOutbox,
    User
  }

  test "concurrent creates by the same member yield exactly one project" do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    org =
      %Organization{}
      |> Organization.changeset(%{
        name: "Quota Race Org #{suffix}",
        slug: "quota-race-org-#{suffix}",
        salix_tenant_id: SalixStore.Ids.new_tenant_id(),
        billing_account_id: "bridge-ba-quota-race-#{suffix}"
      })
      |> Repo.insert!()

    try do
      {:ok, member} = Accounts.create_user(%{email: "quota-race-#{suffix}@example.com"})
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

      parent = self()

      tasks =
        for i <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

            try do
              send(parent, {:ready, self()})

              receive do
                :go -> :ok
              end

              Projects.create_project(
                org.id,
                %{name: "Race #{i}", slug: "race-#{suffix}-#{i}"},
                creator_user_id: member.id
              )
            after
              Ecto.Adapters.SQL.Sandbox.checkin(Repo)
            end
          end)
        end

      # Start both tasks as close to simultaneously as possible.
      for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
      for task <- tasks, do: send(task.pid, :go)

      results = Task.await_many(tasks, 15_000)

      assert Enum.count(results, &match?({:ok, %Project{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :project_quota_reached}, &1)) == 1
      assert [%Project{}] = Projects.list_projects(org.id)
      refute Projects.can_create_project?(org.id, member.id)
    after
      cleanup(org)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end

  # sandbox: false writes are real — remove everything the test (and
  # create_project's transactional side effects) committed, children first.
  defp cleanup(org) do
    project_ids = Repo.all(from(p in Project, where: p.org_id == ^org.id, select: p.id))
    agent_ids = Repo.all(from(a in Agent, where: a.project_id in ^project_ids, select: a.id))

    member_ids =
      Repo.all(from(m in OrgMembership, where: m.org_id == ^org.id, select: m.user_id))

    Repo.delete_all(from(e in ObservabilityEvent, where: e.org_id == ^org.id))
    Repo.delete_all(from(l in AuditLog, where: l.org_id == ^org.id))

    Repo.delete_all(
      from(r in ReconcileOutbox, where: r.aggregate_id in ^(project_ids ++ agent_ids))
    )

    Repo.delete_all(from(m in ProjectMembership, where: m.project_id in ^project_ids))
    Repo.delete_all(from(a in Agent, where: a.project_id in ^project_ids))
    Repo.delete_all(from(p in Project, where: p.org_id == ^org.id))
    Repo.delete_all(from(m in OrgMembership, where: m.org_id == ^org.id))
    Repo.delete_all(from(o in Organization, where: o.id == ^org.id))
    Repo.delete_all(from(u in User, where: u.id in ^member_ids))
  end
end
