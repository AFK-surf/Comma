defmodule BridgeForTeams.SourcedContext.SlackAcquisition do
  @moduledoc """
  BFT-side one-page acquisition coordinator.

  It selects the next durable stream checkpoint, asks Salix for one read-only
  generation-fenced page, and atomically accepts that envelope into BFT. A
  rate limit or transient provider failure records a bounded retry before the
  run is paused. It never sleeps while holding work and never calls a model.
  Retry checkpoint + pause atomicity is anchored by `RecordRetryAndPause` in
  `tla/salix/SlackHistoryImport.tla`.
  """

  import Ecto.Query

  alias BridgeForTeams.{Repo, SlackHistoryImports}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{SlackHistoryImportRun, SlackHistoryStreamCheckpoint}
  alias BridgeForTeams.SourcedContext.Acquisition

  @terminal_acquisition_errors [
    :invalid_provider_page,
    :invalid_messages,
    :invalid_message,
    :invalid_file_metadata,
    :invalid_slack_ts,
    :invalid_root_ts,
    :invalid_stream_kind,
    :invalid_boolean,
    :invalid_page_ordinal,
    :invalid_stream_completion,
    :invalid_page_envelope,
    :invalid_page_response_hash,
    :page_response_hash_mismatch,
    :page_receipt_conflict,
    :source_object_conflict,
    :message_outside_run_range,
    :channel_outside_run_scope,
    :reply_root_outside_discovered_history
  ]

  @spec acquire_one_page(Ecto.UUID.t(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def acquire_one_page(run_id, expected_generation) do
    with {:ok, %SlackHistoryImportRun{} = run} <- SlackHistoryImports.get_run(run_id),
         :ok <- validate_run(run, expected_generation),
         {:ok, stream} <- next_stream(run),
         {:ok, checkpoint} <- checkpoint(run.id, stream),
         request = page_request(run, stream, checkpoint),
         {:ok, envelope} <- Client.impl().slack_history_read_page(request),
         {:ok, receipt} <- Acquisition.accept_page(run.id, expected_generation, envelope) do
      {:ok, receipt}
    else
      {:complete, :all_streams} ->
        {:ok, :ready_to_finalize}

      {:error, {:rate_limited, delay_ms}} when is_integer(delay_ms) and delay_ms > 0 ->
        pause_after_retry(run_id, expected_generation, :rate_limited, delay_ms)

      {:error, :invalid_cursor} ->
        pause_after_cursor_recovery(run_id, expected_generation)

      {:error, reason}
      when reason in [:stale_source, :channel_ineligible, :channel_authority_changed] ->
        SlackHistoryImports.source_disconnected(run_id, expected_generation)

      {:error, reason}
      when reason in [
             :source_unavailable,
             :source_authority_unavailable,
             :unavailable,
             :timeout
           ] ->
        pause_after_retry(run_id, expected_generation, :provider_unavailable, nil)

      {:error, {:feature_disabled, _feature} = reason} ->
        {:error, reason}

      {:error, :disabled} ->
        {:error, {:feature_disabled, :salix_slack_history_read}}

      {:error, reason}
      when reason in [
             :page_object_bound_exceeded,
             :run_page_bound_exceeded,
             :run_object_bound_exceeded,
             :run_byte_bound_exceeded,
             :too_many_subjects
           ] ->
        SlackHistoryImports.pause(run_id, expected_generation, :bound_reached, nil)

      {:error, reason} when reason in @terminal_acquisition_errors ->
        SlackHistoryImports.fail_terminal(run_id, expected_generation, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec finalize(Ecto.UUID.t(), non_neg_integer(), String.t()) ::
          {:ok, SlackHistoryImportRun.t(), struct()} | {:error, term()}
  def finalize(run_id, expected_generation, normalization_revision) do
    Acquisition.finalize_snapshot(run_id, expected_generation,
      normalization_revision: normalization_revision
    )
  end

  defp validate_run(run, expected_generation) do
    cond do
      run.generation != expected_generation -> {:error, :stale_run_generation}
      run.state != "acquiring" -> {:error, {:invalid_transition, run.state, :acquire_page}}
      true -> :ok
    end
  end

  defp next_stream(run) do
    checkpoints =
      Repo.all(
        from(checkpoint in SlackHistoryStreamCheckpoint,
          where: checkpoint.run_id == ^run.id,
          order_by: [
            asc: checkpoint.channel_id,
            asc: checkpoint.stream_kind,
            asc: checkpoint.root_ts
          ]
        )
      )

    by_key = Map.new(checkpoints, &{stream_key(&1), &1})

    missing_or_incomplete_history =
      Enum.find_value(run.channels, fn channel ->
        key = {channel.channel_id, "history", ""}

        case Map.get(by_key, key) do
          nil -> %{channel: channel, stream_kind: "history", root_ts: ""}
          %{complete: false} -> %{channel: channel, stream_kind: "history", root_ts: ""}
          %{complete: true} -> nil
        end
      end)

    cond do
      missing_or_incomplete_history ->
        {:ok, missing_or_incomplete_history}

      checkpoint = Enum.find(checkpoints, &(&1.stream_kind == "replies" and not &1.complete)) ->
        channel = Enum.find(run.channels, &(&1.channel_id == checkpoint.channel_id))

        {:ok,
         %{
           channel: channel,
           stream_kind: "replies",
           root_ts: checkpoint.root_ts
         }}

      true ->
        {:complete, :all_streams}
    end
  end

  defp checkpoint(run_id, stream) do
    case Acquisition.get_checkpoint(
           run_id,
           stream.channel.channel_id,
           stream.stream_kind,
           stream.root_ts
         ) do
      {:ok, checkpoint} -> {:ok, checkpoint}
      {:error, :not_found} -> {:ok, initial_checkpoint()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initial_checkpoint do
    %{
      next_page_ordinal: 0,
      next_cursor: nil,
      timestamp_boundary: nil,
      complete: false,
      retry_count: 0
    }
  end

  defp page_request(run, stream, checkpoint) do
    %{
      tenant_id: run.salix_tenant_id,
      group_id: run.salix_group_id,
      connect_id: run.connect_id,
      expected_connect_generation: run.connect_generation,
      expected_workspace_id: run.source_workspace_id,
      expected_app_id: run.source_app_id,
      channel_id: stream.channel.channel_id,
      expected_channel_authority_revision: stream.channel.authority_revision,
      stream_kind: stream.stream_kind,
      root_ts: stream.root_ts,
      page_ordinal: checkpoint.next_page_ordinal,
      cursor: checkpoint.next_cursor,
      range_start: run.range_start,
      range_end: run.range_end,
      resume_boundary: checkpoint.timestamp_boundary
    }
  end

  defp pause_after_cursor_recovery(run_id, expected_generation) do
    with {:ok, run} <- SlackHistoryImports.get_run(run_id),
         {:ok, stream} <- next_stream(run) do
      Acquisition.pause_stream_retry(
        run_id,
        expected_generation,
        stream.channel.channel_id,
        stream.stream_kind,
        stream.root_ts,
        :provider_unavailable,
        clear_cursor?: true
      )
    end
  end

  defp pause_after_retry(run_id, expected_generation, reason, provider_delay_ms) do
    with {:ok, run} <- SlackHistoryImports.get_run(run_id),
         {:ok, stream} <- next_stream(run) do
      Acquisition.pause_stream_retry(
        run_id,
        expected_generation,
        stream.channel.channel_id,
        stream.stream_kind,
        stream.root_ts,
        reason,
        provider_delay_ms: provider_delay_ms
      )
    end
  end

  defp stream_key(checkpoint),
    do: {checkpoint.channel_id, checkpoint.stream_kind, checkpoint.root_ts}
end
