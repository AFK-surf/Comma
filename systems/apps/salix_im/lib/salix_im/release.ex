defmodule SalixIM.Release do
  @moduledoc """
  Release-native maintenance entrypoints for `bin/comma eval` — the
  production runtime image ships the OTP release only (no Mix), and the
  identity-audit maintenance window asserts "no writers". Audit and flat-state
  cutover start only `:salix_store`. Legacy conversation cutover additionally
  starts a local Registry + owner fleet with recovery wake disabled; it never
  starts the `:salix_im` application, provider runtime, recovery scanner, or web.

      bin/comma eval 'SalixIM.Release.identity_audit()'
      bin/comma eval 'SalixIM.Release.identity_audit(fix: true, confirm_no_writers: true)'
      bin/comma eval 'SalixIM.Release.identity_audit(assert_clean: true)'
      bin/comma eval 'SalixIM.Release.migrate_conversation_storage(confirm_no_writers: true)'
      bin/comma eval 'SalixIM.Release.migrate_conversation_participant_states(confirm_no_writers: true)'
      bin/comma eval 'SalixIM.Release.migrate_conversation_pins(confirm_no_writers: true)'
      bin/comma eval 'SalixIM.Release.migrate_task_statuses(confirm_no_writers: true)'
      bin/comma eval 'SalixIM.Release.migrate_participant_notification_filters(confirm_no_writers: true)'

  `eval` runs the release config providers (runtime.exs → config.json)
  before this code, so the S3 backend is fully configured. Failures
  raise, which `bin/comma eval` surfaces as a nonzero exit for the
  runbook's gate steps — `assert_clean: true` makes a read-only audit
  itself a GATE: any deprecated key (or unsettled duplicate group)
  raises, so "re-audit clean" is an enforced exit status, not prose.
  """

  alias SalixIM.Migrations.{
    ConversationDeliveryParticipantFields,
    ConversationParticipantNotificationFilter,
    ConversationParticipantStatesFlat,
    ConversationPinsAggregate,
    ConversationStorageSegmented,
    TaskConversationStatus
  }

  alias SalixIM.ProviderIdentityAudit

  @doc """
  Cut over flat conversations and normalize their delivery records.

  Canonical writes run through a quiesced local owner fleet, not migration-owned
  storage code. Run the flat participant-state cutover afterward.
  """
  def migrate_conversation_storage(opts \\ []) do
    require_no_writers!(opts, "conversation storage cutover")
    ensure_started = Keyword.get(opts, :ensure_started, &Application.ensure_all_started/1)
    {:ok, _} = ensure_started.(:salix_store)
    :ok = ensure_release_conversation_owners()

    segmented = run_migration!(ConversationStorageSegmented, "conversation storage cutover")

    deliveries =
      run_migration!(
        ConversationDeliveryParticipantFields,
        "conversation delivery field cutover"
      )

    %{segmented: segmented, deliveries: deliveries}
  end

  @doc """
  Exclusively migrate legacy participant notification-filter fields.

  Existing filters are preserved unchanged. Legacy booleans map to
  `messages: all|none` and `statuses: none`, then the legacy field is removed.
  The command is safe to rerun and must finish before the candidate serving
  runtime starts.
  """
  def migrate_participant_notification_filters(opts \\ []) do
    require_no_writers!(opts, "participant notification-filter cutover")
    ensure_started = Keyword.get(opts, :ensure_started, &Application.ensure_all_started/1)
    {:ok, _} = ensure_started.(:salix_store)
    :ok = ensure_release_conversation_owners()

    case ConversationParticipantNotificationFilter.run(limit: opts[:limit]) do
      {:ok, stats} ->
        stats

      {:error, reason} ->
        raise "participant notification-filter cutover failed: #{inspect(reason)}"
    end
  end

  @doc """
  Exclusively cut over legacy nested conversation participant state.

  The runtime reads only the flat projection, so this must finish while every IM
  writer is quiesced and before the new runtime starts. It is safe to rerun.
  """
  def migrate_conversation_participant_states(opts \\ []) do
    require_no_writers!(opts, "participant-state cutover")

    ensure_started = Keyword.get(opts, :ensure_started, &Application.ensure_all_started/1)
    {:ok, _} = ensure_started.(:salix_store)

    case ConversationParticipantStatesFlat.run(limit: opts[:limit]) do
      {:ok, stats} ->
        IO.puts(
          "participant-state cutover complete: #{stats.migrated} migrated, " <>
            "#{stats.skipped} skipped across #{stats.pages} page(s)"
        )

        stats

      {:error, {:participant_state_migration_failed, stats}} ->
        raise "participant-state cutover failed: #{inspect(stats)}"
    end
  end

  @doc """
  Exclusively cut over legacy per-pin objects to one bounded aggregate per group.

  The runtime has no legacy read fallback. This command must complete while
  every IM writer is quiesced and before the new runtime starts.
  """
  def migrate_conversation_pins(opts \\ []) do
    require_no_writers!(opts, "conversation-pin aggregate cutover")
    ensure_started = Keyword.get(opts, :ensure_started, &Application.ensure_all_started/1)
    {:ok, _} = ensure_started.(:salix_store)
    :ok = ensure_release_conversation_owners()

    run_migration!(ConversationPinsAggregate, "conversation-pin aggregate cutover")
  end

  @doc """
  Materialize the legacy non-Workflow Task display status as Conversation status.

  The migration preserves all Task completion and command facts, skips recurring
  Tasks and is safe to rerun. It must finish before the runtime drops the legacy
  display projection.
  """
  def migrate_task_statuses(opts \\ []) do
    require_no_writers!(opts, "Task Conversation status cutover")
    ensure_started = Keyword.get(opts, :ensure_started, &Application.ensure_all_started/1)
    {:ok, _} = ensure_started.(:salix_store)
    :ok = ensure_release_conversation_owners()

    case TaskConversationStatus.run(limit: opts[:limit]) do
      {:ok, stats} -> stats
      {:error, reason} -> raise "Task Conversation status cutover failed: #{inspect(reason)}"
    end
  end

  def retire_task_graphs(opts \\ []) do
    require_no_writers!(opts, "Task graph retirement")
    ensure_started = Keyword.get(opts, :ensure_started, &Application.ensure_all_started/1)
    {:ok, _} = ensure_started.(:salix_store)
    :ok = ensure_release_conversation_owners()
    run_migration!(SalixIM.Migrations.TaskGraphRetirement, "Task graph retirement")
  end

  defp require_no_writers!(opts, operation) do
    unless Keyword.get(opts, :confirm_no_writers, false) do
      raise "refusing #{operation} without confirm_no_writers: true"
    end
  end

  defp run_migration!(module, operation) do
    case module.run() do
      {:ok, stats} -> stats
      {:error, reason} -> raise "#{operation} failed: #{inspect(reason)}"
    end
  end

  defp ensure_release_conversation_owners do
    registry = Process.whereis(SalixIM.ConversationRegistry)
    fleet = Process.whereis(SalixIM.ConversationFleetSup)

    cond do
      is_pid(registry) and is_pid(fleet) ->
        :ok

      is_nil(registry) and is_nil(fleet) ->
        Application.put_env(
          :salix_im,
          :conversation_placement,
          SalixIM.ConversationPlacement.LocalFleet
        )

        children = [
          {Registry,
           keys: :unique,
           name: SalixIM.ConversationRegistry,
           partitions: System.schedulers_online()},
          {DynamicSupervisor, name: SalixIM.ConversationFleetSup, strategy: :one_for_one}
        ]

        case Supervisor.start_link(children,
               strategy: :rest_for_one,
               name: SalixIM.ReleaseConversationOwnerSupervisor
             ) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            raise "failed to start release conversation owners: #{inspect(reason)}"
        end

      true ->
        raise "refusing cutover with a partially running conversation owner supervisor"
    end
  end

  def identity_audit(opts \\ []) do
    fix? = Keyword.get(opts, :fix, false)
    gate? = Keyword.get(opts, :confirm_no_writers, false)

    if fix? and not gate? do
      raise "refusing fix: true without confirm_no_writers: true — quiesce IM writers first"
    end

    {:ok, _} = Application.ensure_all_started(:salix_store)

    case ProviderIdentityAudit.run(fix: fix?, no_writer_gate: gate?) do
      {:ok, report} ->
        Enum.each(
          report.duplicate_groups,
          &IO.puts(ProviderIdentityAudit.format_duplicate(&1))
        )

        Enum.each(report.deprecated, fn entry ->
          IO.puts("deprecated key (#{entry.status}) #{entry.key} identity=#{entry.identity}")
        end)

        Enum.each(report.misaddressed_records, fn key ->
          IO.puts("misaddressed canonical (mutation-ineligible; unkeyed lookups scan): #{key}")
        end)

        IO.puts(
          "#{length(report.certified)} certified, #{length(report.deprecated)} deprecated, " <>
            "#{map_size(report.duplicate_groups)} duplicate group(s), " <>
            "#{length(report.misaddressed_records)} misaddressed record(s)"
        )

        enforce_clean_fix!(report, fix?)
        if Keyword.get(opts, :assert_clean, false), do: enforce_clean_audit!(report)
        :ok

      {:error, reason} ->
        raise "identity audit failed: #{inspect(reason)}"
    end
  end

  @doc """
  The "re-audit clean" gate: raises (→ nonzero `bin/comma eval` exit)
  while ANY deprecated key, unsettled duplicate group, or misaddressed
  canonical record remains — a misaddressed record is exactly the state
  the mutation path refuses to touch (round-12), so a corpus carrying
  one is not clean either. A restore/deploy step gated on this command
  cannot proceed on a corpus materialization could misbehave on.
  """
  def enforce_clean_audit!(report) do
    deprecated = length(report.deprecated)
    duplicates = map_size(report.duplicate_groups)
    misaddressed = length(report.misaddressed_records)

    if deprecated > 0 or duplicates > 0 or misaddressed > 0 do
      raise "audit not clean: #{deprecated} deprecated key(s), " <>
              "#{duplicates} unsettled duplicate group(s), " <>
              "#{misaddressed} misaddressed record(s)"
    end

    :ok
  end

  @doc """
  A fix that skipped keys (`changed > 0`) proves a writer was active
  inside the claimed no-writer window: the snapshot is partial, so the
  procedure must re-run from a fresh audit instead of proceeding.
  """
  def enforce_clean_fix!(report, fix? \\ true) do
    changed = Map.get(report, :changed, 0)

    if fix? and changed > 0 do
      raise "#{changed} key(s) changed under the audit — a writer was active during the " <>
              "no-writer window; re-run the audit + fix from scratch"
    end

    :ok
  end
end
