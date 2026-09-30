defmodule BridgeForTeams.TriageDelegationTest do
  @moduledoc """
  Retained Router-admission regressions for immutable legacy Triage handoffs,
  plus current project and Worker authority checks. New Worker-selected creation
  is composed through the real roster and native evaluator in
  triage_engine_acceptance_test.exs. Delivery suppresses model wakeup only.
  """

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Orgs, TriageDelegation}
  alias BridgeForTeams.Schema.{Agent, Project}
  alias SalixAgent.InternalSessionStore
  alias SalixStore.{Ids, RuntimeIds, ULID}

  @obligation_id "triage-product-" <> String.duplicate("b", 64)
  @request_id "triage-delegation:#{@obligation_id}:0"

  defmodule NoWakeDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts) do
      result = SalixAgent.deliver(agent_id, payload, Keyword.put(opts, :no_wake, true))

      if match?({:ok, _}, result) do
        send(
          Application.fetch_env!(:bridge_for_teams_core, :test_triage_delegation_pid),
          {:router_admission, agent_id, payload, opts}
        )
      end

      result
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    overrides = [
      {:bridge_for_teams_core, :salix_client, BridgeForTeams.Salix.Erpc},
      {:bridge_for_teams_core, :test_triage_delegation_pid, self()},
      {:salix_im, :agent_delivery_mod, NoWakeDelivery},
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :group_context_mod, SalixAgent.TestSupport.GroupContext}
    ]

    previous =
      Enum.map(overrides, fn {app, key, value} ->
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    unless Process.whereis(SalixStore.S3.Fake), do: start_supervised!(SalixStore.S3.Fake)
    unless Process.whereis(Ids), do: start_supervised!(Ids)

    suffix = ULID.generate()

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "triage-delegation-#{suffix}@example.com",
        "name" => "Triage owner"
      })

    {:ok, org} = Orgs.create_org(%{name: "Triage", slug: "triage-delegation-#{suffix}"})
    group_id = Ids.new_group_id(Ids.new_tenant_id())

    org =
      Repo.update!(
        Ecto.Changeset.change(org, salix_tenant_id: Ids.tenant_id_from_group!(group_id))
      )

    project =
      Repo.insert!(%Project{
        org_id: org.id,
        name: "Triage",
        slug: "triage",
        salix_group_id: group_id,
        created_by_user_id: user.id
      })

    router = agent!(project, "Router", "router")
    worker = agent!(project, "Worker", "worker")
    second_worker = agent!(project, "Worker 2", "worker")

    SalixAgent.TestSupport.create_control_group!(group_id, %{
      "router_agent_id" => router.salix_agent_id
    })

    {:ok, control_router} = SalixAgent.Control.get(router.salix_agent_id)
    {:ok, session_id} = RuntimeIds.persisted_router_session_id(control_router)
    {:ok, _} = InternalSessionStore.prepare_create(router.salix_agent_id, session_id)

    %{
      project: project,
      router: router,
      worker: worker,
      second_worker: second_worker,
      session_id: session_id
    }
  end

  test "multiple Workers admit a server-authored handoff to the real Router without creating a Task",
       %{project: project, router: router} do
    claim = claim(project, router)
    delegation = hd(claim.payload["delegations"])

    assert {:ok, prepared} = TriageDelegation.prepare(claim, delegation, @request_id)
    refute_received {:router_admission, _, _, _}

    assert TriageDelegation.commit(prepared) ==
             {:ok, %{"disposition" => "routed", "request_id" => @request_id}}

    assert_receive {:router_admission, router_id, payload, opts}
    assert router_id == router.salix_agent_id
    assert opts[:source_message_id] == @request_id
    refute Keyword.has_key?(opts, :command_text)
    refute Keyword.has_key?(opts, :trusted_source_text)

    origin = payload.trusted_origin
    assert origin["source_actor_type"] == "provider_system"
    assert origin["source_message_id"] == @request_id
    refute Map.has_key?(origin, "source_text")

    assert origin["triage_delegation"] == %{
             "schema" => "comma.triage-delegation-origin.v1",
             "namespace_key" => claim.namespace_key,
             "obligation_id" => claim.obligation_id,
             "index" => 0,
             "request_id" => @request_id,
             "router_agent_id" => router.salix_agent_id,
             "group_id" => project.salix_group_id
           }

    assert origin["provider_context"] == %{
             "connect_id" => claim.payload["target"]["connect_id"],
             "workspace_id" => "T_SOURCE",
             "channel_id" => "C_SOURCE",
             "thread_ts" => "1788775200.000001",
             "message_ts" => "1788775200.000001",
             "event_type" => "triage_delegation",
             "app_authored" => true
           }

    refute Map.has_key?(origin["provider_context"], "triage_delegation")
    refute Map.has_key?(prepared.metadata, "triage_delegation")
    assert_no_tasks!(project)
  end

  test "handoff carries the assigned task and source context without private payload data",
       %{
         project: project,
         router: router
       } do
    claim = claim(project, router)

    assert {:ok, prepared} =
             TriageDelegation.prepare(claim, hd(claim.payload["delegations"]), @request_id)

    content = prepared.content
    assert content =~ "Assigned task: Inspect the rollout"
    assert content =~ "triage_delegation_ref: #{@request_id}"
    assert content =~ "The rollout reports a token-expired error."
    assert content =~ "slack://T_SOURCE/C_SOURCE/1788775200.000001/1788775201.000002"
    assert content =~ Jason.encode!(claim.payload["target"]["connect_id"])
    assert content =~ ~s("channel_id":"C_SOURCE")
    assert content =~ ~s("thread_ts":"1788775200.000001")
    refute content =~ "claim-secret"
    refute content =~ "hidden-payload-secret"
    refute content =~ "raw-body-secret"
    refute content =~ claim.namespace_key
    refute content =~ claim.run_id
    refute_received {:router_admission, _, _, _}
  end

  test "repeated commit retains the stable source id and persists one Router input", %{
    project: project,
    router: router,
    session_id: session_id
  } do
    claim = claim(project, router)

    assert {:ok, prepared} =
             TriageDelegation.prepare(claim, hd(claim.payload["delegations"]), @request_id)

    for _attempt <- 1..2 do
      assert TriageDelegation.commit(prepared) ==
               {:ok, %{"disposition" => "routed", "request_id" => @request_id}}
    end

    router_id = router.salix_agent_id
    assert_receive {:router_admission, ^router_id, _, opts}, 2_000
    assert opts[:source_message_id] == @request_id

    assert {:ok, session} = InternalSessionStore.read(router.salix_agent_id, session_id)
    assert MapSet.member?(SalixAgent.InternalSession.get(session, :input_dedupe), @request_id)
    assert MapSet.size(SalixAgent.InternalSession.get(session, :input_dedupe)) == 1
    assert length(SalixAgent.InternalSession.get(session, :input_queue)) == 1
    assert_no_tasks!(project)
  end

  test "request id and delegation must select the same original bounded slot", %{
    project: project,
    router: router
  } do
    claim = claim(project, router)
    first = hd(claim.payload["delegations"])
    second = %{"task" => "Inspect the source logs", "source_refs" => []}
    claim = put_in(claim.payload["delegations"], [first, second])

    assert {:ok, prepared} =
             TriageDelegation.prepare(claim, second, "triage-delegation:#{@obligation_id}:1")

    assert prepared.handoff["index"] == 1

    for {candidate_claim, delegation, request_id} <- [
          {claim, second, @request_id},
          {claim, first, "triage-delegation:other-obligation:0"},
          {claim, first, "triage-delegation:#{@obligation_id}:2"},
          {claim, first, "triage-delegation:#{@obligation_id}:00"},
          {claim, Map.put(first, "task", "Different intent"), @request_id},
          {update_in(claim.payload, &Map.delete(&1, "delegations")), first, @request_id},
          {Map.delete(claim, :namespace_key), first, @request_id}
        ] do
      assert {:error, :invalid_delegation, false} =
               TriageDelegation.prepare(candidate_claim, delegation, request_id)
    end

    refute_received {:router_admission, _, _, _}
  end

  for change <- [
        :archived_project,
        :inactive_project,
        :changed_group,
        :archived_router,
        :missing_router,
        :reassigned_router
      ] do
    test "prepare and commit reject #{change}", %{project: project, router: router} do
      claim = claim(project, router)
      delegation = hd(claim.payload["delegations"])
      assert {:ok, prepared} = TriageDelegation.prepare(claim, delegation, @request_id)

      change_authority!(unquote(change), project, router)

      assert {:error, _reason, false} =
               TriageDelegation.prepare(claim, delegation, @request_id)

      assert {:error, _reason, false} = TriageDelegation.commit(prepared)
      refute_received {:router_admission, _, _, _}
    end
  end

  test "chosen Worker authorization accepts either active canonical Worker", %{
    project: project,
    router: router,
    worker: worker,
    second_worker: second_worker
  } do
    for chosen <- [worker, second_worker] do
      assert :ok =
               TriageDelegation.authorize_target(
                 claim(project, router),
                 router.salix_agent_id,
                 chosen.salix_agent_id
               )
    end

    refute_received {:router_admission, _, _, _}
    assert_no_tasks!(project)
  end

  test "Worker archival after prepare does not turn Router admission into Worker selection", %{
    project: project,
    router: router,
    worker: worker,
    second_worker: second_worker
  } do
    claim = claim(project, router)

    assert {:ok, prepared} =
             TriageDelegation.prepare(claim, hd(claim.payload["delegations"]), @request_id)

    archive_agent_fixture!(worker)
    archive_agent_fixture!(second_worker)

    assert TriageDelegation.commit(prepared) ==
             {:ok, %{"disposition" => "routed", "request_id" => @request_id}}

    assert_receive {:router_admission, _, _, _}
    assert_no_tasks!(project)
  end

  test "chosen Worker authorization rejects archived, missing, wrong-role and noncanonical targets",
       %{project: project, router: router, worker: worker, second_worker: second_worker} do
    claim = claim(project, router)
    archive_agent_fixture!(worker)
    assert :ok = SalixStore.S3.delete(SalixStore.Keys.ctl_agent(second_worker.salix_agent_id))

    for worker_ref <- [
          worker.salix_agent_id,
          second_worker.salix_agent_id,
          router.salix_agent_id,
          worker.id,
          worker.salix["name"],
          Ids.new_agent_id(project.salix_group_id),
          Ids.new_agent_id(Ids.new_group_id(Ids.new_tenant_id()))
        ] do
      assert {:error, _reason, false} =
               TriageDelegation.authorize_target(claim, router.salix_agent_id, worker_ref)
    end

    refute_received {:router_admission, _, _, _}
    assert_no_tasks!(project)
  end

  test "chosen Worker authorization rejects stale product or current Router authority", %{
    project: project,
    router: router,
    worker: worker
  } do
    original = claim(project, router)
    stale = put_in(original.payload["product_identity"]["salix_agent_id"], worker.salix_agent_id)

    assert {:error, _reason, false} =
             TriageDelegation.authorize_target(
               stale,
               router.salix_agent_id,
               worker.salix_agent_id
             )

    assert {:error, _reason, false} =
             TriageDelegation.authorize_target(
               original,
               worker.salix_agent_id,
               worker.salix_agent_id
             )

    change_authority!(:reassigned_router, project, router)

    assert {:error, _reason, false} =
             TriageDelegation.authorize_target(
               original,
               router.salix_agent_id,
               worker.salix_agent_id
             )

    refute_received {:router_admission, _, _, _}
  end

  test "prepare accepts an external Router without selecting a Worker", %{
    project: project,
    router: router
  } do
    # Seed the owner record, not retired BFT configuration columns. This test
    # covers delegation eligibility, not external-runtime configuration admission.
    key = SalixStore.Keys.ctl_agent(router.salix_agent_id)
    {:ok, %{body: body, etag: etag}} = SalixStore.S3.get(key)
    external = body |> Jason.decode!() |> Map.put("runtime_config", %{"kind" => "external"})
    assert {:ok, _} = SalixStore.S3.put(key, Jason.encode!(external), if_match: etag)
    claim = claim(project, router)

    assert {:ok, prepared} =
             TriageDelegation.prepare(claim, hd(claim.payload["delegations"]), @request_id)

    assert prepared.handoff["router_agent_id"] == router.salix_agent_id
    refute Map.has_key?(prepared, :worker)
    refute_received {:router_admission, _, _, _}
  end

  defp change_authority!(:archived_project, project, _router),
    do: Repo.update!(Ecto.Changeset.change(project, archived_at: DateTime.utc_now()))

  defp change_authority!(:inactive_project, project, _router),
    do: Repo.update!(Ecto.Changeset.change(project, status: "inactive"))

  defp change_authority!(:changed_group, project, _router),
    do:
      Repo.update!(
        Ecto.Changeset.change(project,
          salix_group_id: Ids.new_group_id(Ids.new_tenant_id())
        )
      )

  defp change_authority!(:archived_router, _project, router),
    do: archive_agent_fixture!(router)

  defp change_authority!(:missing_router, _project, router),
    do: SalixStore.S3.delete(SalixStore.Keys.ctl_agent(router.salix_agent_id))

  defp change_authority!(:reassigned_router, project, _router) do
    replacement = agent!(project, "Replacement Router", "router")

    SalixAgent.TestSupport.create_control_group!(project.salix_group_id, %{
      "router_agent_id" => replacement.salix_agent_id
    })
  end

  defp agent!(project, name, role) do
    agent_id = Ids.new_agent_id(project.salix_group_id)

    SalixAgent.TestSupport.create_control_agent!(agent_id, %{
      "name" => name,
      "role" => role,
      "runtime_config" => %{"kind" => "internal"}
    })

    reference =
      Repo.insert!(%Agent{
        project_id: project.id,
        salix_agent_id: agent_id,
        role: role,
        configuration_authority: "salix"
      })

    {:ok, agent} = BridgeForTeams.Agents.get_agent(reference.id)
    agent
  end

  defp assert_no_tasks!(project) do
    assert {:ok, %{"data" => [], "has_more" => false}} =
             SalixIM.Conversations.list_group_conversations(project.salix_group_id,
               kind: "agent_task",
               limit: 10
             )
  end

  defp claim(project, router) do
    %{
      namespace_key: String.duplicate("a", 64),
      obligation_id: @obligation_id,
      run_id: "diagnostic-run",
      claim_token: "claim-secret",
      payload: %{
        "product_identity" => %{
          "project_id" => project.id,
          "project_salix_group_id" => project.salix_group_id,
          "agent_id" => router.id,
          "salix_agent_id" => router.salix_agent_id
        },
        "target" => %{
          "connect_id" => Ids.new_connect_id(),
          "connect_generation" => "private-generation",
          "workspace_id" => "T_SOURCE",
          "channel_id" => "C_SOURCE",
          "thread_ts" => "1788775200.000001"
        },
        "source_messages" => [
          %{
            "actor_id" => "U_SOURCE",
            "actor_kind" => "human",
            "message_ts" => "1788775201.000002",
            "excerpt" => "The rollout reports a token-expired error.",
            "raw_body" => "raw-body-secret"
          }
        ],
        "source_authority" => %{"hidden" => "hidden-payload-secret"},
        "delegations" => [
          %{
            "task" => "Inspect the rollout",
            "source_refs" => ["slack://T_SOURCE/C_SOURCE/1788775200.000001/1788775201.000002"]
          }
        ]
      }
    }
  end
end
