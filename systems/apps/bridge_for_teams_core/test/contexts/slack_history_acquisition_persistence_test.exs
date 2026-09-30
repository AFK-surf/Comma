defmodule BridgeForTeams.SlackHistoryAcquisitionPersistenceTest do
  use BridgeForTeams.DataCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{
    Accounts,
    Memberships,
    Orgs,
    Projects,
    Repo,
    SlackHistoryImports,
    SlackHistoryOnboarding
  }

  alias BridgeForTeams.SlackHistoryOnboarding.Reconciler
  alias BridgeForTeams.Schema.{SlackHistoryPageReceipt, SourcedContextObject}
  alias BridgeForTeams.SourcedContext.{Acquisition, CanonicalJSON, SlackAcquisition}

  defmodule SalixClient do
    def slack_history_read_page(request) do
      handler =
        Application.fetch_env!(
          :bridge_for_teams_core,
          :slack_history_acquisition_test_handler
        )

      handler.(request)
    end
  end

  defmodule ReadinessProcessor do
    @behaviour BridgeForTeams.SourcedContext.Processor

    @impl true
    def derive(_request), do: {:ok, %{artifacts: []}}
  end

  setup do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    previous_handler =
      Application.get_env(:bridge_for_teams_core, :slack_history_acquisition_test_handler)

    Application.put_env(:bridge_for_teams_core, :salix_client, SalixClient)

    on_exit(fn ->
      restore_env(:bridge_for_teams_core, :salix_client, previous_client)

      restore_env(
        :bridge_for_teams_core,
        :slack_history_acquisition_test_handler,
        previous_handler
      )
    end)

    suffix = System.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{"name" => "Acquisition #{suffix}", "slug" => "acq-#{suffix}"})

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "acq-#{suffix}@example.test",
        "name" => "Acquisition owner"
      })

    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

    {:ok, project} =
      Projects.create_project(
        org.id,
        %{"name" => "Acquisition project", "slug" => "acq-project-#{suffix}"},
        creator_user_id: user.id
      )

    attrs = %{
      org_id: org.id,
      project_id: project.id,
      requested_by_user_id: user.id,
      client_request_id: Ecto.UUID.generate(),
      salix_tenant_id: org.salix_tenant_id,
      salix_group_id: project.salix_group_id,
      source_workspace_id: "T_HISTORY",
      source_app_id: "A_HISTORY",
      connect_id: "conn-history",
      connect_generation: "gen-1",
      selected_channels: [
        %{
          id: "C_HISTORY",
          name: "history",
          visibility: "public",
          authority_revision: String.duplicate("a", 64)
        }
      ],
      range_start: ~U[2026-08-17 00:00:00Z],
      range_end: ~U[2026-08-24 00:00:00Z],
      policy_revision: "context-lifecycle:v1",
      coverage_profile: "slack-root-bounded:v1",
      audience_scope: "project-public-channels:v1"
    }

    {:ok, run} = SlackHistoryImports.create_run(attrs)
    %{org: org, project: project, user: user, run: run}
  end

  test "coordinator carries pinned authority across Salix and the durable checkpoint", ctx do
    owner = self()

    Application.put_env(
      :bridge_for_teams_core,
      :slack_history_acquisition_test_handler,
      fn request ->
        send(owner, {:salix_page_request, request})

        {:ok,
         page_envelope(request, [
           %{
             "message_ts" => slack_ts(~U[2026-08-20 12:00:00Z]),
             "thread_ts" => nil,
             "actor_id" => "U_COORDINATOR",
             "actor_kind" => "user",
             "text" => "Coordinator accepted this source fact",
             "observable_version" => "original",
             "reply_count" => 0,
             "file_metadata" => []
           }
         ])}
      end
    )

    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(ctx.run.id, ctx.run.generation)

    assert {:ok, receipt} =
             SlackAcquisition.acquire_one_page(ctx.run.id, acquiring.generation)

    assert receipt.accepted_connect_generation == "gen-1"
    assert receipt.accepted_channel_authority_revision == String.duplicate("a", 64)

    assert_receive {:salix_page_request, request}
    assert request.tenant_id == ctx.org.salix_tenant_id
    assert request.group_id == ctx.project.salix_group_id
    assert request.expected_workspace_id == "T_HISTORY"
    assert request.expected_app_id == "A_HISTORY"
    assert request.expected_connect_generation == "gen-1"
    assert request.expected_channel_authority_revision == String.duplicate("a", 64)
    assert request.page_ordinal == 0
    assert request.cursor == nil

    assert SlackAcquisition.acquire_one_page(ctx.run.id, acquiring.generation) ==
             {:ok, :ready_to_finalize}

    assert {:ok, acquired, snapshot} =
             SlackAcquisition.finalize(
               ctx.run.id,
               acquiring.generation,
               "slack-normalization:v1"
             )

    assert acquired.state == "acquired"
    assert snapshot.object_count == 1
  end

  test "reconciler notification replaces the pending retry timer after a worker crash", ctx do
    owner = self()

    Application.put_env(
      :bridge_for_teams_core,
      :slack_history_acquisition_test_handler,
      fn _request ->
        send(owner, :reconciler_adapter_crash)
        raise "simulated adapter crash"
      end
    )

    previous_reconciler =
      Application.get_env(:bridge_for_teams_core, Reconciler)

    Application.put_env(:bridge_for_teams_core, Reconciler,
      enabled: true,
      interval_ms: 5_000
    )

    on_exit(fn ->
      restore_env(:bridge_for_teams_core, Reconciler, previous_reconciler)
    end)

    pid = start_supervised!({Reconciler, interval_ms: 5_000})

    assert_receive :reconciler_adapter_crash
    first_idle = wait_for_reconciler_idle(pid)
    first_timer_ref = first_idle.timer_ref
    assert is_reference(first_timer_ref)
    assert is_integer(Process.read_timer(first_timer_ref))

    assert :ok = Reconciler.notify(ctx.run.id)
    assert_receive :reconciler_adapter_crash

    second_idle = wait_for_reconciler_idle(pid)
    assert second_idle.timer_ref != first_timer_ref
    assert Process.read_timer(first_timer_ref) == false
    assert is_integer(Process.read_timer(second_idle.timer_ref))

    refute_receive :reconciler_adapter_crash, 100
  end

  test "coordinator persists bounded retry state instead of sleeping", ctx do
    Application.put_env(
      :bridge_for_teams_core,
      :slack_history_acquisition_test_handler,
      fn _request -> {:error, {:rate_limited, 17_000}} end
    )

    before_pause = DateTime.utc_now()

    assert {:ok, %{state: "acquiring", advanced?: true}} =
             Reconciler.run_once(run_id: ctx.run.id)

    assert {:ok, %{state: "paused", advanced?: true}} =
             Reconciler.run_once(run_id: ctx.run.id)

    assert {:ok, paused} = SlackHistoryImports.get_run(ctx.run.id)

    assert paused.state == "paused"
    assert paused.paused_reason == "rate_limited"
    assert DateTime.diff(paused.retry_not_before, before_pause, :second) in 16..18

    assert {:ok, checkpoint} =
             Acquisition.get_checkpoint(ctx.run.id, "C_HISTORY", "history", "")

    assert checkpoint.retry_count == 1
    assert checkpoint.next_page_ordinal == 0
  end

  test "launch readiness keeps dry-run, publish, and grounding gates independent" do
    previous_features =
      Application.fetch_env!(:bridge_for_teams_core, :sourced_context_features)

    previous_reconciler = Application.get_env(:bridge_for_teams_core, Reconciler)

    previous_processor =
      Application.get_env(:bridge_for_teams_core, :sourced_context_processor)

    evidence = %{
      model_provider: "fixture",
      model_id: "fixture-model",
      model_revision: "model-rev-1",
      prompt_template_id: "bft-history-extraction",
      prompt_revision: "prompt-rev-1",
      policy_revision: "extraction-policy-rev-1",
      schema_revision: "people-project-decision-v1",
      processor_config: %{"temperature_millis" => 0}
    }

    on_exit(fn ->
      Application.put_env(
        :bridge_for_teams_core,
        :sourced_context_features,
        previous_features
      )

      restore_env(:bridge_for_teams_core, Reconciler, previous_reconciler)

      restore_env(
        :bridge_for_teams_core,
        :sourced_context_processor,
        previous_processor
      )
    end)

    Application.delete_env(:bridge_for_teams_core, :sourced_context_processor)

    Application.put_env(:bridge_for_teams_core, Reconciler,
      enabled: false,
      derivation_evidence: evidence
    )

    refute SlackHistoryOnboarding.readiness().dry_run?
    refute SlackHistoryOnboarding.readiness().worker?

    Application.put_env(:bridge_for_teams_core, Reconciler,
      enabled: true,
      derivation_evidence: nil
    )

    refute SlackHistoryOnboarding.readiness().dry_run?
    refute SlackHistoryOnboarding.readiness().processor?

    Application.put_env(:bridge_for_teams_core, Reconciler,
      enabled: true,
      derivation_evidence: evidence
    )

    refute SlackHistoryOnboarding.readiness().dry_run?
    refute SlackHistoryOnboarding.readiness().processor?

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_processor,
      ReadinessProcessor
    )

    assert SlackHistoryOnboarding.readiness().dry_run?

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.merge(previous_features, commit: false, grounding: false)
    )

    readiness = SlackHistoryOnboarding.readiness()
    assert readiness.dry_run?
    refute readiness.commit?
    refute readiness.grounding?

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(previous_features, :onboarding_preview, false)
    )

    readiness = SlackHistoryOnboarding.readiness()
    refute readiness.onboarding_preview?
    assert readiness.dry_run?
    refute SlackHistoryOnboarding.available?()
  end

  test "retry checkpoint and paused run roll back together before transaction commit", ctx do
    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(ctx.run.id, ctx.run.generation)

    assert {:error, :simulated_worker_crash} =
             Repo.transaction(fn ->
               assert {:ok, paused, _event} =
                        Acquisition.pause_stream_retry(
                          ctx.run.id,
                          acquiring.generation,
                          "C_HISTORY",
                          "history",
                          "",
                          :rate_limited,
                          provider_delay_ms: 17_000
                        )

               assert paused.state == "paused"
               Repo.rollback(:simulated_worker_crash)
             end)

    assert {:ok, unchanged} = SlackHistoryImports.get_run(ctx.run.id)
    assert unchanged.state == "acquiring"
    assert unchanged.generation == acquiring.generation
    assert unchanged.retry_not_before == nil

    assert {:error, :not_found} =
             Acquisition.get_checkpoint(ctx.run.id, "C_HISTORY", "history", "")
  end

  test "fresh-cursor empty pages stop at the durable receipt bound and pause the run", ctx do
    previous_bounds = Application.fetch_env!(:bridge_for_teams_core, :sourced_context_bounds)

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_bounds,
      Keyword.put(previous_bounds, :run_pages, 1)
    )

    on_exit(fn ->
      Application.put_env(:bridge_for_teams_core, :sourced_context_bounds, previous_bounds)
    end)

    Application.put_env(
      :bridge_for_teams_core,
      :slack_history_acquisition_test_handler,
      fn request ->
        envelope =
          request
          |> page_envelope([])
          |> Map.merge(%{
            next_cursor: "cursor-#{request.page_ordinal + 1}",
            stream_complete: false
          })

        {:ok, Map.put(envelope, :response_sha256, Acquisition.page_sha256(envelope))}
      end
    )

    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(ctx.run.id, ctx.run.generation)

    assert {:ok, _receipt} =
             SlackAcquisition.acquire_one_page(ctx.run.id, acquiring.generation)

    assert {:ok, paused, %{to: :paused}} =
             SlackAcquisition.acquire_one_page(ctx.run.id, acquiring.generation)

    assert paused.paused_reason == "bound_reached"

    assert {:ok, %{state: "paused", advanced?: false}} =
             Reconciler.run_once(run_id: ctx.run.id)

    assert {:ok, still_paused} = SlackHistoryImports.get_run(ctx.run.id)
    assert still_paused.generation == paused.generation
    assert still_paused.paused_reason == "bound_reached"

    assert Repo.aggregate(
             from(receipt in SlackHistoryPageReceipt, where: receipt.run_id == ^ctx.run.id),
             :count
           ) == 1

    assert {:ok, checkpoint} =
             Acquisition.get_checkpoint(ctx.run.id, "C_HISTORY", "history", "")

    assert checkpoint.next_page_ordinal == 1
    assert checkpoint.next_cursor == "cursor-1"
  end

  test "coordinator freezes an incomplete run when Salix proves source drift", ctx do
    Application.put_env(
      :bridge_for_teams_core,
      :slack_history_acquisition_test_handler,
      fn _request -> {:error, :stale_source} end
    )

    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(ctx.run.id, ctx.run.generation)

    assert {:ok, stale, %{to: :stale_source}} =
             SlackAcquisition.acquire_one_page(ctx.run.id, acquiring.generation)

    assert stale.state == "stale_source"
    assert stale.context_bundle_id == ctx.run.context_bundle_id
    assert stale.snapshot_id == nil
  end

  test "coordinator persists malformed provider data as a terminal run failure", ctx do
    Application.put_env(
      :bridge_for_teams_core,
      :slack_history_acquisition_test_handler,
      fn _request -> {:error, :invalid_provider_page} end
    )

    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(ctx.run.id, ctx.run.generation)

    assert {:ok, failed, %{to: :failed_terminal}} =
             SlackAcquisition.acquire_one_page(ctx.run.id, acquiring.generation)

    assert failed.state == "failed_terminal"
    assert failed.failure_reason == "invalid_provider_page"
  end

  test "expired provider cursor is cleared but its durable time boundary is retained", ctx do
    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(ctx.run.id, ctx.run.generation)

    first_page =
      page_envelope(acquisition_request(ctx.run), [
        %{
          "message_ts" => "1787227200.000001",
          "thread_ts" => nil,
          "actor_id" => "U_CURSOR",
          "actor_kind" => "user",
          "text" => "First page before cursor expiry",
          "observable_version" => "original",
          "reply_count" => 0,
          "file_metadata" => []
        }
      ])
      |> Map.merge(%{next_cursor: "cursor-that-expires", stream_complete: false})
      |> then(&Map.put(&1, :response_sha256, Acquisition.page_sha256(&1)))

    assert {:ok, _receipt} =
             Acquisition.accept_page(ctx.run.id, acquiring.generation, first_page)

    owner = self()

    Application.put_env(
      :bridge_for_teams_core,
      :slack_history_acquisition_test_handler,
      fn request ->
        send(owner, {:expired_cursor_request, request})
        {:error, :invalid_cursor}
      end
    )

    assert {:ok, paused, %{to: :paused}} =
             SlackAcquisition.acquire_one_page(ctx.run.id, acquiring.generation)

    assert paused.paused_reason == "provider_unavailable"

    assert_receive {:expired_cursor_request, request}
    assert request.cursor == "cursor-that-expires"
    assert request.resume_boundary == "1787227200.000001"

    assert {:ok, checkpoint} =
             Acquisition.get_checkpoint(ctx.run.id, "C_HISTORY", "history", "")

    assert checkpoint.next_cursor == nil
    assert checkpoint.timestamp_boundary == "1787227200.000001"
    assert checkpoint.next_page_ordinal == 1
    assert checkpoint.retry_count == 1
  end

  test "reply checkpoints must come from discovered roots and advance forward in time", ctx do
    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(ctx.run.id, ctx.run.generation)

    undiscovered_reply = %{
      channel_id: "C_HISTORY",
      stream_kind: "replies",
      root_ts: "1787227200.000001",
      page_ordinal: 0,
      request_cursor: nil,
      next_cursor: nil,
      stream_complete: true,
      accepted_connect_generation: "gen-1",
      accepted_channel_authority_revision: String.duplicate("a", 64),
      observed_at: ~U[2026-08-24 00:01:00Z],
      messages: []
    }

    undiscovered_reply =
      Map.put(
        undiscovered_reply,
        :response_sha256,
        Acquisition.page_sha256(undiscovered_reply)
      )

    assert {:error, :reply_root_outside_discovered_history} =
             Acquisition.accept_page(ctx.run.id, acquiring.generation, undiscovered_reply)

    root = %{
      "message_ts" => "1787227200.000001",
      "thread_ts" => nil,
      "actor_id" => "U_ROOT",
      "actor_kind" => "user",
      "text" => "Thread root",
      "observable_version" => "original",
      "reply_count" => 2,
      "file_metadata" => []
    }

    history = page_envelope(acquisition_request(ctx.run), [root])
    assert {:ok, _receipt} = Acquisition.accept_page(ctx.run.id, acquiring.generation, history)

    reply_messages = [
      root,
      %{
        root
        | "message_ts" => "1787227300.000001",
          "thread_ts" => root["message_ts"],
          "text" => "Second reply",
          "reply_count" => 0
      }
    ]

    reply_page = %{undiscovered_reply | messages: reply_messages}
    reply_page = Map.put(reply_page, :response_sha256, Acquisition.page_sha256(reply_page))

    assert {:ok, _receipt} =
             Acquisition.accept_page(ctx.run.id, acquiring.generation, reply_page)

    assert {:ok, checkpoint} =
             Acquisition.get_checkpoint(
               ctx.run.id,
               "C_HISTORY",
               "replies",
               root["message_ts"]
             )

    assert checkpoint.timestamp_boundary == "1787227300.000001"
  end

  test "one fenced page, checkpoint, encrypted object, and snapshot commit atomically", ctx do
    assert {:ok, acquiring, _event} =
             SlackHistoryImports.start_acquisition(ctx.run.id, ctx.run.generation)

    message = %{
      "message_ts" => slack_ts(~U[2026-08-20 12:00:00Z]),
      "thread_ts" => nil,
      "actor_id" => "U_HISTORY",
      "actor_kind" => "user",
      "text" => "Peng approved the Atlas launch decision",
      "observable_version" => "original",
      "reply_count" => 0,
      "file_metadata" => []
    }

    envelope = %{
      channel_id: "C_HISTORY",
      stream_kind: "history",
      root_ts: "",
      page_ordinal: 0,
      request_cursor: nil,
      next_cursor: nil,
      stream_complete: true,
      accepted_connect_generation: "gen-1",
      accepted_channel_authority_revision: String.duplicate("a", 64),
      observed_at: ~U[2026-08-24 00:01:00Z],
      messages: [message]
    }

    envelope = Map.put(envelope, :response_sha256, Acquisition.page_sha256(envelope))

    assert {:ok, receipt} =
             Acquisition.accept_page(ctx.run.id, acquiring.generation, envelope)

    assert receipt.object_count == 1
    assert receipt.accepted_connect_generation == "gen-1"
    assert receipt.next_cursor_ciphertext == nil

    assert {:ok, replayed} =
             Acquisition.accept_page(ctx.run.id, acquiring.generation, envelope)

    assert replayed.id == receipt.id
    assert replayed.replayed? == true

    conflicting_message = %{message | "text" => "different response under the same page"}
    conflicting = %{envelope | messages: [conflicting_message]}
    conflicting = Map.put(conflicting, :response_sha256, Acquisition.page_sha256(conflicting))

    assert {:error, :page_receipt_conflict} =
             Acquisition.accept_page(ctx.run.id, acquiring.generation, conflicting)

    assert Repo.aggregate(
             from(object in SourcedContextObject, where: object.run_id == ^ctx.run.id),
             :count
           ) == 1

    stored = Repo.one!(from(object in SourcedContextObject, where: object.run_id == ^ctx.run.id))
    refute stored.payload_ciphertext =~ message["text"]
    assert stored.payload_sha256 == CanonicalJSON.sha256(CanonicalJSON.encode!(message))

    assert {:ok, checkpoint} =
             Acquisition.get_checkpoint(ctx.run.id, "C_HISTORY", "history", "")

    assert checkpoint.complete == true
    assert checkpoint.next_cursor == nil
    assert checkpoint.next_page_ordinal == 1

    assert {:ok, acquired, snapshot} =
             Acquisition.finalize_snapshot(ctx.run.id, acquiring.generation,
               normalization_revision: "slack-normalization:v1"
             )

    assert acquired.state == "acquired"
    assert acquired.snapshot_id == snapshot.id
    assert snapshot.object_count == 1
    assert snapshot.byte_count > 0
    assert snapshot.coverage["complete"] == true

    assert {:ok, frozen} = Acquisition.read_snapshot(snapshot.id)
    assert frozen.snapshot.id == snapshot.id
    assert [decrypted] = frozen.objects
    assert decrypted.payload["text"] == message["text"]
    assert decrypted.source.channel_id == "C_HISTORY"

    assert {:ok, unchanged, %{effect: :frozen_snapshot_unchanged}} =
             SlackHistoryImports.source_disconnected(ctx.run.id, acquired.generation)

    assert unchanged.snapshot_id == snapshot.id
  end

  defp slack_ts(datetime) do
    seconds = DateTime.to_unix(datetime, :second)
    "#{seconds}.000001"
  end

  defp page_envelope(request, messages) do
    envelope = %{
      channel_id: request.channel_id,
      stream_kind: request.stream_kind,
      root_ts: request.root_ts,
      page_ordinal: request.page_ordinal,
      request_cursor: request.cursor,
      next_cursor: nil,
      stream_complete: true,
      accepted_connect_generation: request.expected_connect_generation,
      accepted_channel_authority_revision: request.expected_channel_authority_revision,
      observed_at: ~U[2026-08-24 00:01:00Z],
      messages: messages
    }

    Map.put(envelope, :response_sha256, Acquisition.page_sha256(envelope))
  end

  defp acquisition_request(run) do
    %{
      channel_id: "C_HISTORY",
      stream_kind: "history",
      root_ts: "",
      page_ordinal: 0,
      cursor: nil,
      expected_connect_generation: run.connect_generation,
      expected_channel_authority_revision: String.duplicate("a", 64)
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp wait_for_reconciler_idle(pid, attempts \\ 100)

  defp wait_for_reconciler_idle(_pid, 0),
    do: flunk("reconciler did not settle on one retry timer")

  defp wait_for_reconciler_idle(pid, attempts) do
    state = :sys.get_state(pid)

    if is_nil(state.task) and is_reference(state.timer_ref) do
      state
    else
      Process.sleep(5)
      wait_for_reconciler_idle(pid, attempts - 1)
    end
  end
end
