defmodule BridgeForTeams.SlackHistoryDerivationPersistenceTest do
  require SystemsRuntime.Proc

  use BridgeForTeams.DataCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{
    Accounts,
    ContextLifecycle,
    Memberships,
    Orgs,
    Projects,
    Repo,
    SlackHistoryImports,
    SlackHistoryOnboarding
  }

  alias BridgeForTeams.Schema.{
    Agent,
    AuditLog,
    ContextBundle,
    ContextBundleSubject,
    ContextLifecycleEvidence,
    ProjectKnowledgeAlias,
    ProjectKnowledgeAssertion,
    SlackHistoryImportRun,
    SourcedContextArtifact,
    SourcedContextDerivation,
    SourcedContextDerivationAttempt,
    SourcedContextObject,
    SourcedContextPublication,
    SourcedContextReviewRevision,
    SourcedContextSnapshot
  }

  alias BridgeForTeams.SourcedContext.{
    Acquisition,
    Derivations,
    Grounding,
    Previews,
    ProcessorOutput,
    Publications
  }

  defmodule Processor do
    @behaviour BridgeForTeams.SourcedContext.Processor

    @impl true
    def derive(request) do
      handler =
        SystemsRuntime.fetch_env!(
          :bridge_for_teams_core,
          :sourced_context_derivation_test_handler
        )

      handler.(request)
    end
  end

  defmodule CurrentRouterClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    def get_group(_id) do
      {:ok,
       %{
         "router_agent_id" =>
           SystemsRuntime.fetch_env!(:bridge_for_teams_core, :test_current_router)
       }}
    end
  end

  setup do
    previous_handler =
      SystemsRuntime.get_env(:bridge_for_teams_core, :sourced_context_derivation_test_handler)

    on_exit(fn ->
      restore_env(
        :bridge_for_teams_core,
        :sourced_context_derivation_test_handler,
        previous_handler
      )
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{"name" => "Derivation #{suffix}", "slug" => "derive-#{suffix}"})

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "derive-#{suffix}@example.test",
        "name" => "Derivation owner"
      })

    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

    {:ok, project} =
      Projects.create_project(
        org.id,
        %{"name" => "Derivation project", "slug" => "derive-project-#{suffix}"},
        creator_user_id: user.id
      )

    {:ok, run} = SlackHistoryImports.create_run(run_attrs(org, project, user, suffix))
    agent = Repo.get_by!(Agent, project_id: project.id, role: "router")
    # Dispatch now consumes the authoritative Salix group, not an unprovisioned
    # local role row. Complete the fixture's normal provisioning outbox first.
    Enum.reduce_while(1..5, nil, fn _, _ ->
      case BridgeForTeams.Salix.Reconciler.drain_once() do
        {:ok, 0} -> {:halt, :ok}
        {:ok, _} -> {:cont, :ok}
      end
    end)

    assert {:ok, _} = BridgeForTeams.Agents.current_router(project)

    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(run.id, run.generation)

    envelope = source_page(acquiring)
    assert {:ok, _receipt} = Acquisition.accept_page(run.id, acquiring.generation, envelope)

    assert {:ok, acquired, snapshot} =
             Acquisition.finalize_snapshot(run.id, acquiring.generation,
               normalization_revision: "slack-normalization:test:v1"
             )

    %{org: org, project: project, user: user, agent: agent, run: acquired, snapshot: snapshot}
  end

  test "same frozen snapshot supports idempotent, versioned derivations without Slack refetch",
       ctx do
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      &processor_result(&1, "approved")
    )

    request = derivation_request(ctx, ctx.run.generation, "derive-v1", "model-rev-1")

    assert {:ok, %{run: deriving, attempt: attempt, replayed?: false}} =
             Derivations.request(ctx.run.id, request)

    assert deriving.state == "deriving"
    assert deriving.derivation_id == attempt.id
    assert attempt.snapshot_id == ctx.snapshot.id
    assert attempt.model_revision == "model-rev-1"

    assert {:ok, %{run: replay_run, attempt: replay_attempt, replayed?: true}} =
             Derivations.request(ctx.run.id, request)

    assert replay_run.generation == deriving.generation
    assert replay_attempt.id == attempt.id

    assert {:ok,
            %{
              run: preview,
              attempt: completed,
              derivation: first_derivation,
              review_revision: first_review
            }} = Derivations.process(attempt.id, "worker-1", processor: Processor)

    assert preview.state == "preview_ready"
    assert completed.status == "completed"
    assert first_derivation.id == attempt.id
    assert first_derivation.snapshot_id == ctx.snapshot.id
    assert first_derivation.model_revision == "model-rev-1"
    assert first_derivation.prompt_template_id == "bft-history-extraction"
    assert first_derivation.prompt_revision == "prompt-rev-1"
    assert first_derivation.policy_revision == "extraction-policy-rev-1"
    assert first_derivation.schema_revision == "people-project-decision-v1"
    assert first_derivation.artifact_count == 3
    assert first_review.derivation_id == first_derivation.id
    assert first_review.revision == 1
    assert first_review.selected_count == 3
    assert length(first_review.items) == 3

    stored_artifact =
      Repo.one!(
        from(artifact in SourcedContextArtifact,
          where: artifact.derivation_id == ^first_derivation.id,
          order_by: [asc: artifact.stable_key],
          limit: 1
        )
      )

    refute stored_artifact.payload_ciphertext =~ "Atlas"

    source_count_before =
      Repo.aggregate(
        from(object in SourcedContextObject, where: object.run_id == ^ctx.run.id),
        :count
      )

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      &processor_result(&1, "deferred")
    )

    second_request =
      derivation_request(ctx, preview.generation, "derive-v2", "model-rev-2")

    assert {:ok, %{run: _deriving_again, attempt: second_attempt}} =
             Derivations.request(ctx.run.id, second_request)

    assert second_attempt.snapshot_id == ctx.snapshot.id
    assert second_attempt.parent_derivation_id == first_derivation.id

    assert {:ok,
            %{
              run: second_preview,
              derivation: second_derivation,
              review_revision: second_review
            }} = Derivations.process(second_attempt.id, "worker-2", processor: Processor)

    assert second_preview.state == "preview_ready"
    assert second_derivation.snapshot_id == first_derivation.snapshot_id
    assert second_derivation.parent_derivation_id == first_derivation.id
    assert second_derivation.output_sha256 != first_derivation.output_sha256
    assert second_review.revision == 2
    assert second_review.parent_revision_id == first_review.id

    assert {:ok, comparison} =
             Previews.compare(first_derivation.id, second_derivation.id, ctx.user.id)

    assert comparison.same_snapshot == true
    assert comparison.source_changed == false

    assert %{status: :changed} =
             Enum.find(comparison.changes, &(&1.stable_key == "decision:atlas-launch"))

    assert {:ok, preview_view} = Previews.get(ctx.run.id, ctx.user.id)
    assert preview_view.source_snapshot.id == ctx.snapshot.id
    assert preview_view.derivation.model_revision == "model-rev-2"
    assert preview_view.review_revision.id == second_review.id

    decision_item =
      Enum.find(preview_view.items, &(&1.stable_key == "decision:atlas-launch"))

    assert [%{payload: %{"text" => "Peng approved the Atlas launch"}}] =
             decision_item.sources

    revision_items =
      Enum.map(preview_view.items, fn item ->
        if item.stable_key == "decision:atlas-launch" do
          %{
            artifact_id: item.artifact_id,
            payload: %{
              "content" => "Atlas launch is approved after human review",
              "about" => item.payload["about"]
            }
          }
        else
          %{artifact_id: item.artifact_id}
        end
      end)

    revise_request = %{
      expected_generation: second_preview.generation,
      user_id: ctx.user.id,
      parent_review_revision_id: second_review.id,
      items: revision_items
    }

    assert {:ok, %{run: revised_run, review_revision: revised, replayed?: false}} =
             Previews.revise(ctx.run.id, revise_request)

    assert revised.revision == 3
    assert revised.parent_revision_id == second_review.id
    assert revised_run.review_revision_id == revised.id

    assert {:ok, %{review_revision: replayed_revision, replayed?: true}} =
             Previews.revise(ctx.run.id, revise_request)

    assert replayed_revision.id == revised.id

    assert {:ok, revised_view} = Previews.get(ctx.run.id, ctx.user.id)
    revised_decision = Enum.find(revised_view.items, &(&1.kind == "decision"))
    assert revised_decision.edited == true
    assert revised_decision.payload["content"] == "Atlas launch is approved after human review"

    assert {:error, :derivation_evidence_already_exists} =
             Derivations.request(
               ctx.run.id,
               derivation_request(
                 ctx,
                 revised_run.generation,
                 "same-evidence-new-command",
                 "model-rev-2"
               )
             )

    commit_request = %{
      expected_generation: revised_run.generation,
      user_id: ctx.user.id,
      command_id: "commit-reviewed-preview",
      snapshot_id: ctx.snapshot.id,
      derivation_id: second_derivation.id,
      review_revision_id: revised.id,
      confirmed?: false
    }

    assert {:error, :explicit_confirmation_required} =
             Publications.commit(ctx.run.id, commit_request)

    assert Grounding.ground_for_agent(ctx.agent.id, "What did Peng decide about Atlas?") ==
             :none

    assert {:ok,
            %{
              run: committed,
              publication: publication,
              receipt: commit_receipt,
              replayed?: false
            }} = Publications.commit(ctx.run.id, %{commit_request | confirmed?: true})

    assert committed.state == "committed"
    assert committed.publication_id == publication.id
    assert publication.status == "active"
    assert commit_receipt.kind == "committed"

    assert {:ok, %{publication: replayed_publication, replayed?: true}} =
             Publications.commit(ctx.run.id, %{commit_request | confirmed?: true})

    assert replayed_publication.id == publication.id

    assert {:ok, grounded} =
             Grounding.ground_for_agent(ctx.agent.id, "What did Peng decide about Atlas?")

    assert grounded.status == :resolved
    assert length(grounded.entities) == 2
    assert [grounded_fact] = grounded.facts
    assert grounded_fact.kind == :decision
    assert grounded_fact.content == "Atlas launch is approved after human review"

    assert Enum.any?(
             grounded_fact.source_refs,
             &(&1.type == "sourced_context_publication" and &1.ref == publication.id)
           )

    triage_capability = %{
      "schema" => "comma.bft-sourced-context-request.v1",
      "org_id" => ctx.org.id,
      "project_id" => ctx.project.id,
      "caller" => %{
        "kind" => "salix_agent",
        "agent_id" => ctx.agent.id,
        "salix_agent_id" => ctx.agent.salix_agent_id
      },
      "audience" => %{
        "scope" => "project-public-channels:v1",
        "provider" => "slack",
        "tenant_id" => ctx.org.salix_tenant_id,
        "group_id" => ctx.project.salix_group_id,
        "connect_id" => "conn-triage-current",
        "connect_generation" => "installation-generation-current",
        "triage_authority_generation" => "triage-generation-current",
        "workspace_id" => "T_CURRENT",
        "app_id" => "A_CURRENT",
        "channel_id" => "C_CURRENT",
        "visibility" => "public",
        "shared" => false,
        "authority_revision" => String.duplicate("a", 64),
        "source_mode" => "callback"
      }
    }

    assert {:ok, triage_grounded} =
             Grounding.ground_for_triage(
               ctx.agent.id,
               "What did Peng decide about Atlas?",
               triage_capability
             )

    assert triage_grounded == grounded

    forged_scope = put_in(triage_capability, ["audience", "scope"], "private-memory:v1")

    assert {:error, :invalid_grounding_request_capability} =
             Grounding.ground_for_triage(
               ctx.agent.id,
               "What did Peng decide about Atlas?",
               forged_scope
             )

    shared_channel = put_in(triage_capability, ["audience", "shared"], true)

    assert {:error, :invalid_grounding_request_capability} =
             Grounding.ground_for_triage(
               ctx.agent.id,
               "What did Peng decide about Atlas?",
               shared_channel
             )

    assert Repo.aggregate(
             from(assertion in ProjectKnowledgeAssertion,
               where: assertion.project_id == ^ctx.project.id
             ),
             :count
           ) == 0

    assert Repo.aggregate(
             from(alias_record in ProjectKnowledgeAlias,
               where: alias_record.project_id == ^ctx.project.id
             ),
             :count
           ) == 0

    assert {:ok, disconnected, %{effect: :frozen_snapshot_unchanged}} =
             SlackHistoryImports.source_disconnected(ctx.run.id, committed.generation)

    assert disconnected.state == "committed"
    assert disconnected.publication_id == publication.id

    assert {:ok, still_grounded} =
             Grounding.ground_for_agent(ctx.agent.id, "What did Peng decide about Atlas?")

    assert still_grounded.facts == grounded.facts

    rollback_request = %{
      expected_generation: disconnected.generation,
      user_id: ctx.user.id,
      command_id: "rollback-reviewed-preview",
      reason: "explicit user rollback"
    }

    assert {:ok, %{run: rolled_back, publication: inactive, replayed?: false}} =
             Publications.rollback(ctx.run.id, rollback_request)

    assert rolled_back.state == "rolled_back"
    assert inactive.status == "inactive"
    assert inactive.deactivation_reason == "explicit user rollback"

    assert Grounding.ground_for_agent(ctx.agent.id, "What did Peng decide about Atlas?") ==
             :none

    assert {:ok, %{publication: replayed_inactive, replayed?: true}} =
             Publications.rollback(ctx.run.id, rollback_request)

    assert replayed_inactive.id == inactive.id

    assert %ContextBundle{lifecycle_state: "registered"} =
             Repo.get!(ContextBundle, ctx.run.context_bundle_id)

    assert {:ok, rolled_back_preview} = Previews.get(ctx.run.id, ctx.user.id)
    assert rolled_back_preview.review_revision.id == revised.id

    assert Repo.aggregate(
             from(object in SourcedContextObject, where: object.run_id == ^ctx.run.id),
             :count
           ) == source_count_before

    audits =
      Repo.all(
        from(audit in AuditLog,
          where:
            audit.org_id == ^ctx.org.id and
              like(audit.action, "sourced_context.%"),
          order_by: [asc: audit.created_at, asc: audit.id]
        )
      )

    actions = MapSet.new(audits, & &1.action)

    assert MapSet.subset?(
             MapSet.new([
               "sourced_context.snapshot.finalized",
               "sourced_context.derivation.requested",
               "sourced_context.preview.generated",
               "sourced_context.preview.revised",
               "sourced_context.preview.committed",
               "sourced_context.publication.rolled_back"
             ]),
             actions
           )

    derivation_audit =
      Enum.find(audits, &(&1.action == "sourced_context.derivation.requested"))

    assert derivation_audit.metadata["model_id"] == "fixture-model"
    assert derivation_audit.metadata["model_revision"] == "model-rev-1"
    assert derivation_audit.metadata["prompt_revision"] == "[REDACTED]"
    assert derivation_audit.metadata["schema_revision"] == "people-project-decision-v1"

    audit_payload = Jason.encode!(Enum.map(audits, & &1.metadata))
    refute audit_payload =~ "Atlas"
    refute audit_payload =~ "Peng approved"
  end

  test "published shared context reaches the production project Agent path until rollback", ctx do
    {preview, derivation, review} = derive_preview(ctx, "project-agent-runtime")

    assert {:ok, %{run: committed, publication: publication}} =
             Publications.commit(preview.id, %{
               expected_generation: preview.generation,
               user_id: ctx.user.id,
               command_id: "commit-project-agent-runtime",
               snapshot_id: preview.snapshot_id,
               derivation_id: derivation.id,
               review_revision_id: review.id,
               confirmed?: true
             })

    features = SystemsRuntime.fetch_env!(:bridge_for_teams_core, :sourced_context_features)

    on_exit(fn ->
      SystemsRuntime.put_env(:bridge_for_teams_core, :sourced_context_features, features)
    end)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :grounding, false)
    )

    assert Grounding.ground_for_agent(ctx.agent.id, "What did Peng decide about Atlas?") ==
             :none

    assert {:ok, %{items: imported_items}} =
             Grounding.list_active_context_for_agent(ctx.agent.id, ctx.user.id)

    assert Enum.map(imported_items, & &1.kind) == [:person, :project, :decision]
    assert Enum.any?(imported_items, &(&1[:name] == "Peng"))
    assert Enum.any?(imported_items, &(&1[:content] == "Atlas launch is approved"))

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :knowledge_inspection, false)
    )

    assert Grounding.list_active_context_for_agent(ctx.agent.id, ctx.user.id) == :none

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :grounding, false)
    )

    {:ok, outsider} =
      Accounts.create_user(%{
        "email" =>
          "sourced-context-outsider-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test",
        "name" => "Sourced context outsider"
      })

    assert {:error, :forbidden} =
             Grounding.list_active_context_for_agent(ctx.agent.id, outsider.id)

    SystemsRuntime.put_env(:bridge_for_teams_core, :sourced_context_features, features)

    previous_provider = SystemsRuntime.get_env(:salix_agent, :project_knowledge_provider_mod)

    SystemsRuntime.put_env(
      :salix_agent,
      :project_knowledge_provider_mod,
      BridgeForTeams.ProjectKnowledge.AgentProvider
    )

    on_exit(fn ->
      restore_env(:salix_agent, :project_knowledge_provider_mod, previous_provider)
    end)

    question = "What did Peng decide about Atlas?"

    assert {:ok, grounded} =
             BridgeForTeams.ProjectKnowledge.AgentProvider.retrieve(
               ctx.agent.salix_agent_id,
               question,
               %{session_id: "session-project-agent-runtime"}
             )

    assert grounded.status == :resolved
    assert [%{kind: :decision, content: "Atlas launch is approved"} = decision] = grounded.facts

    assert Enum.any?(
             decision.source_refs,
             &(&1.type == "sourced_context_publication" and &1.ref == publication.id)
           )

    project_agent_capability = Grounding.project_agent_capability(ctx.agent)

    assert {:ok, ^grounded} =
             Grounding.ground_for_project_agent(
               ctx.agent.id,
               question,
               project_agent_capability
             )

    forged_agent =
      put_in(project_agent_capability, ["caller", "salix_agent_id"], "agt1_forged")

    assert {:error, :invalid_grounding_request_capability} =
             Grounding.ground_for_project_agent(ctx.agent.id, question, forged_agent)

    session = %{
      messages: [
        %{
          id: 1,
          role: "user",
          content: question,
          source_message_id: "im_provider:slack:conn-runtime:event-runtime"
        }
      ]
    }

    assert {:messages, [payload]} =
             SalixAgent.ProjectKnowledgeContext.prepare(
               ctx.agent.salix_agent_id,
               "session-project-agent-runtime",
               session
             )

    assert payload["runtime_message_type"] == "project_knowledge"
    assert payload["content"] =~ "Atlas launch is approved"
    assert Jason.encode!(payload["source_refs"]) =~ publication.id

    assert {:ok, disconnected, %{effect: :frozen_snapshot_unchanged}} =
             SlackHistoryImports.source_disconnected(ctx.run.id, committed.generation)

    assert {:ok, %{status: :resolved}} =
             BridgeForTeams.ProjectKnowledge.AgentProvider.retrieve(
               ctx.agent.salix_agent_id,
               question,
               %{session_id: "session-after-disconnect"}
             )

    assert {:ok, %{run: %{state: "rolled_back"}}} =
             Publications.rollback(ctx.run.id, %{
               expected_generation: disconnected.generation,
               user_id: ctx.user.id,
               command_id: "rollback-project-agent-runtime",
               reason: "product acceptance rollback"
             })

    assert {:ok, %{status: :unknown, entities: [], facts: []}} =
             BridgeForTeams.ProjectKnowledge.AgentProvider.retrieve(
               ctx.agent.salix_agent_id,
               question,
               %{session_id: "session-after-rollback"}
             )

    assert :none =
             SalixAgent.ProjectKnowledgeContext.prepare(
               ctx.agent.salix_agent_id,
               "session-after-rollback",
               session
             )
  end

  test "expired processor leases are fenced and only the newest worker can publish a preview",
       ctx do
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      &processor_result(&1, "approved")
    )

    assert {:ok, %{attempt: attempt}} =
             Derivations.request(
               ctx.run.id,
               derivation_request(ctx, ctx.run.generation, "lease", "model-rev-lease")
             )

    assert {:ok, first_claim} = Derivations.claim(attempt.id, "worker-old")

    attempt
    |> Repo.reload!()
    |> SourcedContextDerivationAttempt.transition_changeset(%{
      status: "processing",
      retry_count: 0,
      lease_generation: first_claim.lease_generation,
      lease_owner: "worker-old",
      lease_expires_at: DateTime.add(SystemsClock.utc_now(), -1, :second)
    })
    |> Repo.update!()

    assert {:ok, newest_claim} = Derivations.claim(attempt.id, "worker-new")
    assert newest_claim.lease_generation == first_claim.lease_generation + 1

    assert {:error, :stale_derivation_lease} =
             Derivations.run_claim(first_claim, processor: Processor)

    assert {:ok, %{run: preview, attempt: completed}} =
             Derivations.run_claim(newest_claim, processor: Processor)

    assert preview.state == "preview_ready"
    assert completed.status == "completed"
  end

  test "processor metadata cannot persist source text or secret-like config", ctx do
    secret = "Peng approved the private Atlas launch"

    invalid_config =
      ctx
      |> derivation_request(ctx.run.generation, "secret-config", "model-rev-secret-config")
      |> Map.put(:processor_config, %{"api_key" => secret})

    assert {:error, :invalid_processor_config} =
             Derivations.request(ctx.run.id, invalid_config)

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      fn request ->
        {:ok, result} = processor_result(request, "approved")
        {:ok, %{result | warnings: %{"ambiguous_items" => secret}}}
      end
    )

    assert {:ok, %{attempt: attempt}} =
             Derivations.request(
               ctx.run.id,
               derivation_request(ctx, ctx.run.generation, "warning-echo", "model-rev-warning")
             )

    assert {:ok, %{run: failed_run, attempt: failed_attempt}} =
             Derivations.process(attempt.id, "warning-echo-worker", processor: Processor)

    assert failed_run.state == "failed_terminal"
    assert failed_attempt.last_error_class == "invalid_processor_output"
    refute Repo.get(SourcedContextDerivation, attempt.id)

    persisted =
      Jason.encode!(%{
        processor_config: failed_attempt.processor_config,
        last_error_class: failed_attempt.last_error_class,
        audits:
          Repo.all(
            from(audit in AuditLog,
              where: audit.org_id == ^ctx.org.id,
              select: audit.metadata
            )
          )
      })

    refute persisted =~ secret
  end

  test "a lifecycle request waits for an in-flight processor and then fences its output", ctx do
    bundle = Repo.get!(ContextBundle, ctx.run.context_bundle_id)
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      fn request ->
        SystemsRuntime.Proc.send(parent, {:processor_started, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
          :release_processor -> processor_result(request, "finished-before-lifecycle-return")
        end
      end
    )

    assert {:ok, %{attempt: attempt}} =
             Derivations.request(
               ctx.run.id,
               derivation_request(
                 ctx,
                 ctx.run.generation,
                 "in-flight-lifecycle",
                 "model-rev-flight"
               )
             )

    assert {:ok, claim} = Derivations.claim(attempt.id, "worker-in-flight")

    derivation_task =
      SystemsRuntime.Task.async(fn -> Derivations.run_claim(claim, processor: Processor) end)

    assert_receive {:processor_started, processor_pid}

    lifecycle_task =
      SystemsRuntime.Task.async(fn ->
        result =
          ContextLifecycle.request_erasure(bundle.id, %{
            expected_revision: bundle.lifecycle_revision,
            requested_by_user_id: ctx.user.id,
            command_id: SystemsRuntime.Proc.uuid(),
            reason: "user_request"
          })

        SystemsRuntime.Proc.send(
          parent,
          {:lifecycle_request_returned, SystemsRuntime.Proc.self()}
        )

        result
      end)

    refute_receive {:lifecycle_request_returned, _pid}, 100
    SystemsRuntime.Proc.send(processor_pid, :release_processor)

    assert {:ok, %{bundle: pending}} = SystemsRuntime.Task.await(lifecycle_task, :infinity)
    assert pending.lifecycle_state == "erasure_pending"

    assert {:error, :context_lifecycle_not_ready} =
             SystemsRuntime.Task.await(derivation_task, :infinity)

    refute Repo.get(SourcedContextDerivation, attempt.id)

    assert Repo.aggregate(
             from(review in SourcedContextReviewRevision, where: review.run_id == ^ctx.run.id),
             :count
           ) == 0
  end

  test "a lifecycle request wins before commit and no publication is created", ctx do
    {preview_run, derivation, review} = derive_preview(ctx, "commit-lifecycle")
    bundle = Repo.get!(ContextBundle, preview_run.context_bundle_id)

    assert {:ok, %{bundle: pending}} =
             ContextLifecycle.request_deletion(bundle.id, %{
               expected_revision: bundle.lifecycle_revision,
               requested_by_user_id: ctx.user.id,
               command_id: SystemsRuntime.Proc.uuid(),
               reason: "user_request"
             })

    assert pending.lifecycle_state == "deletion_pending"

    assert {:error, :context_lifecycle_not_ready} =
             Publications.commit(ctx.run.id, %{
               expected_generation: preview_run.generation,
               user_id: ctx.user.id,
               command_id: "commit-after-lifecycle",
               snapshot_id: ctx.snapshot.id,
               derivation_id: derivation.id,
               review_revision_id: review.id,
               confirmed?: true
             })

    refute Repo.get_by(SourcedContextPublication, run_id: ctx.run.id)
    assert Repo.get!(SlackHistoryImportRun, ctx.run.id).generation == preview_run.generation
  end

  test "late cancel atomically deactivates a committed publication", ctx do
    {preview_run, derivation, review} = derive_preview(ctx, "late-cancel")

    commit_request = %{
      expected_generation: preview_run.generation,
      user_id: ctx.user.id,
      command_id: "late-cancel-commit",
      snapshot_id: ctx.snapshot.id,
      derivation_id: derivation.id,
      review_revision_id: review.id,
      confirmed?: true
    }

    assert {:ok, %{run: _committed, publication: publication}} =
             Publications.commit(ctx.run.id, commit_request)

    assert {:ok, %{status: :resolved}} =
             Grounding.ground_for_agent(ctx.agent.id, "What happened to Atlas?")

    cancel_request = %{
      # This is the preview generation accepted by a cancel racing commit. The
      # server turns it into a rollback if commit won first.
      expected_generation: preview_run.generation,
      user_id: ctx.user.id,
      command_id: "late-cancel-command",
      reason: "user canceled after commit"
    }

    assert {:ok,
            %{
              run: canceled,
              publication: inactive,
              receipt: receipt,
              replayed?: false
            }} = Publications.cancel(ctx.run.id, cancel_request)

    assert canceled.state == "rolled_back"
    assert inactive.id == publication.id
    assert inactive.status == "inactive"
    assert receipt.kind == "rolled_back_after_late_cancel"

    assert Grounding.ground_for_agent(ctx.agent.id, "What happened to Atlas?") == :none

    assert {:ok, %{publication: replayed, replayed?: true}} =
             Publications.cancel(ctx.run.id, cancel_request)

    assert replayed.id == publication.id
  end

  test "authorization and non-empty reviewed selection fail closed", ctx do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    {:ok, outsider} =
      Accounts.create_user(%{
        "email" => "derive-outsider-#{suffix}@example.test",
        "name" => "Outside reviewer"
      })

    unauthorized_request =
      ctx
      |> derivation_request(ctx.run.generation, "unauthorized", "model-rev-unauthorized")
      |> Map.put(:requested_by_user_id, outsider.id)

    assert {:error, :forbidden} = Derivations.request(ctx.run.id, unauthorized_request)

    {preview_run, derivation, review} = derive_preview(ctx, "empty-review")

    assert {:error, :forbidden} = Previews.get(ctx.run.id, outsider.id)

    assert {:error, :forbidden} =
             Previews.revise(ctx.run.id, %{
               expected_generation: preview_run.generation,
               user_id: outsider.id,
               parent_review_revision_id: review.id,
               items: []
             })

    assert {:ok, %{run: empty_run, review_revision: empty_review}} =
             Previews.revise(ctx.run.id, %{
               expected_generation: preview_run.generation,
               user_id: ctx.user.id,
               parent_review_revision_id: review.id,
               items: []
             })

    assert empty_review.selected_count == 0

    commit_request = %{
      expected_generation: empty_run.generation,
      user_id: ctx.user.id,
      command_id: "reject-empty-review",
      snapshot_id: ctx.snapshot.id,
      derivation_id: derivation.id,
      review_revision_id: empty_review.id,
      confirmed?: true
    }

    assert {:error, :empty_or_incomplete_review} =
             Publications.commit(ctx.run.id, commit_request)

    assert {:error, :forbidden} =
             Publications.commit(ctx.run.id, %{commit_request | user_id: outsider.id})

    assert Grounding.ground_for_agent(ctx.agent.id, "What happened to Atlas?") == :none
  end

  test "shared lifecycle erasure hides immediately and purges Slack content, not its tombstone",
       ctx do
    {preview_run, derivation, review} = derive_preview(ctx, "lifecycle-erasure")

    assert {:ok, %{run: committed, publication: publication}} =
             Publications.commit(ctx.run.id, %{
               expected_generation: preview_run.generation,
               user_id: ctx.user.id,
               command_id: "lifecycle-erasure-commit",
               snapshot_id: ctx.snapshot.id,
               derivation_id: derivation.id,
               review_revision_id: review.id,
               confirmed?: true
             })

    assert {:ok, %{status: :resolved}} =
             Grounding.ground_for_agent(ctx.agent.id, "What happened to Atlas?")

    bundle = Repo.get!(ContextBundle, committed.context_bundle_id)

    assert {:ok, %{bundle: pending, request: request}} =
             ContextLifecycle.request_erasure(bundle.id, %{
               expected_revision: bundle.lifecycle_revision,
               requested_by_user_id: ctx.user.id,
               command_id: SystemsRuntime.Proc.uuid(),
               reason: "user_request"
             })

    assert pending.lifecycle_state == "erasure_pending"
    assert Grounding.ground_for_agent(ctx.agent.id, "What happened to Atlas?") == :none
    assert {:error, :context_lifecycle_not_ready} = Previews.get(ctx.run.id, ctx.user.id)

    assert %SourcedContextPublication{id: publication_id, status: "active"} =
             Repo.get!(SourcedContextPublication, publication.id)

    assert publication_id == publication.id

    assert {:ok, claim} = ContextLifecycle.claim(request.id, "slack-context-purger")

    assert {:ok, %{bundle: deleted, request: completed, evidence: evidence}} =
             ContextLifecycle.run_claim(claim)

    assert deleted.lifecycle_state == "deleted"
    assert completed.state == "completed"
    assert evidence.source_type == "slack_history_import"
    assert evidence.counts["source_objects_deleted"] == 1
    assert evidence.counts["publications_deleted"] == 1
    assert evidence.counts["subject_index_rows_deleted"] >= 3

    assert Repo.aggregate(
             from(object in SourcedContextObject, where: object.run_id == ^ctx.run.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(snapshot in SourcedContextSnapshot, where: snapshot.run_id == ^ctx.run.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(review_revision in SourcedContextReviewRevision,
               where: review_revision.run_id == ^ctx.run.id
             ),
             :count
           ) == 0

    assert Repo.aggregate(
             from(publication_row in SourcedContextPublication,
               where: publication_row.run_id == ^ctx.run.id
             ),
             :count
           ) == 0

    assert Repo.aggregate(
             from(subject in ContextBundleSubject, where: subject.bundle_id == ^bundle.id),
             :count
           ) == 0

    assert %SlackHistoryImportRun{
             state: "committed",
             context_bundle_id: bundle_id,
             client_request_id: client_request_id,
             policy_revision: "context-lifecycle:v1",
             coverage_profile: "slack-root-bounded:v1",
             audience_scope: "project-public-channels:v1"
           } = Repo.get!(SlackHistoryImportRun, ctx.run.id)

    assert bundle_id == bundle.id
    assert {:ok, ^client_request_id} = Ecto.UUID.cast(client_request_id)

    assert %ContextLifecycleEvidence{} =
             Repo.get_by!(ContextLifecycleEvidence, request_id: request.id)
  end

  defp derive_preview(ctx, request_id) do
    SystemsRuntime.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      &processor_result(&1, "approved")
    )

    assert {:ok, %{attempt: attempt}} =
             Derivations.request(
               ctx.run.id,
               derivation_request(
                 ctx,
                 ctx.run.generation,
                 request_id,
                 "model-rev-#{request_id}"
               )
             )

    assert {:ok, %{run: preview, derivation: derivation, review_revision: review}} =
             Derivations.process(attempt.id, "worker-#{request_id}", processor: Processor)

    {preview, derivation, review}
  end

  defp processor_result(request, decision) do
    [first | _] = request.objects
    source_ids = Enum.map(request.objects, & &1.id)

    {:ok,
     %{
       artifacts: [
         %{
           kind: :person,
           stable_key: "person:peng",
           payload: %{"name" => "Peng", "aliases" => ["Peng X"]},
           confidence_millis: 940,
           source_object_ids: [first.id]
         },
         %{
           kind: :project,
           stable_key: "project:atlas",
           payload: %{"name" => "Atlas", "aliases" => ["Project Atlas"]},
           confidence_millis: 910,
           source_object_ids: [first.id]
         },
         %{
           kind: :decision,
           stable_key: "decision:atlas-launch",
           payload: %{
             "content" => "Atlas launch is #{decision}",
             "about" => [
               %{"kind" => "person", "stable_key" => "person:peng"},
               %{"kind" => "project", "stable_key" => "project:atlas"}
             ]
           },
           confidence_millis: 880,
           source_object_ids: source_ids
         }
       ],
       warnings: %{"ambiguous_items" => 0}
     }}
  end

  defp derivation_request(ctx, expected_generation, request_id, model_revision) do
    %{
      expected_generation: expected_generation,
      requested_by_user_id: ctx.user.id,
      client_request_id: request_id,
      model_provider: "fixture",
      model_id: "fixture-model",
      model_revision: model_revision,
      prompt_template_id: "bft-history-extraction",
      prompt_revision: "prompt-rev-1",
      policy_revision: "extraction-policy-rev-1",
      schema_revision: "people-project-decision-v1",
      processor_config: %{"temperature_millis" => 0}
    }
  end

  defp run_attrs(org, project, user, _suffix) do
    %{
      org_id: org.id,
      project_id: project.id,
      requested_by_user_id: user.id,
      client_request_id: SystemsRuntime.Proc.uuid(),
      salix_tenant_id: org.salix_tenant_id,
      salix_group_id: project.salix_group_id,
      source_workspace_id: "T_DERIVATION",
      source_app_id: "A_DERIVATION",
      connect_id: "conn-derivation",
      connect_generation: "gen-1",
      selected_channels: [
        %{
          id: "C_DERIVATION",
          name: "derivation",
          visibility: "public",
          authority_revision: String.duplicate("d", 64)
        }
      ],
      range_start: ~U[2026-08-17 00:00:00Z],
      range_end: ~U[2026-08-24 00:00:00Z],
      policy_revision: "context-lifecycle:v1",
      coverage_profile: "slack-root-bounded:v1",
      audience_scope: "project-public-channels:v1"
    }
  end

  defp source_page(run) do
    envelope = %{
      channel_id: "C_DERIVATION",
      stream_kind: "history",
      root_ts: "",
      page_ordinal: 0,
      request_cursor: nil,
      next_cursor: nil,
      stream_complete: true,
      accepted_connect_generation: run.connect_generation,
      accepted_channel_authority_revision: String.duplicate("d", 64),
      observed_at: ~U[2026-08-24 00:01:00Z],
      messages: [
        %{
          "message_ts" => "1787227200.000001",
          "thread_ts" => nil,
          "actor_id" => "U_PENG",
          "actor_kind" => "user",
          "text" => "Peng approved the Atlas launch",
          "observable_version" => "original",
          "reply_count" => 0,
          "file_metadata" => []
        }
      ]
    }

    Map.put(envelope, :response_sha256, Acquisition.page_sha256(envelope))
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
