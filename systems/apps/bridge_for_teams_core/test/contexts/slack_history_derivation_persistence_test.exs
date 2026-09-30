defmodule BridgeForTeams.SlackHistoryDerivationPersistenceTest do
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
        Application.fetch_env!(
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
         "router_agent_id" => Application.fetch_env!(:bridge_for_teams_core, :test_current_router)
       }}
    end
  end

  setup do
    previous_handler =
      Application.get_env(:bridge_for_teams_core, :sourced_context_derivation_test_handler)

    on_exit(fn ->
      restore_env(
        :bridge_for_teams_core,
        :sourced_context_derivation_test_handler,
        previous_handler
      )
    end)

    suffix = System.unique_integer([:positive])

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

  test "processor identity is kind plus stable key", ctx do
    test_pid = self()

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      fn request ->
        send(test_pid, {:processor_request, request})
        cross_kind_identity_result(request)
      end
    )

    request = derivation_request(ctx, ctx.run.generation, "cross-kind", "model-rev-cross-kind")

    assert {:ok, %{attempt: attempt}} = Derivations.request(ctx.run.id, request)

    assert {:ok, %{derivation: derivation}} =
             Derivations.process(attempt.id, "worker-cross-kind", processor: Processor)

    assert_receive {:processor_request, %{agent_id: agent_id}}
    assert agent_id == ctx.agent.salix_agent_id

    identities =
      Repo.all(
        from(artifact in SourcedContextArtifact,
          where: artifact.derivation_id == ^derivation.id,
          order_by: [asc: artifact.kind, asc: artifact.stable_key],
          select: {artifact.kind, artifact.stable_key}
        )
      )

    assert identities == [
             {"decision", "launch"},
             {"person", "atlas"},
             {"project", "atlas"}
           ]

    source_ids =
      Repo.all(
        from(object in SourcedContextObject,
          where: object.run_id == ^ctx.run.id,
          select: object.id
        )
      )
      |> MapSet.new()

    request_objects = Enum.map(source_ids, &%{id: &1})
    {:ok, output} = cross_kind_identity_result(%{objects: request_objects})
    [person | _rest] = output.artifacts

    assert {:error, :duplicate_artifact_identity} =
             ProcessorOutput.normalize(
               %{output | artifacts: [person, person]},
               source_ids,
               processor_output_bounds()
             )
  end

  test "dispatch uses the group's current Router, not the first local router role", ctx do
    {:ok, replacement} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
        ctx.project.id,
        %{role: "router", name: "Replacement"}
      )

    old_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    old_router = Application.get_env(:bridge_for_teams_core, :test_current_router)

    on_exit(fn ->
      restore_env(:bridge_for_teams_core, :salix_client, old_client)
      restore_env(:bridge_for_teams_core, :test_current_router, old_router)
    end)

    Application.put_env(:bridge_for_teams_core, :salix_client, CurrentRouterClient)
    Application.put_env(:bridge_for_teams_core, :test_current_router, replacement.salix_agent_id)
    pid = self()

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      fn request ->
        send(pid, {:selected_router, request.agent_id})
        cross_kind_identity_result(request)
      end
    )

    attrs = derivation_request(ctx, ctx.run.generation, "current-router", "router-rev")
    assert {:ok, %{attempt: attempt}} = Derivations.request(ctx.run.id, attrs)

    assert {:ok, %{derivation: _}} =
             Derivations.process(attempt.id, "router-worker", processor: Processor)

    assert_receive {:selected_router, selected}
    assert selected == replacement.salix_agent_id
  end

  test "same frozen snapshot supports idempotent, versioned derivations without Slack refetch",
       ctx do
    Application.put_env(
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

    Application.put_env(
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

    features = Application.fetch_env!(:bridge_for_teams_core, :sourced_context_features)

    on_exit(fn ->
      Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)
    end)

    Application.put_env(
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

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :knowledge_inspection, false)
    )

    assert Grounding.list_active_context_for_agent(ctx.agent.id, ctx.user.id) == :none

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :grounding, false)
    )

    {:ok, outsider} =
      Accounts.create_user(%{
        "email" => "sourced-context-outsider-#{System.unique_integer([:positive])}@example.test",
        "name" => "Sourced context outsider"
      })

    assert {:error, :forbidden} =
             Grounding.list_active_context_for_agent(ctx.agent.id, outsider.id)

    Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)

    previous_provider = Application.get_env(:salix_agent, :project_knowledge_provider_mod)

    Application.put_env(
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

  test "more than twenty duplicate imports remain one context and rollback removes one support",
       ctx do
    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      &processor_result(&1, "approved")
    )

    committed = [commit_canonical_support!(ctx, ctx.run, 0)]

    committed =
      Enum.reduce(1..20, committed, fn ordinal, acc ->
        {:ok, run} =
          SlackHistoryImports.create_run(run_attrs(ctx.org, ctx.project, ctx.user, ordinal))

        [commit_canonical_support!(ctx, run, ordinal) | acc]
      end)

    assert Repo.aggregate(
             from(publication in SourcedContextPublication,
               where: publication.status == "active"
             ),
             :count
           ) == 21

    [newest_active | _] = committed

    assert {:ok, %{id: active_run_id}} =
             SlackHistoryOnboarding.active_context_run(ctx.project.id, ctx.user.id)

    assert active_run_id == newest_active.run.id

    assert {:ok, %{runs: first_page, next_cursor: cursor}} =
             SlackHistoryOnboarding.list_runs_page(ctx.project.id, ctx.user.id)

    assert length(first_page) == 20
    assert is_binary(cursor)

    assert {:ok, %{runs: [oldest], next_cursor: nil}} =
             SlackHistoryOnboarding.list_runs_page(ctx.project.id, ctx.user.id, before: cursor)

    assert {:ok, exact_oldest} =
             SlackHistoryOnboarding.get_run(ctx.project.id, ctx.user.id, oldest.id)

    assert exact_oldest.id == oldest.id

    assert {:ok, grounded} =
             Grounding.ground_for_agent(
               ctx.agent.id,
               "What did Peng decide about Atlas?"
             )

    assert grounded.status == :resolved
    assert length(grounded.entities) == 2
    assert [%{content: "Atlas launch is approved"}] = grounded.facts

    [rolled_back | remaining] = committed

    assert {:ok, %{run: %{state: "rolled_back"}}} =
             Publications.rollback(rolled_back.run.id, %{
               expected_generation: rolled_back.run.generation,
               user_id: ctx.user.id,
               command_id: "rollback-canonical-support-#{rolled_back.run.id}",
               reason: "test one-support removal"
             })

    assert length(remaining) == 20

    assert {:ok, %{id: next_active_run_id}} =
             SlackHistoryOnboarding.active_context_run(ctx.project.id, ctx.user.id)

    assert next_active_run_id == hd(remaining).run.id

    assert {:ok, still_grounded} =
             Grounding.ground_for_agent(
               ctx.agent.id,
               "What did Peng decide about Atlas?"
             )

    assert still_grounded.status == :resolved
    assert length(still_grounded.entities) == 2
    assert [%{content: "Atlas launch is approved"}] = still_grounded.facts
  end

  test "active context skips a newer publication whose lifecycle is no longer readable", ctx do
    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      &processor_result(&1, "approved")
    )

    older = commit_canonical_support!(ctx, ctx.run, 0)

    {:ok, newer_run} =
      SlackHistoryImports.create_run(run_attrs(ctx.org, ctx.project, ctx.user, 1))

    newer = commit_canonical_support!(ctx, newer_run, 1)
    bundle = Repo.get!(ContextBundle, newer.run.context_bundle_id)

    assert {:ok, _pending_bundle} =
             bundle
             |> ContextBundle.lifecycle_changeset(%{
               lifecycle_state: "deletion_pending",
               subject_index_state: bundle.subject_index_state,
               lifecycle_revision: bundle.lifecycle_revision + 1,
               last_error: nil
             })
             |> Repo.update()

    assert {:ok, %{id: active_run_id}} =
             SlackHistoryOnboarding.active_context_run(ctx.project.id, ctx.user.id)

    assert active_run_id == older.run.id
  end

  test "grounding falls back to older support when the newest import is rolled back before read lock",
       ctx do
    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      &processor_result(&1, "approved")
    )

    older = commit_canonical_support!(ctx, ctx.run, 0)

    {:ok, newer_run} =
      SlackHistoryImports.create_run(run_attrs(ctx.org, ctx.project, ctx.user, 1))

    newer = commit_canonical_support!(ctx, newer_run, 1)
    observer_marker = {:grounding_selection_observer, make_ref()}

    observer = fn rows ->
      unless Process.get(observer_marker) do
        Process.put(observer_marker, true)

        assert Enum.any?(rows, &(&1.publication.id == newer.publication.id))

        assert {:ok, %{run: %{state: "rolled_back"}}} =
                 Publications.rollback(newer.run.id, %{
                   expected_generation: newer.run.generation,
                   user_id: ctx.user.id,
                   command_id: "rollback-during-grounding-#{newer.run.id}",
                   reason: "test representative fallback"
                 })
      end
    end

    assert {:ok, grounded} =
             Grounding.ground_for_agent(
               ctx.agent.id,
               "What did Peng decide about Atlas?",
               candidate_selection_observer: observer
             )

    assert Process.get(observer_marker)
    assert grounded.status == :resolved
    assert length(grounded.entities) == 2
    assert [%{content: "Atlas launch is approved"}] = grounded.facts
    assert Repo.reload!(newer.publication).status == "inactive"
    assert Repo.reload!(older.publication).status == "active"
  end

  test "expired processor leases are fenced and only the newest worker can publish a preview",
       ctx do
    Application.put_env(
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
      lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
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

  test "processor outages persist retry state and resume without rereading Slack", ctx do
    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      fn _request -> {:error, :temporarily_unavailable} end
    )

    assert {:ok, %{attempt: attempt}} =
             Derivations.request(
               ctx.run.id,
               derivation_request(ctx, ctx.run.generation, "retry", "model-rev-retry")
             )

    assert {:ok, %{run: paused, attempt: paused_attempt}} =
             Derivations.process(attempt.id, "worker-retry-1", processor: Processor)

    assert paused.state == "paused"
    assert paused.resume_phase == "deriving"
    assert paused_attempt.status == "paused"
    assert paused_attempt.retry_count == 1
    assert paused_attempt.retry_not_before != nil

    assert {:error, {:retry_not_before, _retry_at}} =
             Derivations.claim(attempt.id, "worker-too-early")

    past = DateTime.add(DateTime.utc_now(), -1, :second)

    paused_attempt
    |> SourcedContextDerivationAttempt.transition_changeset(%{
      status: "paused",
      retry_count: 1,
      retry_not_before: past,
      last_error_class: "processor_unavailable",
      lease_generation: paused_attempt.lease_generation,
      lease_owner: nil,
      lease_expires_at: nil
    })
    |> Repo.update!()

    paused
    |> SlackHistoryImportRun.transition_changeset(%{
      state: "paused",
      generation: paused.generation,
      resume_phase: "deriving",
      paused_reason: "processor_unavailable",
      retry_not_before: past,
      snapshot_id: paused.snapshot_id,
      derivation_id: paused.derivation_id,
      context_bundle_id: paused.context_bundle_id
    })
    |> Repo.update!()

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      &processor_result(&1, "approved-after-retry")
    )

    assert {:ok, %{run: preview, attempt: completed}} =
             Derivations.process(attempt.id, "worker-retry-2", processor: Processor)

    assert preview.state == "preview_ready"
    assert completed.status == "completed"
    assert completed.retry_count == 1
  end

  test "processor metadata cannot persist source text or secret-like config", ctx do
    secret = "Peng approved the private Atlas launch"

    invalid_config =
      ctx
      |> derivation_request(ctx.run.generation, "secret-config", "model-rev-secret-config")
      |> Map.put(:processor_config, %{"api_key" => secret})

    assert {:error, :invalid_processor_config} =
             Derivations.request(ctx.run.id, invalid_config)

    Application.put_env(
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

  test "a lifecycle request rejects queued and already-claimed derivation work", ctx do
    owner = self()

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      fn request ->
        send(owner, :processor_invoked_after_lifecycle_request)
        processor_result(request, "must-not-persist")
      end
    )

    assert {:ok, %{attempt: queued_attempt}} =
             Derivations.request(
               ctx.run.id,
               derivation_request(ctx, ctx.run.generation, "queued-lifecycle", "model-rev-queued")
             )

    bundle = Repo.get!(ContextBundle, ctx.run.context_bundle_id)

    assert {:ok, %{bundle: pending}} =
             ContextLifecycle.request_erasure(bundle.id, %{
               expected_revision: bundle.lifecycle_revision,
               requested_by_user_id: ctx.user.id,
               command_id: Ecto.UUID.generate(),
               reason: "user_request"
             })

    assert pending.lifecycle_state == "erasure_pending"

    assert {:error, :context_lifecycle_not_ready} =
             Derivations.claim(queued_attempt.id, "worker-after-lifecycle")

    refute_receive :processor_invoked_after_lifecycle_request

    assert %SourcedContextDerivationAttempt{status: "pending"} =
             Repo.get!(SourcedContextDerivationAttempt, queued_attempt.id)
  end

  test "a lifecycle request after claim prevents processor invocation", ctx do
    owner = self()

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      fn request ->
        send(owner, :processor_invoked_after_claim)
        processor_result(request, "must-not-persist")
      end
    )

    assert {:ok, %{attempt: attempt}} =
             Derivations.request(
               ctx.run.id,
               derivation_request(
                 ctx,
                 ctx.run.generation,
                 "claimed-lifecycle",
                 "model-rev-claimed"
               )
             )

    assert {:ok, claim} = Derivations.claim(attempt.id, "worker-before-lifecycle")
    bundle = Repo.get!(ContextBundle, ctx.run.context_bundle_id)

    assert {:ok, %{bundle: pending}} =
             ContextLifecycle.request_deletion(bundle.id, %{
               expected_revision: bundle.lifecycle_revision,
               requested_by_user_id: ctx.user.id,
               command_id: Ecto.UUID.generate(),
               reason: "user_request"
             })

    assert pending.lifecycle_state == "deletion_pending"

    assert {:error, :context_lifecycle_not_ready} =
             Derivations.run_claim(claim, processor: Processor)

    refute_receive :processor_invoked_after_claim
    refute Repo.get(SourcedContextDerivation, attempt.id)
  end

  test "a lifecycle request waits for an in-flight processor and then fences its output", ctx do
    bundle = Repo.get!(ContextBundle, ctx.run.context_bundle_id)
    parent = self()

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_derivation_test_handler,
      fn request ->
        send(parent, {:processor_started, self()})

        receive do
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
      Task.async(fn -> Derivations.run_claim(claim, processor: Processor) end)

    assert_receive {:processor_started, processor_pid}, 5_000

    lifecycle_task =
      Task.async(fn ->
        result =
          ContextLifecycle.request_erasure(bundle.id, %{
            expected_revision: bundle.lifecycle_revision,
            requested_by_user_id: ctx.user.id,
            command_id: Ecto.UUID.generate(),
            reason: "user_request"
          })

        send(parent, {:lifecycle_request_returned, self()})
        result
      end)

    refute_receive {:lifecycle_request_returned, _pid}, 100
    send(processor_pid, :release_processor)

    assert {:ok, %{bundle: pending}} = Task.await(lifecycle_task, 5_000)
    assert pending.lifecycle_state == "erasure_pending"

    assert {:error, :context_lifecycle_not_ready} =
             Task.await(derivation_task, 5_000)

    refute Repo.get(SourcedContextDerivation, attempt.id)

    assert Repo.aggregate(
             from(review in SourcedContextReviewRevision, where: review.run_id == ^ctx.run.id),
             :count
           ) == 0
  end

  test "lifecycle pending rejects review revisions without advancing the run", ctx do
    {preview_run, _derivation, review} = derive_preview(ctx, "revise-lifecycle")
    revision_count = Repo.aggregate(SourcedContextReviewRevision, :count)
    bundle = Repo.get!(ContextBundle, preview_run.context_bundle_id)

    assert {:ok, %{bundle: pending}} =
             ContextLifecycle.request_erasure(bundle.id, %{
               expected_revision: bundle.lifecycle_revision,
               requested_by_user_id: ctx.user.id,
               command_id: Ecto.UUID.generate(),
               reason: "user_request"
             })

    assert pending.lifecycle_state == "erasure_pending"

    assert {:error, :context_lifecycle_not_ready} =
             Previews.revise(ctx.run.id, %{
               expected_generation: preview_run.generation,
               user_id: ctx.user.id,
               parent_review_revision_id: review.id,
               items: []
             })

    assert Repo.aggregate(SourcedContextReviewRevision, :count) == revision_count
    assert Repo.get!(SlackHistoryImportRun, ctx.run.id).generation == preview_run.generation
  end

  test "a lifecycle request wins before commit and no publication is created", ctx do
    {preview_run, derivation, review} = derive_preview(ctx, "commit-lifecycle")
    bundle = Repo.get!(ContextBundle, preview_run.context_bundle_id)

    assert {:ok, %{bundle: pending}} =
             ContextLifecycle.request_deletion(bundle.id, %{
               expected_revision: bundle.lifecycle_revision,
               requested_by_user_id: ctx.user.id,
               command_id: Ecto.UUID.generate(),
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

  test "a lost commit response replays its receipt after lifecycle becomes pending", ctx do
    {preview_run, derivation, review} = derive_preview(ctx, "commit-replay-after-lifecycle")

    commit_request = %{
      expected_generation: preview_run.generation,
      user_id: ctx.user.id,
      command_id: "commit-before-lifecycle-replay",
      snapshot_id: ctx.snapshot.id,
      derivation_id: derivation.id,
      review_revision_id: review.id,
      confirmed?: true
    }

    assert {:ok, %{publication: publication, receipt: receipt, replayed?: false}} =
             Publications.commit(ctx.run.id, commit_request)

    bundle = Repo.get!(ContextBundle, preview_run.context_bundle_id)

    assert {:ok, %{bundle: pending}} =
             ContextLifecycle.request_deletion(bundle.id, %{
               expected_revision: bundle.lifecycle_revision,
               requested_by_user_id: ctx.user.id,
               command_id: Ecto.UUID.generate(),
               reason: "user_request"
             })

    assert pending.lifecycle_state == "deletion_pending"

    assert {:ok, %{publication: replayed_publication, receipt: replayed_receipt, replayed?: true}} =
             Publications.commit(ctx.run.id, commit_request)

    assert replayed_publication.id == publication.id
    assert replayed_receipt.id == receipt.id

    assert Repo.aggregate(
             from(row in SourcedContextPublication, where: row.run_id == ^ctx.run.id),
             :count
           ) == 1
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
    suffix = System.unique_integer([:positive])

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
               command_id: Ecto.UUID.generate(),
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
    Application.put_env(
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

  defp commit_canonical_support!(ctx, %{state: "acquired"} = run, ordinal) do
    request_ctx = %{ctx | run: run}

    assert {:ok, %{attempt: attempt}} =
             Derivations.request(
               run.id,
               derivation_request(
                 request_ctx,
                 run.generation,
                 "canonical-derive-#{ordinal}",
                 "canonical-model-v1"
               )
             )

    assert {:ok, %{run: preview, derivation: derivation, review_revision: review}} =
             Derivations.process(attempt.id, "canonical-worker-#{ordinal}", processor: Processor)

    assert {:ok, %{run: committed, publication: publication}} =
             Publications.commit(preview.id, %{
               expected_generation: preview.generation,
               user_id: ctx.user.id,
               command_id: "canonical-commit-#{ordinal}",
               snapshot_id: preview.snapshot_id,
               derivation_id: derivation.id,
               review_revision_id: review.id,
               confirmed?: true
             })

    %{run: committed, publication: publication}
  end

  defp commit_canonical_support!(ctx, run, ordinal) do
    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(run.id, run.generation)

    assert {:ok, _receipt} =
             Acquisition.accept_page(run.id, acquiring.generation, source_page(acquiring))

    assert {:ok, acquired, _snapshot} =
             Acquisition.finalize_snapshot(run.id, acquiring.generation,
               normalization_revision: "slack-normalization:test:v1"
             )

    commit_canonical_support!(ctx, acquired, ordinal)
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

  defp cross_kind_identity_result(request) do
    [first | _] = request.objects

    {:ok,
     %{
       artifacts: [
         %{
           kind: :person,
           stable_key: "atlas",
           payload: %{"name" => "Atlas", "aliases" => []},
           confidence_millis: 900,
           source_object_ids: [first.id]
         },
         %{
           kind: :project,
           stable_key: "atlas",
           payload: %{"name" => "Atlas", "aliases" => []},
           confidence_millis: 900,
           source_object_ids: [first.id]
         },
         %{
           kind: :decision,
           stable_key: "launch",
           payload: %{
             "content" => "Atlas is approved",
             "about" => [
               %{"kind" => "person", "stable_key" => "atlas"},
               %{"kind" => "project", "stable_key" => "atlas"}
             ]
           },
           confidence_millis: 900,
           source_object_ids: [first.id]
         }
       ],
       warnings: %{}
     }}
  end

  defp processor_output_bounds do
    [
      max_artifacts: 100,
      max_sources_per_artifact: 20,
      max_payload_bytes: 8_000,
      max_warnings_bytes: 16_384
    ]
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
      client_request_id: Ecto.UUID.generate(),
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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
