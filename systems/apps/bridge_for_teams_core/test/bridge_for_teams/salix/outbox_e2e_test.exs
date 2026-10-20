defmodule BridgeForTeams.Salix.OutboxE2ETest do
  @moduledoc """
  End-to-end coverage of the BridgeForTeams → Salix reconcile outbox: a real
  domain mutation (via the contexts) enqueues outbox row(s), draining them with
  `Reconciler.drain_once/0` invokes the real Salix erpc boundary with arguments
  derived from the actual domain data, writes Salix control-plane records, and
  the rows end up `done`.

  This closes the loop the unit suites only cover in halves — context tests
  assert rows are *enqueued*; the reconciler test drives *synthetic* payloads.
  Here we verify the full chain with live records.

  async: false — these tests reset Salix's process-shared S3 fake backend and
  temporarily override Salix node discovery.
  """
  use BridgeForTeams.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.BridgeForTeams"]

  alias BridgeForTeams.{Agents, Environments, Orgs, ProjectIMConnects, Projects, Repo}
  alias BridgeForTeams.Salix.{Reconciler, TenantConfigChecker}
  alias BridgeForTeams.Schema.{ProjectDeviceProjection, ReconcileOutbox}

  setup do
    SalixStore.S3.Fake.reset()
    prev_salix_vm = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_vm)

    on_exit(fn ->
      SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_nodes_override)
      restore_env(:bridge_for_teams_core, :salix_vm, prev_salix_vm)
    end)

    :ok
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp drain_all do
    # Drain repeatedly until quiescent (each call claims one batch).
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp statuses do
    Repo.all(ReconcileOutbox) |> Enum.map(& &1.status) |> Enum.uniq()
  end

  test "authority transfer drains old obligations and fences delayed configuration" do
    {:ok, org} = Orgs.create_org(%{"name" => "Authority", "slug" => "authority"})

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Authority", "slug" => "authority"})

    {:ok, agent} =
      BridgeForTeams.TestSupport.LegacyWorker.create(project.id, %{
        "name" => "Before",
        "role" => "worker"
      })

    # Representative pre-rollout row and immutable legacy outbox command.
    Repo.update!(
      Ecto.Changeset.change(Repo.get!(BridgeForTeams.Schema.Agent, agent.id),
        configuration_authority: "legacy"
      )
    )

    {:ok, legacy_id} = Ecto.UUID.dump(agent.id)
    Repo.query!("UPDATE agents SET name = 'Before' WHERE id = $1", [legacy_id])

    # The dashboard writes no Worker, whoever holds its configuration.
    assert {:error, :workers_retired} =
             Agents.update_agent(agent, %{"name" => "Blocked legacy write"})

    Repo.update_all(from(r in ReconcileOutbox, where: r.aggregate_id == ^agent.id),
      set: [op: "create_agent"]
    )

    assert {:error, :drain_agent_configuration_outbox} = Agents.transfer_configuration(agent.id)
    drain_all()
    # Older product Groups may predate the billing-owner metadata. Absence is
    # not permission for a second writer; the explicit transfer fills the scope.
    group_key = SalixStore.Keys.ctl_group(project.salix_group_id)
    {:ok, %{body: body, etag: etag}} = SalixStore.S3.get(group_key)
    group = body |> Jason.decode!() |> Map.delete("billing_owner")
    {:ok, _} = SalixStore.S3.put(group_key, Jason.encode!(group), if_match: etag)

    assert {:error, :agent_configuration_transfer_required} =
             SalixAgent.Control.configure(
               agent.salix_agent_id,
               %{"name" => "Premature"},
               org.salix_tenant_id
             )

    assert {:ok, transferred} = Agents.transfer_configuration(agent.id)
    assert transferred.configuration_authority == "salix"
    assert {:ok, _} = Agents.transfer_configuration(agent.id)

    count = Repo.aggregate(ReconcileOutbox, :count)

    assert {:ok, _configured} =
             SalixAgent.Control.configure(
               agent.salix_agent_id,
               %{"name" => "Canonical", "system_prompt" => "Current instructions"},
               org.salix_tenant_id
             )

    assert {:ok, %{"name" => "Canonical"}} = SalixAgent.Control.get(agent.salix_agent_id)
    assert Repo.get!(BridgeForTeams.Schema.Agent, agent.id).salix == %{}
    assert Repo.aggregate(ReconcileOutbox, :count) == count
    assert Repo.query!("SELECT name FROM agents WHERE id = $1", [legacy_id]).rows == [["Before"]]
    assert is_nil(Repo.get!(BridgeForTeams.Schema.Agent, agent.id).salix["name"])
    assert {:ok, %{salix: %{"name" => "Canonical"}}} = Agents.get_agent(agent.id)

    assert {:error, :configuration_authority_transferred} =
             SalixAgent.Control.update(
               agent.salix_agent_id,
               %{"system_prompt" => "Stale instructions"},
               org.salix_tenant_id
             )

    assert {:ok, %{"name" => "Canonical", "system_prompt" => "Current instructions"}} =
             SalixAgent.Control.get(agent.salix_agent_id)
  end

  test "BFT audits its own writes while Router commands stay inside Salix" do
    {:ok, org} = Orgs.create_org(%{"name" => "Audit boundary", "slug" => "audit-boundary"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Audit", "slug" => "audit"})

    {:ok, agent} =
      BridgeForTeams.TestSupport.LegacyWorker.create(project.id, %{
        "name" => "Worker",
        "role" => "worker"
      })

    drain_all()
    {:ok, router} = Agents.current_router(project)
    {:ok, record} = SalixAgent.Control.get(router.salix_agent_id)

    ctx = %{
      agent_id: router.salix_agent_id,
      session_id: record["router_session_id"],
      tool_call_id: "rename"
    }

    count = Repo.aggregate(BridgeForTeams.Schema.AuditLog, :count)

    assert {:ok, _} =
             SalixAgent.AgentManagement.run(
               :update,
               %{"agent_id" => agent.salix_agent_id, "name" => "Router change"},
               ctx
             )

    assert Repo.aggregate(BridgeForTeams.Schema.AuditLog, :count) == count

    assert {:ok, _} =
             Agents.update_agent(router, %{"name" => "Product change"},
               actor_label: "owner@example.test"
             )

    assert [audit] =
             BridgeForTeams.Observability.list_audit_logs(org.id,
               action: "agent.config_updated",
               result: "ok"
             )

    assert audit.actor_label == "owner@example.test"
    assert audit.resource_id == router.id
    assert audit.redacted_diff["name"]["to"] == "Product change"
  end

  test "Router metadata converges through the Salix owner, the dashboard writes no Worker, and archive is permanent" do
    SalixAgent.TestSupport.configure_platform_models!()
    {:ok, org} = Orgs.create_org(%{"name" => "Management", "slug" => "management"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Managed", "slug" => "managed"})
    drain_all()
    router = Repo.get_by!(BridgeForTeams.Schema.Agent, project_id: project.id, role: "router")
    {:ok, router_record} = SalixAgent.Control.get(router.salix_agent_id)

    ctx = %{
      agent_id: router.salix_agent_id,
      session_id: router_record["router_session_id"],
      tool_call_id: "create-reviewer"
    }

    input = %{
      "name" => "Reviewer",
      "purpose" => "Initial",
      "creation_reason" => "This test needs an independent Worker",
      "runtime" => %{"kind" => "internal"}
    }

    assert {:ok, created} = SalixAgent.AgentManagement.run(:create, input, ctx)
    assert created["result"] == "applied"
    assert created["agent"]["name"] == "Reviewer"
    id = created["agent"]["agent_id"]
    refute Repo.get_by(BridgeForTeams.Schema.Agent, salix_agent_id: id)
    assert {:ok, product_agent} = Agents.get_project_agent(project.id, id)
    assert product_agent.project_id == project.id
    # A Worker that a Router creates follows the platform Worker model.
    refute product_agent.salix["model"]

    assert {:ok, replayed} = SalixAgent.AgentManagement.run(:create, input, ctx)
    assert replayed["replayed"]
    assert replayed["agent"]["agent_id"] == id
    drain_all()

    assert {:ok, %{"agent" => detail}} =
             SalixAgent.AgentManagement.run(:get, %{"agent_id" => id}, ctx)

    assert detail["model"]["source"] == "platform_default"

    assert {:ok, accepted} =
             SalixAgent.AgentManagement.run(:update, %{"agent_id" => id, "name" => "A"}, %{
               ctx
               | tool_call_id: "rename-A"
             })

    assert accepted["result"] == "applied"
    # The dashboard writes no Worker: the Router's change stands.
    assert {:error, :workers_retired} =
             Agents.update_agent(product_agent, %{"name" => "B", "purpose" => "Backend"})

    assert {:ok, after_b} = SalixAgent.Control.get(id)
    assert after_b["name"] == "A"

    drain_all()
    assert {:ok, ^after_b} = SalixAgent.Control.get(id)

    assert {:ok, archive} =
             SalixAgent.AgentManagement.run(
               :archive,
               %{"agent_id" => id, "user_confirmed" => true},
               ctx
             )

    assert archive["agent"]["lifecycle"] == "archived"

    assert {:error, :workers_retired} =
             Agents.update_agent(product_agent, %{"name" => "stale writer"})

    drain_all()

    assert {:ok, %{"agent" => archived}} =
             SalixAgent.AgentManagement.run(:get, %{"agent_id" => id}, ctx)

    assert archived["permanent"]

    assert {:ok, %{"agent" => archived}} =
             SalixAgent.AgentManagement.run(:get, %{"agent_id" => id}, ctx)

    assert archived["lifecycle"] == "archived"

    assert {:error, :agent_permanently_archived} =
             SalixAgent.Control.unarchive(id, org.salix_tenant_id)
  end

  test "a Router creates and moves a station-bound BFT Worker without provisioning resources" do
    {:ok, org} =
      Orgs.create_org(%{"name" => "Compute Management", "slug" => "compute-management"})

    {:ok, project} = Projects.create_project(org.id, %{"name" => "Compute", "slug" => "compute"})
    drain_all()
    router = Repo.get_by!(BridgeForTeams.Schema.Agent, project_id: project.id, role: "router")
    {:ok, record} = SalixAgent.Control.get(router.salix_agent_id)

    ctx =
      %{
        agent_id: record["agent_id"],
        session_id: record["router_session_id"],
        role: "router",
        runtime_kind: :internal
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("router", :internal, ctx)
      )

    counts = compute_counts()

    create_args = %{
      "name" => "Station reviewer",
      "purpose" => "Execute the test responsibility",
      "creation_reason" => "This test needs an independent Worker",
      "runtime" => %{"kind" => "station", "device_id" => "dev-laptop"},
      "model" => %{"kind" => "runtime", "provider" => "codex"}
    }

    created = management_tool!("agent.create_worker", create_args, ctx, "create-station")
    assert created["result"] == "applied"
    id = created["agent"]["agent_id"]
    drain_all()
    detail = management_tool!("agent.get", %{"agent_id" => id}, ctx, "get-created")["agent"]

    assert detail["runtime"] == %{
             "kind" => "station",
             "runs_on" => %{"kind" => "station", "device_id" => "dev-laptop"},
             "provider" => "codex"
           }

    assert management_tool!("agent.create_worker", create_args, ctx, "create-station")["agent"][
             "agent_id"
           ] == id

    rebind_args = %{
      "agent_id" => id,
      "target" => %{"kind" => "cloud_vm"},
      "expected_binding_revision" => detail["binding_revision"]
    }

    rebound = management_tool!("agent.rebind_runtime", rebind_args, ctx, "rebind-station")
    assert rebound["result"] == "applied"
    drain_all()
    detail = management_tool!("agent.get", %{"agent_id" => id}, ctx, "get-rebound")["agent"]
    assert detail["runtime"]["runs_on"] == %{"kind" => "cloud_vm"}

    [conflict] =
      SalixAgent.Tools.execute(
        [
          %{
            "id" => "stale-decision",
            "name" => "agent.rebind_runtime",
            "args" => %{
              rebind_args
              | "target" => %{"kind" => "station", "device_id" => "dev-desk"}
            }
          }
        ],
        ctx
      )

    assert conflict.error
    assert conflict.content =~ "binding_conflict"
    assert compute_counts() == counts
  end

  defp compute_counts do
    for schema <- [
          SalixStore.Compute.Environment,
          SalixStore.Compute.Allocation,
          SalixStore.Compute.Workload
        ],
        do: SalixStore.Repo.aggregate(schema, :count)
  end

  defp management_tool!(name, args, ctx, id) do
    [result] = SalixAgent.Tools.execute([%{"id" => id, "name" => name, "args" => args}], ctx)
    refute result.error, inspect(result)
    Jason.decode!(result.content)
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  test "org creation reconciles a Salix tenant and its conversation link config" do
    vm_config = %{
      "default_provider" => "cloudflare",
      "providers" => %{
        "cloudflare" => %{
          "enabled" => true,
          "gateway_base_url" => "https://salix-vm-gateway-staging.example.workers.dev",
          "gateway_secret" => "gateway-secret"
        }
      }
    }

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_vm, vm_config)

    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})

    assert {:ok, 2} = Reconciler.drain_once()

    assert {:ok, %{"tenant_id" => tenant_id, "name" => "Acme"}} =
             Salix.Control.Tenants.get(org.salix_tenant_id)

    assert SalixStore.Ids.valid_tenant_id?(tenant_id)

    base_url =
      :bridge_for_teams_web
      |> SystemsRuntime.fetch_env!(:public_base_url)
      |> String.trim_trailing("/")

    assert {:ok, %{"conversation_url_template" => template}} =
             Salix.Control.Tenants.get_config(org.salix_tenant_id, "conversation_links", %{})

    assert template ==
             base_url <>
               "/tasks/{tenant_id}/{group_id}/{conversation_id}"

    assert {:ok, %{}} = Salix.Control.Tenants.get_config(org.salix_tenant_id, "vm", %{})

    assert statuses() == ["done"]
  end

  test "tenant config checker asynchronously repairs an existing tenant template" do
    vm_config = %{
      "default_provider" => "cloudflare",
      "providers" => %{
        "cloudflare" => %{
          "enabled" => true,
          "gateway_base_url" => "https://salix-vm-gateway-staging.example.workers.dev",
          "gateway_secret" => "gateway-secret"
        }
      }
    }

    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_vm, vm_config)

    {:ok, org} = Orgs.create_org(%{"name" => "Checker", "slug" => "checker"})

    assert {:ok, 1} = Reconciler.drain_once(limit: 1)

    assert {:ok, %{}} =
             Salix.Control.Tenants.get_config(org.salix_tenant_id, "conversation_links", %{})

    assert {:ok, %{}} = Salix.Control.Tenants.get_config(org.salix_tenant_id, "vm", %{})

    start_supervised!(
      {TenantConfigChecker,
       enabled: true, initial_delay_ms: 1, interval_ms: 60_000, retry_interval_ms: 20}
    )

    template =
      eventually(fn ->
        case Salix.Control.Tenants.get_config(org.salix_tenant_id, "conversation_links", %{}) do
          {:ok, %{"conversation_url_template" => value}} when is_binary(value) and value != "" ->
            value

          _other ->
            nil
        end
      end)

    base_url =
      :bridge_for_teams_web
      |> SystemsRuntime.fetch_env!(:public_base_url)
      |> String.trim_trailing("/")

    assert template ==
             base_url <>
               "/tasks/{tenant_id}/{group_id}/{conversation_id}"

    assert {:ok, %{}} = Salix.Control.Tenants.get_config(org.salix_tenant_id, "vm", %{})

    assert %{status: "ok"} = TenantConfigChecker.status()
  end

  test "project creation reconciles a Salix group with its default router" do
    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Billing", "slug" => "billing"})
    assert Agents.list_agents(project.id) == []

    association =
      Repo.get_by!(BridgeForTeams.Schema.Agent, project_id: project.id, role: "router")

    assert {:ok, %{provisioning: "provisioning"}} = Agents.get_agent(association.id)

    drain_all()
    [router] = Agents.list_agents(project.id)

    assert {:ok,
            %{
              "group_id" => group_id,
              "tenant_id" => tenant_id,
              "name" => "Billing",
              "router_agent_id" => router_agent_id
            }} =
             Salix.Control.Groups.get(project.salix_group_id)

    assert group_id == project.salix_group_id
    assert SalixStore.Ids.valid_group_id_for_tenant?(group_id, tenant_id)
    assert tenant_id == org.salix_tenant_id
    assert router_agent_id == router.salix_agent_id

    assert {:ok, attrs} =
             SalixAgent.Control.get(router.salix_agent_id, org.salix_tenant_id)

    assert attrs["role"] == "router"
    assert attrs["group_id"] == project.salix_group_id
    assert statuses() == ["done"]
  end

  test "project Slack connect creates and deletes a group-scoped Salix connect" do
    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Billing", "slug" => "billing"})

    # The Salix group must exist before the connect can be created.
    drain_all()

    assert {:ok, connect} =
             ProjectIMConnects.create_project_connect(org.id, project.id, "slack", %{
               "app_name" => "Comma",
               "app_id" => "A0E2E",
               "client_id" => "cid",
               "client_secret" => "csecret",
               "signing_secret" => "ssecret"
             })

    assert connect["provider"] == "slack"
    assert connect["group_id"] == project.salix_group_id
    assert connect["client_secret_configured"] == true
    assert connect["signing_secret_configured"] == true
    # Slack connects expose an install URL to finish the OAuth flow.
    assert is_binary(connect["oauth_url"])

    install_scopes =
      connect["oauth_url"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("scope")
      |> String.split(",")

    assert "files:read" in install_scopes
    assert "files:write" in install_scopes

    assert {:ok, [listed]} =
             SalixIM.ProviderConnects.list_group_im_connects(project.salix_group_id, "slack")

    assert listed["connect_id"] == connect["connect_id"]

    # Deleting the project connect removes it from the group-scoped listing.
    assert {:ok, _} =
             ProjectIMConnects.delete_project_connect(org.id, project.id, connect["connect_id"])

    assert {:ok, []} =
             SalixIM.ProviderConnects.list_group_im_connects(project.salix_group_id, "slack")

    # No reconcile rows are produced by the synchronous provider-connect path.
    assert statuses() in [["done"], []]
  end

  test "agent creation reconciles its model under tenant and group" do
    choice = %{"kind" => "catalog", "model" => "claude-opus-4-8", "allow_paid" => false}
    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "P", "slug" => "p"})

    {:ok, agent} =
      Agents.create_agent(project.id, %{
        "role" => "router",
        "name" => "Router",
        "model" => choice
      })

    drain_all()

    # The control-plane agent is provisioned under the org's tenant + project's
    # group, keyed by the agent's salix id.
    assert {:ok, attrs} =
             SalixAgent.Control.get(agent.salix_agent_id, org.salix_tenant_id)

    assert attrs["agent_id"] == agent.salix_agent_id
    assert attrs["group_id"] == project.salix_group_id
    assert attrs["tenant_id"] == org.salix_tenant_id
    assert attrs["role"] == "router"
    assert attrs["model"] == choice

    assert {:ok, _state} = SalixAgent.get_state(agent.salix_agent_id)

    assert statuses() == ["done"]
  end

  test "project VM default uses Salix platform Cloudflare provider without explicit provider" do
    {:ok, _} =
      SalixWeb.CloudVM.put_default_vm_config(%{
        "default_provider" => "cloudflare",
        "providers" => %{"cloudflare" => %{"enabled" => true}}
      })

    {:ok, org} = Orgs.create_org(%{"name" => "CloudVM", "slug" => "cloudvm"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "P", "slug" => "p"})

    drain_all()

    router_agent = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

    assert {:ok, router} =
             SalixAgent.Control.get(router_agent.salix_agent_id, org.salix_tenant_id)

    assert SalixAgent.CloudVM.allowed?(router)

    assert {:ok,
            %{
              "billing_owner" => %{"vm_profile_key" => "cf-standard-2"},
              "cloud_vm_enabled" => true
            }} =
             Salix.Control.Groups.get(project.salix_group_id)

    assert {:error, :not_found} =
             SalixWeb.ComputeProviders.Cloudflare.get_record(project.salix_group_id)

    assert statuses() == ["done"]
  end

  test "station-bound worker creation reconciles its binding into Salix" do
    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "P", "slug" => "p"})
    drain_all()

    device_id = SalixStore.Ids.new_device_id()

    {:ok, _transport_id, env} =
      SalixEnv.Registry.connect("nonode@nohost", %{
        "tenant_id" => org.salix_tenant_id,
        "group_id" => project.salix_group_id,
        "device_id" => device_id,
        "connector_id" => "connector-#{SystemsRuntime.Proc.unique_integer([:positive])}",
        "name" => "Mac Studio"
      })

    {:ok, _} =
      SalixEnv.Registry.update_meta(
        env["connector_run_id"],
        &Map.put(&1, "capabilities", %{"tasks" => 2})
      )

    refresh_device_projection(project.id, device_id)

    {:ok, agent} =
      BridgeForTeams.TestSupport.LegacyWorker.create_station(
        project,
        %{"name" => "station-worker"},
        %{
          "kind" => "station",
          "device_id" => device_id,
          "runtime" => "claude"
        }
      )

    # Salix keeps the binding whether or not the station is connected: a Task
    # checks the station when it is made.
    assert {:ok, %{"status" => "disconnected"}} =
             SalixEnv.Registry.mark_disconnected(env["connector_run_id"])

    drain_all()

    assert {:ok, attrs} = SalixAgent.Control.get(agent.salix_agent_id, org.salix_tenant_id)
    assert attrs["role"] == "worker"

    assert attrs["station_binding"] == %{
             "runs_on" => %{"kind" => "station", "device_id" => device_id},
             "model" => %{"kind" => "runtime", "provider" => "claude"},
             "binding_revision" => 1
           }

    assert statuses() == ["done"]
  end

  defp refresh_device_projection(project_id, device_id, attempts \\ 20)

  defp refresh_device_projection(_project_id, _device_id, 0),
    do: flunk("device projection did not converge")

  defp refresh_device_projection(project_id, device_id, attempts) do
    assert {:ok, _result} =
             Environments.reconcile_device_projection(projection_page_limit: 100)

    if Repo.get_by(ProjectDeviceProjection, project_id: project_id, device_id: device_id) do
      :ok
    else
      refresh_device_projection(project_id, device_id, attempts - 1)
    end
  end

  test "a permanent client error marks the row failed and bumps attempts" do
    {:ok, _} =
      Reconciler.enqueue("project", "missing_group", "update_group", %{
        "group_id" => "missing_group",
        "tenant_id" => "missing_tenant",
        "attrs" => %{"name" => "Nope"}
      })

    assert {:ok, 1} = Reconciler.drain_once()

    row = Repo.one(from(r in ReconcileOutbox, where: r.op == "update_group"))
    assert row.status == "failed"
    assert row.attempts == 1
    assert row.last_error =~ "not_found"
  end

  test "a transient client error defers the row for retry (stays pending)" do
    {:ok, _org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})
    # :unavailable / :timeout are transient — the row is deferred, not failed.
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_nodes_override, [])

    assert {:ok, 0} = Reconciler.drain_once()

    row = Repo.one(from(r in ReconcileOutbox, where: r.op == "create_tenant"))
    assert row.status == "pending"
    assert row.attempts == 1
    assert row.last_error =~ "transient"
  end
end
