defmodule BridgeForTeams.ContextLifecycleDeletionTest do
  use BridgeForTeams.DataCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{Accounts, ContextLifecycle, Memberships, Orgs, Projects, Repo}

  alias BridgeForTeams.Schema.{
    AuditLog,
    ContextBundle,
    ContextBundleSubject,
    ContextLifecycleEvidence,
    ContextLifecycleRequest
  }

  defmodule Purger do
    def purge(_bundle) do
      case Application.get_env(:bridge_for_teams_core, :context_lifecycle_test_purger) do
        fun when is_function(fun, 1) -> fun.(:purge)
        _ -> {:ok, %{rows_deleted: 3, payloads_deleted: 2}}
      end
    end
  end

  setup do
    previous = Application.get_env(:bridge_for_teams_core, :context_lifecycle_test_purger)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:bridge_for_teams_core, :context_lifecycle_test_purger)
      else
        Application.put_env(:bridge_for_teams_core, :context_lifecycle_test_purger, previous)
      end
    end)

    suffix = System.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{"name" => "Lifecycle #{suffix}", "slug" => "lifecycle-#{suffix}"})

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "lifecycle-#{suffix}@example.test",
        "name" => "Lifecycle owner"
      })

    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

    {:ok, project} =
      Projects.create_project(
        org.id,
        %{"name" => "Lifecycle project", "slug" => "lifecycle-project-#{suffix}"},
        creator_user_id: user.id
      )

    {:ok, bundle} =
      ContextLifecycle.register_bundle(%{
        org_id: org.id,
        project_id: project.id,
        source_type: "meeting_transcript",
        source_ref: "meeting:#{suffix}",
        classification: "project_context",
        policy_ref: "context-lifecycle:test:v1",
        subjects: [
          %{kind: "organization", ref: org.id},
          %{kind: "project", ref: project.id},
          %{kind: "user", ref: user.id}
        ]
      })

    %{org: org, project: project, user: user, bundle: bundle}
  end

  test "deletion request is idempotent and can be restored before purge starts", ctx do
    request = deletion_request(ctx, Ecto.UUID.generate(), "user_request")

    assert {:ok, %{bundle: pending, request: deletion, replayed?: false}} =
             ContextLifecycle.request_deletion(ctx.bundle.id, request)

    assert pending.lifecycle_state == "deletion_pending"
    assert pending.lifecycle_revision == 1
    assert deletion.state == "pending"
    assert deletion.kind == "deletion"

    assert {:ok, %{request: readable, evidence: nil}} =
             ContextLifecycle.get_request(deletion.id, ctx.user.id)

    assert readable.id == deletion.id

    assert {:ok, %{bundles: [covered], completeness: :complete, truncated?: false}} =
             ContextLifecycle.list_bundles_for_subject(
               ctx.org.id,
               "user",
               ctx.user.id,
               ctx.user.id
             )

    assert covered.id == ctx.bundle.id

    assert {:ok, %{request: replayed, replayed?: true}} =
             ContextLifecycle.request_deletion(ctx.bundle.id, request)

    assert replayed.id == deletion.id

    assert {:error, :command_id_conflict} =
             ContextLifecycle.request_deletion(
               ctx.bundle.id,
               %{request | reason: "retention_expired"}
             )

    restore = %{
      expected_revision: pending.lifecycle_revision,
      requested_by_user_id: ctx.user.id,
      command_id: Ecto.UUID.generate(),
      reason: "request_submitted_in_error"
    }

    assert {:ok, %{bundle: restored, request: canceled, replayed?: false}} =
             ContextLifecycle.restore(ctx.bundle.id, restore)

    assert restored.lifecycle_state == "registered"
    assert restored.lifecycle_revision == 2
    assert canceled.state == "canceled"

    assert {:ok, %{bundle: replay_bundle, request: replay_request, replayed?: true}} =
             ContextLifecycle.restore(ctx.bundle.id, restore)

    assert replay_bundle.lifecycle_revision == restored.lifecycle_revision
    assert replay_request.id == canceled.id
    assert Repo.aggregate(ContextBundleSubject, :count) == 3

    assert MapSet.subset?(
             MapSet.new([
               "context.lifecycle.deletion_requested",
               "context.lifecycle.restored"
             ]),
             audit_actions(ctx.org.id)
           )
  end

  test "lifecycle commands retain only opaque identifiers and finite reason codes", ctx do
    assert {:error, :invalid_lifecycle_command_id} =
             ContextLifecycle.request_deletion(ctx.bundle.id, %{
               expected_revision: ctx.bundle.lifecycle_revision,
               requested_by_user_id: ctx.user.id,
               command_id: "delete Peng's private Slack history",
               reason: "user_request"
             })

    assert {:error, :invalid_lifecycle_reason} =
             ContextLifecycle.request_deletion(ctx.bundle.id, %{
               expected_revision: ctx.bundle.lifecycle_revision,
               requested_by_user_id: ctx.user.id,
               command_id: Ecto.UUID.generate(),
               reason: "delete Peng's private Slack history"
             })

    assert {:ok, %{request: request}} =
             ContextLifecycle.request_deletion(
               ctx.bundle.id,
               deletion_request(ctx, Ecto.UUID.generate(), "retention_expired")
             )

    assert Ecto.UUID.cast(request.command_id) == {:ok, request.command_id}
    assert request.reason == "retention_expired"
    refute inspect(request) =~ "private Slack history"
  end

  test "shared worker fences leases and leaves a source-neutral tombstone", ctx do
    assert {:ok, %{bundle: pending, request: request}} =
             ContextLifecycle.request_erasure(
               ctx.bundle.id,
               deletion_request(ctx, Ecto.UUID.generate(), "user_request")
             )

    assert pending.lifecycle_state == "erasure_pending"

    assert {:error, :bundle_not_writable} =
             ContextLifecycle.add_subjects(ctx.bundle.id, [%{kind: "user", ref: "late"}])

    assert {:ok, claim} = ContextLifecycle.claim(request.id, "lifecycle-worker-1")
    assert claim.lease_generation == 1

    assert {:error, {:lifecycle_request_lease_held, _expires_at}} =
             ContextLifecycle.claim(request.id, "lifecycle-worker-2")

    assert {:ok, %{bundle: deleted, request: completed, evidence: evidence}} =
             ContextLifecycle.run_claim(claim, purger: Purger)

    assert deleted.lifecycle_state == "deleted"
    assert deleted.lifecycle_revision == 2
    assert completed.state == "completed"
    assert evidence.request_id == completed.id
    assert evidence.source_type == "meeting_transcript"

    assert evidence.counts == %{
             "payloads_deleted" => 2,
             "rows_deleted" => 3,
             "subject_index_rows_deleted" => 3
           }

    assert Repo.aggregate(ContextBundleSubject, :count) == 0

    assert %ContextBundle{} = Repo.get!(ContextBundle, ctx.bundle.id)

    assert %ContextLifecycleEvidence{} =
             Repo.get_by!(ContextLifecycleEvidence, request_id: request.id)

    assert "context.lifecycle.purge_completed" in audit_actions(ctx.org.id)

    assert {:error, :stale_lifecycle_lease} =
             ContextLifecycle.run_claim(%{claim | lease_generation: 0}, purger: Purger)
  end

  test "a purge that returns after lease expiry rolls back and emits no completion evidence",
       ctx do
    previous_bounds =
      Application.get_env(:bridge_for_teams_core, :context_lifecycle_bounds, [])

    Application.put_env(
      :bridge_for_teams_core,
      :context_lifecycle_bounds,
      Keyword.put(previous_bounds, :context_lifecycle_lease_ms, 1_000)
    )

    on_exit(fn ->
      Application.put_env(:bridge_for_teams_core, :context_lifecycle_bounds, previous_bounds)
    end)

    Application.put_env(
      :bridge_for_teams_core,
      :context_lifecycle_test_purger,
      fn :purge ->
        Process.sleep(1_100)
        {:ok, %{rows_deleted: 3, payloads_deleted: 2}}
      end
    )

    assert {:ok, %{request: request}} =
             ContextLifecycle.request_erasure(
               ctx.bundle.id,
               deletion_request(ctx, Ecto.UUID.generate(), "user_request")
             )

    assert {:ok, claim} = ContextLifecycle.claim(request.id, "lease-expiry-worker")

    assert {:error, :stale_lifecycle_lease} =
             ContextLifecycle.run_claim(claim, purger: Purger)

    assert %ContextLifecycleRequest{state: "processing", lease_owner: "lease-expiry-worker"} =
             Repo.get!(ContextLifecycleRequest, request.id)

    refute Repo.get_by(ContextLifecycleEvidence, request_id: request.id)
    assert Repo.aggregate(ContextBundleSubject, :count) == 3
    assert Repo.get!(ContextBundle, ctx.bundle.id).lifecycle_state == "erasure_pending"
  end

  test "transactional purge failure persists retry state and remains recoverable", ctx do
    Application.put_env(
      :bridge_for_teams_core,
      :context_lifecycle_test_purger,
      fn :purge -> {:error, :storage_temporarily_unavailable} end
    )

    assert {:ok, %{request: request}} =
             ContextLifecycle.request_deletion(
               ctx.bundle.id,
               deletion_request(ctx, Ecto.UUID.generate(), "retention_expired")
             )

    assert {:ok, claim} = ContextLifecycle.claim(request.id, "lifecycle-worker-retry")

    assert {:ok, %{bundle: pending, request: retrying, outcome: :retry_scheduled}} =
             ContextLifecycle.run_claim(claim, purger: Purger)

    assert pending.lifecycle_state == "deletion_pending"
    assert retrying.state == "retry_wait"
    assert retrying.retry_count == 1
    assert retrying.retry_not_before != nil
    refute Repo.exists?(from(evidence in ContextLifecycleEvidence, select: evidence.id))

    restore = %{
      expected_revision: pending.lifecycle_revision,
      requested_by_user_id: ctx.user.id,
      command_id: Ecto.UUID.generate(),
      reason: "request_submitted_in_error"
    }

    assert {:ok, %{bundle: restored, request: canceled}} =
             ContextLifecycle.restore(ctx.bundle.id, restore)

    assert restored.lifecycle_state == "registered"
    assert canceled.state == "canceled"
  end

  test "source adapter error text is reduced to a finite content-free class", ctx do
    secret = "Peng private Slack text must never be audit metadata"

    Application.put_env(
      :bridge_for_teams_core,
      :context_lifecycle_test_purger,
      fn :purge -> {:error, secret} end
    )

    assert {:ok, %{request: request}} =
             ContextLifecycle.request_deletion(
               ctx.bundle.id,
               deletion_request(ctx, Ecto.UUID.generate(), "user_request")
             )

    assert {:ok, claim} = ContextLifecycle.claim(request.id, "redacting-purger")

    assert {:ok, %{bundle: pending, request: retrying, outcome: :retry_scheduled}} =
             ContextLifecycle.run_claim(claim, purger: Purger)

    assert pending.last_error == "unknown"
    assert retrying.last_error_class == "unknown"

    stored_request = Repo.get!(ContextLifecycleRequest, request.id)
    stored_bundle = Repo.get!(ContextBundle, ctx.bundle.id)

    persisted =
      Jason.encode!(%{
        request: %{
          command_id: stored_request.command_id,
          reason: stored_request.reason,
          last_error_class: stored_request.last_error_class
        },
        bundle: %{
          lifecycle_state: stored_bundle.lifecycle_state,
          last_error: stored_bundle.last_error
        },
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

  test "source adapter count labels are a fixed schema", ctx do
    secret_key = "Peng private Slack count"

    Application.put_env(
      :bridge_for_teams_core,
      :context_lifecycle_test_purger,
      fn :purge -> {:ok, %{secret_key => 1}} end
    )

    assert {:ok, %{request: request}} =
             ContextLifecycle.request_erasure(
               ctx.bundle.id,
               deletion_request(ctx, Ecto.UUID.generate(), "user_request")
             )

    assert {:ok, claim} = ContextLifecycle.claim(request.id, "count-schema-purger")

    assert {:ok, %{request: failed, outcome: :failed_terminal}} =
             ContextLifecycle.run_claim(claim, purger: Purger)

    assert failed.last_error_class == "invalid_purge_counts"
    refute Repo.get_by(ContextLifecycleEvidence, request_id: request.id)

    refute Jason.encode!(%{reason: failed.reason, last_error_class: failed.last_error_class}) =~
             secret_key
  end

  defp deletion_request(ctx, command_id, reason) do
    %{
      expected_revision: ctx.bundle.lifecycle_revision,
      requested_by_user_id: ctx.user.id,
      command_id: command_id,
      reason: reason
    }
  end

  defp audit_actions(org_id) do
    Repo.all(
      from(audit in AuditLog,
        where: audit.org_id == ^org_id,
        select: audit.action
      )
    )
    |> MapSet.new()
  end
end
