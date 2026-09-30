defmodule BridgeForTeams.SlackHistoryImport.StateMachineTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.SlackHistoryImport.StateMachine

  describe "fixture-backed durable lifecycle" do
    test "decodes every constrained storage state through an explicit finite mapping" do
      states = [
        created: "created",
        acquiring: "acquiring",
        paused: "paused",
        stale_source: "stale_source",
        acquired: "acquired",
        deriving: "deriving",
        preview_ready: "preview_ready",
        committed: "committed",
        canceled: "canceled",
        rolled_back: "rolled_back",
        failed_terminal: "failed_terminal"
      ]

      Enum.each(states, fn {expected, stored} ->
        assert StateMachine.state_from_storage!(stored) == expected
      end)

      assert_raise KeyError, fn -> StateMachine.state_from_storage!("unknown") end
    end

    test "constructor rejects blank or missing source authority identities" do
      assert {:error, :invalid_run_id} =
               StateMachine.new("",
                 connect_id: "connect-1",
                 connect_generation: "gen-1",
                 source_workspace_id: "workspace-1"
               )

      assert {:error, :invalid_connect_generation} =
               StateMachine.new("run-1",
                 connect_id: "connect-1",
                 source_workspace_id: "workspace-1"
               )

      assert {:error, :invalid_source_workspace_id} =
               StateMachine.new("run-1",
                 connect_id: "connect-1",
                 connect_generation: "gen-1",
                 source_workspace_id: ""
               )

      assert {:error, :replacement_requires_reconnect} =
               StateMachine.new("run-2",
                 connect_id: "connect-2",
                 connect_generation: "gen-2",
                 source_workspace_id: "workspace-other",
                 replaces_run_id: "run-1"
               )
    end

    test "pauses and resumes transient acquisition/derivation failures" do
      run = new_run()

      assert {:ok, run, %{to: :acquiring}} =
               StateMachine.start_acquisition(run, run.generation)

      assert {:ok, run, %{to: :paused}} =
               StateMachine.pause(run, run.generation, :rate_limited, ~U[2026-08-24 09:01:00Z])

      assert run.resume_phase == :acquiring
      assert {:ok, run, %{to: :acquiring}} = StateMachine.resume(run, run.generation)

      assert {:ok, run, %{to: :acquired}} =
               StateMachine.complete_acquisition(run, run.generation, "snapshot-1")

      assert {:ok, run, %{to: :deriving}} =
               StateMachine.start_derivation(run, run.generation, "derivation-1")

      assert {:ok, run, %{to: :paused}} =
               StateMachine.pause(run, run.generation, :processor_unavailable, nil)

      assert run.resume_phase == :deriving
      assert {:ok, run, %{to: :deriving}} = StateMachine.resume(run, run.generation)

      assert {:ok, run, %{to: :preview_ready}} =
               StateMachine.complete_derivation(run, run.generation, "review-1")

      refute run.state in [:committing, :rolling_back]
    end

    test "rejects stale worker generations, illegal transitions, and empty identities" do
      run = new_run()

      assert {:error, :stale_run_generation} =
               StateMachine.start_acquisition(run, run.generation + 1)

      assert {:error, {:invalid_transition, :created, :complete_acquisition}} =
               StateMachine.complete_acquisition(run, run.generation, "snapshot-1")

      {:ok, acquiring, _event} = StateMachine.start_acquisition(run, run.generation)

      assert {:error, :invalid_snapshot_id} =
               StateMachine.complete_acquisition(acquiring, acquiring.generation, nil)

      {:ok, acquired, _event} =
        StateMachine.complete_acquisition(acquiring, acquiring.generation, "snapshot-1")

      assert {:error, :invalid_derivation_id} =
               StateMachine.start_derivation(acquired, acquired.generation, "")
    end

    test "terminal failure is limited to pre-preview work" do
      run = new_run()

      assert {:ok, failed, %{to: :failed_terminal}} =
               StateMachine.fail_terminal(run, run.generation, :stale_source_scope)

      assert failed.failure_reason == :stale_source_scope
      preview = preview_fixture()

      assert {:error, {:invalid_transition, :preview_ready, :fail_terminal}} =
               StateMachine.fail_terminal(preview, preview.generation, :invalid_review_revision)
    end

    test "a new derivation reuses the frozen snapshot but clears stale review evidence" do
      preview = preview_fixture()

      assert {:ok, deriving, %{from: :preview_ready, to: :deriving}} =
               StateMachine.start_derivation(
                 preview,
                 preview.generation,
                 "derivation-2"
               )

      assert deriving.snapshot_id == preview.snapshot_id
      assert deriving.derivation_id == "derivation-2"
      assert deriving.review_revision_id == nil

      assert {:ok, revised, %{to: :preview_ready}} =
               StateMachine.complete_derivation(
                 deriving,
                 deriving.generation,
                 "review-2"
               )

      assert {:ok, edited, %{from: :preview_ready, to: :preview_ready}} =
               StateMachine.revise_preview(
                 revised,
                 revised.generation,
                 "review-3"
               )

      assert edited.review_revision_id == "review-3"
    end
  end

  describe "disconnect and reconnect" do
    test "disconnect before acquisition still requires a fresh replacement run" do
      run = new_run()

      assert {:ok, stale, %{to: :stale_source}} =
               StateMachine.source_disconnected(run, run.generation)

      assert {:error, :source_generation_retired} =
               StateMachine.resume(stale, stale.generation)

      assert {:ok, replacement, _evidence} =
               StateMachine.restart_after_reconnect(stale, "run-2",
                 connect_id: "connect-2",
                 connect_generation: "gen-2",
                 source_workspace_id: "workspace-1"
               )

      assert replacement.state == :created
    end

    test "disconnect retires an incomplete acquisition and the old run cannot resume" do
      run = new_run()
      {:ok, acquiring, _event} = StateMachine.start_acquisition(run, run.generation)

      assert {:ok, stale, %{to: :stale_source}} =
               StateMachine.source_disconnected(acquiring, acquiring.generation)

      assert stale.connect_generation == "gen-1"
      assert stale.paused_reason == :source_disconnected

      assert {:error, :source_generation_retired} =
               StateMachine.resume(stale, stale.generation)
    end

    test "reconnect creates a clean replacement under a fresh generation" do
      run = new_run()
      {:ok, acquiring, _event} = StateMachine.start_acquisition(run, run.generation)
      {:ok, stale, _event} = StateMachine.source_disconnected(acquiring, acquiring.generation)

      assert {:ok, replacement, evidence} =
               StateMachine.restart_after_reconnect(stale, "run-2",
                 connect_id: "connect-2",
                 connect_generation: "gen-2",
                 source_workspace_id: "workspace-1"
               )

      assert replacement.state == :created
      assert replacement.replaces_run_id == stale.id
      assert replacement.connect_generation == "gen-2"
      assert replacement.snapshot_id == nil
      assert replacement.command_receipts == %{}
      assert evidence.old_connect_generation == "gen-1"

      assert {:error, :connect_generation_not_advanced} =
               StateMachine.restart_after_reconnect(stale, "run-3",
                 connect_id: "connect-2",
                 connect_generation: "gen-1",
                 source_workspace_id: "workspace-1"
               )

      assert {:error, :source_workspace_mismatch} =
               StateMachine.restart_after_reconnect(stale, "run-3",
                 connect_id: "connect-2",
                 connect_generation: "gen-2",
                 source_workspace_id: "workspace-other"
               )

      assert {:error, :replacement_run_id_reused} =
               StateMachine.restart_after_reconnect(stale, stale.id,
                 connect_id: "connect-2",
                 connect_generation: "gen-2",
                 source_workspace_id: "workspace-1"
               )
    end

    test "disconnect after snapshot freeze does not block derivation or commit" do
      preview = preview_fixture()

      assert {:ok, unchanged, %{effect: :frozen_snapshot_unchanged}} =
               StateMachine.source_disconnected(preview, preview.generation)

      assert unchanged == preview

      assert {:ok, committed, _receipt} =
               StateMachine.commit(
                 unchanged,
                 unchanged.generation,
                 "commit-after-disconnect",
                 commit_evidence(unchanged)
               )

      assert StateMachine.effective_visible?(committed, true)

      assert {:ok, still_committed, %{effect: :frozen_snapshot_unchanged}} =
               StateMachine.source_disconnected(committed, committed.generation)

      assert still_committed == committed
      assert StateMachine.effective_visible?(still_committed, true)

      assert {:ok, refresh, %{replaces_run_id: "run-1"}} =
               StateMachine.restart_after_reconnect(still_committed, "run-2",
                 connect_id: "connect-2",
                 connect_generation: "gen-2",
                 source_workspace_id: "workspace-1"
               )

      assert refresh.state == :created
      assert refresh.snapshot_id == nil
      assert StateMachine.effective_visible?(still_committed, true)

      {:ok, refresh, _event} = StateMachine.start_acquisition(refresh, refresh.generation)

      {:ok, refresh, _event} =
        StateMachine.complete_acquisition(refresh, refresh.generation, "snapshot-2")

      {:ok, refresh, _event} =
        StateMachine.start_derivation(refresh, refresh.generation, "derivation-2")

      {:ok, refresh, _event} =
        StateMachine.complete_derivation(refresh, refresh.generation, "review-2")

      assert {:ok, refreshed_context, _receipt} =
               StateMachine.commit(
                 refresh,
                 refresh.generation,
                 "commit-refresh",
                 commit_evidence(refresh, "publication-2")
               )

      assert StateMachine.effective_visible?(still_committed, true)
      assert StateMachine.effective_visible?(refreshed_context, true)
    end

    test "source disconnect cannot turn a frozen derivation pause into a retired source" do
      run = new_run()
      {:ok, run, _event} = StateMachine.start_acquisition(run, run.generation)
      {:ok, run, _event} = StateMachine.complete_acquisition(run, run.generation, "snapshot-1")

      {:ok, deriving, _event} =
        StateMachine.start_derivation(run, run.generation, "derivation-1")

      assert {:ok, unchanged, %{effect: :frozen_snapshot_unchanged}} =
               StateMachine.pause(
                 deriving,
                 deriving.generation,
                 :source_disconnected,
                 nil
               )

      assert unchanged == deriving

      assert {:ok, processor_paused, %{to: :paused}} =
               StateMachine.pause(deriving, deriving.generation, :processor_unavailable, nil)

      assert {:ok, still_paused, %{effect: :frozen_snapshot_unchanged}} =
               StateMachine.source_disconnected(processor_paused, processor_paused.generation)

      assert still_paused == processor_paused

      assert {:ok, resumed, %{to: :deriving}} =
               StateMachine.resume(still_paused, still_paused.generation)

      assert resumed.state == :deriving
    end
  end

  describe "atomic commit, cancel, and rollback" do
    test "commit requires exact preview evidence and a validated publication scope" do
      run = preview_fixture()
      evidence = commit_evidence(run)

      assert {:error, :publication_scope_invalid} =
               StateMachine.commit(
                 run,
                 run.generation,
                 "commit-denied",
                 %{evidence | publication_scope_validated?: false}
               )

      assert {:error, :actor_unauthorized} =
               StateMachine.commit(
                 run,
                 run.generation,
                 "commit-actor-denied",
                 %{evidence | actor_authorized?: false}
               )

      assert {:error, :preview_evidence_mismatch} =
               StateMachine.commit(
                 run,
                 run.generation,
                 "commit-wrong-preview",
                 %{evidence | review_revision_id: "review-other"}
               )

      assert {:error, :invalid_publication_id} =
               StateMachine.commit(
                 run,
                 run.generation,
                 "commit-empty-publication",
                 %{evidence | publication_id: ""}
               )

      assert {:error, :explicit_confirmation_required} =
               StateMachine.commit(
                 run,
                 run.generation,
                 "commit-unconfirmed",
                 Map.delete(evidence, :confirmed?)
               )

      expected_generation = run.generation

      assert {:ok, committed, %{kind: :committed, command_id: "commit-1"}} =
               StateMachine.commit(run, expected_generation, "commit-1", evidence)

      assert committed.commit_base_generation == expected_generation
      assert StateMachine.effective_visible?(committed, true)
      refute StateMachine.effective_visible?(committed, false)
      refute StateMachine.effective_visible?(%{committed | publication_id: ""}, true)

      assert {:ok, replayed, %{replayed?: true, kind: :committed}} =
               StateMachine.commit(committed, expected_generation, "commit-1", evidence)

      assert replayed == committed
    end

    test "a late accepted cancel becomes server-owned rollback after commit wins" do
      preview = preview_fixture()
      expected_generation = preview.generation

      {:ok, committed, _receipt} =
        StateMachine.commit(preview, expected_generation, "commit-1", commit_evidence(preview))

      assert {:ok, rolled_back, %{kind: :rolled_back_after_late_cancel}} =
               StateMachine.cancel(committed, expected_generation, "cancel-1")

      refute StateMachine.effective_visible?(rolled_back, true)

      assert {:ok, replayed, %{replayed?: true, kind: :rolled_back_after_late_cancel}} =
               StateMachine.cancel(rolled_back, expected_generation, "cancel-1")

      assert replayed == rolled_back
    end

    test "cancel wins before commit, and unrelated stale cancel cannot roll back later" do
      preview = preview_fixture()
      expected_generation = preview.generation

      assert {:ok, canceled, %{kind: :canceled}} =
               StateMachine.cancel(preview, expected_generation, "cancel-1")

      assert {:error, {:invalid_transition, :canceled, :commit}} =
               StateMachine.commit(
                 canceled,
                 canceled.generation,
                 "commit-1",
                 commit_evidence(preview)
               )

      {:ok, committed, _receipt} =
        StateMachine.commit(preview, expected_generation, "commit-2", commit_evidence(preview))

      assert {:error, :stale_run_generation} =
               StateMachine.cancel(committed, expected_generation - 1, "cancel-stale")
    end

    test "explicit rollback is atomic and idempotent by command id" do
      preview = preview_fixture()

      {:ok, committed, _receipt} =
        StateMachine.commit(
          preview,
          preview.generation,
          "commit-1",
          commit_evidence(preview)
        )

      assert {:ok, rolled_back, %{kind: :rolled_back}} =
               StateMachine.rollback(committed, committed.generation, "rollback-1")

      refute StateMachine.effective_visible?(rolled_back, true)

      assert {:ok, replayed, %{replayed?: true, kind: :rolled_back}} =
               StateMachine.rollback(rolled_back, committed.generation, "rollback-1")

      assert replayed == rolled_back
    end
  end

  defp new_run do
    {:ok, run} =
      StateMachine.new("run-1",
        connect_id: "connect-1",
        connect_generation: "gen-1",
        source_workspace_id: "workspace-1"
      )

    run
  end

  defp preview_fixture do
    run = new_run()
    {:ok, run, _event} = StateMachine.start_acquisition(run, run.generation)
    {:ok, run, _event} = StateMachine.complete_acquisition(run, run.generation, "snapshot-1")
    {:ok, run, _event} = StateMachine.start_derivation(run, run.generation, "derivation-1")
    {:ok, run, _event} = StateMachine.complete_derivation(run, run.generation, "review-1")
    run
  end

  defp commit_evidence(run, publication_id \\ "publication-1") do
    %{
      snapshot_id: run.snapshot_id,
      derivation_id: run.derivation_id,
      review_revision_id: run.review_revision_id,
      publication_id: publication_id,
      actor_authorized?: true,
      publication_scope_validated?: true,
      confirmed?: true
    }
  end
end
