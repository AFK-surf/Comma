defmodule BridgeForTeams.SourcedContext.Acquisition do
  @moduledoc """
  Durable acceptance boundary for generation-fenced, read-only Slack pages.

  Provider calls happen in Salix. This module accepts only the normalized page
  envelope returned after Salix's post-call generation check. Source objects,
  the immutable page receipt, the encrypted cursor, and the resume checkpoint
  are committed in one BFT transaction. The reverse protocol anchors are
  `AcceptPage`, `ReplayAcceptedPage`, `ReplayConflictingPage`, and
  `RestartAfterAcceptedPage` in `tla/salix/SlackHistoryImport.tla`.
  """

  import Ecto.Query

  alias BridgeForTeams.{ContextLifecycle, Repo, SlackHistoryImports}
  alias BridgeForTeams.SlackHistoryImport.StateMachine
  alias BridgeForTeams.SourcedContext.{CanonicalJSON, Crypto, Instrumentation}

  alias BridgeForTeams.Schema.{
    SlackHistoryImportChannel,
    SlackHistoryImportRun,
    SlackHistoryPageReceipt,
    SlackHistoryStreamCheckpoint,
    SourcedContextObject,
    SourcedContextSnapshot
  }

  @message_keys ~w(
    actor_id actor_kind file_metadata message_ts observable_version reply_count text thread_ts
  )
  @file_keys ~w(id mimetype name size)
  @actor_kinds ~w(user bot app unknown)
  @stream_kinds ~w(history replies)
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @retry_reasons [:rate_limited, :provider_unavailable]
  @provider_backoff_base_ms 1_000
  @provider_backoff_max_ms 60_000

  @spec page_sha256(map()) :: String.t()
  def page_sha256(envelope) when is_map(envelope) do
    envelope = envelope |> Map.delete(:response_sha256) |> Map.delete("response_sha256")
    {:ok, page} = normalized_page(envelope)
    CanonicalJSON.sha256(page.canonical_bytes)
  end

  @spec accept_page(Ecto.UUID.t(), non_neg_integer(), map()) ::
          {:ok, SlackHistoryPageReceipt.t()} | {:error, term()}
  def accept_page(run_id, expected_generation, envelope) when is_map(envelope) do
    Instrumentation.measure(:sourced_context_acquisition, fn ->
      with :ok <- feature_enabled(:acquisition),
           :ok <- encryption_available(),
           {:ok, page} <- normalized_page(envelope) do
        case Repo.transaction(fn -> persist_page(run_id, expected_generation, page) end) do
          {:ok, %SlackHistoryPageReceipt{} = receipt} -> {:ok, receipt}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def accept_page(_run_id, _expected_generation, _envelope),
    do: {:error, :invalid_page_envelope}

  @spec get_checkpoint(Ecto.UUID.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_checkpoint(run_id, channel_id, stream_kind, root_ts) do
    with :ok <- feature_enabled(:acquisition),
         %SlackHistoryStreamCheckpoint{} = checkpoint <-
           Repo.get_by(SlackHistoryStreamCheckpoint,
             run_id: run_id,
             channel_id: channel_id,
             stream_kind: stream_kind,
             root_ts: root_ts
           ),
         {:ok, cursor} <- decrypt_cursor(checkpoint) do
      {:ok,
       %{
         run_id: checkpoint.run_id,
         channel_id: checkpoint.channel_id,
         stream_kind: checkpoint.stream_kind,
         root_ts: checkpoint.root_ts,
         next_page_ordinal: checkpoint.next_page_ordinal,
         timestamp_boundary: checkpoint.timestamp_boundary,
         next_cursor: cursor,
         complete: checkpoint.complete,
         object_count: checkpoint.object_count,
         byte_count: checkpoint.byte_count,
         retry_count: checkpoint.retry_count
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Atomically records one stream retry (optionally clearing its cursor) and pauses the run."
  @spec pause_stream_retry(
          Ecto.UUID.t(),
          non_neg_integer(),
          String.t(),
          String.t(),
          String.t(),
          atom(),
          keyword()
        ) :: {:ok, SlackHistoryImportRun.t(), map()} | {:error, term()}
  def pause_stream_retry(
        run_id,
        expected_generation,
        channel_id,
        stream_kind,
        root_ts,
        reason,
        opts \\ []
      )

  def pause_stream_retry(
        run_id,
        expected_generation,
        channel_id,
        stream_kind,
        root_ts,
        reason,
        opts
      )
      when reason in @retry_reasons and is_list(opts) do
    with :ok <- feature_enabled(:acquisition),
         {:ok, stream_kind} <- stream_kind(stream_kind),
         {:ok, root_ts} <- root_ts(stream_kind, root_ts),
         {:ok, provider_delay_ms} <- optional_delay(Keyword.get(opts, :provider_delay_ms)),
         clear_cursor? when is_boolean(clear_cursor?) <- Keyword.get(opts, :clear_cursor?, false) do
      case Repo.transaction(fn ->
             {_bundle, run} = lock_lifecycle_ready_run!(run_id)

             if run.generation != expected_generation,
               do: Repo.rollback(:stale_run_generation)

             if run.state != "acquiring",
               do: Repo.rollback({:invalid_transition, run.state, :record_retry})

             unless selected_channel_id?(run.id, channel_id),
               do: Repo.rollback(:channel_outside_run_scope)

             checkpoint =
               lock_retry_checkpoint!(run.id, channel_id, stream_kind, root_ts)

             retry_count = checkpoint.retry_count + 1

             {pause_reason, retry_at} =
               if retry_count > bound(:stream_retries) do
                 {:bound_reached, nil}
               else
                 attrs = %{retry_count: retry_count}

                 attrs =
                   if clear_cursor?,
                     do: Map.put(attrs, :provider_cursor_ciphertext, nil),
                     else: attrs

                 checkpoint
                 |> SlackHistoryStreamCheckpoint.changeset(attrs)
                 |> Repo.update!()

                 delay_ms = provider_delay_ms || provider_backoff_ms(retry_count)
                 {reason, DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)}
               end

             SlackHistoryImports.transition_in_transaction(run.id, fn protocol_run ->
               StateMachine.pause(
                 protocol_run,
                 expected_generation,
                 pause_reason,
                 retry_at
               )
             end)
           end) do
        {:ok, {%SlackHistoryImportRun{} = run, event}} -> {:ok, run, event}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_cursor_recovery_option}
    end
  end

  def pause_stream_retry(
        _run_id,
        _expected_generation,
        _channel_id,
        _stream_kind,
        _root_ts,
        _reason,
        _opts
      ),
      do: {:error, :invalid_pause_reason}

  @spec finalize_snapshot(Ecto.UUID.t(), non_neg_integer(), keyword()) ::
          {:ok, SlackHistoryImportRun.t(), SourcedContextSnapshot.t()} | {:error, term()}
  def finalize_snapshot(run_id, expected_generation, opts) when is_list(opts) do
    Instrumentation.measure(:sourced_context_acquisition, fn ->
      with :ok <- feature_enabled(:acquisition),
           {:ok, normalization_revision} <-
             nonempty(Keyword.get(opts, :normalization_revision), :invalid_normalization_revision) do
        case Repo.transaction(fn ->
               persist_snapshot(run_id, expected_generation, normalization_revision)
             end) do
          {:ok, {%SlackHistoryImportRun{} = run, %SourcedContextSnapshot{} = snapshot}} ->
            {:ok, run, snapshot}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
    |> audit_snapshot()
  end

  def finalize_snapshot(_run_id, _expected_generation, _opts),
    do: {:error, :invalid_snapshot_options}

  @spec read_snapshot(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def read_snapshot(snapshot_id) do
    with :ok <- feature_enabled(:derivation),
         %SourcedContextSnapshot{} = snapshot <- Repo.get(SourcedContextSnapshot, snapshot_id),
         {:ok, objects} <- load_snapshot_objects(snapshot) do
      {:ok, %{snapshot: snapshot, objects: objects}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_page(run_id, expected_generation, page) do
    {_bundle, run} = lock_lifecycle_ready_run!(run_id)
    validate_run_for_page!(run, expected_generation, page)
    receipt_key = receipt_key(page)

    case Repo.get_by(SlackHistoryPageReceipt, run_id: run.id, receipt_key: receipt_key) do
      %SlackHistoryPageReceipt{} = existing ->
        replay_page!(existing, page)

      nil ->
        enforce_page_bound!(run.id)
        checkpoint = lock_or_build_checkpoint(run, page)
        validate_checkpoint!(checkpoint, page)
        {new_count, new_bytes, actor_subjects} = persist_objects!(run, page)
        enforce_run_bounds!(run.id)
        add_actor_subjects!(run, actor_subjects)
        cursor_ciphertext = encrypt_cursor!(run.id, page)
        receipt = insert_receipt!(run, page, receipt_key, cursor_ciphertext)
        persist_checkpoint!(checkpoint, page, new_count, new_bytes, cursor_ciphertext)
        ensure_reply_checkpoints!(run.id, page)
        receipt
    end
  end

  defp persist_snapshot(run_id, expected_generation, normalization_revision) do
    {_bundle, run} = lock_lifecycle_ready_run!(run_id)
    run = preload_channels(run)

    if run.generation != expected_generation,
      do: Repo.rollback(:stale_run_generation)

    if run.state != "acquiring",
      do:
        Repo.rollback(
          {:invalid_transition, StateMachine.state_from_storage!(run.state), :finalize_snapshot}
        )

    ensure_complete_coverage!(run)

    objects =
      Repo.all(
        from(object in SourcedContextObject,
          where: object.run_id == ^run.id,
          order_by: [
            asc: object.channel_id,
            asc: object.message_ts,
            asc: object.observable_version
          ]
        )
      )

    receipts =
      Repo.all(
        from(receipt in SlackHistoryPageReceipt,
          where: receipt.run_id == ^run.id,
          order_by: [
            asc: receipt.channel_id,
            asc: receipt.stream_kind,
            asc: receipt.root_ts,
            asc: receipt.page_ordinal
          ]
        )
      )

    if receipts == [], do: Repo.rollback(:snapshot_has_no_pages)

    manifest = manifest(run, objects, receipts, normalization_revision)
    now = DateTime.utc_now()

    snapshot =
      %SourcedContextSnapshot{}
      |> SourcedContextSnapshot.changeset(%{
        run_id: run.id,
        normalization_revision: normalization_revision,
        coverage_profile: run.coverage_profile,
        manifest_sha256: CanonicalJSON.sha256(CanonicalJSON.encode!(manifest)),
        object_count: length(objects),
        byte_count: Enum.sum(Enum.map(objects, & &1.byte_count)),
        coverage: coverage(run, objects, receipts),
        started_at: Enum.min_by(receipts, & &1.created_at, DateTime).created_at,
        finalized_at: now,
        created_at: now
      })
      |> Repo.insert!()

    case SlackHistoryImports.complete_acquisition(run.id, expected_generation, snapshot.id) do
      {:ok, transitioned, _event} -> {transitioned, snapshot}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp audit_snapshot({:ok, run, snapshot} = response) do
    Instrumentation.record_audit(
      "sourced_context.snapshot.finalized",
      %{
        org_id: run.org_id,
        project_id: run.project_id,
        resource_type: "slack_history_import_run",
        resource_id: run.id,
        resource_label: "Slack history onboarding"
      },
      run.requested_by_user_id,
      snapshot.id,
      %{
        snapshot_id: snapshot.id,
        source_workspace_id: run.source_workspace_id,
        connect_generation: run.connect_generation,
        normalization_revision: snapshot.normalization_revision,
        coverage_profile: snapshot.coverage_profile,
        manifest_sha256: snapshot.manifest_sha256,
        object_count: snapshot.object_count,
        byte_count: snapshot.byte_count,
        channel_count: snapshot.coverage["channels"],
        page_count: snapshot.coverage["pages"]
      }
    )

    response
  end

  defp audit_snapshot(response), do: response

  defp normalized_page(envelope) do
    with {:ok, channel_id} <- nonempty(value(envelope, :channel_id), :invalid_channel_id),
         {:ok, stream_kind} <- stream_kind(value(envelope, :stream_kind)),
         {:ok, root_ts} <- root_ts(stream_kind, value(envelope, :root_ts)),
         {:ok, page_ordinal} <- nonnegative_integer(value(envelope, :page_ordinal)),
         {:ok, request_cursor} <- cursor(value(envelope, :request_cursor)),
         {:ok, next_cursor} <- cursor(value(envelope, :next_cursor)),
         {:ok, stream_complete} <- boolean(value(envelope, :stream_complete)),
         true <- stream_complete == is_nil(next_cursor) || {:error, :invalid_stream_completion},
         {:ok, accepted_generation} <-
           nonempty(value(envelope, :accepted_connect_generation), :invalid_connect_generation),
         {:ok, accepted_channel_authority_revision} <-
           sha256_value(
             value(envelope, :accepted_channel_authority_revision),
             :invalid_channel_authority_revision
           ),
         %DateTime{} = observed_at <- value(envelope, :observed_at),
         {:ok, messages} <- normalize_messages(value(envelope, :messages)),
         page_map = canonical_page(messages, next_cursor, stream_complete),
         canonical_bytes = CanonicalJSON.encode!(page_map),
         computed_sha256 = CanonicalJSON.sha256(canonical_bytes),
         {:ok, response_sha256} <- sha256(value(envelope, :response_sha256), computed_sha256) do
      {:ok,
       %{
         channel_id: channel_id,
         stream_kind: stream_kind,
         root_ts: root_ts,
         page_ordinal: page_ordinal,
         request_cursor: request_cursor,
         next_cursor: next_cursor,
         stream_complete: stream_complete,
         accepted_connect_generation: accepted_generation,
         accepted_channel_authority_revision: accepted_channel_authority_revision,
         observed_at: observed_at,
         messages: messages,
         canonical_bytes: canonical_bytes,
         response_sha256: response_sha256,
         timestamp_boundary: page_boundary(stream_kind, messages)
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_page_envelope}
      _invalid -> {:error, :invalid_page_envelope}
    end
  end

  defp normalize_messages(messages) when is_list(messages) do
    if length(messages) <= bound(:page_objects) do
      Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
        case normalize_message(message) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        error -> error
      end
    else
      {:error, :page_object_bound_exceeded}
    end
  end

  defp normalize_messages(_messages), do: {:error, :invalid_messages}

  defp normalize_message(message) when is_map(message) do
    with true <- Enum.sort(Map.keys(message)) == Enum.sort(@message_keys),
         {:ok, message_ts} <- slack_ts(message["message_ts"]),
         {:ok, thread_ts} <- optional_slack_ts(message["thread_ts"]),
         {:ok, actor_id} <- nonempty(message["actor_id"], :invalid_actor_id),
         true <- message["actor_kind"] in @actor_kinds,
         true <- is_binary(message["text"]) and byte_size(message["text"]) <= 40_000,
         {:ok, observable_version} <-
           nonempty(message["observable_version"], :invalid_observable_version),
         true <- is_integer(message["reply_count"]) and message["reply_count"] in 0..1_000,
         {:ok, files} <- normalize_files(message["file_metadata"]) do
      {:ok,
       %{
         "message_ts" => message_ts,
         "thread_ts" => thread_ts,
         "actor_id" => actor_id,
         "actor_kind" => message["actor_kind"],
         "text" => message["text"],
         "observable_version" => observable_version,
         "reply_count" => message["reply_count"],
         "file_metadata" => files
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_message}
      _invalid -> {:error, :invalid_message}
    end
  end

  defp normalize_message(_message), do: {:error, :invalid_message}

  defp normalize_files(files) when is_list(files) and length(files) <= 10 do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      if is_map(file) and Enum.sort(Map.keys(file)) == Enum.sort(@file_keys) and
           is_binary(file["id"]) and file["id"] != "" and
           (is_nil(file["name"]) or is_binary(file["name"])) and
           (is_nil(file["mimetype"]) or is_binary(file["mimetype"])) and
           (is_nil(file["size"]) or (is_integer(file["size"]) and file["size"] >= 0)) do
        {:cont, {:ok, [Map.take(file, @file_keys) | acc]}}
      else
        {:halt, {:error, :invalid_file_metadata}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_files(_files), do: {:error, :invalid_file_metadata}

  defp canonical_page(messages, next_cursor, stream_complete) do
    %{
      "messages" => messages,
      "next_cursor" => next_cursor || "",
      "stream_complete" => stream_complete
    }
  end

  defp lock_run!(run_id) do
    Repo.one(
      from(run in SlackHistoryImportRun,
        where: run.id == ^run_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:not_found)
  end

  # Context lifecycle owns the outer lock. Every acquisition write therefore
  # takes bundle -> run, matching derivation, preview, commit, and purge.
  defp lock_lifecycle_ready_run!(run_id) do
    bundle_id =
      Repo.one(
        from(run in SlackHistoryImportRun,
          where: run.id == ^run_id,
          select: run.context_bundle_id
        )
      ) || Repo.rollback(:not_found)

    bundle =
      Repo.one(
        from(bundle in BridgeForTeams.Schema.ContextBundle,
          where: bundle.id == ^bundle_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:context_lifecycle_not_ready)

    unless bundle.lifecycle_state == "registered" and bundle.subject_index_state == "complete",
      do: Repo.rollback(:context_lifecycle_not_ready)

    run = lock_run!(run_id)

    if run.context_bundle_id == bundle.id,
      do: {bundle, run},
      else: Repo.rollback(:context_lifecycle_not_ready)
  end

  defp optional_delay(nil), do: {:ok, nil}

  defp optional_delay(delay_ms) when is_integer(delay_ms) and delay_ms > 0,
    do: {:ok, delay_ms}

  defp optional_delay(_delay_ms), do: {:error, :invalid_provider_retry_delay}

  defp provider_backoff_ms(retry_count) do
    multiplier = Integer.pow(2, max(retry_count - 1, 0))
    min(@provider_backoff_base_ms * multiplier, @provider_backoff_max_ms)
  end

  defp validate_run_for_page!(run, expected_generation, page) do
    cond do
      run.generation != expected_generation ->
        Repo.rollback(:stale_run_generation)

      run.state != "acquiring" ->
        Repo.rollback({:invalid_transition, run.state, :accept_page})

      run.connect_generation != page.accepted_connect_generation ->
        Repo.rollback(:stale_source)

      not selected_channel?(
        run.id,
        page.channel_id,
        page.accepted_channel_authority_revision
      ) ->
        Repo.rollback(:channel_outside_run_scope)

      not Enum.all?(page.messages, &message_in_range?(&1, run)) ->
        Repo.rollback(:message_outside_run_range)

      true ->
        :ok
    end
  end

  defp selected_channel?(run_id, channel_id, authority_revision) do
    Repo.exists?(
      from(channel in SlackHistoryImportChannel,
        where:
          channel.run_id == ^run_id and channel.channel_id == ^channel_id and
            channel.visibility == "public" and
            channel.authority_revision == ^authority_revision
      )
    )
  end

  defp selected_channel_id?(run_id, channel_id) do
    Repo.exists?(
      from(channel in SlackHistoryImportChannel,
        where:
          channel.run_id == ^run_id and channel.channel_id == ^channel_id and
            channel.visibility == "public"
      )
    )
  end

  defp lock_retry_checkpoint!(run_id, channel_id, stream_kind, root_ts) do
    Repo.one(
      from(checkpoint in SlackHistoryStreamCheckpoint,
        where:
          checkpoint.run_id == ^run_id and checkpoint.channel_id == ^channel_id and
            checkpoint.stream_kind == ^stream_kind and checkpoint.root_ts == ^root_ts,
        lock: "FOR UPDATE"
      )
    ) ||
      %SlackHistoryStreamCheckpoint{}
      |> SlackHistoryStreamCheckpoint.changeset(%{
        run_id: run_id,
        channel_id: channel_id,
        stream_kind: stream_kind,
        root_ts: root_ts,
        next_page_ordinal: 0,
        complete: false,
        object_count: 0,
        byte_count: 0,
        retry_count: 0
      })
      |> Repo.insert!()
  end

  defp replay_page!(existing, page) do
    if existing.response_sha256 == page.response_sha256 and
         existing.accepted_connect_generation == page.accepted_connect_generation and
         existing.channel_id == page.channel_id and existing.stream_kind == page.stream_kind and
         existing.root_ts == page.root_ts and existing.page_ordinal == page.page_ordinal do
      %{existing | replayed?: true}
    else
      Repo.rollback(:page_receipt_conflict)
    end
  end

  defp lock_or_build_checkpoint(run, page) do
    checkpoint =
      Repo.one(
        from(checkpoint in SlackHistoryStreamCheckpoint,
          where:
            checkpoint.run_id == ^run.id and checkpoint.channel_id == ^page.channel_id and
              checkpoint.stream_kind == ^page.stream_kind and checkpoint.root_ts == ^page.root_ts,
          lock: "FOR UPDATE"
        )
      )

    case {checkpoint, page.stream_kind} do
      {%SlackHistoryStreamCheckpoint{} = checkpoint, _stream_kind} ->
        checkpoint

      {nil, "history"} ->
        %SlackHistoryStreamCheckpoint{
          run_id: run.id,
          channel_id: page.channel_id,
          stream_kind: page.stream_kind,
          root_ts: page.root_ts,
          next_page_ordinal: 0,
          complete: false,
          object_count: 0,
          byte_count: 0,
          retry_count: 0
        }

      {nil, "replies"} ->
        Repo.rollback(:reply_root_outside_discovered_history)
    end
  end

  defp validate_checkpoint!(checkpoint, page) do
    with false <- checkpoint.complete,
         true <- checkpoint.next_page_ordinal == page.page_ordinal,
         {:ok, expected_cursor} <- decrypt_cursor(checkpoint),
         true <- expected_cursor == page.request_cursor do
      :ok
    else
      true -> Repo.rollback(:stream_already_complete)
      false -> Repo.rollback(:checkpoint_mismatch)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_objects!(run, page) do
    Enum.reduce(page.messages, {0, 0, MapSet.new()}, fn message, {count, bytes, actor_subjects} ->
      payload = CanonicalJSON.encode!(message)
      payload_sha256 = CanonicalJSON.sha256(payload)

      existing =
        Repo.one(
          from(object in SourcedContextObject,
            where:
              object.run_id == ^run.id and object.workspace_id == ^run.source_workspace_id and
                object.channel_id == ^page.channel_id and
                object.message_ts == ^message["message_ts"] and
                object.observable_version == ^message["observable_version"]
          )
        )

      actor_ref_sha256 =
        CanonicalJSON.sha256(run.source_workspace_id <> "\0" <> message["actor_id"])

      case existing do
        %SourcedContextObject{payload_sha256: ^payload_sha256} ->
          {count, bytes, MapSet.put(actor_subjects, actor_ref_sha256)}

        %SourcedContextObject{} ->
          Repo.rollback(:source_object_conflict)

        nil ->
          id = Ecto.UUID.generate()
          {:ok, ciphertext} = Crypto.seal(payload, object_aad(id))

          %SourcedContextObject{id: id}
          |> SourcedContextObject.changeset(%{
            run_id: run.id,
            workspace_id: run.source_workspace_id,
            channel_id: page.channel_id,
            message_ts: message["message_ts"],
            thread_ts: message["thread_ts"],
            observable_version: message["observable_version"],
            actor_ref_sha256: actor_ref_sha256,
            payload_ciphertext: ciphertext,
            payload_sha256: payload_sha256,
            byte_count: byte_size(payload),
            observed_at: page.observed_at,
            created_at: DateTime.utc_now()
          })
          |> Repo.insert!()

          {count + 1, bytes + byte_size(payload), MapSet.put(actor_subjects, actor_ref_sha256)}
      end
    end)
  end

  defp enforce_run_bounds!(run_id) do
    {count, bytes} =
      Repo.one(
        from(object in SourcedContextObject,
          where: object.run_id == ^run_id,
          select: {count(object.id), fragment("COALESCE(SUM(?), 0)::bigint", object.byte_count)}
        )
      )

    cond do
      count > bound(:run_objects) -> Repo.rollback(:run_object_bound_exceeded)
      bytes > bound(:run_bytes) -> Repo.rollback(:run_byte_bound_exceeded)
      true -> :ok
    end
  end

  defp enforce_page_bound!(run_id) do
    count =
      Repo.aggregate(
        from(receipt in SlackHistoryPageReceipt, where: receipt.run_id == ^run_id),
        :count
      )

    if count < bound(:run_pages),
      do: :ok,
      else: Repo.rollback(:run_page_bound_exceeded)
  end

  defp add_actor_subjects!(run, subjects) do
    if MapSet.size(subjects) == 0 do
      :ok
    else
      attrs = Enum.map(subjects, &%{kind: "external_user", ref: &1})

      case ContextLifecycle.add_subjects(run.context_bundle_id, attrs) do
        {:ok, _bundle} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp insert_receipt!(run, page, receipt_key, cursor_ciphertext) do
    %SlackHistoryPageReceipt{}
    |> SlackHistoryPageReceipt.changeset(%{
      run_id: run.id,
      channel_id: page.channel_id,
      stream_kind: page.stream_kind,
      root_ts: page.root_ts,
      page_ordinal: page.page_ordinal,
      receipt_key: receipt_key,
      response_sha256: page.response_sha256,
      accepted_connect_generation: page.accepted_connect_generation,
      accepted_channel_authority_revision: page.accepted_channel_authority_revision,
      object_count: length(page.messages),
      byte_count: byte_size(page.canonical_bytes),
      timestamp_boundary: page.timestamp_boundary,
      next_cursor_ciphertext: cursor_ciphertext,
      stream_complete: page.stream_complete,
      created_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp persist_checkpoint!(checkpoint, page, new_count, new_bytes, cursor_ciphertext) do
    checkpoint
    |> SlackHistoryStreamCheckpoint.changeset(%{
      run_id: checkpoint.run_id,
      channel_id: checkpoint.channel_id,
      stream_kind: checkpoint.stream_kind,
      root_ts: checkpoint.root_ts,
      next_page_ordinal: page.page_ordinal + 1,
      timestamp_boundary: page.timestamp_boundary || checkpoint.timestamp_boundary,
      provider_cursor_ciphertext: cursor_ciphertext,
      complete: page.stream_complete,
      object_count: checkpoint.object_count + new_count,
      byte_count: checkpoint.byte_count + new_bytes,
      retry_count: checkpoint.retry_count
    })
    |> then(fn changeset ->
      if Ecto.get_meta(checkpoint, :state) == :built,
        do: Repo.insert!(changeset),
        else: Repo.update!(changeset)
    end)
  end

  defp ensure_reply_checkpoints!(run_id, %{stream_kind: "history"} = page) do
    page.messages
    |> Enum.filter(&(&1["reply_count"] > 0))
    |> Enum.each(fn message ->
      %SlackHistoryStreamCheckpoint{}
      |> SlackHistoryStreamCheckpoint.changeset(%{
        run_id: run_id,
        channel_id: page.channel_id,
        stream_kind: "replies",
        root_ts: message["message_ts"],
        next_page_ordinal: 0,
        complete: false,
        object_count: 0,
        byte_count: 0,
        retry_count: 0
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:run_id, :channel_id, :stream_kind, :root_ts]
      )
    end)
  end

  defp ensure_reply_checkpoints!(_run_id, _page), do: :ok

  defp ensure_complete_coverage!(run) do
    checkpoints =
      Repo.all(
        from(checkpoint in SlackHistoryStreamCheckpoint, where: checkpoint.run_id == ^run.id)
      )

    history_channels =
      checkpoints
      |> Enum.filter(&(&1.stream_kind == "history" and &1.complete))
      |> MapSet.new(& &1.channel_id)

    selected_channels = MapSet.new(run.channels, & &1.channel_id)

    cond do
      history_channels != selected_channels -> Repo.rollback(:incomplete_channel_coverage)
      Enum.any?(checkpoints, &(not &1.complete)) -> Repo.rollback(:incomplete_thread_coverage)
      true -> :ok
    end
  end

  defp manifest(run, objects, receipts, normalization_revision) do
    %{
      "schema" => "comma.sourced-context-snapshot-manifest.v1",
      "run_id" => run.id,
      "workspace_id" => run.source_workspace_id,
      "connect_generation" => run.connect_generation,
      "range_start" => DateTime.to_iso8601(run.range_start),
      "range_end" => DateTime.to_iso8601(run.range_end),
      "normalization_revision" => normalization_revision,
      "coverage_profile" => run.coverage_profile,
      "objects" =>
        Enum.map(objects, fn object ->
          %{
            "channel_id" => object.channel_id,
            "message_ts" => object.message_ts,
            "observable_version" => object.observable_version,
            "payload_sha256" => object.payload_sha256
          }
        end),
      "pages" =>
        Enum.map(receipts, fn receipt ->
          %{
            "receipt_key" => receipt.receipt_key,
            "response_sha256" => receipt.response_sha256,
            "connect_generation" => receipt.accepted_connect_generation
          }
        end)
    }
  end

  defp coverage(run, objects, receipts) do
    %{
      "complete" => true,
      "profile" => run.coverage_profile,
      "channels" => length(run.channels),
      "objects" => length(objects),
      "pages" => length(receipts),
      "root_bounded" => true
    }
  end

  defp load_snapshot_objects(snapshot) do
    objects =
      Repo.all(
        from(object in SourcedContextObject,
          where: object.run_id == ^snapshot.run_id,
          order_by: [
            asc: object.channel_id,
            asc: object.message_ts,
            asc: object.observable_version
          ],
          limit: ^(bound(:run_objects) + 1)
        )
      )

    if length(objects) > bound(:run_objects) do
      {:error, :snapshot_object_bound_exceeded}
    else
      Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, acc} ->
        with {:ok, plaintext} <- Crypto.unseal(object.payload_ciphertext, object_aad(object.id)),
             true <- CanonicalJSON.sha256(plaintext) == object.payload_sha256,
             {:ok, payload} <- Jason.decode(plaintext) do
          view = %{
            id: object.id,
            source: %{
              workspace_id: object.workspace_id,
              channel_id: object.channel_id,
              message_ts: object.message_ts,
              thread_ts: object.thread_ts,
              observable_version: object.observable_version
            },
            payload: payload
          }

          {:cont, {:ok, [view | acc]}}
        else
          _invalid -> {:halt, {:error, :snapshot_integrity_failed}}
        end
      end)
      |> case do
        {:ok, decrypted} -> {:ok, Enum.reverse(decrypted)}
        error -> error
      end
    end
  end

  defp encrypt_cursor!(_run_id, %{next_cursor: nil}), do: nil

  defp encrypt_cursor!(run_id, page) do
    {:ok, ciphertext} = Crypto.seal(page.next_cursor, checkpoint_aad(run_id, page))
    ciphertext
  end

  defp decrypt_cursor(%SlackHistoryStreamCheckpoint{provider_cursor_ciphertext: nil}),
    do: {:ok, nil}

  defp decrypt_cursor(checkpoint) do
    Crypto.unseal(
      checkpoint.provider_cursor_ciphertext,
      checkpoint_aad(checkpoint.run_id, checkpoint)
    )
  end

  defp checkpoint_aad(run_id, stream) do
    "checkpoint:#{run_id}:#{stream.channel_id}:#{stream.stream_kind}:#{stream.root_ts}"
  end

  defp object_aad(id), do: "object:#{id}"

  defp receipt_key(page),
    do: Enum.join([page.channel_id, page.stream_kind, page.root_ts, page.page_ordinal], ":")

  defp page_boundary(_stream_kind, []), do: nil

  defp page_boundary("history", messages),
    do: messages |> Enum.map(& &1["message_ts"]) |> Enum.min()

  defp page_boundary("replies", messages),
    do: messages |> Enum.map(& &1["message_ts"]) |> Enum.max()

  defp message_in_range?(message, run) do
    with {:ok, datetime} <- slack_ts_datetime(message["message_ts"]) do
      DateTime.compare(datetime, run.range_start) in [:eq, :gt] and
        DateTime.compare(datetime, run.range_end) == :lt
    else
      _invalid -> false
    end
  end

  defp slack_ts_datetime(value) do
    case String.split(value, ".", parts: 2) do
      [seconds, micros] ->
        with {seconds, ""} <- Integer.parse(seconds),
             {micros, ""} <- Integer.parse(String.pad_trailing(micros, 6, "0")),
             {:ok, datetime} <- DateTime.from_unix(seconds * 1_000_000 + micros, :microsecond) do
          {:ok, datetime}
        else
          _invalid -> {:error, :invalid_slack_ts}
        end

      _invalid ->
        {:error, :invalid_slack_ts}
    end
  end

  defp slack_ts(value) when is_binary(value) do
    value = String.trim(value)

    if value =~ ~r/\A[0-9]{1,12}\.[0-9]{1,6}\z/,
      do: {:ok, value},
      else: {:error, :invalid_slack_ts}
  end

  defp slack_ts(_value), do: {:error, :invalid_slack_ts}
  defp optional_slack_ts(nil), do: {:ok, nil}
  defp optional_slack_ts(""), do: {:ok, nil}
  defp optional_slack_ts(value), do: slack_ts(value)

  defp stream_kind(kind) when kind in @stream_kinds, do: {:ok, kind}
  defp stream_kind(_kind), do: {:error, :invalid_stream_kind}

  defp root_ts("history", value) when value in [nil, ""], do: {:ok, ""}
  defp root_ts("replies", value), do: slack_ts(value)
  defp root_ts(_kind, _value), do: {:error, :invalid_root_ts}

  defp cursor(nil), do: {:ok, nil}
  defp cursor(""), do: {:ok, nil}

  defp cursor(value) when is_binary(value) and byte_size(value) <= 1_024,
    do: {:ok, value}

  defp cursor(_value), do: {:error, :invalid_cursor}

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: {:error, :invalid_boolean}

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp nonnegative_integer(_value), do: {:error, :invalid_page_ordinal}

  defp sha256(nil, computed), do: {:ok, computed}

  defp sha256(value, computed) when is_binary(value) do
    if Regex.match?(@sha256, value) and value == computed,
      do: {:ok, value},
      else: {:error, :page_response_hash_mismatch}
  end

  defp sha256(_value, _computed), do: {:error, :invalid_page_response_hash}

  defp sha256_value(value, error) when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(@sha256, value), do: {:ok, value}, else: {:error, error}
  end

  defp sha256_value(_value, error), do: {:error, error}

  defp nonempty(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      normalized -> {:ok, normalized}
    end
  end

  defp nonempty(_value, error), do: {:error, error}

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp preload_channels(run) do
    Repo.preload(run,
      channels: from(channel in SlackHistoryImportChannel, order_by: [asc: channel.channel_id])
    )
  end

  defp feature_enabled(feature) do
    if Keyword.get(
         Application.get_env(:bridge_for_teams_core, :sourced_context_features, []),
         feature,
         false
       ),
       do: :ok,
       else: {:error, {:feature_disabled, feature}}
  end

  defp encryption_available do
    if Crypto.available?(),
      do: :ok,
      else: {:error, :sourced_context_encryption_unavailable}
  end

  defp bound(key) do
    Application.get_env(:bridge_for_teams_core, :sourced_context_bounds, [])
    |> Keyword.fetch!(key)
  end
end
