defmodule BridgeForTeams.SourcedContext.Publications do
  @moduledoc """
  Atomic explicit commit, cancel, and rollback for sourced-context previews.

  A publication is the only audience edge. Commit activates it in the same
  row-locked transaction that advances the import run and records an immutable
  command receipt. Rollback and a late cancel deactivate it in the same manner.
  Neither operation deletes the source bundle or changes Slack connection
  state. Commit validates the fixed product publication scope; it does not
  claim current recipient authorization, which remains a feature-off runtime
  integration gate.
  """

  import Ecto.Query

  alias BridgeForTeams.{Memberships, Repo, SlackHistoryImports}
  alias BridgeForTeams.SlackHistoryImport.StateMachine
  alias BridgeForTeams.SourcedContext.Instrumentation

  alias BridgeForTeams.Schema.{
    ContextBundle,
    SlackHistoryImportCommandReceipt,
    SlackHistoryImportRun,
    SourcedContextDerivation,
    SourcedContextPublication,
    SourcedContextReviewItem,
    SourcedContextReviewRevision,
    SourcedContextSnapshot
  }

  @spec commit(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def commit(run_id, attrs) when is_map(attrs) do
    Instrumentation.measure(:sourced_context_publication, fn ->
      with :ok <- commit_feature_enabled(),
           {:ok, command} <- normalize_commit(attrs) do
        transaction(fn -> persist_commit(run_id, command) end)
      end
    end)
    |> audit_publication("sourced_context.preview.committed")
  end

  def commit(_run_id, _attrs), do: {:error, :invalid_commit_command}

  @spec rollback(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def rollback(run_id, attrs) when is_map(attrs) do
    Instrumentation.measure(:sourced_context_publication, fn ->
      with {:ok, command} <- normalize_terminal_command(attrs, :rollback) do
        transaction(fn -> persist_rollback(run_id, command) end)
      end
    end)
    |> audit_publication("sourced_context.publication.rolled_back")
  end

  def rollback(_run_id, _attrs), do: {:error, :invalid_rollback_command}

  @spec cancel(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def cancel(run_id, attrs) when is_map(attrs) do
    Instrumentation.measure(:sourced_context_publication, fn ->
      with {:ok, command} <- normalize_terminal_command(attrs, :cancel) do
        transaction(fn -> persist_cancel(run_id, command) end)
      end
    end)
    |> audit_publication("sourced_context.import.canceled")
  end

  def cancel(_run_id, _attrs), do: {:error, :invalid_cancel_command}

  defp persist_commit(run_id, command) do
    {bundle, run} = lock_lifecycle_run(run_id)
    :ok = authorize_admin(command.user_id, run.project_id)

    case lock_receipt(run.id, command.command_id) do
      %SlackHistoryImportCommandReceipt{} = receipt ->
        replay_commit(run, receipt, command)

      nil ->
        :ok = require_lifecycle_ready(bundle)
        new_commit(run, command)
    end
  end

  defp new_commit(run, command) do
    :ok = ensure_supported_publication_scope(run)
    :ok = ensure_commit_evidence(run, command)
    publication_id = Ecto.UUID.generate()

    evidence = %{
      snapshot_id: command.snapshot_id,
      derivation_id: command.derivation_id,
      review_revision_id: command.review_revision_id,
      publication_id: publication_id,
      actor_authorized?: true,
      publication_scope_validated?: true,
      confirmed?: command.confirmed?
    }

    {committed_run, protocol_receipt} =
      SlackHistoryImports.transition_in_transaction(run.id, fn protocol_run ->
        StateMachine.commit(
          protocol_run,
          command.expected_generation,
          command.command_id,
          evidence
        )
      end)

    now = DateTime.utc_now()

    publication =
      %SourcedContextPublication{id: publication_id}
      |> SourcedContextPublication.active_changeset(%{
        id: publication_id,
        run_id: run.id,
        bundle_id: run.context_bundle_id,
        review_revision_id: command.review_revision_id,
        status: "active",
        audience_scope: run.audience_scope,
        committed_by_user_id: command.user_id,
        commit_command_id: command.command_id,
        activated_at: now
      })
      |> Repo.insert!()

    result = %{
      "publication_id" => publication.id,
      "snapshot_id" => command.snapshot_id,
      "derivation_id" => command.derivation_id,
      "review_revision_id" => command.review_revision_id,
      "committed_by_user_id" => command.user_id
    }

    receipt =
      insert_receipt!(
        run.id,
        command.command_id,
        protocol_receipt.kind,
        command.expected_generation,
        committed_run.generation,
        result,
        now
      )

    %{
      run: committed_run,
      publication: publication,
      receipt: receipt,
      replayed?: false
    }
  end

  defp replay_commit(run, receipt, command) do
    expected = %{
      "publication_id" => receipt.result["publication_id"],
      "snapshot_id" => command.snapshot_id,
      "derivation_id" => command.derivation_id,
      "review_revision_id" => command.review_revision_id,
      "committed_by_user_id" => command.user_id
    }

    cond do
      receipt.kind != "committed" ->
        Repo.rollback(:command_id_conflict)

      not command.confirmed? ->
        Repo.rollback(:explicit_confirmation_required)

      Map.take(receipt.result, Map.keys(expected)) != expected ->
        Repo.rollback(:command_id_conflict)

      true ->
        publication =
          Repo.get(SourcedContextPublication, receipt.result["publication_id"]) ||
            Repo.rollback(:publication_receipt_inconsistent)

        %{
          run: run,
          publication: publication,
          receipt: receipt,
          replayed?: true
        }
    end
  end

  defp persist_rollback(run_id, command) do
    {_bundle, run} = lock_lifecycle_run(run_id)
    :ok = authorize_admin(command.user_id, run.project_id)

    case lock_receipt(run.id, command.command_id) do
      %SlackHistoryImportCommandReceipt{} = receipt ->
        replay_terminal(run, receipt, command, ["rolled_back"])

      nil ->
        new_rollback(run, command)
    end
  end

  defp new_rollback(run, command) do
    publication = lock_publication(run)

    {rolled_back_run, protocol_receipt} =
      SlackHistoryImports.transition_in_transaction(run.id, fn protocol_run ->
        StateMachine.rollback(
          protocol_run,
          command.expected_generation,
          command.command_id
        )
      end)

    now = DateTime.utc_now()
    publication = deactivate!(publication, now, command.reason)

    result = %{
      "publication_id" => publication.id,
      "deactivation_reason" => command.reason,
      "requested_by_user_id" => command.user_id
    }

    receipt =
      insert_receipt!(
        run.id,
        command.command_id,
        protocol_receipt.kind,
        command.expected_generation,
        rolled_back_run.generation,
        result,
        now
      )

    %{
      run: rolled_back_run,
      publication: publication,
      receipt: receipt,
      replayed?: false
    }
  end

  defp persist_cancel(run_id, command) do
    {_bundle, run} = lock_lifecycle_run(run_id)
    :ok = authorize_admin(command.user_id, run.project_id)

    case lock_receipt(run.id, command.command_id) do
      %SlackHistoryImportCommandReceipt{} = receipt ->
        replay_terminal(run, receipt, command, ["canceled", "rolled_back_after_late_cancel"])

      nil ->
        new_cancel(run, command)
    end
  end

  defp new_cancel(run, command) do
    {canceled_run, protocol_receipt} =
      SlackHistoryImports.transition_in_transaction(run.id, fn protocol_run ->
        StateMachine.cancel(
          protocol_run,
          command.expected_generation,
          command.command_id
        )
      end)

    now = DateTime.utc_now()

    publication =
      case protocol_receipt.kind do
        :rolled_back_after_late_cancel ->
          run
          |> lock_publication()
          |> deactivate!(now, command.reason)

        :canceled ->
          nil
      end

    result = %{
      "publication_id" => publication && publication.id,
      "deactivation_reason" => command.reason,
      "requested_by_user_id" => command.user_id
    }

    receipt =
      insert_receipt!(
        run.id,
        command.command_id,
        protocol_receipt.kind,
        command.expected_generation,
        canceled_run.generation,
        result,
        now
      )

    %{
      run: canceled_run,
      publication: publication,
      receipt: receipt,
      replayed?: false
    }
  end

  defp replay_terminal(run, receipt, command, allowed_kinds) do
    expected = %{
      "deactivation_reason" => command.reason,
      "requested_by_user_id" => command.user_id
    }

    cond do
      receipt.kind not in allowed_kinds ->
        Repo.rollback(:command_id_conflict)

      Map.take(receipt.result, Map.keys(expected)) != expected ->
        Repo.rollback(:command_id_conflict)

      true ->
        publication =
          case receipt.result["publication_id"] do
            nil -> nil
            id -> Repo.get(SourcedContextPublication, id)
          end

        %{
          run: run,
          publication: publication,
          receipt: receipt,
          replayed?: true
        }
    end
  end

  defp ensure_commit_evidence(run, command) do
    with true <- run.state == "preview_ready",
         true <- run.generation == command.expected_generation,
         true <- run.snapshot_id == command.snapshot_id,
         true <- run.derivation_id == command.derivation_id,
         true <- run.review_revision_id == command.review_revision_id,
         %SourcedContextSnapshot{run_id: run_id, coverage: %{"complete" => true}} <-
           Repo.get(SourcedContextSnapshot, command.snapshot_id),
         true <- run_id == run.id,
         %SourcedContextDerivation{run_id: run_id, snapshot_id: snapshot_id} <-
           Repo.get(SourcedContextDerivation, command.derivation_id),
         true <- run_id == run.id and snapshot_id == command.snapshot_id,
         %SourcedContextReviewRevision{
           run_id: run_id,
           snapshot_id: snapshot_id,
           derivation_id: derivation_id,
           selected_count: selected_count
         } <- Repo.get(SourcedContextReviewRevision, command.review_revision_id),
         true <-
           run_id == run.id and snapshot_id == command.snapshot_id and
             derivation_id == command.derivation_id,
         true <- selected_count > 0,
         true <- review_item_count(command.review_revision_id) == selected_count,
         true <- command.confirmed? do
      :ok
    else
      false -> commit_evidence_error(run, command)
      nil -> {:error, :preview_evidence_mismatch} |> rollback_error()
      _mismatch -> {:error, :preview_evidence_mismatch} |> rollback_error()
    end
  end

  defp ensure_supported_publication_scope(%{audience_scope: "project-public-channels:v1"}),
    do: :ok

  defp ensure_supported_publication_scope(_run), do: Repo.rollback(:publication_scope_invalid)

  defp commit_evidence_error(run, command) do
    reason =
      cond do
        not command.confirmed? ->
          :explicit_confirmation_required

        run.state != "preview_ready" ->
          {:invalid_transition, run.state, :commit}

        run.generation != command.expected_generation ->
          :stale_run_generation

        run.snapshot_id != command.snapshot_id or run.derivation_id != command.derivation_id or
            run.review_revision_id != command.review_revision_id ->
          :preview_evidence_mismatch

        true ->
          :empty_or_incomplete_review
      end

    Repo.rollback(reason)
  end

  defp review_item_count(review_id) do
    Repo.aggregate(
      from(item in SourcedContextReviewItem, where: item.review_revision_id == ^review_id),
      :count
    )
  end

  defp lock_run(id) do
    Repo.one(
      from(run in SlackHistoryImportRun,
        where: run.id == ^id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  # Deletion/erasure and authorized context reads own the bundle lock. Every
  # publication visibility mutation takes that lock before the run lock, so a
  # returned lifecycle/rollback/cancel command cannot race a plaintext read,
  # and an older preview cannot publish after a lifecycle request returns.
  defp lock_lifecycle_run(run_id) do
    bundle_id =
      Repo.one(
        from(run in SlackHistoryImportRun,
          where: run.id == ^run_id,
          select: run.context_bundle_id
        )
      ) || Repo.rollback(:not_found)

    bundle =
      Repo.one(
        from(bundle in ContextBundle,
          where: bundle.id == ^bundle_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:context_lifecycle_not_ready)

    run = lock_run(run_id)

    if run.context_bundle_id == bundle.id,
      do: {bundle, run},
      else: Repo.rollback(:context_lifecycle_not_ready)
  end

  defp require_lifecycle_ready(%ContextBundle{
         lifecycle_state: "registered",
         subject_index_state: "complete"
       }),
       do: :ok

  defp require_lifecycle_ready(_bundle), do: Repo.rollback(:context_lifecycle_not_ready)

  defp lock_receipt(run_id, command_id) do
    Repo.one(
      from(receipt in SlackHistoryImportCommandReceipt,
        where: receipt.run_id == ^run_id and receipt.command_id == ^command_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_publication(run) do
    publication =
      Repo.one(
        from(publication in SourcedContextPublication,
          where: publication.run_id == ^run.id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:publication_not_found)

    if publication.id == run.publication_id and publication.status == "active" do
      publication
    else
      Repo.rollback(:publication_state_inconsistent)
    end
  end

  defp deactivate!(publication, now, reason) do
    publication
    |> SourcedContextPublication.deactivate_changeset(%{
      status: "inactive",
      deactivated_at: now,
      deactivation_reason: reason
    })
    |> Repo.update!()
  end

  defp insert_receipt!(
         run_id,
         command_id,
         kind,
         expected_generation,
         resulting_generation,
         result,
         now
       ) do
    %SlackHistoryImportCommandReceipt{}
    |> SlackHistoryImportCommandReceipt.changeset(%{
      run_id: run_id,
      command_id: command_id,
      kind: Atom.to_string(kind),
      expected_generation: expected_generation,
      resulting_generation: resulting_generation,
      result: result,
      created_at: now
    })
    |> Repo.insert!()
  end

  defp normalize_commit(attrs) do
    with {:ok, expected_generation} <- expected_generation(attrs),
         {:ok, user_id} <- uuid(value(attrs, :user_id), :invalid_user_id),
         {:ok, command_id} <- command_id(value(attrs, :command_id)),
         {:ok, snapshot_id} <- uuid(value(attrs, :snapshot_id), :invalid_snapshot_id),
         {:ok, derivation_id} <- uuid(value(attrs, :derivation_id), :invalid_derivation_id),
         {:ok, review_revision_id} <-
           uuid(value(attrs, :review_revision_id), :invalid_review_revision_id),
         confirmed? when is_boolean(confirmed?) <- value(attrs, :confirmed?) do
      {:ok,
       %{
         expected_generation: expected_generation,
         user_id: user_id,
         command_id: command_id,
         snapshot_id: snapshot_id,
         derivation_id: derivation_id,
         review_revision_id: review_revision_id,
         confirmed?: confirmed?
       }}
    else
      nil -> {:error, :explicit_confirmation_required}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_commit_command}
    end
  end

  defp normalize_terminal_command(attrs, kind) do
    with {:ok, expected_generation} <- expected_generation(attrs),
         {:ok, user_id} <- uuid(value(attrs, :user_id), :invalid_user_id),
         {:ok, command_id} <- command_id(value(attrs, :command_id)),
         {:ok, reason} <- reason(value(attrs, :reason), kind) do
      {:ok,
       %{
         expected_generation: expected_generation,
         user_id: user_id,
         command_id: command_id,
         reason: reason
       }}
    end
  end

  defp expected_generation(attrs) do
    case value(attrs, :expected_generation) do
      generation when is_integer(generation) and generation >= 0 -> {:ok, generation}
      _ -> {:error, :invalid_expected_generation}
    end
  end

  defp command_id(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 256,
      do: {:ok, value},
      else: {:error, :invalid_command_id}
  end

  defp command_id(_value), do: {:error, :invalid_command_id}

  defp reason(value, kind) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 256,
      do: {:ok, value},
      else: {:error, invalid_terminal_command(kind)}
  end

  defp reason(nil, kind), do: {:ok, Atom.to_string(kind)}
  defp reason(_value, kind), do: {:error, invalid_terminal_command(kind)}

  defp invalid_terminal_command(:rollback), do: :invalid_rollback_command
  defp invalid_terminal_command(:cancel), do: :invalid_cancel_command

  defp authorize_admin(user_id, project_id) do
    case Memberships.authorize(user_id, :write, %{
           project_id: project_id,
           min_project_role: "admin"
         }) do
      :ok -> :ok
      {:error, _reason} -> Repo.rollback(:forbidden)
    end
  end

  defp commit_feature_enabled do
    if Keyword.get(
         Application.get_env(:bridge_for_teams_core, :sourced_context_features, []),
         :commit,
         false
       ),
       do: :ok,
       else: {:error, {:feature_disabled, :commit}}
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  defp audit_publication({:ok, %{replayed?: false} = result} = response, action) do
    run = result.run
    receipt = result.receipt
    receipt_result = receipt.result || %{}

    actor_user_id =
      receipt_result["committed_by_user_id"] || receipt_result["requested_by_user_id"]

    Instrumentation.record_audit(
      action,
      %{
        org_id: run.org_id,
        project_id: run.project_id,
        resource_type: "slack_history_import_run",
        resource_id: run.id,
        resource_label: "Slack history onboarding"
      },
      actor_user_id,
      receipt.id,
      %{
        state: run.state,
        generation: run.generation,
        snapshot_id: run.snapshot_id,
        derivation_id: run.derivation_id,
        review_revision_id: run.review_revision_id,
        publication_id: receipt_result["publication_id"],
        command_kind: receipt.kind
      }
    )

    response
  end

  defp audit_publication(response, _action), do: response

  defp rollback_error({:error, reason}), do: Repo.rollback(reason)

  defp uuid(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, error}
    end
  end

  defp value(map, key, default \\ nil) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
