defmodule BridgeForTeams.SlackHistoryImportPersistenceTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    ContextLifecycle,
    Memberships,
    Orgs,
    Projects,
    Repo,
    SlackHistoryImports
  }

  alias BridgeForTeams.Schema.SlackHistoryImportChannel

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{
        "name" => "History import #{suffix}",
        "slug" => "history-import-#{suffix}"
      })

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "history-import-#{suffix}@example.test",
        "name" => "History importer"
      })

    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

    {:ok, project} =
      Projects.create_project(
        org.id,
        %{"name" => "History project", "slug" => "history-project-#{suffix}"},
        creator_user_id: user.id
      )

    %{org: org, project: project, user: user}
  end

  test "a source-neutral bundle and one immutable Slack import run survive reload", ctx do
    assert {:ok, bundle} =
             ContextLifecycle.register_bundle(%{
               org_id: ctx.org.id,
               project_id: ctx.project.id,
               source_type: "meeting",
               source_ref: "meeting:fixture:#{ctx.project.id}",
               classification: "project_context",
               policy_ref: "context-lifecycle:test:v1",
               subjects: [
                 %{kind: "user", ref: ctx.user.id},
                 %{kind: "organization", ref: ctx.org.id}
               ]
             })

    assert {:ok, reloaded_bundle} = ContextLifecycle.get_bundle(bundle.id)
    assert reloaded_bundle.id == bundle.id
    assert reloaded_bundle.source_type == "meeting"
    assert reloaded_bundle.lifecycle_state == "registered"
    assert reloaded_bundle.subject_index_state == "complete"

    assert Enum.map(reloaded_bundle.subjects, &{&1.kind, &1.ref}) |> Enum.sort() ==
             [{"organization", ctx.org.id}, {"user", ctx.user.id}]

    assert {:ok, same_bundle} =
             ContextLifecycle.register_bundle(%{
               org_id: ctx.org.id,
               project_id: ctx.project.id,
               source_type: "meeting",
               source_ref: "meeting:fixture:#{ctx.project.id}",
               classification: "project_context",
               policy_ref: "context-lifecycle:test:v1",
               subjects: [
                 %{kind: "organization", ref: ctx.org.id},
                 %{kind: "user", ref: ctx.user.id}
               ]
             })

    assert same_bundle.id == bundle.id

    from = ~U[2026-08-17 00:00:00Z]
    to = ~U[2026-08-24 00:00:00Z]
    request_id = Ecto.UUID.generate()

    attrs = %{
      org_id: ctx.org.id,
      project_id: ctx.project.id,
      requested_by_user_id: ctx.user.id,
      client_request_id: request_id,
      salix_tenant_id: ctx.org.salix_tenant_id,
      salix_group_id: ctx.project.salix_group_id,
      source_workspace_id: "T_HISTORY",
      source_app_id: "A_HISTORY",
      connect_id: "conn-history",
      connect_generation: "gen-1",
      selected_channels: selected_channels(),
      range_start: from,
      range_end: to,
      policy_revision: "context-lifecycle:v1",
      coverage_profile: "slack-root-bounded:v1",
      audience_scope: "project-public-channels:v1"
    }

    assert {:ok, run} = SlackHistoryImports.create_run(attrs)
    assert {:ok, same_run} = SlackHistoryImports.create_run(attrs)
    assert same_run.id == run.id

    assert {:error, %Ecto.Changeset{}} =
             SlackHistoryImports.create_run(%{
               attrs
               | client_request_id: "Slack text must not survive as a tombstone"
             })

    assert {:error, :idempotency_conflict} =
             SlackHistoryImports.create_run(%{
               attrs
               | selected_channels: [
                   %{
                     id: "C_OTHER",
                     name: "other",
                     visibility: "public",
                     authority_revision: String.duplicate("b", 64)
                   }
                 ]
             })

    assert {:ok, reloaded_run} = SlackHistoryImports.get_run(run.id)
    assert reloaded_run.source_workspace_id == "T_HISTORY"
    assert reloaded_run.connect_id == "conn-history"
    assert reloaded_run.connect_generation == "gen-1"
    assert DateTime.compare(reloaded_run.range_start, from) == :eq
    assert DateTime.compare(reloaded_run.range_end, to) == :eq
    assert reloaded_run.state == "created"
    assert reloaded_run.generation == 0
    assert Enum.map(reloaded_run.channels, & &1.channel_id) == ["C_DECISIONS", "C_HISTORY"]

    assert_raise Postgrex.Error, ~r/slack history import source identity is immutable/, fn ->
      reloaded_run
      |> Ecto.Changeset.change(
        source_workspace_id: "T_OTHER",
        connect_generation: "gen-2"
      )
      |> Repo.update!(mode: :savepoint)
    end

    assert_raise Postgrex.Error, ~r/slack history import source identity is immutable/, fn ->
      reloaded_run
      |> Ecto.Changeset.change(
        policy_revision: "context-lifecycle:forged:v2",
        coverage_profile: "slack-forged:v2",
        audience_scope: "forged-audience:v2"
      )
      |> Repo.update!(mode: :savepoint)
    end

    selected_channel =
      Repo.get_by!(SlackHistoryImportChannel, run_id: run.id, channel_id: "C_HISTORY")

    assert_raise Postgrex.Error, ~r/slack history import channel scope is immutable/, fn ->
      selected_channel
      |> Ecto.Changeset.change(
        channel_id: "C_FORGED",
        channel_name: "forged",
        authority_revision: String.duplicate("f", 64)
      )
      |> Repo.update!(mode: :savepoint)
    end

    assert {:ok, still_original} = SlackHistoryImports.get_run(run.id)
    assert still_original.source_workspace_id == "T_HISTORY"
    assert still_original.connect_generation == "gen-1"
    assert still_original.policy_revision == "context-lifecycle:v1"
    assert still_original.coverage_profile == "slack-root-bounded:v1"
    assert still_original.audience_scope == "project-public-channels:v1"

    assert %SlackHistoryImportChannel{
             channel_id: "C_HISTORY",
             channel_name: "history",
             authority_revision: authority_revision
           } = Repo.get!(SlackHistoryImportChannel, selected_channel.id)

    assert authority_revision == String.duplicate("a", 64)
  end

  test "row-locked transitions survive reload and reject stale workers", ctx do
    assert {:ok, run} = SlackHistoryImports.create_run(run_attrs(ctx, "transition"))

    assert {:ok, acquiring, %{from: :created, to: :acquiring}} =
             SlackHistoryImports.start_acquisition(run.id, run.generation)

    assert acquiring.generation == 1

    assert {:error, :stale_run_generation} =
             SlackHistoryImports.start_acquisition(run.id, run.generation)

    retry_at = ~U[2026-08-24 01:00:00Z]

    assert {:ok, paused, %{to: :paused}} =
             SlackHistoryImports.pause(
               run.id,
               acquiring.generation,
               :rate_limited,
               retry_at
             )

    assert {:ok, reloaded_pause} = SlackHistoryImports.get_run(run.id)
    assert reloaded_pause.state == "paused"
    assert reloaded_pause.resume_phase == "acquiring"
    assert reloaded_pause.paused_reason == "rate_limited"
    assert DateTime.compare(reloaded_pause.retry_not_before, retry_at) == :eq

    assert {:ok, resumed, %{to: :acquiring}} =
             SlackHistoryImports.resume(run.id, paused.generation)

    snapshot_id = Ecto.UUID.generate()

    assert {:error, :snapshot_not_found} =
             SlackHistoryImports.complete_acquisition(run.id, resumed.generation, snapshot_id)

    assert {:ok, stale, %{to: :stale_source}} =
             SlackHistoryImports.source_disconnected(run.id, resumed.generation)

    assert {:ok, reloaded} = SlackHistoryImports.get_run(run.id)
    assert reloaded.state == "stale_source"
    assert reloaded.generation == stale.generation
    assert reloaded.snapshot_id == nil
  end

  test "resume honors the persisted retry window", ctx do
    assert {:ok, run} = SlackHistoryImports.create_run(run_attrs(ctx, "retry-window"))

    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(run.id, run.generation)

    retry_at = DateTime.add(DateTime.utc_now(), 60, :second)

    assert {:ok, paused, _event} =
             SlackHistoryImports.pause(
               run.id,
               acquiring.generation,
               :rate_limited,
               retry_at
             )

    assert {:error, {:retry_not_before, ^retry_at}} =
             SlackHistoryImports.resume(run.id, paused.generation)

    assert {:ok, still_paused} = SlackHistoryImports.get_run(run.id)
    assert still_paused.state == "paused"
    assert still_paused.generation == paused.generation
  end

  test "disconnect preserves the old run and reconnect creates a clean replacement", ctx do
    assert {:ok, run} = SlackHistoryImports.create_run(run_attrs(ctx, "reconnect"))

    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(run.id, run.generation)

    assert {:ok, stale, %{to: :stale_source}} =
             SlackHistoryImports.source_disconnected(run.id, acquiring.generation)

    assert stale.connect_generation == "gen-1"
    assert stale.paused_reason == "source_disconnected"

    assert {:error, :source_generation_retired} =
             SlackHistoryImports.resume(run.id, stale.generation)

    reconnect_attrs = %{
      expected_generation: stale.generation,
      requested_by_user_id: ctx.user.id,
      client_request_id: Ecto.UUID.generate(),
      source_workspace_id: "T_HISTORY",
      source_app_id: "A_HISTORY_RECONNECTED",
      connect_id: "conn-history-2",
      connect_generation: "gen-2",
      selected_channels: [
        %{
          id: "C_HISTORY",
          name: "history",
          visibility: "public",
          authority_revision: String.duplicate("a", 64)
        }
      ],
      range_start: ~U[2026-08-18 00:00:00Z],
      range_end: ~U[2026-08-25 00:00:00Z],
      policy_revision: "context-lifecycle:v1",
      coverage_profile: "slack-root-bounded:v1",
      audience_scope: "project-public-channels:v1"
    }

    assert {:ok, replacement, %{replaces_run_id: old_id}} =
             SlackHistoryImports.restart_after_reconnect(run.id, reconnect_attrs)

    assert old_id == run.id
    assert replacement.id != run.id
    assert replacement.replaces_run_id == run.id
    assert replacement.state == "created"
    assert replacement.generation == 0
    assert replacement.connect_generation == "gen-2"
    assert replacement.snapshot_id == nil
    assert replacement.derivation_id == nil
    assert replacement.publication_id == nil

    assert {:ok, same_replacement, %{replayed?: true}} =
             SlackHistoryImports.restart_after_reconnect(run.id, reconnect_attrs)

    assert same_replacement.id == replacement.id

    assert {:ok, still_stale} = SlackHistoryImports.get_run(run.id)
    assert still_stale.state == "stale_source"
    assert still_stale.connect_generation == "gen-1"
    assert still_stale.snapshot_id == nil

    assert {:error, :replacement_requires_reconnect} =
             ctx
             |> run_attrs("forged-replacement")
             |> Map.put(:replaces_run_id, run.id)
             |> SlackHistoryImports.create_run()

    assert {:error, :source_workspace_mismatch} =
             SlackHistoryImports.restart_after_reconnect(
               run.id,
               %{
                 reconnect_attrs
                 | client_request_id: Ecto.UUID.generate(),
                   source_workspace_id: "T_OTHER"
               }
             )

    assert {:error, :connect_generation_not_advanced} =
             SlackHistoryImports.restart_after_reconnect(
               run.id,
               %{
                 reconnect_attrs
                 | client_request_id: Ecto.UUID.generate(),
                   connect_generation: "gen-1"
               }
             )
  end

  defp run_attrs(ctx, _suffix) do
    %{
      org_id: ctx.org.id,
      project_id: ctx.project.id,
      requested_by_user_id: ctx.user.id,
      client_request_id: Ecto.UUID.generate(),
      salix_tenant_id: ctx.org.salix_tenant_id,
      salix_group_id: ctx.project.salix_group_id,
      source_workspace_id: "T_HISTORY",
      source_app_id: "A_HISTORY",
      connect_id: "conn-history",
      connect_generation: "gen-1",
      selected_channels: selected_channels(),
      range_start: ~U[2026-08-17 00:00:00Z],
      range_end: ~U[2026-08-24 00:00:00Z],
      policy_revision: "context-lifecycle:v1",
      coverage_profile: "slack-root-bounded:v1",
      audience_scope: "project-public-channels:v1"
    }
  end

  defp selected_channels do
    [
      %{
        id: "C_HISTORY",
        name: "history",
        visibility: "public",
        authority_revision: String.duplicate("a", 64)
      },
      %{
        id: "C_DECISIONS",
        name: "decisions",
        visibility: "public",
        authority_revision: String.duplicate("b", 64)
      }
    ]
  end
end
