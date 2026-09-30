defmodule BridgeForTeams.ContextLifecycle.SlackHistoryPurger do
  @moduledoc """
  Storage-layout purge for a Slack-history context bundle.

  The shared lifecycle owner invokes this adapter inside its transaction. The
  import-run row remains as a content-free tombstone so reconnect replacement
  links and audit identity stay valid; channel metadata, cursors, source
  payloads, derived artifacts, reviews, and publications are physically
  deleted. Retention and restore decisions remain in `ContextLifecycle`.

  The owning transaction and lease protocol are modeled in
  `tla/salix/ContextLifecyclePurge.tla`.
  """

  @behaviour BridgeForTeams.ContextLifecycle.Purger

  import Ecto.Query

  alias BridgeForTeams.Repo

  alias BridgeForTeams.Schema.{
    ContextBundle,
    SlackHistoryImportChannel,
    SlackHistoryImportCommandReceipt,
    SlackHistoryImportRun,
    SlackHistoryPageReceipt,
    SlackHistoryStreamCheckpoint,
    SourcedContextArtifact,
    SourcedContextArtifactSource,
    SourcedContextDerivation,
    SourcedContextDerivationAttempt,
    SourcedContextObject,
    SourcedContextPublication,
    SourcedContextReviewRevision,
    SourcedContextSnapshot
  }

  @impl true
  def purge(%ContextBundle{source_type: "slack_history_import"} = bundle) do
    with {:ok, run_id} <- cast_run_id(bundle.source_ref),
         %SlackHistoryImportRun{} = run <- Repo.get(SlackHistoryImportRun, run_id),
         true <- run.context_bundle_id == bundle.id do
      counts = purge_run_content(run.id)

      {:ok,
       counts
       |> Map.put("payloads_deleted", payload_count(counts))
       |> Map.put("rows_deleted", counts |> Map.values() |> Enum.sum())}
    else
      :error -> {:error, {:terminal, :invalid_slack_history_bundle_identity}}
      nil -> {:error, {:terminal, :slack_history_run_not_found}}
      false -> {:error, {:terminal, :slack_history_bundle_mismatch}}
    end
  end

  def purge(%ContextBundle{}),
    do: {:error, {:terminal, :unsupported_context_source_type}}

  defp purge_run_content(run_id) do
    %{}
    |> put_count(
      "publications_deleted",
      delete_all(
        from(publication in SourcedContextPublication, where: publication.run_id == ^run_id)
      )
    )
    |> put_count(
      "command_receipts_deleted",
      delete_all(
        from(receipt in SlackHistoryImportCommandReceipt, where: receipt.run_id == ^run_id)
      )
    )
    |> put_count("review_items_deleted", delete_review_items(run_id))
    |> put_count(
      "artifact_sources_deleted",
      delete_all(
        from(source in SourcedContextArtifactSource,
          join: artifact in SourcedContextArtifact,
          on: artifact.id == source.artifact_id,
          join: derivation in SourcedContextDerivation,
          on: derivation.id == artifact.derivation_id,
          where: derivation.run_id == ^run_id,
          select: source
        )
      )
    )
    |> put_count(
      "derivation_attempts_deleted",
      delete_all(
        from(attempt in SourcedContextDerivationAttempt, where: attempt.run_id == ^run_id)
      )
    )
    |> put_count("review_revisions_deleted", delete_review_revisions(run_id))
    |> put_count(
      "artifacts_deleted",
      delete_all(
        from(artifact in SourcedContextArtifact,
          join: derivation in SourcedContextDerivation,
          on: derivation.id == artifact.derivation_id,
          where: derivation.run_id == ^run_id,
          select: artifact
        )
      )
    )
    |> put_count("derivations_deleted", delete_derivations(run_id))
    |> put_count(
      "snapshots_deleted",
      delete_all(from(snapshot in SourcedContextSnapshot, where: snapshot.run_id == ^run_id))
    )
    |> put_count(
      "source_objects_deleted",
      delete_all(from(object in SourcedContextObject, where: object.run_id == ^run_id))
    )
    |> put_count(
      "page_receipts_deleted",
      delete_all(from(receipt in SlackHistoryPageReceipt, where: receipt.run_id == ^run_id))
    )
    |> put_count(
      "stream_checkpoints_deleted",
      delete_all(
        from(checkpoint in SlackHistoryStreamCheckpoint, where: checkpoint.run_id == ^run_id)
      )
    )
    |> put_count(
      "channels_deleted",
      delete_all(from(channel in SlackHistoryImportChannel, where: channel.run_id == ^run_id))
    )
  end

  # Review revisions and derivations are immutable parent-linked chains with
  # ON DELETE RESTRICT. Newest-first single-row deletes preserve that contract.
  defp delete_review_revisions(run_id) do
    from(review in SourcedContextReviewRevision,
      where: review.run_id == ^run_id,
      order_by: [desc: review.revision, desc: review.id],
      select: review.id
    )
    |> Repo.all()
    |> Enum.reduce(0, fn id, count ->
      count + delete_all(from(review in SourcedContextReviewRevision, where: review.id == ^id))
    end)
  end

  defp delete_derivations(run_id) do
    from(derivation in SourcedContextDerivation,
      where: derivation.run_id == ^run_id,
      order_by: [desc: derivation.completed_at, desc: derivation.id],
      select: derivation.id
    )
    |> Repo.all()
    |> Enum.reduce(0, fn id, count ->
      count +
        delete_all(from(derivation in SourcedContextDerivation, where: derivation.id == ^id))
    end)
  end

  defp delete_review_items(run_id) do
    result =
      Repo.query!(
        """
        DELETE FROM sourced_context_review_items AS item
        USING sourced_context_review_revisions AS review
        WHERE item.review_revision_id = review.id AND review.run_id = $1
        """,
        [Ecto.UUID.dump!(run_id)]
      )

    result.num_rows
  end

  defp delete_all(query) do
    {count, _rows} = Repo.delete_all(query)
    count
  end

  defp put_count(counts, key, value), do: Map.put(counts, key, value)

  defp payload_count(counts) do
    counts["source_objects_deleted"] + counts["artifacts_deleted"] +
      counts["review_items_deleted"] + counts["page_receipts_deleted"] +
      counts["stream_checkpoints_deleted"]
  end

  defp cast_run_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end
end
