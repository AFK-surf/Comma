defmodule BridgeForTeams.Salix.ReconcilerTest do
  # async: false — these tests reset Salix's process-shared S3 fake backend and
  # temporarily override Salix node discovery.
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.Observability
  alias BridgeForTeams.Salix.Reconciler
  alias BridgeForTeams.Schema.{Agent, Organization, Project, ReconcileOutbox}

  setup do
    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      Application.delete_env(:bridge_for_teams_core, :salix_nodes_override)
    end)

    :ok
  end

  defp pending_for(op) do
    Repo.all(from(r in ReconcileOutbox, where: r.op == ^op and r.status == "pending"))
  end

  defp row(op), do: Repo.one(from(r in ReconcileOutbox, where: r.op == ^op))

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp org_fixture do
    suffix = System.unique_integer([:positive])
    tenant_id = SalixStore.Ids.new_tenant_id()

    %Organization{}
    |> Organization.changeset(%{
      name: "Reconcile Org #{suffix}",
      slug: "reconcile-org-#{suffix}",
      salix_tenant_id: tenant_id,
      billing_account_id: "bridge-ba-#{tenant_id}"
    })
    |> Repo.insert!()
  end

  defp project_fixture(%Organization{} = org) do
    suffix = System.unique_integer([:positive])

    %Project{}
    |> Project.changeset(%{
      org_id: org.id,
      name: "Reconcile Project #{suffix}",
      slug: "reconcile-project-#{suffix}",
      salix_group_id: SalixStore.Ids.new_group_id(org.salix_tenant_id)
    })
    |> Repo.insert!()
  end

  defp agent_fixture(%Project{} = project) do
    suffix = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{
      project_id: project.id,
      role: "worker",
      name: "Reconcile Agent #{suffix}",
      salix_agent_id: SalixStore.Ids.new_agent_id(project.salix_group_id)
    })
    |> Repo.insert!()
  end

  defp seed_tenant_group_agent(agent_id, tenant_id, group_id, role) do
    assert {:ok, _} = Salix.Control.Tenants.create_preallocated(%{}, tenant_id)
    assert {:ok, _} = Salix.Control.Groups.create_preallocated(%{}, tenant_id, group_id)

    assert {:ok, _} =
             SalixAgent.Control.create_preallocated(
               %{"group_id" => group_id, "role" => role},
               tenant_id,
               agent_id
             )
  end

  test "archival cleanup retries release failures even when the group is gone" do
    org = org_fixture()
    project = project_fixture(org)
    connect_id = SalixStore.Ids.new_connect_id()
    app_id = "archived-feishu"
    key = SalixStore.Keys.ctl_im_connect(project.salix_group_id, connect_id)
    identity_key = SalixStore.Keys.ctl_im_provider_identity("feishu", app_id)

    assert {:ok, _} =
             SalixStore.CasRecord.create(key, %{
               "tenant_id" => org.salix_tenant_id,
               "group_id" => project.salix_group_id,
               "connect_id" => connect_id,
               "provider" => "feishu",
               "app_id" => app_id,
               "disabled_at" => 1
             })

    assert :ok =
             SalixIM.ProviderIdentity.reserve_provider(
               "feishu",
               app_id,
               org.salix_tenant_id,
               project.salix_group_id,
               connect_id
             )

    assert {:ok, _} = BridgeForTeams.Projects.archive_project(project)
    SalixStore.S3.Fake.set_fault({:fail, 503, :delete, identity_key})
    assert {:ok, 0} = Reconciler.drain_once()
    assert row("delete_group_im_connects").status == "pending"
    assert {:ok, %{"deleted_at" => deleted_at}} = SalixStore.CasRecord.get(key)
    assert is_integer(deleted_at)

    assert {:ok, 1} = Reconciler.drain_once()
    assert row("delete_group_im_connects").status == "done"
    assert {:error, :not_found} = SalixStore.CasRecord.get(identity_key)
    assert :ok = SalixIM.ProviderIdentity.ensure_available("feishu", app_id)
  end

  test "enqueue inserts a pending outbox row" do
    assert {:ok, row} =
             Reconciler.enqueue("project", "proj_1", "create_tenant", %{
               "attrs" => %{"id" => "proj_1"}
             })

    assert row.status == "pending"
    assert row.attempts == 0
    assert row.op == "create_tenant"
  end

  test "drains create_tenant + create_group, marks done, applies via the client" do
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)

    {:ok, _} =
      Reconciler.enqueue("project", tenant_id, "create_tenant", %{
        "attrs" => %{"tenant_id" => tenant_id, "name" => "Tenant"}
      })

    {:ok, _} =
      Reconciler.enqueue("project", group_id, "create_group", %{
        "attrs" => %{"group_id" => group_id, "tenant_id" => tenant_id, "name" => "Group"}
      })

    assert {:ok, 2} = Reconciler.drain_once()

    assert row("create_tenant").status == "done"
    assert row("create_tenant").processed_at != nil
    assert row("create_group").status == "done"

    assert {:ok, %{"tenant_id" => ^tenant_id, "name" => "Tenant"}} =
             Salix.Control.Tenants.get(tenant_id)

    assert {:ok, %{"group_id" => ^group_id, "tenant_id" => ^tenant_id, "name" => "Group"}} =
             Salix.Control.Groups.get(group_id)
  end

  test "create_agent with vm.enabled degrades to VM-less when no provider is configured" do
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    {:ok, _} = Salix.Control.Tenants.create_preallocated(%{}, tenant_id)
    {:ok, _} = Salix.Control.Groups.create_preallocated(%{}, tenant_id, group_id)

    {:ok, _} =
      Reconciler.enqueue("agent", agent_id, "create_agent", %{
        "attrs" => %{
          "agent_id" => agent_id,
          "group_id" => group_id,
          "tenant_id" => tenant_id,
          "role" => "router",
          "vm" => %{"enabled" => true}
        }
      })

    # The tenant has no VM provider (and no platform default), yet the row
    # drains clean — the router provisions without a VM instead of stranding.
    assert {:ok, 1} = Reconciler.drain_once()
    assert row("create_agent").status == "done"

    assert {:ok, agent} = SalixAgent.Control.get(agent_id)
    refute get_in(agent, ["vm", "enabled"]) == true
  end

  test "drains update_group, sets the group's router agent" do
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    agent_id = SalixStore.Ids.new_agent_id(group_id)
    seed_tenant_group_agent(agent_id, tenant_id, group_id, "router")

    {:ok, _} =
      Reconciler.enqueue("project", group_id, "update_group", %{
        "group_id" => group_id,
        "tenant_id" => tenant_id,
        "attrs" => %{
          "router_agent_id" => agent_id,
          "billing_owner" => %{
            "billing_account_id" => "ba_bridge",
            "salix_group_id" => group_id,
            "salix_tenant_id" => tenant_id,
            "router_agent_id" => agent_id
          }
        }
      })

    assert {:ok, 1} = Reconciler.drain_once()
    assert row("update_group").status == "done"

    assert {:ok,
            %{
              "router_agent_id" => ^agent_id,
              "billing_owner" => %{"billing_account_id" => "ba_bridge"}
            }} = Salix.Control.Groups.get(group_id)
  end

  test "drains update_group, applies the swarm owner email list to the group" do
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)

    assert {:ok, _} = Salix.Control.Tenants.create_preallocated(%{}, tenant_id)
    assert {:ok, _} = Salix.Control.Groups.create_preallocated(%{}, tenant_id, group_id)

    {:ok, _} =
      Reconciler.enqueue("project", group_id, "update_group", %{
        "group_id" => group_id,
        "tenant_id" => tenant_id,
        "attrs" => %{"owner_emails" => ["owner-a@example.com", "owner-b@example.com"]}
      })

    assert {:ok, 1} = Reconciler.drain_once()
    assert row("update_group").status == "done"

    assert {:ok, %{"owner_emails" => ["owner-a@example.com", "owner-b@example.com"]}} =
             Salix.Control.Groups.get(group_id)
  end

  test "transient error (:unavailable) keeps the row pending and bumps attempts" do
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [])
    tenant_id = SalixStore.Ids.new_tenant_id()

    {:ok, _} =
      Reconciler.enqueue("project", tenant_id, "create_tenant", %{
        "attrs" => %{"tenant_id" => tenant_id}
      })

    # transient rows are not counted as advanced
    assert {:ok, 0} = Reconciler.drain_once()

    r = row("create_tenant")
    assert r.status == "pending"
    assert r.attempts == 1
    assert r.last_error =~ "transient"
    assert r.processed_at == nil

    # a second drain retries it
    assert {:ok, 0} = Reconciler.drain_once()
    assert row("create_tenant").attempts == 2

    # once salix recovers it drains clean
    Application.delete_env(:bridge_for_teams_core, :salix_nodes_override)
    assert {:ok, 1} = Reconciler.drain_once()
    assert row("create_tenant").status == "done"
  end

  test "non-transient error marks the row failed" do
    {:ok, _} =
      Reconciler.enqueue("project", "missing_group", "update_group", %{
        "group_id" => "missing_group",
        "tenant_id" => "missing_tenant",
        "attrs" => %{"name" => "Nope"}
      })

    assert {:ok, 1} = Reconciler.drain_once()
    r = row("update_group")
    assert r.status == "failed"
    assert r.attempts == 1
    assert r.last_error =~ "not_found"
  end

  test "unknown op marks the row failed" do
    {:ok, _} = Reconciler.enqueue("weird", "x", "do_a_barrel_roll", %{})

    assert {:ok, 1} = Reconciler.drain_once()
    assert row("do_a_barrel_roll").status == "failed"
    assert row("do_a_barrel_roll").last_error =~ "unknown op"
  end

  test "failed organization reconcile rows emit org-scoped observability events without payload" do
    org = org_fixture()

    {:ok, _} =
      Reconciler.enqueue("organization", org.id, "do_a_barrel_roll", %{
        "attrs" => %{
          "client_secret" => "super-secret",
          "prompt" => "secret prompt"
        }
      })

    assert {:ok, 1} = Reconciler.drain_once()
    failed = row("do_a_barrel_roll")
    assert failed.status == "failed"

    assert [event] = Observability.list_events(org.id, source: "salix.control")
    assert event.domain == "org"
    assert event.event_type == "salix.reconcile.failed"
    assert event.resource_type == "salix_tenant"
    assert event.resource_id == org.salix_tenant_id
    assert event.status == "failed"
    assert event.reason_class == "unknown_op"
    assert event.correlation_id == "reconcile:#{failed.id}"
    assert event.evidence["aggregate"] == "organization"
    assert event.evidence["aggregate_id"] == org.id
    assert event.evidence["op"] == "do_a_barrel_roll"
    assert event.evidence["attempts"] == "1"
    assert event.evidence["reconcile_outbox_id"] == failed.id
    refute inspect(event) =~ "super-secret"
    refute inspect(event) =~ "secret prompt"
  end

  test "failed project and agent reconcile rows emit scoped observability events" do
    org = org_fixture()
    project = project_fixture(org)
    agent = agent_fixture(project)

    {:ok, _} = Reconciler.enqueue("project", project.id, "project_unknown_op", %{})
    {:ok, _} = Reconciler.enqueue("agent", agent.id, "agent_unknown_op", %{})

    assert {:ok, 2} = Reconciler.drain_once()

    events = Observability.list_events(org.id, source: "salix.control")
    project_event = Enum.find(events, &(&1.domain == "project"))
    agent_event = Enum.find(events, &(&1.domain == "agent"))

    assert project_event.project_id == project.id
    assert project_event.resource_type == "salix_group"
    assert project_event.resource_id == project.salix_group_id
    assert project_event.evidence["aggregate"] == "project"
    assert project_event.evidence["aggregate_id"] == project.id
    assert project_event.evidence["op"] == "project_unknown_op"

    assert agent_event.project_id == project.id
    assert agent_event.resource_type == "salix_agent"
    assert agent_event.resource_id == agent.salix_agent_id
    assert agent_event.evidence["aggregate"] == "agent"
    assert agent_event.evidence["aggregate_id"] == agent.id
    assert agent_event.evidence["op"] == "agent_unknown_op"
  end

  test "done rows are not re-drained (idempotent at the outbox level)" do
    tenant_id = SalixStore.Ids.new_tenant_id()

    {:ok, _} =
      Reconciler.enqueue("project", tenant_id, "create_tenant", %{
        "attrs" => %{"tenant_id" => tenant_id}
      })

    assert {:ok, 1} = Reconciler.drain_once()
    assert pending_for("create_tenant") == []

    # second drain finds nothing pending
    assert {:ok, 0} = Reconciler.drain_once()
    assert row("create_tenant").attempts == 1
  end

  test "limit caps rows processed per drain" do
    for i <- 1..5 do
      id = SalixStore.Ids.new_tenant_id()

      {:ok, _} =
        Reconciler.enqueue("project", "p#{i}", "create_tenant", %{
          "attrs" => %{"tenant_id" => id}
        })
    end

    assert {:ok, 2} = Reconciler.drain_once(limit: 2)
    assert length(pending_for("create_tenant")) == 3
  end

  test "accepts atom-keyed payloads (pre-DB-round-trip)" do
    tenant_id = SalixStore.Ids.new_tenant_id()

    {:ok, _} =
      Reconciler.enqueue("project", tenant_id, "create_tenant", %{
        attrs: %{"tenant_id" => tenant_id}
      })

    # NOTE: payload is stored as JSONB so it comes back string-keyed; the row
    # read by the drainer has "attrs" — this asserts the round-trip path works.
    assert {:ok, 1} = Reconciler.drain_once()
    assert {:ok, %{"tenant_id" => ^tenant_id}} = Salix.Control.Tenants.get(tenant_id)
  end

  # `last_error` is varchar(255); an unclamped inspect/1 of a large reason used
  # to abort the whole drain transaction (Postgres 22001) and wedge the queue.
  defmodule GiantHardErrorClient do
    def create_tenant(_attrs), do: {:error, {:boom, String.duplicate("x", 1_000)}}
  end

  defmodule GiantTransientErrorClient do
    def create_tenant(_attrs), do: {:error, {:transient, String.duplicate("y", 1_000)}}
  end

  test "clamps an oversized hard-failure reason instead of aborting the drain" do
    org = org_fixture()
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, GiantHardErrorClient)
    on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev) end)

    {:ok, _} = Reconciler.enqueue("organization", org.id, "create_tenant", %{"attrs" => %{}})

    assert {:ok, 1} = Reconciler.drain_once()

    failed = row("create_tenant")
    assert failed.status == "failed"
    assert failed.attempts == 1
    assert String.length(failed.last_error) <= 255
    assert failed.last_error =~ ":boom"
  end

  test "clamps an oversized transient reason and leaves the row pending" do
    org = org_fixture()
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, GiantTransientErrorClient)
    on_exit(fn -> restore_env(:bridge_for_teams_core, :salix_client, prev) end)

    {:ok, _} = Reconciler.enqueue("organization", org.id, "create_tenant", %{"attrs" => %{}})

    assert {:ok, 0} = Reconciler.drain_once()

    deferred = row("create_tenant")
    assert deferred.status == "pending"
    assert deferred.attempts == 1
    assert String.length(deferred.last_error) <= 255
    assert deferred.last_error =~ "transient:"
  end
end
