defmodule BridgeForTeams.ContextLifecycleReadBarrierTest do
  @moduledoc """
  The lifecycle visibility fence needs two real PostgreSQL transactions; a
  shared SQL-sandbox connection would serialize for unrelated reasons and
  could not prove the row-lock contract.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias BridgeForTeams.ContextLifecycle.{Deadlines, Operations, ReadBarrier}
  alias BridgeForTeams.Repo
  alias BridgeForTeams.SourcedContext.{Grounding, Payloads, Publications}

  alias BridgeForTeams.Schema.{
    Agent,
    AuditLog,
    ContextBundle,
    ContextLifecycleRequest,
    Organization,
    OrgMembership,
    ObservabilityEvent,
    Project,
    SlackHistoryImportRun,
    SourcedContextArtifact,
    SourcedContextArtifactSource,
    SourcedContextDerivation,
    SourcedContextObject,
    SourcedContextPublication,
    SourcedContextReviewItem,
    SourcedContextReviewRevision,
    SourcedContextSnapshot,
    User
  }

  test "transaction deadlines cannot drift below the processor bound" do
    previous_lifecycle =
      Application.get_env(:bridge_for_teams_core, :context_lifecycle_bounds, [])

    previous_sourced = Application.get_env(:bridge_for_teams_core, :sourced_context_bounds, [])

    Application.put_env(
      :bridge_for_teams_core,
      :context_lifecycle_bounds,
      read_barrier_transaction_timeout_ms: 1_000,
      lifecycle_request_transaction_timeout_ms: 1_000
    )

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_bounds,
      processor_timeout_ms: 20_000
    )

    try do
      assert Deadlines.read_barrier_transaction_timeout_ms() == 25_000
      assert Deadlines.lifecycle_request_transaction_timeout_ms() == 30_000
    after
      Application.put_env(
        :bridge_for_teams_core,
        :context_lifecycle_bounds,
        previous_lifecycle
      )

      Application.put_env(:bridge_for_teams_core, :sourced_context_bounds, previous_sourced)
    end
  end

  test "a lifecycle update cannot return while an authorized context read is active" do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    suffix = System.unique_integer([:positive])

    org =
      %Organization{}
      |> Organization.changeset(%{
        name: "Context read barrier #{suffix}",
        slug: "context-read-barrier-#{suffix}",
        billing_account_id: "context-read-barrier-ba-#{suffix}",
        salix_tenant_id: "context-read-barrier-tenant-#{suffix}"
      })
      |> Repo.insert!()

    bundle =
      %ContextBundle{}
      |> ContextBundle.registration_changeset(%{
        org_id: org.id,
        source_type: "read_barrier_test",
        source_ref: "bundle-#{suffix}",
        classification: "internal",
        policy_ref: "context-policy-v1"
      })
      |> Repo.insert!()
      |> ContextBundle.lifecycle_changeset(%{
        lifecycle_state: "registered",
        subject_index_state: "complete",
        lifecycle_revision: 0
      })
      |> Repo.update!()

    parent = self()

    reader =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        try do
          ReadBarrier.run([bundle.id], fn ->
            send(parent, {:context_read_locked, self()})

            receive do
              :release_context_read -> :plaintext_returned
            end
          end)
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Repo)
        end
      end)

    try do
      assert_receive {:context_read_locked, reader_pid}, 5_000

      updater =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            current = Repo.get!(ContextBundle, bundle.id)
            send(parent, {:lifecycle_update_started, self()})

            result =
              current
              |> ContextBundle.lifecycle_changeset(%{
                lifecycle_state: "erasure_pending",
                subject_index_state: "complete",
                lifecycle_revision: 1
              })
              |> Repo.update()

            send(parent, {:lifecycle_update_completed, self()})
            result
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end)

      assert_receive {:lifecycle_update_started, updater_pid}, 5_000
      refute_receive {:lifecycle_update_completed, ^updater_pid}, 100

      send(reader_pid, :release_context_read)
      assert Task.await(reader, 5_000) == :plaintext_returned

      assert {:ok, %ContextBundle{lifecycle_state: "erasure_pending"}} =
               Task.await(updater, 5_000)

      assert_receive {:lifecycle_update_completed, ^updater_pid}

      assert ReadBarrier.run([bundle.id], fn -> :must_not_run end) ==
               {:error, :context_lifecycle_not_ready}
    after
      send(reader.pid, :release_context_read)
      Repo.delete_all(from(row in ContextBundle, where: row.id == ^bundle.id))
      Repo.delete!(org)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end

  test "rollback cannot return while an authorized context read is active" do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    fixture = committed_publication_fixture!()
    parent = self()

    reader =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        try do
          ReadBarrier.run([fixture.bundle.id], fn ->
            send(parent, {:publication_read_locked, self()})

            receive do
              :release_publication_read -> :plaintext_returned
            end
          end)
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Repo)
        end
      end)

    try do
      assert_receive {:publication_read_locked, reader_pid}, 5_000

      rollback =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            send(parent, {:rollback_started, self()})

            Publications.rollback(fixture.run.id, %{
              expected_generation: fixture.run.generation,
              user_id: fixture.user.id,
              command_id: "read-barrier-rollback-#{fixture.suffix}",
              reason: "test_rollback"
            })
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end)

      assert_receive {:rollback_started, rollback_pid}, 5_000
      refute_receive {:DOWN, _ref, :process, ^rollback_pid, _reason}, 100

      send(reader_pid, :release_publication_read)
      assert Task.await(reader, 5_000) == :plaintext_returned

      assert {:ok, %{publication: %SourcedContextPublication{status: "inactive"}}} =
               Task.await(rollback, 5_000)
    after
      send(reader.pid, :release_publication_read)
      cleanup_publication_fixture(fixture)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end

  test "a lifecycle request waits past the database default timeout for a bounded context read" do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    fixture = committed_publication_fixture!()
    parent = self()

    reader =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        try do
          ReadBarrier.run([fixture.bundle.id], fn ->
            send(parent, {:long_context_read_locked, self()})

            receive do
              :release_long_context_read -> :plaintext_returned
            end
          end)
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Repo)
        end
      end)

    try do
      assert_receive {:long_context_read_locked, reader_pid}, 5_000

      request =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            Operations.request_erasure(fixture.bundle.id, %{
              requested_by_user_id: fixture.user.id,
              command_id: Ecto.UUID.generate(),
              reason: "user_request",
              expected_revision: fixture.bundle.lifecycle_revision
            })
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end)

      request_ref = request.ref
      refute_receive {^request_ref, _result}, 15_250
      refute_receive {:DOWN, ^request_ref, :process, _pid, _reason}, 0

      send(reader_pid, :release_long_context_read)
      assert Task.await(reader, 5_000) == :plaintext_returned

      assert {:ok,
              %{
                bundle: %ContextBundle{lifecycle_state: "erasure_pending"},
                request: %ContextLifecycleRequest{state: "pending"}
              }} = Task.await(request, 5_000)
    after
      send(reader.pid, :release_long_context_read)
      cleanup_publication_fixture(fixture)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end

  defmodule AgentReader do
    def get_agent("publication-barrier-agent-" <> suffix = agent_id, _tenant_id) do
      {:ok,
       %{
         "agent_id" => agent_id,
         "group_id" => "publication-barrier-group-#{suffix}",
         "role" => "router",
         "name" => "Publication barrier agent"
       }}
    end
  end

  test "Knowledge materialization remains inside the lifecycle read barrier" do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, AgentReader)
    on_exit(fn -> Application.put_env(:bridge_for_teams_core, :salix_client, previous_client) end)
    Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    fixture = committed_publication_fixture!()
    parent = self()
    features = Application.fetch_env!(:bridge_for_teams_core, :sourced_context_features)

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :knowledge_inspection, true)
    )

    reader =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        try do
          Grounding.list_active_context_for_agent(fixture.agent.id, fixture.user.id,
            candidate_projection_observer: fn candidates ->
              send(parent, {:knowledge_projection_locked, self(), length(candidates)})

              receive do
                :release_knowledge_projection -> :ok
              end
            end
          )
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Repo)
        end
      end)

    try do
      assert_receive {:knowledge_projection_locked, reader_pid, 1}, 5_000

      request =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            send(parent, {:knowledge_erasure_started, self()})

            Operations.request_erasure(fixture.bundle.id, %{
              requested_by_user_id: fixture.user.id,
              command_id: Ecto.UUID.generate(),
              reason: "user_request",
              expected_revision: fixture.bundle.lifecycle_revision
            })
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end)

      assert_receive {:knowledge_erasure_started, request_pid}, 5_000
      request_ref = request.ref
      refute_receive {^request_ref, _result}, 100
      refute_receive {:DOWN, ^request_ref, :process, ^request_pid, _reason}, 0

      send(reader_pid, :release_knowledge_projection)

      assert {:ok, %{items: [%{kind: :person, name: "Peng"}]}} = Task.await(reader, 5_000)

      assert {:ok,
              %{
                bundle: %ContextBundle{lifecycle_state: "erasure_pending"},
                request: %ContextLifecycleRequest{state: "pending"}
              }} = Task.await(request, 5_000)
    after
      send(reader.pid, :release_knowledge_projection)
      Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)
      cleanup_publication_fixture(fixture)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end

  defp committed_publication_fixture! do
    suffix = System.unique_integer([:positive])
    now = DateTime.utc_now()
    run_id = Ecto.UUID.generate()

    org =
      %Organization{}
      |> Organization.changeset(%{
        name: "Publication barrier #{suffix}",
        slug: "publication-barrier-#{suffix}",
        billing_account_id: "publication-barrier-ba-#{suffix}",
        salix_tenant_id: "publication-barrier-tenant-#{suffix}"
      })
      |> Repo.insert!()

    user =
      %User{}
      |> User.changeset(%{
        email: "publication-barrier-#{suffix}@example.test",
        name: "Publication barrier owner"
      })
      |> Repo.insert!()

    membership =
      %OrgMembership{}
      |> OrgMembership.changeset(%{org_id: org.id, user_id: user.id, role: "owner"})
      |> Repo.insert!()

    project =
      %Project{}
      |> Project.changeset(%{
        org_id: org.id,
        created_by_user_id: user.id,
        name: "Publication barrier",
        slug: "publication-barrier-#{suffix}",
        salix_group_id: "publication-barrier-group-#{suffix}"
      })
      |> Repo.insert!()

    agent =
      %Agent{}
      |> Agent.changeset(%{
        project_id: project.id,
        salix_agent_id: "publication-barrier-agent-#{suffix}",
        role: "router",
        name: "Publication barrier agent"
      })
      |> Repo.insert!()

    bundle =
      %ContextBundle{}
      |> ContextBundle.registration_changeset(%{
        org_id: org.id,
        project_id: project.id,
        source_type: "slack_history_import",
        source_ref: run_id,
        classification: "internal",
        policy_ref: "context-lifecycle:v1"
      })
      |> Repo.insert!()
      |> ContextBundle.lifecycle_changeset(%{
        lifecycle_state: "registered",
        subject_index_state: "complete",
        lifecycle_revision: 0
      })
      |> Repo.update!()

    run =
      %SlackHistoryImportRun{id: run_id}
      |> SlackHistoryImportRun.create_changeset(%{
        org_id: org.id,
        project_id: project.id,
        requested_by_user_id: user.id,
        client_request_id: Ecto.UUID.generate(),
        salix_tenant_id: org.salix_tenant_id,
        salix_group_id: project.salix_group_id,
        source_workspace_id: "T_PUBLICATION_BARRIER",
        source_app_id: "A_PUBLICATION_BARRIER",
        connect_id: "publication-barrier-connect-#{suffix}",
        connect_generation: "generation-1",
        range_start: DateTime.add(now, -86_400, :second),
        range_end: now,
        policy_revision: "context-lifecycle:v1",
        coverage_profile: "slack-root-bounded:v1",
        audience_scope: "project-public-channels:v1"
      })
      |> Repo.insert!()
      |> SlackHistoryImportRun.transition_changeset(%{
        state: "acquired",
        generation: 1,
        context_bundle_id: bundle.id
      })
      |> Repo.update!()

    snapshot =
      %SourcedContextSnapshot{}
      |> SourcedContextSnapshot.changeset(%{
        run_id: run.id,
        normalization_revision: "publication-barrier:v1",
        coverage_profile: run.coverage_profile,
        manifest_sha256: String.duplicate("a", 64),
        object_count: 1,
        byte_count: 0,
        coverage: %{"complete" => true},
        started_at: now,
        finalized_at: now,
        created_at: now
      })
      |> Repo.insert!()

    source_object =
      %SourcedContextObject{}
      |> SourcedContextObject.changeset(%{
        run_id: run.id,
        workspace_id: run.source_workspace_id,
        channel_id: "C_PUBLICATION_BARRIER",
        message_ts: "1.000001",
        observable_version: "fixture:v1",
        payload_ciphertext: "fixture-source-payload",
        payload_sha256: String.duplicate("d", 64),
        byte_count: 0,
        observed_at: now,
        created_at: now
      })
      |> Repo.insert!()

    derivation =
      %SourcedContextDerivation{}
      |> SourcedContextDerivation.changeset(%{
        run_id: run.id,
        snapshot_id: snapshot.id,
        model_provider: "fixture",
        model_id: "fixture-model",
        model_revision: "fixture-model-v1",
        prompt_template_id: "publication-barrier",
        prompt_revision: "publication-barrier-v1",
        policy_revision: "publication-barrier-v1",
        schema_revision: "publication-barrier-v1",
        processor_config: %{},
        output_sha256: String.duplicate("b", 64),
        artifact_count: 1,
        warnings: %{},
        created_at: now,
        completed_at: now
      })
      |> Repo.insert!()

    artifact_id = Ecto.UUID.generate()

    {:ok, artifact_payload} =
      Payloads.seal(:artifact, artifact_id, %{"name" => "Peng", "aliases" => []})

    artifact =
      %SourcedContextArtifact{id: artifact_id}
      |> SourcedContextArtifact.changeset(%{
        derivation_id: derivation.id,
        kind: "person",
        stable_key: "person:peng",
        payload_ciphertext: artifact_payload.ciphertext,
        payload_sha256: artifact_payload.sha256,
        confidence_millis: 950,
        created_at: now
      })
      |> Repo.insert!()

    artifact_source =
      %SourcedContextArtifactSource{}
      |> SourcedContextArtifactSource.changeset(%{
        artifact_id: artifact.id,
        source_object_id: source_object.id,
        created_at: now
      })
      |> Repo.insert!()

    review =
      %SourcedContextReviewRevision{}
      |> SourcedContextReviewRevision.changeset(%{
        run_id: run.id,
        snapshot_id: snapshot.id,
        derivation_id: derivation.id,
        revision: 1,
        created_by_user_id: user.id,
        selection_sha256: String.duplicate("c", 64),
        selected_count: 1,
        created_at: now
      })
      |> Repo.insert!()

    review_item_id = Ecto.UUID.generate()

    {:ok, review_payload} =
      Payloads.seal(:review_item, review_item_id, %{"name" => "Peng", "aliases" => []})

    review_item =
      %SourcedContextReviewItem{id: review_item_id}
      |> SourcedContextReviewItem.changeset(%{
        review_revision_id: review.id,
        artifact_id: artifact.id,
        kind: artifact.kind,
        payload_ciphertext: review_payload.ciphertext,
        payload_sha256: review_payload.sha256,
        created_at: now
      })
      |> Repo.insert!()

    publication_id = Ecto.UUID.generate()

    publication =
      %SourcedContextPublication{id: publication_id}
      |> SourcedContextPublication.active_changeset(%{
        id: publication_id,
        run_id: run.id,
        bundle_id: bundle.id,
        review_revision_id: review.id,
        status: "active",
        audience_scope: run.audience_scope,
        committed_by_user_id: user.id,
        commit_command_id: "publication-barrier-commit-#{suffix}",
        activated_at: now
      })
      |> Repo.insert!()

    run =
      run
      |> SlackHistoryImportRun.transition_changeset(%{
        state: "committed",
        generation: 5,
        snapshot_id: snapshot.id,
        derivation_id: derivation.id,
        review_revision_id: review.id,
        publication_id: publication.id,
        commit_base_generation: 4,
        context_bundle_id: bundle.id
      })
      |> Repo.update!()

    %{
      suffix: suffix,
      org: org,
      user: user,
      membership: membership,
      project: project,
      agent: agent,
      bundle: bundle,
      run: run,
      snapshot: snapshot,
      source_object: source_object,
      derivation: derivation,
      artifact: artifact,
      artifact_source: artifact_source,
      review: review,
      review_item: review_item,
      publication: publication
    }
  end

  defp cleanup_publication_fixture(fixture) do
    Repo.delete_all(from(event in ObservabilityEvent, where: event.org_id == ^fixture.org.id))
    Repo.delete_all(from(log in AuditLog, where: log.org_id == ^fixture.org.id))

    Repo.delete_all(
      from(request in ContextLifecycleRequest, where: request.bundle_id == ^fixture.bundle.id)
    )

    Repo.delete_all(from(row in SourcedContextPublication, where: row.run_id == ^fixture.run.id))

    Repo.delete_all(
      from(row in SourcedContextReviewItem, where: row.id == ^fixture.review_item.id)
    )

    Repo.delete_all(
      from(row in SourcedContextReviewRevision, where: row.id == ^fixture.review.id)
    )

    Repo.delete_all(
      from(row in SourcedContextArtifactSource, where: row.id == ^fixture.artifact_source.id)
    )

    Repo.delete_all(from(row in SourcedContextArtifact, where: row.id == ^fixture.artifact.id))

    Repo.delete_all(
      from(row in SourcedContextDerivation, where: row.id == ^fixture.derivation.id)
    )

    Repo.delete_all(from(row in SourcedContextObject, where: row.id == ^fixture.source_object.id))

    Repo.delete_all(from(row in SourcedContextSnapshot, where: row.id == ^fixture.snapshot.id))
    Repo.delete_all(from(row in SlackHistoryImportRun, where: row.id == ^fixture.run.id))
    Repo.delete_all(from(row in ContextBundle, where: row.id == ^fixture.bundle.id))
    Repo.delete!(fixture.agent)
    Repo.delete!(fixture.project)
    Repo.delete!(fixture.membership)
    Repo.delete!(fixture.org)
    Repo.delete!(fixture.user)
  end
end
