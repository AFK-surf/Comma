defmodule SalixStore.RepoTestSetup do
  @moduledoc """
  Test-only bring-up for `SalixStore.Repo` (the S3.Fake of the Postgres side).

  Suites whose tests touch salix control tables call `ensure!/0` from their
  `test_helper.exs`: it creates the test database when missing, starts the
  repo, runs the expand migrations, and seeds the **cutover marker** so the
  baseline is a migrated (ready) node — empty key rows plus the marker row.
  This mirrors a deployed node: the request path never mints the marker (only
  the release ceremony / `Comma.Release.migrate/0` do), and readiness
  (`Comma.PodLifecycle.ready(:salix)` via `SalixStore.TenantApiKeyReadiness`)
  keeps an unmigrated pod out of service. Cutover-flow tests explicitly delete
  the marker to exercise the un-migrated state. Never started in production.
  """

  alias SalixStore.Repo

  @spec ensure!() :: :ok
  def ensure! do
    {:ok, _} = Application.ensure_all_started(:salix_store)
    config = Repo.config()

    case Repo.__adapter__().storage_up(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "salix_store_test database create failed: #{inspect(reason)}"
    end

    unless Process.whereis(Repo) do
      {:ok, pid} = Repo.start_link()
      Process.unlink(pid)
    end

    # The app may have started the repo before this ran (test config sets
    # :start_repo), in which case its pool spent the boot failing against a
    # database that did not exist yet. Wait for the reconnect before migrating.
    await_connection!(50)

    # Only the expand migrations. The cutover lives in priv/release_migrations
    # and calls run/0 against S3 — driving it from here would couple every
    # suite's baseline to the shared Fake bucket's state. The steady-state
    # marker is seeded directly instead.
    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:salix_store, "priv/repo/migrations"),
      :up,
      all: true
    )

    Repo.query!(
      "TRUNCATE runtime_subscription_bindings, meeting_calendar_settings, triage_record_body_sizes, subscription_accounts, subscription_oauth_attempts"
    )

    Repo.query!(
      "TRUNCATE triage_product_effect_attempts, triage_companion_reaction_obligations, triage_product_obligations, triage_context_entries, triage_patrol_cursors"
    )

    Repo.query!(
      "TRUNCATE conversation_log_recovery, conversation_search_gc_runs, conversation_search_backfill_runs, " <>
        "conversation_search_discovery_cursors"
    )

    Repo.query!(
      "TRUNCATE ifc_scope_labels, ifc_tag_clearances, ifc_principal_facts, ifc_scope_facts, ifc_scope_members, ifc_receipts, slack_mirror_outbox, slack_mirror_channel_watermarks, slack_mirror_backfill_connects, conversation_search_jobs, conversation_search_states, slack_triage_thread_subscriptions, slack_triage_channels, triage_projection_obligations, triage_recovery_leases, triage_intent_settlements, triage_late_results, triage_lifecycle_events, triage_activity_index_entries, triage_time_index_entries, triage_correlation_entries, triage_replays, triage_runs, triage_run_fences, triage_buckets, triage_bucket_memberships, triage_recipient_aliases, triage_ambient_aliases, triage_receipt_projections, meeting_group_projections, slack_router_thread_participations, local_file_refs, calendar_feed_subscriptions, compute_migration_items, compute_migration_runs, service_route_audit, service_routes, service_imports, service_exports, personal_mesh_registry_audit, personal_mesh_rate_buckets, personal_mesh_endpoints, personal_mesh_operations, personal_mesh_invites, personal_mesh_tombstones, personal_mesh_members, personal_meshes, compute_runtime_inputs, compute_runtime_release, compute_reconciler_claims, compute_reconciler_cursors, agent_vmm_audit_events, agent_vmm_sessions, external_worker_operations, external_worker_bindings, compute_commands, compute_grants, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_route_capabilities, agent_vmm_membership_credentials, agent_vmm_trust_anchors, agent_vmm_registrations, tenant_api_keys, composio_settings, feishu_tenant_apps, tenant_configs, schedules, schedule_runs, agent_loops, agent_loop_acks, oauth_provider_apps, session_work_candidates, session_work_backfill_expected_candidates, session_work_backfill_state CASCADE"
    )

    # Seed the terminal cutover markers so the baseline is a fully-migrated
    # (ready) node — one marker per migrated dataset. Names match each cutover
    # module's @marker_name.
    Repo.query!("""
    INSERT INTO salix_cutover_markers (name, completed_at, evidence)
    VALUES
      ('group_compute_authority_v1', now(), '{"phase":"complete"}'::jsonb),
      ('agent_configuration_writers_v1', now(), '{"phase":"complete"}'::jsonb),
      ('tenant_api_keys_v1', now(), '{"mode":"test-baseline"}'::jsonb),
      ('provider_credentials_v1', now(), '{"mode":"test-baseline"}'::jsonb),
      ('tenant_configs_v1', now(), '{"mode":"test-baseline"}'::jsonb),
      ('schedules_v1', now(), '{"mode":"test-baseline"}'::jsonb),
      ('meeting_group_projection_v1', now(), '{"mode":"test-baseline"}'::jsonb),
      ('conversation_search_projection_v1', now(), '{"mode":"test-baseline","writer_generation":"test-search-generation"}'::jsonb),
      ('slack_triage_channels_v1', now(), '{"mode":"test-baseline"}'::jsonb),
      ('oauth_apps_v1', now(), '{"mode":"test-baseline"}'::jsonb),
      ('internal_session_format2_v1', now(), '{"mode":"test-baseline"}'::jsonb),
      ('session_work_candidates_v1', now(), '{"mode":"test-baseline","uncovered_authoritative_work":0}'::jsonb)
    ON CONFLICT (name) DO NOTHING
    """)

    Repo.query!("""
    INSERT INTO conversation_search_backfill_runs
      (writer_generation, writer_barrier_authority, writer_barrier_at,
       required_discovery_cycle, sealed_at, inserted_at, updated_at)
    VALUES
      ('test-search-generation', 'test-fixture', now(), 1, now(), now(), now())
    ON CONFLICT (writer_generation) DO NOTHING
    """)

    Repo.query!("""
    INSERT INTO conversation_search_discovery_cursors
      (id, writer_generation, completed_cycles, cycle_started_at,
       last_cycle_completed_at, inserted_at, updated_at)
    VALUES ('main', 'test-search-generation', 1, now(), now(), now(), now())
    ON CONFLICT (id) DO NOTHING
    """)

    :ok
  end

  defp await_connection!(0), do: raise("salix_store_test database never became reachable")

  defp await_connection!(attempts) do
    case Repo.query("SELECT 1") do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Process.sleep(100)
        await_connection!(attempts - 1)
    end
  end
end
