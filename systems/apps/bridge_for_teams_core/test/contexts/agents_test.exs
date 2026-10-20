defmodule BridgeForTeams.AgentsTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Agents, Orgs, Projects}
  alias BridgeForTeams.Schema.{Agent, ReconcileOutbox}
  alias BridgeForTeams.TestSupport.LegacyWorker

  defmodule RaisingFeeSink do
    def insert(_rows), do: raise("fee sink down")
  end

  defmodule TypedSinkFake do
    def insert(rows) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:bridge_typed_rows, rows})
      {:ok, length(rows)}
    end
  end

  setup do
    ensure_billing_repo_started()
    prev_fee_sink = SystemsRuntime.get_env(:billing_core, :fee_control_typed_sink)
    prev_observer = SystemsRuntime.get_env(:bridge_for_teams_core, :fee_control_observer)
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

  test "Workers are retired: a new one is refused and nothing is queued", %{project: project} do
    before = Repo.aggregate(ReconcileOutbox, :count)

    assert {:error, :workers_retired} =
             Agents.create_agent(project.id, %{"role" => "worker", "name" => "W"})

    assert {:error, :workers_retired} = Agents.create_agent(project.id, %{"name" => "W"})
    assert Repo.aggregate(ReconcileOutbox, :count) == before
    refute Repo.get_by(Agent, project_id: project.id, role: "worker")
  end

  test "a Worker queued before the release still drains and stays read-only", %{
    org: org,
    project: project
  } do
    {:ok, other_project} = Projects.create_project(org.id, %{name: "Q", slug: "q"})
    {:ok, worker} = LegacyWorker.create(project, %{"name" => "A"})
    {:ok, foreign} = LegacyWorker.create(other_project, %{"name" => "B"})
    drain_all()

    assert {:ok, %{"role" => "worker", "name" => "A"}} =
             SalixAgent.Control.get(worker.salix_agent_id)

    assert {:ok, page} = Agents.page_agents(project, limit: 50)
    assert worker.id in Enum.map(page.items, & &1.id)
    refute foreign.id in Enum.map(page.items, & &1.id)

    assert {:ok, worker} = Agents.get_agent(worker.id)
    assert {:error, :workers_retired} = Agents.update_agent(worker, %{"system_prompt" => "hi"})
    assert {:ok, record} = SalixAgent.Control.get(worker.salix_agent_id)
    assert record["system_prompt"] in [nil, ""]
  end

  test "update_agent applies through Salix without another BFT config row", %{project: project} do
    router = router(project)
    before = Repo.aggregate(ReconcileOutbox, :count)
    assert {:ok, updated} = Agents.update_agent(router, %{"system_prompt" => "hi"})
    assert updated.salix["system_prompt"] == "hi"
    assert Repo.aggregate(ReconcileOutbox, :count) == before
    refute Repo.get!(Agent, router.id).salix["system_prompt"]
  end

  test "inline credentials cannot masquerade as an applied model configuration", %{
    project: project
  } do
    assert {:error, :use_model_choice} =
             Agents.create_agent(
               project.id,
               %{
                 "role" => "router",
                 "llm_config" => %{"model" => "ignored", "api_key" => "private"}
               }
             )

    router = router(project)

    assert {:error, :use_model_choice} =
             Agents.update_agent(
               router,
               %{"llm_config" => %{"model" => "ignored", "api_key" => "private"}}
             )

    assert {:ok, record} = SalixAgent.Control.get(router.salix_agent_id)
    refute Map.has_key?(record, "llm_config")
  end

  test "create_agent copies the org default Router model only at creation", %{
    org: org,
    project: project
  } do
    default = %{"kind" => "catalog", "model" => "gpt-5.5", "allow_paid" => false}
    {:ok, org} = Orgs.update_org(org, %{"default_router_model" => default})

    assert {:ok, agent} = Agents.create_agent(project.id, %{"role" => "router"})

    row =
      Repo.one(
        from(r in ReconcileOutbox,
          where:
            r.aggregate == "agent" and r.aggregate_id == ^agent.id and
              r.op == "create_owned_agent"
        )
      )

    assert row.payload["attrs"]["model"] == default
    drain_all()

    assert {:ok, %{"model" => ^default}} = SalixAgent.Control.get(agent.salix_agent_id)

    # A later org default applies to new Agents only.
    next_default = %{"kind" => "catalog", "model" => "claude-opus-4-8", "allow_paid" => false}
    {:ok, _} = Orgs.update_org(org, %{"default_router_model" => next_default})

    assert {:ok, %{"model" => ^default}} = SalixAgent.Control.get(agent.salix_agent_id)
  end

  test "update_agent sends the model choice to Salix; nil follows the platform model", %{
    project: project
  } do
    choice = %{"kind" => "catalog", "model" => "claude-haiku-4-5", "allow_paid" => false}
    router = router(project)

    assert {:ok, updated} = Agents.update_agent(router, %{"model" => choice})
    assert updated.salix["model"] == choice
    assert {:ok, %{"model" => ^choice}} = SalixAgent.Control.get(router.salix_agent_id)

    assert {:ok, cleared} = Agents.update_agent(updated, %{"model" => nil})
    assert cleared.salix["model"] == nil
    assert {:ok, record} = SalixAgent.Control.get(router.salix_agent_id)
    assert record["model"] == nil
  end

  defp router(project), do: Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

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
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :fee_control_observer,
      SystemsRuntime.Proc.self()
    )

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
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :fee_control_observer,
      SystemsRuntime.Proc.self()
    )

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

  test "an Agent on a catalog model can deliver with revoked credits", %{
    org: org,
    project: project
  } do
    revoke_default_entitlement(org.billing_account_id)

    {:ok, agent} = Agents.create_agent(project.id, %{"role" => "router"})
    drain_all()

    assert {:error, {:billing_unavailable, _}} =
             Agents.deliver(agent, %{"content" => "blocked"}, [])

    # Only the org's own Profiles serve a catalog model; the platform does not pay.
    {:ok, agent} =
      Agents.update_agent(agent, %{
        "model" => %{"kind" => "catalog", "model" => "gpt-5", "allow_paid" => false}
      })

    assert {:ok, :created} =
             Agents.deliver(agent, %{"content" => "subscription"},
               source_message_id: "pool-no-credits:#{agent.id}"
             )
  end

  test "deliver allows active credits when fee-control projection sink fails", %{
    org: org,
    project: project
  } do
    issue_billing_grant(org.billing_account_id)
    SystemsRuntime.put_env(:billing_core, :fee_control_typed_sink, RaisingFeeSink)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :fee_control_observer,
      SystemsRuntime.Proc.self()
    )

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

  defp eventually_session(agent_id, session_id, predicate) when is_function(predicate, 1),
    do: eventually_session(agent_id, session_id, predicate, 50)

  defp eventually_session(agent_id, session_id, predicate, attempts) when attempts > 0 do
    case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        if predicate.(session) do
          {:ok, session}
        else
          SystemsRuntime.Proc.sleep(10)
          eventually_session(agent_id, session_id, predicate, attempts - 1)
        end

      {:error, :not_found} ->
        SystemsRuntime.Proc.sleep(10)
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
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end
  end

  defp future_expiry do
    SystemsClock.utc_now()
    |> DateTime.add(30, :day)
    |> DateTime.truncate(:second)
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

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
