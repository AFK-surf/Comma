defmodule BridgeForTeams.AgentsTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Agents, Environments, Observability, Orgs, Projects}
  alias BridgeForTeams.Schema.{Agent, ProjectDeviceProjection, ReconcileOutbox}
  alias SalixStore.RuntimeIds

  defmodule RaisingFeeSink do
    def insert(_rows), do: raise("fee sink down")
  end

  defmodule TypedSinkFake do
    def insert(rows) do
      send(self(), {:bridge_typed_rows, rows})
      {:ok, length(rows)}
    end
  end

  defmodule RuntimeInventoryClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient
    @moduledoc false

    def list_group_envs(group_id, tenant_id) do
      envs =
        :bridge_for_teams_core
        |> Application.get_env(:test_runtime_inventory, [])
        |> Enum.filter(&(&1["group_id"] == group_id and &1["tenant_id"] == tenant_id))

      {:ok, envs}
    end

    def page_group_envs(group_id, tenant_id, _opts) do
      {:ok, envs} = list_group_envs(group_id, tenant_id)
      {:ok, %{records: envs, next_cursor: nil}}
    end

    def get_agent(agent_id, tenant_id), do: SalixAgent.Control.get(agent_id, tenant_id)

    def get_agent_projection(agent_id, tenant_id),
      do: SalixAgent.Control.get(agent_id, tenant_id)
  end

  setup do
    ensure_billing_repo_started()
    prev_fee_sink = Application.get_env(:billing_core, :fee_control_typed_sink)
    prev_observer = Application.get_env(:bridge_for_teams_core, :fee_control_observer)
    SalixStore.S3.Fake.reset()
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    {:ok, project} = Projects.create_project(org.id, %{name: "P", slug: "p"})
    drain_all()

    on_exit(fn ->
      restore_env(:billing_core, :fee_control_typed_sink, prev_fee_sink)
      restore_env(:bridge_for_teams_core, :fee_control_observer, prev_observer)
    end)

    %{org: org, project: project}
  end

  defp drain_all do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp external_codex_runtime_config(
         command_path \\ "/Applications/Codex.app/Contents/MacOS/codex",
         device_id \\ "device_mac"
       ) do
    runtime_id = RuntimeIds.runtime_id(command_path)

    %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => device_id,
      "runtime_id" => runtime_id,
      "device_runtime_id" => RuntimeIds.device_runtime_id(device_id, "codex", runtime_id),
      "model" => "claude-sonnet-4",
      "model_provider" => "anthropic"
    }
  end

  defp runtime_inventory_fields(runtime_config) do
    Map.take(runtime_config, ~w(model model_provider))
  end

  defp register_external_runtime(org, project, runtime_config) do
    transport_id = "transport_" <> Ecto.UUID.generate()
    connector_id = "connector_" <> Ecto.UUID.generate()

    meta = %{
      "tenant_id" => org.salix_tenant_id,
      "group_id" => project.salix_group_id,
      "device_id" => runtime_config["device_id"],
      "connector_id" => connector_id,
      "name" => "test-device",
      "agent_runtimes" => [
        %{
          "kind" => "external",
          "provider" => "codex",
          "runtime_id" => runtime_config["runtime_id"],
          "device_runtime_id" => runtime_config["device_runtime_id"],
          "version_detected" => true,
          "auth_ready" => true,
          "native_server_startable" => true,
          "ready" => true,
          "readiness_checked_at" => System.system_time(:millisecond),
          "readiness_valid_until" => System.system_time(:millisecond) + 600_000
        }
        |> Map.merge(runtime_inventory_fields(runtime_config))
      ]
    }

    {:ok, _transport_id, record} =
      SalixEnv.Registry.connect("nonode@nohost", meta, transport_id: transport_id)

    env = SalixEnv.Control.environment_json(record)

    Application.put_env(
      :bridge_for_teams_core,
      :test_runtime_inventory,
      [env | Application.get_env(:bridge_for_teams_core, :test_runtime_inventory, [])]
    )

    refresh_device_projection(project.id, runtime_config["device_id"])
    :ok
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

  defp materialize_salix_group_agent(org, project, agent, runtime_config) do
    {:ok, _tenant} = Salix.Control.Tenants.create_preallocated(%{}, org.salix_tenant_id)

    {:ok, _group} =
      Salix.Control.Groups.create_preallocated(
        %{"name" => project.name},
        org.salix_tenant_id,
        project.salix_group_id
      )

    SalixAgent.Control.create_owned_preallocated(
      %{
        "group_id" => project.salix_group_id,
        "role" => agent.role,
        "name" => agent.salix["name"],
        "runtime_config" => runtime_config
      },
      org.salix_tenant_id,
      agent.salix_agent_id
    )
  end

  test "create_agent assigns salix id and enqueues config", %{project: project} do
    assert {:ok, %Agent{} = agent} =
             Agents.create_agent(project.id, %{
               "role" => "router",
               "name" => "Router"
             })

    assert SalixStore.Ids.valid_agent_id_for_group?(agent.salix_agent_id, project.salix_group_id)

    ops =
      Repo.all(ReconcileOutbox)
      |> Enum.filter(&(&1.aggregate == "agent" and &1.aggregate_id == agent.id))
      |> Enum.map(& &1.op)
      |> Enum.sort()

    assert ops == ["create_owned_agent"]
  end

  test "create_agent stores external Codex runtime config and forwards it through outbox",
       %{
         org: org,
         project: project
       } do
    prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, RuntimeInventoryClient)

    on_exit(fn ->
      restore_env(:bridge_for_teams_core, :salix_client, prev_client)
      Application.delete_env(:bridge_for_teams_core, :test_runtime_inventory)
    end)

    runtime_config = external_codex_runtime_config()
    client_runtime_config = Map.drop(runtime_config, ~w(model model_provider))
    :ok = register_external_runtime(org, project, runtime_config)

    assert {:ok, %Agent{} = agent} =
             Agents.create_agent(project.id, %{
               "role" => "worker",
               "name" => "codex-worker",
               "runtime_config" => client_runtime_config
             })

    assert agent.salix["runtime_config"] == runtime_config

    row =
      Repo.one!(
        from(r in ReconcileOutbox,
          where:
            r.aggregate == "agent" and r.aggregate_id == ^agent.id and
              r.op == "create_owned_agent"
        )
      )

    assert row.payload["attrs"]["runtime_config"] == runtime_config
  end

  test "rebind_external_runtime changes the canonical configuration without a BFT snapshot", %{
    org: org,
    project: project
  } do
    prev_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, RuntimeInventoryClient)

    on_exit(fn ->
      restore_env(:bridge_for_teams_core, :salix_client, prev_client)
      Application.delete_env(:bridge_for_teams_core, :test_runtime_inventory)
    end)

    initial_runtime_config = external_codex_runtime_config()
    next_runtime_config = external_codex_runtime_config("/usr/local/bin/codex", "device_studio")
    :ok = register_external_runtime(org, project, initial_runtime_config)
    :ok = register_external_runtime(org, project, next_runtime_config)

    assert {:ok, %Agent{} = agent} =
             Agents.create_agent(project.id, %{
               "role" => "worker",
               "name" => "codex-worker",
               "runtime_config" => initial_runtime_config
             })

    assert {:ok, _salix_agent} =
             materialize_salix_group_agent(org, project, agent, initial_runtime_config)

    assert {:ok, %Agent{} = updated} =
             Agents.rebind_external_runtime(
               project,
               agent,
               next_runtime_config["device_runtime_id"]
             )

    assert updated.id == agent.id
    assert updated.salix["runtime_config"] == next_runtime_config
    refute Repo.get!(Agent, agent.id).salix["runtime_config"]
    assert {:ok, record} = SalixAgent.Control.get(agent.salix_agent_id)
    assert record["runtime_config"] == next_runtime_config
  end

  test "create_agent stores and forwards VM provider config", %{project: project} do
    vm = %{"enabled" => true, "provider" => "cloudflare"}

    assert {:ok, %Agent{} = agent} =
             Agents.create_agent(project.id, %{
               "role" => "worker",
               "name" => "cf-worker",
               "vm" => vm
             })

    assert agent.salix["vm"] == vm

    row =
      Repo.one!(
        from(r in ReconcileOutbox,
          where:
            r.aggregate == "agent" and r.aggregate_id == ^agent.id and
              r.op == "create_owned_agent"
        )
      )

    assert row.payload["attrs"]["vm"] == vm
  end

  test "create_agent rejects VM recreate command fields", %{project: project} do
    assert {:error, cs} =
             Agents.create_agent(project.id, %{
               "role" => "worker",
               "vm" => %{"enabled" => true, "provider" => "cloudflare", "recreate" => true}
             })

    assert %{vm: ["recreate is only supported when changing VM provider"]} = errors_on(cs)
  end

  test "create_agent rejects mismatched stable external runtime identity", %{
    project: project
  } do
    assert {:error, cs} =
             Agents.create_agent(project.id, %{
               "role" => "worker",
               "runtime_config" => %{
                 "kind" => "external",
                 "provider" => "codex",
                 "device_id" => "device_mac",
                 "runtime_id" => RuntimeIds.runtime_id("/usr/local/bin/codex"),
                 "device_runtime_id" => "not-the-derived-device-runtime-id"
               }
             })

    assert %{
             runtime_config: [
               "device_runtime_id must match device_id/provider/runtime_id"
             ]
           } =
             errors_on(cs)
  end

  test "create_agent requires complete stable external runtime binding", %{
    project: project
  } do
    assert {:error, cs} =
             Agents.create_agent(project.id, %{
               "role" => "worker",
               "runtime_config" => %{
                 "kind" => "external",
                 "provider" => "codex",
                 "device_runtime_id" => "incomplete-runtime"
               }
             })

    assert %{
             runtime_config: [
               "must include runtime_id",
               "must include device_id"
             ]
           } = errors_on(cs)
  end

  test "create_agent normalizes internal runtime config to kind only", %{project: project} do
    assert {:ok, %Agent{} = agent} =
             Agents.create_agent(project.id, %{
               "role" => "worker",
               "runtime_config" => %{
                 "kind" => "internal",
                 "device_runtime_id" => "ignored"
               }
             })

    assert agent.salix["runtime_config"] == nil
  end

  test "create_agent rejects external runtime config on router agents", %{project: project} do
    assert {:error, cs} =
             Agents.create_agent(project.id, %{
               "role" => "router",
               "runtime_config" => %{
                 "kind" => "external",
                 "provider" => "codex",
                 "device_runtime_id" => "device_runtime_runtime_codex"
               }
             })

    assert %{role: ["must be worker for external runtime agents"]} = errors_on(cs)
  end

  test "validates role", %{project: project} do
    assert {:error, cs} = Agents.create_agent(project.id, %{"role" => "boss"})
    assert %{role: _} = errors_on(cs)
  end

  test "list excludes archived", %{project: project} do
    {:ok, a1} = Agents.create_agent(project.id, %{"role" => "worker", "name" => "A"})
    {:ok, a2} = Agents.create_agent(project.id, %{"role" => "worker", "name" => "B"})
    drain_all()
    {:ok, _} = Agents.archive_agent(a2)
    ids = Agents.list_agents(project.id) |> Enum.map(& &1.id)
    assert a1.id in ids
    refute a2.id in ids
  end

  test "canonical pages retain product references and exclude foreign projects", %{
    org: org,
    project: project
  } do
    {:ok, other_project} = Projects.create_project(org.id, %{name: "Q", slug: "q"})
    {:ok, first} = Agents.create_agent(project.id, %{"role" => "worker", "name" => "A"})
    {:ok, second} = Agents.create_agent(other_project.id, %{"role" => "worker", "name" => "B"})
    drain_all()
    assert {:ok, first_page} = Agents.page_agents(project, limit: 50)
    assert first.id in Enum.map(first_page.items, & &1.id)
    refute second.id in Enum.map(first_page.items, & &1.id)
    assert {:ok, second_page} = Agents.page_agents(other_project, limit: 50)
    assert second.id in Enum.map(second_page.items, & &1.id)
  end

  test "update_agent applies through Salix without another BFT config row", %{project: project} do
    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "worker"})
    drain_all()
    before = Repo.aggregate(ReconcileOutbox, :count)
    assert {:ok, updated} = Agents.update_agent(agent, %{"system_prompt" => "hi"})
    assert updated.salix["system_prompt"] == "hi"
    assert Repo.aggregate(ReconcileOutbox, :count) == before
    refute Repo.get!(Agent, agent.id).salix["system_prompt"]
  end

  test "update and archive do not forward stale BFT runtime config", %{project: project} do
    runtime_config = external_codex_runtime_config()

    agent =
      Repo.insert!(%Agent{
        project_id: project.id,
        salix_agent_id: SalixStore.Ids.new_agent_id(project.salix_group_id),
        role: "worker",
        salix: %{"name" => "Codex", "runtime_config" => runtime_config}
      })

    assert {:error, :agent_configuration_transfer_required} =
             Agents.update_agent(agent, %{"name" => "Renamed Codex"})

    assert {:error, :agent_configuration_transfer_required} = Agents.archive_agent(agent)
    refute Repo.exists?(from r in ReconcileOutbox, where: r.aggregate_id == ^agent.id)
  end

  test "router agents cannot be archived", %{org: org, project: project} do
    audit_opts = [actor_label: "ops-admin@example.com"]
    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

    assert {:error, :router_agent} = Agents.archive_agent(router, audit_opts)
    assert is_nil(Repo.reload(router).salix["archived_at"])

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "agent.archived",
               result: "failed"
             )

    assert audit.resource_id == router.id
    assert audit.reason_class == "router_agent"
  end

  test "agent write actions record redacted audit rows", %{org: org, project: project} do
    audit_opts = [actor_label: "ops-admin@example.com"]

    assert {:ok, agent} =
             Agents.create_agent(
               project.id,
               %{"role" => "worker", "name" => "triage"},
               audit_opts
             )

    assert [created] = Observability.list_audit_logs(org.id, action: "agent.created")
    assert created.actor_label == "ops-admin@example.com"
    assert created.resource_type == "agent"
    assert created.resource_id == agent.id
    assert created.metadata["project_id"] == project.id
    assert created.metadata["agent_name"] == "triage"
    assert created.metadata["instructions_configured"] == "false"
    assert created.redacted_diff["role"] == %{"from" => nil, "to" => "worker"}

    drain_all()

    assert {:ok, updated} =
             Agents.update_agent(
               agent,
               %{
                 "system_prompt" => "Handle incidents with bearer secret-token"
               },
               audit_opts
             )

    assert [config_updated] =
             Observability.list_audit_logs(org.id, action: "agent.config_updated")

    assert config_updated.resource_id == agent.id

    assert config_updated.redacted_diff["instructions_configured"] == %{
             "from" => "false",
             "to" => "true"
           }

    refute Map.has_key?(config_updated.redacted_diff, "inline_model_configured")

    refute inspect(config_updated) =~ "Handle incidents"
    refute inspect(config_updated) =~ "secret-token"
    refute inspect(config_updated) =~ "private-model"
    refute inspect(config_updated) =~ "sk-test"

    assert {:ok, ^updated} = Agents.set_router_agent(updated, audit_opts)

    assert [router_set] = Observability.list_audit_logs(org.id, action: "agent.router_set")
    assert router_set.resource_id == agent.id
    assert router_set.redacted_diff["router_agent_id"]["to"] == agent.salix_agent_id

    assert {:ok, archived} = Agents.archive_agent(updated, audit_opts)
    assert Agent.lifecycle(archived) == "archived"

    assert [archived_audit] = Observability.list_audit_logs(org.id, action: "agent.archived")
    assert archived_audit.resource_id == agent.id

    assert archived_audit.redacted_diff["status"] == %{
             "from" => Agent.lifecycle(updated),
             "to" => "archived"
           }

    assert archived_audit.redacted_diff["archived_at"]["to"]
  end

  test "failed agent write attempts record redacted audit rows", %{org: org, project: project} do
    audit_opts = [actor_label: "ops-admin@example.com"]

    assert {:error, create_changeset} =
             Agents.create_agent(
               project.id,
               %{
                 "role" => "boss",
                 "name" => "bad-agent",
                 "system_prompt" => "Do not leak this instruction"
               },
               audit_opts
             )

    assert %{role: _} = errors_on(create_changeset)

    assert [create_audit] = Observability.list_audit_logs(org.id, action: "agent.created")
    assert create_audit.result == "failed"
    assert create_audit.reason_class == "validation_failed"
    assert is_nil(create_audit.resource_id)
    assert create_audit.resource_label == "Agent write attempt"
    assert create_audit.metadata["attempted_role"] == "boss"
    assert create_audit.metadata["attempted_name_configured"] == "true"
    assert create_audit.metadata["attempted_instructions_configured"] == "true"
    assert create_audit.metadata["validation_fields"] == ["role"]
    refute inspect(create_audit) =~ "Do not leak"

    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "worker"})

    drain_all()

    assert {:error, :agent_role_immutable} =
             Agents.update_agent(
               agent,
               %{"role" => "boss", "system_prompt" => "Keep this private"},
               audit_opts
             )

    assert [update_audit] =
             Observability.list_audit_logs(org.id, action: "agent.config_updated")

    assert update_audit.result == "failed"
    assert update_audit.reason_class == "agent_role_immutable"
    assert update_audit.resource_id == agent.id
    assert update_audit.metadata["attempted_instructions_configured"] == "true"
    refute inspect(update_audit) =~ "Keep this private"

    unprovisioned = %{agent | salix_agent_id: nil}
    assert {:error, :not_provisioned} = Agents.set_router_agent(unprovisioned, audit_opts)

    assert [router_audit] = Observability.list_audit_logs(org.id, action: "agent.router_set")
    assert router_audit.result == "failed"
    assert router_audit.reason_class == "not_provisioned"
    assert router_audit.resource_id == agent.id
  end

  test "inline credentials cannot masquerade as an applied model configuration", %{
    project: project
  } do
    assert {:error, :use_template_catalog} =
             Agents.create_agent(
               project.id,
               %{
                 "role" => "worker",
                 "llm_config" => %{"model" => "ignored", "api_key" => "private"}
               }
             )

    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "worker"})
    drain_all()

    assert {:error, :use_template_catalog} =
             Agents.update_agent(
               agent,
               %{"llm_config" => %{"model" => "ignored", "api_key" => "private"}}
             )

    assert {:ok, record} = SalixAgent.Control.get(agent.salix_agent_id)
    refute Map.has_key?(record, "llm_config")
  end

  test "create_agent copies the org default only at creation", %{
    org: org,
    project: project
  } do
    {:ok, _} =
      SalixAgent.Templates.create(%{
        "template_id" => "tmpl-default",
        "name" => "Org default",
        "model" => "org-model",
        "provider" => "mock"
      })

    {:ok, _} = Orgs.update_org(org, %{"default_template_id" => "tmpl-default"})
    drain_all()

    assert {:ok, agent} = Agents.create_agent(project.id, %{"role" => "worker"})
    refute agent.salix["template_id"]

    row =
      Repo.one(
        from(r in ReconcileOutbox,
          where:
            r.aggregate == "agent" and r.aggregate_id == ^agent.id and
              r.op == "create_owned_agent"
        )
      )

    refute row.payload["attrs"]["template_id"]
    drain_all()

    assert {:ok, record} = SalixAgent.Control.get(agent.salix_agent_id)
    assert record["template_id"] == "tmpl-default"

    assert {:ok, %{"template_id" => "tmpl-default"}, :pinned} =
             SalixAgent.Templates.resolve_template_for_record(record)

    # A later org default applies to new Agents only.
    {:ok, _} =
      SalixAgent.Templates.create(%{
        "template_id" => "tmpl-next",
        "name" => "Next default",
        "model" => "next-model",
        "provider" => "mock"
      })

    {:ok, _} = Orgs.update_org(org, %{"default_template_id" => "tmpl-next"})
    drain_all()

    assert {:ok, record} = SalixAgent.Control.get(agent.salix_agent_id)

    assert {:ok, %{"template_id" => "tmpl-default"}, :pinned} =
             SalixAgent.Templates.resolve_template_for_record(record)

    assert {:ok, next} = Agents.create_agent(project.id, %{"role" => "worker"})
    drain_all()
    assert {:ok, next_record} = SalixAgent.Control.get(next.salix_agent_id)
    assert next_record["template_id"] == "tmpl-next"
  end

  test "update_agent applies the selected catalog template in Salix", %{project: project} do
    {:ok, _} =
      SalixAgent.Templates.create(%{
        "template_id" => "tmpl-pick",
        "name" => "Selected",
        "model" => "selected-model",
        "provider" => "mock"
      })

    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "worker", "name" => "w"})
    drain_all()
    assert {:ok, updated} = Agents.update_agent(agent, %{"template_id" => "tmpl-pick"})
    assert updated.salix["template_id"] == "tmpl-pick"
    refute Repo.get!(Agent, agent.id).salix["template_id"]
    assert {:ok, %{"template_id" => "tmpl-pick"}} = SalixAgent.Control.get(agent.salix_agent_id)
  end

  test "deliver stamps server-side billing context through Salix erpc", %{
    org: org,
    project: project
  } do
    issue_billing_grant(org.billing_account_id)
    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "router"})
    drain_all()

    assert {:ok, status} =
             Agents.deliver(
               agent,
               %{
                 "content" => "hello",
                 "billing_context" => %{"billing_account_id" => "spoofed"}
               },
               source_message_id: "bft-agents-test:billing-context:#{agent.id}"
             )

    # Fresh per-test source id against the permanent session ledger:
    # deterministically :created (staged-era timing slack removed, A2).
    assert status == :created

    {:ok, router_record} = SalixAgent.Control.get(agent.salix_agent_id, org.salix_tenant_id)
    {:ok, router_session_id} = SalixStore.RuntimeIds.persisted_router_session_id(router_record)

    assert {:ok, session} =
             eventually_session(agent.salix_agent_id, router_session_id, fn session ->
               SalixAgent.InternalSession.get(session, :billing_context)["billing_account_id"] ==
                 org.billing_account_id
             end)

    assert SalixAgent.InternalSession.get(session, :billing_context)["billing_account_id"] ==
             org.billing_account_id

    assert SalixAgent.InternalSession.get(session, :billing_context)["entrypoint"] ==
             "direct_deliver"

    assert SalixAgent.InternalSession.get(session, :billing_context)["salix_group_id"] ==
             project.salix_group_id

    refute SalixAgent.InternalSession.get(session, :billing_context)["billing_account_id"] ==
             "spoofed"

    state =
      BillingCore.State.new(
        pricing_catalog: [price(:llm, :input, "openai", "gpt-x", 2)],
        grants: [
          %{
            id: "grant_bridge",
            billing_account_id: org.billing_account_id,
            remaining_credits: 100,
            expires_at: future_expiry()
          }
        ]
      )

    assert {:ok, charge, state} =
             BillingCore.LLMMetering.after_llm_call(%{
               state: state,
               typed_sink: TypedSinkFake,
               billing_context: SalixAgent.InternalSession.get(session, :billing_context),
               source_key: "bridge-direct-1",
               provider: "openai",
               model: "gpt-x",
               usage: %{prompt_tokens: 10}
             })

    assert charge.charged_credits == 20
    assert [%{remaining_credits: 80}] = state.grants

    assert_receive {:bridge_typed_rows,
                    [
                      %{
                        "source_key" => "bridge-direct-1",
                        "entrypoint" => "direct_deliver",
                        "billing_account_id" => billing_account_id,
                        "prompt_tokens" => 10
                      }
                    ]}

    assert billing_account_id == org.billing_account_id
  end

  test "deliver allows the default unlimited entitlement with zero credits", %{
    org: _org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :fee_control_observer, self())

    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "router"})
    drain_all()

    assert {:ok, status} =
             Agents.deliver(
               agent,
               %{"content" => "hello"},
               source_message_id: "bft-agents-test:zero-credit:#{agent.id}"
             )

    # Fresh per-test source id against the permanent session ledger:
    # deterministically :created (staged-era timing slack removed, A2).
    assert status == :created

    assert_receive {:bridge_fee_control_check,
                    %BillingCore.FeeControl.Decision{
                      allowed?: true,
                      reason: "allowed_unlimited",
                      entitlement_mode: :unlimited_metered,
                      balance_snapshot: 0
                    }, %{"entrypoint" => "direct_deliver"}}
  end

  test "deliver blocks when the default unlimited entitlement is revoked and no credits remain",
       %{
         org: org,
         project: project
       } do
    Application.put_env(:bridge_for_teams_core, :fee_control_observer, self())

    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "router"})
    drain_all()

    assert {:ok, status} =
             Agents.deliver(agent, %{"content" => "hello"},
               source_message_id: "bft-agents-test:inline-1:#{agent.id}"
             )

    # Fresh per-test source id against the permanent session ledger:
    # deterministically :created (staged-era timing slack removed, A2).
    assert status == :created

    assert_receive {:bridge_fee_control_check,
                    %BillingCore.FeeControl.Decision{
                      allowed?: true,
                      reason: "allowed_unlimited"
                    }, %{"entrypoint" => "direct_deliver"}}

    revoke_default_entitlement(org.billing_account_id)

    {:ok, blocked_agent} = Agents.create_agent(project.id, %{"role" => "router"})
    drain_all()

    assert {:error, {:billing_unavailable, decision}} =
             Agents.deliver(
               blocked_agent,
               %{"content" => "hello"},
               []
             )

    assert decision.allowed? == false
    assert decision.reason == "insufficient_credits"
    assert decision.entitlement_mode == :metered

    assert_receive {:bridge_fee_control_check,
                    %BillingCore.FeeControl.Decision{
                      allowed?: false,
                      reason: "insufficient_credits",
                      entitlement_mode: :metered
                    }, %{"entrypoint" => "direct_deliver"}}
  end

  test "a private subscription template can deliver with revoked credits", %{
    org: org,
    project: project
  } do
    revoke_default_entitlement(org.billing_account_id)

    {:ok, template} =
      SalixAgent.Templates.create_private(
        %{
          "name" => "Subscription",
          "model" => "gpt-5",
          "provider_config" => %{"account_pool" => "codex"}
        },
        org.salix_tenant_id
      )

    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "router"})
    drain_all()

    assert {:error, {:billing_unavailable, _}} =
             Agents.deliver(agent, %{"content" => "blocked"}, [])

    {:ok, agent} = Agents.update_agent(agent, %{"template_id" => template["template_id"]})

    assert {:ok, :created} =
             Agents.deliver(agent, %{"content" => "subscription"},
               source_message_id: "pool-no-credits:#{agent.id}"
             )
  end

  test "deliver unprovisioned errors", %{project: _project} do
    assert {:error, :not_provisioned} =
             Agents.deliver(%Agent{salix_agent_id: nil}, %{}, [])
  end

  test "deliver allows active credits when fee-control projection sink fails", %{
    org: org,
    project: project
  } do
    issue_billing_grant(org.billing_account_id)
    Application.put_env(:billing_core, :fee_control_typed_sink, RaisingFeeSink)
    Application.put_env(:bridge_for_teams_core, :fee_control_observer, self())

    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "router"})
    drain_all()

    assert {:ok, status} =
             Agents.deliver(agent, %{"content" => "hello"},
               source_message_id: "bft-agents-test:inline-2:#{agent.id}"
             )

    # Fresh per-test source id against the permanent session ledger:
    # deterministically :created (staged-era timing slack removed, A2).
    assert status == :created

    assert_receive {:bridge_fee_control_check,
                    %{
                      allowed?: true,
                      mode: :enforce,
                      query_performed: true,
                      balance_snapshot: 100
                    }, _context}
  end

  test "set_router_agent enqueues update_group and assigns the group router", %{project: project} do
    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "router", "name" => "Router"})
    before_ids = Repo.all(from(r in ReconcileOutbox, select: r.id))

    assert {:ok, ^agent} = Agents.set_router_agent(agent)

    row =
      Repo.one(
        from(r in ReconcileOutbox,
          where:
            r.aggregate == "project" and r.aggregate_id == ^project.id and
              r.op == "update_group" and r.id not in ^before_ids
        )
      )

    assert row
    assert row.payload["group_id"] == project.salix_group_id
    assert row.payload["attrs"]["router_agent_id"] == agent.salix_agent_id
    assert row.payload["attrs"]["billing_owner"]["billing_account_id"]
    assert row.payload["attrs"]["billing_owner"]["salix_group_id"] == project.salix_group_id
    assert row.payload["attrs"]["billing_owner"]["router_agent_id"] == agent.salix_agent_id

    drain_all()

    assert {:ok, group} = Salix.Control.Groups.get(project.salix_group_id)
    assert group["router_agent_id"] == agent.salix_agent_id
    assert group["billing_owner"]["billing_account_id"]
  end

  test "set_router_agent on an unprovisioned agent errors" do
    assert {:error, :not_provisioned} = Agents.set_router_agent(%Agent{salix_agent_id: nil})
  end

  defp eventually_session(agent_id, session_id, predicate) when is_function(predicate, 1),
    do: eventually_session(agent_id, session_id, predicate, 50)

  defp eventually_session(agent_id, session_id, predicate, attempts) when attempts > 0 do
    case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        if predicate.(session) do
          {:ok, session}
        else
          Process.sleep(10)
          eventually_session(agent_id, session_id, predicate, attempts - 1)
        end

      {:error, :not_found} ->
        Process.sleep(10)
        eventually_session(agent_id, session_id, predicate, attempts - 1)

      other ->
        other
    end
  end

  defp eventually_session(_agent_id, _session_id, _predicate, 0), do: {:error, :not_found}

  defp issue_billing_grant(account_id) do
    ensure_billing_repo_started()

    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        surface: "bridge",
        product_owner_type: "organization",
        product_owner_id: account_id
      })

    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        credits: 100,
        valid_from: ~U[2026-06-17 00:00:00Z],
        expires_at: future_expiry(),
        source_type: "manual_contract",
        source_id: "test:#{account_id}",
        source_event_id: "test:#{account_id}",
        idempotency_key: "test:#{account_id}:2026-06"
      })

    :ok
  end

  defp revoke_default_entitlement(account_id) do
    ensure_billing_repo_started()

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      UPDATE credit_grants
      SET status = 'revoked', updated_at = now()
      WHERE billing_account_id = $1 AND source_type = 'default_entitlement'
      """,
      [account_id]
    )

    :ok
  end

  defp ensure_billing_repo_started do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end
  end

  defp future_expiry do
    DateTime.utc_now()
    |> DateTime.add(30, :day)
    |> DateTime.truncate(:second)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp price(resource_kind, component, provider, sku, usd_micros_per_unit) do
    %{
      resource_kind: resource_kind,
      component: component,
      provider: provider,
      sku: sku,
      usd_micros_per_unit: usd_micros_per_unit,
      effective_at: ~U[2026-06-17 12:00:00Z]
    }
  end
end
