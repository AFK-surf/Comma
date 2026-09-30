defmodule SalixIM.ProviderReceipts do
  @moduledoc false

  alias SalixIM.Provider.Slack.EndpointRevision
  alias SalixIM.Triage.AddressingEvidence
  alias SalixStore.{CasRecord, Keys, S3}

  @slack_triage_authority_keys ~w(
    provider tenant_id group_id connect_id connect_generation workspace_id
    approved_channel_id inbound_agent_id app_id bot_user_id bot_id oauth_completed_at
    triage_enabled
  )
  @verified_recheck_message_keys ~w(
    workspace_id channel_id root_thread_ts message_ts actor_id actor_kind text
  )
  @verified_clickhouse_message_keys ~w(
    workspace_id channel_id root_thread_ts message_ts message_ts_us observed_version
    ingest_at actor_id actor_kind text
  )
  @recheck_occurrence_keys ~w(entry_id schedule_id scheduled_for_ms)
  @receipt_keys ~w(
    schema connect_id event_id connect_generation created_at receipt_ref
    source_message_ref triage_event
  )
  @triage_event_v1_keys ~w(
    event_id connect_generation message_ts actor_id text fast_path bucket
    endpoint_provenance source_mode
  )
  @typed_receipt_schemas ~w(
    comma.slack-triage-event-receipt.v1 comma.slack-triage-event-receipt.v2
    comma.slack-triage-event-receipt.v3
  )
  # The two author kinds a typed receipt can ever carry. `human` and `agent`
  # are the only ones the callback route admits; the observation vocabulary's
  # `system` and `unknown` describe messages nobody authored on purpose and are
  # inadmissible upstream, so they can never reach a receipt.
  @actor_kinds ~w(human agent)
  @bucket_keys ~w(workspace_id channel_id thread_ts)
  @callback_provenance_keys ~w(
    schema captured_at_ms callback_api_app_id fast_path_bot_user_id
    endpoint_revision_sha256
  )
  @clickhouse_provenance_keys ~w(
    schema table message_ts_us observed_version ingest_at cursor_revision
  )
  @lower_hex_64 ~r/\A[0-9a-f]{64}\z/
  @slack_ts ~r/\A[0-9]+\.[0-9]{6}\z/
  @triage_receipt_read_concurrency 8
  @triage_receipt_read_timeout 1_000

  def record_slack(connect_id, event_id),
    do: record(Keys.ctl_im_slack_event_receipt(connect_id, event_id), connect_id, event_id)

  def fetch_slack(connect_id, event_id),
    do: CasRecord.get(Keys.ctl_im_slack_event_receipt(connect_id, event_id))

  @doc """
  Records one durable re-evaluation of the original Slack source selected by a
  shared one-shot Schedule.

  `source_message_ref` remains the physical Slack message. The occurrence has
  a distinct deterministic `event_id`, so a due follow-up may intentionally
  re-enter the same Runtime without weakening callback physical-source
  deduplication.
  """
  def record_slack_triage_recheck(authority, verified_message, occurrence)
      when is_map(authority) and is_map(verified_message) and is_map(occurrence) do
    create_slack_triage_receipt(
      authority,
      slack_triage_recheck_receipt(authority, verified_message, occurrence)
    )
  end

  def record_slack_triage_recheck(_authority, _verified_message, _occurrence),
    do: {:error, :invalid_slack_triage_recheck}

  @doc "Records one current human or explicitly addressed agent message from the shared mirror."
  def record_slack_triage_clickhouse(authority, verified_message, cursor_revision)
      when is_map(authority) and is_map(verified_message) and is_integer(cursor_revision) do
    create_slack_triage_receipt(
      authority,
      slack_triage_clickhouse_receipt(authority, verified_message, cursor_revision)
    )
  end

  def record_slack_triage_clickhouse(_authority, _verified_message, _cursor_revision),
    do: {:error, :invalid_slack_triage_clickhouse_message}

  @doc false
  def slack_triage_clickhouse_event_id(authority, message_ts_us)
      when is_map(authority) and is_integer(message_ts_us) and message_ts_us >= 0 do
    clickhouse_event_id(authority, message_ts_us)
  end

  def slack_triage_clickhouse_event_id(_authority, _message_ts_us),
    do: {:error, :invalid_slack_triage_clickhouse_message}

  defp create_slack_triage_receipt(_authority, {:error, _reason} = error), do: error

  defp create_slack_triage_receipt(authority, {:ok, receipt}) do
    key = Keys.ctl_im_slack_event_receipt(receipt["connect_id"], receipt["event_id"])

    result =
      case CasRecord.create(key, receipt) do
        {:ok, created} ->
          {:ok, :created, created}

        {:error, :exists} ->
          resolve_slack_triage_receipt(key, receipt, :duplicate)

        {:error, _reason} ->
          resolve_slack_triage_receipt(key, receipt, :created)
      end

    case result do
      {:ok, _kind, current} -> observe_slack_triage_receipt(authority, current)
      _failed -> :ok
    end

    result
  end

  @doc "Best-effort read-index repair; it never admits work or changes provider receipt success."
  def observe_slack_triage_receipt(authority, receipt) do
    if verify_slack_triage_receipt(authority, receipt) == :ok do
      SalixIM.Triage.Telemetry.observe(
        :intake_index,
        get_in(receipt, ["triage_event", "source_mode"]),
        :bft,
        fn -> SalixStore.TriageIntake.observe(authority["group_id"], receipt) end
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Normalizes a durable v1/v2/v3 Slack Triage receipt to a strict runtime shape."
  def normalize_slack_triage_receipt(
        %{"schema" => "comma.slack-triage-event-receipt.v2"} = receipt
      ) do
    if valid_slack_triage_receipt?(receipt),
      do: {:ok, receipt},
      else: {:error, :invalid_slack_triage_receipt}
  end

  def normalize_slack_triage_receipt(
        %{"schema" => "comma.slack-triage-event-receipt.v3"} = receipt
      ) do
    if valid_slack_triage_receipt?(receipt),
      do: {:ok, receipt},
      else: {:error, :invalid_slack_triage_receipt}
  end

  # The v1 route admitted only ordinary human root messages: explicit mentions
  # went to legacy, app-authored messages were excluded, and replies had no
  # typed receipt yet. Its missing evidence therefore has one lossless
  # compatibility interpretation without consulting `fast_path` for addressing.
  def normalize_slack_triage_receipt(
        %{"schema" => "comma.slack-triage-event-receipt.v1"} = receipt
      ) do
    if valid_v1_slack_triage_receipt?(receipt) do
      event = receipt["triage_event"]
      trigger_kind = if direct_question?(event["text"]), do: "question_heuristic", else: "none"

      {:ok,
       receipt
       |> Map.put("schema", "comma.slack-triage-event-receipt.v2")
       |> update_in(["triage_event"], fn event ->
         event
         |> Map.put("actor_kind", "human")
         |> Map.put("event_type", "message")
         |> Map.put("addressing_kind", "ambient")
         |> Map.put("trigger_kind", trigger_kind)
       end)}
    else
      {:error, :invalid_slack_triage_receipt}
    end
  end

  def normalize_slack_triage_receipt(_receipt),
    do: {:error, :invalid_slack_triage_receipt}

  @doc "Validates one durable typed Slack Triage receipt against current connect authority."
  def verify_slack_triage_receipt(authority, receipt)
      when is_map(authority) and is_map(receipt) do
    with {:ok, normalized} <- normalize_slack_triage_receipt(receipt) do
      verify_normalized_slack_triage_receipt(authority, normalized)
    end
  end

  def verify_slack_triage_receipt(_authority, _receipt),
    do: {:error, :invalid_slack_triage_receipt}

  defp verify_normalized_slack_triage_receipt(authority, receipt) do
    event = receipt["triage_event"]
    bucket = is_map(event) && event["bucket"]
    provenance = is_map(event) && event["endpoint_provenance"]

    with true <- exact_keys?(authority, @slack_triage_authority_keys),
         true <- valid_slack_triage_authority?(authority),
         true <- valid_slack_triage_receipt?(receipt),
         {:ok, endpoint_revision} <- EndpointRevision.sha256(authority),
         true <- receipt["connect_id"] == authority["connect_id"],
         true <- receipt["connect_generation"] == authority["connect_generation"],
         true <- event["connect_generation"] == authority["connect_generation"],
         true <- receipt["event_id"] == event["event_id"],
         true <- bucket["workspace_id"] == authority["workspace_id"],
         true <- bucket["channel_id"] == authority["approved_channel_id"],
         :ok <-
           verify_slack_triage_provenance(
             provenance,
             authority,
             endpoint_revision,
             receipt["created_at"]
           ),
         true <- valid_addressed_connect?(event, authority["connect_id"]),
         true <- valid_authority_addressing?(event, authority),
         true <- receipt["receipt_ref"] == expected_receipt_ref(receipt),
         true <- receipt["source_message_ref"] == expected_source_message_ref(receipt) do
      :ok
    else
      _invalid -> {:error, :invalid_slack_triage_receipt}
    end
  end

  @doc """
  Reads one bounded global page and hydrates strict v1/v2 Triage receipts.

  Valid v1 receipts are returned in the v2 runtime shape. `legacy_count` is
  reserved for historical untyped provider receipts; other record families use
  disjoint prefixes and therefore cannot pollute this scan.
  """
  def list_slack_triage_page(selector, cursor \\ nil, limit \\ 25)

  def list_slack_triage_page(:all, cursor, limit)
      when (is_binary(cursor) or is_nil(cursor)) and is_integer(limit) and limit in 1..25 do
    prefix = Keys.ctl_im_slack_event_receipts_prefix()

    with {:ok, start_after} <- decode_slack_triage_cursor(cursor, prefix),
         opts <- [max_keys: limit] |> maybe_put_start_after(start_after),
         {:ok, %{objects: objects, next: next}} <- S3.list(prefix, opts),
         :ok <- validate_slack_triage_page_objects(objects, start_after, next, prefix),
         {:ok, hydrated} <- hydrate_slack_triage_page(objects),
         {:ok, next_cursor} <- next_slack_triage_cursor(objects, next) do
      {:ok,
       Map.merge(hydrated, %{
         next_cursor: next_cursor,
         scan_complete: is_nil(next),
         scanned_count: length(objects)
       })}
    else
      {:error, :invalid_slack_triage_cursor} = error -> error
      {:error, _reason} -> {:error, :slack_triage_page_unavailable}
      _invalid -> {:error, :invalid_slack_triage_page}
    end
  end

  def list_slack_triage_page(_selector, _cursor, _limit),
    do: {:error, :invalid_slack_triage_page}

  def delete_slack(connect_id, event_id),
    do: delete(Keys.ctl_im_slack_event_receipt(connect_id, event_id))

  def wechat_completed?(connect_id, event_id) do
    case CasRecord.get(Keys.ctl_im_wechat_event_receipt(connect_id, event_id)) do
      {:ok, %{"completed_at" => _}} -> {:ok, true}
      {:ok, _legacy_receipt} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
      error -> error
    end
  end

  def complete_wechat(connect_id, event_id) do
    CasRecord.update(Keys.ctl_im_wechat_event_receipt(connect_id, event_id), fn current ->
      (current || %{"connect_id" => connect_id, "event_id" => event_id, "created_at" => now()})
      |> Map.put_new("completed_at", now())
    end)
  end

  def record_telegram(connect_id, event_id),
    do: record(Keys.ctl_im_telegram_event_receipt(connect_id, event_id), connect_id, event_id)

  def delete_telegram(connect_id, event_id),
    do: delete(Keys.ctl_im_telegram_event_receipt(connect_id, event_id))

  def record_feishu(connect_id, message_id),
    do: record(Keys.ctl_im_feishu_event_receipt(connect_id, message_id), connect_id, message_id)

  def delete_feishu(connect_id, message_id),
    do: delete(Keys.ctl_im_feishu_event_receipt(connect_id, message_id))

  defp record(key, connect_id, event_id) do
    event_id = trim(event_id)

    if event_id == "" do
      {:ok, true}
    else
      rec = %{"connect_id" => connect_id, "event_id" => event_id, "created_at" => now()}

      case CasRecord.create(key, rec) do
        {:ok, _record} -> {:ok, true}
        {:error, :exists} -> {:ok, false}
        {:error, _} = error -> error
      end
    end
  end

  defp slack_triage_recheck_receipt(authority, verified_message, occurrence) do
    with true <- exact_keys?(authority, @slack_triage_authority_keys),
         true <- exact_keys?(verified_message, @verified_recheck_message_keys),
         true <- exact_keys?(occurrence, @recheck_occurrence_keys),
         true <- valid_slack_triage_authority?(authority),
         true <- valid_verified_recheck_message?(verified_message, authority),
         true <- valid_recheck_occurrence?(occurrence),
         {:ok, endpoint_revision} <- EndpointRevision.sha256(authority) do
      verified =
        verified_message
        |> Map.put("provider_event_id", recheck_event_id(authority, verified_message, occurrence))
        |> Map.put("callback_app_id", authority["app_id"])
        |> Map.put("event_type", "message")

      receipt = slack_triage_receipt(authority, verified, endpoint_revision, "scheduled_recheck")

      {:ok,
       put_in(
         receipt,
         ["triage_event", "recheck_context_ref"],
         "triage-context://" <> occurrence["entry_id"]
       )}
    else
      _other -> {:error, :invalid_slack_triage_recheck}
    end
  end

  defp slack_triage_clickhouse_receipt(authority, verified_message, cursor_revision) do
    with true <- exact_keys?(authority, @slack_triage_authority_keys),
         true <- exact_keys?(verified_message, @verified_clickhouse_message_keys),
         true <- valid_slack_triage_authority?(authority),
         true <- valid_verified_clickhouse_message?(verified_message, authority),
         true <- cursor_revision >= 0 do
      {:ok, clickhouse_triage_receipt(authority, verified_message, cursor_revision)}
    else
      _other -> {:error, :invalid_slack_triage_clickhouse_message}
    end
  end

  defp slack_triage_receipt(authority, verified, endpoint_revision, source_mode) do
    captured_at_ms = now()
    connect_generation = authority["connect_generation"]
    workspace_id = authority["workspace_id"]
    channel_id = authority["approved_channel_id"]
    root_thread_ts = verified["root_thread_ts"]
    message_ts = verified["message_ts"]
    event_id = verified["provider_event_id"]
    key = Keys.ctl_im_slack_event_receipt(authority["connect_id"], event_id)
    event_type = verified["event_type"]

    addressed? =
      event_type == "app_mention" or mentions_bot?(verified["text"], authority["bot_user_id"])

    addressing_kind = if addressed?, do: "directed", else: "ambient"
    trigger_kind = trigger_kind(verified, addressed?)

    triage_event =
      %{
        "event_id" => event_id,
        "connect_generation" => connect_generation,
        "message_ts" => message_ts,
        "actor_id" => verified["actor_id"],
        "actor_kind" => verified["actor_kind"],
        "text" => verified["text"],
        "event_type" => event_type,
        "addressing_kind" => addressing_kind,
        "trigger_kind" => trigger_kind,
        "fast_path" => trigger_kind != "none",
        "bucket" => %{
          "workspace_id" => workspace_id,
          "channel_id" => channel_id,
          "thread_ts" => root_thread_ts
        },
        "endpoint_provenance" => %{
          "schema" => "comma.slack-endpoint-provenance.v1",
          "captured_at_ms" => captured_at_ms,
          "callback_api_app_id" => verified["callback_app_id"],
          "fast_path_bot_user_id" => authority["bot_user_id"],
          "endpoint_revision_sha256" => endpoint_revision
        },
        "source_mode" => source_mode
      }
      |> maybe_put_addressed_connect(addressing_kind, authority["connect_id"])

    %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "connect_id" => authority["connect_id"],
      "event_id" => event_id,
      "connect_generation" => connect_generation,
      "created_at" => captured_at_ms,
      "receipt_ref" => "s3://" <> key,
      "source_message_ref" =>
        Enum.join(
          [connect_generation, workspace_id, channel_id, root_thread_ts, message_ts],
          ":"
        ),
      "triage_event" => triage_event
    }
  end

  defp clickhouse_triage_receipt(authority, verified, cursor_revision) do
    created_at = now()
    connect_generation = authority["connect_generation"]
    workspace_id = authority["workspace_id"]
    channel_id = authority["approved_channel_id"]
    root_thread_ts = verified["root_thread_ts"]
    message_ts = verified["message_ts"]
    message_ts_us = verified["message_ts_us"]
    event_id = clickhouse_event_id(authority, message_ts_us)
    key = Keys.ctl_im_slack_event_receipt(authority["connect_id"], event_id)

    directed? =
      verified["actor_kind"] == "agent" and
        mentions_bot?(verified["text"], authority["bot_user_id"])

    addressing_kind = if(directed?, do: "directed", else: "ambient")
    trigger_kind = if directed?, do: "mention", else: "none"

    %{
      "schema" => "comma.slack-triage-event-receipt.v3",
      "connect_id" => authority["connect_id"],
      "event_id" => event_id,
      "connect_generation" => connect_generation,
      "created_at" => created_at,
      "receipt_ref" => "s3://" <> key,
      "source_message_ref" =>
        Enum.join(
          [connect_generation, workspace_id, channel_id, root_thread_ts, message_ts],
          ":"
        ),
      "triage_event" =>
        %{
          "event_id" => event_id,
          "connect_generation" => connect_generation,
          "message_ts" => message_ts,
          "actor_id" => verified["actor_id"],
          "actor_kind" => verified["actor_kind"],
          "text" => verified["text"],
          "event_type" => "message",
          "addressing_kind" => addressing_kind,
          "trigger_kind" => trigger_kind,
          "fast_path" => trigger_kind != "none",
          "bucket" =>
            %{
              "workspace_id" => workspace_id,
              "channel_id" => channel_id,
              "thread_ts" => root_thread_ts
            }
            |> then(fn bucket ->
              if directed?, do: bucket, else: Map.put(bucket, "scope_kind", "channel")
            end),
          "endpoint_provenance" => %{
            "schema" => "comma.slack-clickhouse-etl-provenance.v1",
            "table" => "slack_messages",
            "message_ts_us" => message_ts_us,
            "observed_version" => verified["observed_version"],
            "ingest_at" => verified["ingest_at"],
            "cursor_revision" => cursor_revision
          },
          "source_mode" => "clickhouse_etl"
        }
        |> maybe_put_addressed_connect(addressing_kind, authority["connect_id"])
    }
  end

  defp clickhouse_event_id(authority, message_ts_us) do
    [
      "slack-clickhouse-etl-v1",
      authority["connect_id"],
      authority["approved_channel_id"],
      Integer.to_string(message_ts_us)
    ]
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp valid_verified_clickhouse_message?(message, authority) do
    Enum.all?(
      @verified_clickhouse_message_keys -- ["message_ts_us", "observed_version"],
      &canonical_nonblank?(message[&1])
    ) and
      message["actor_kind"] in @actor_kinds and
      message["workspace_id"] == authority["workspace_id"] and
      message["channel_id"] == authority["approved_channel_id"] and
      Regex.match?(@slack_ts, message["root_thread_ts"]) and
      Regex.match?(@slack_ts, message["message_ts"]) and
      slack_ts_micros(message["message_ts"]) == {:ok, message["message_ts_us"]} and
      is_integer(message["observed_version"]) and message["observed_version"] >= 0 and
      valid_iso8601?(message["ingest_at"]) and
      message["actor_id"] not in [
        authority["app_id"],
        authority["bot_user_id"],
        authority["bot_id"]
      ] and
      case message["actor_kind"] do
        "human" ->
          not mentions_bot?(message["text"], authority["bot_user_id"])

        "agent" ->
          message["root_thread_ts"] == message["message_ts"] or
            mentions_bot?(message["text"], authority["bot_user_id"])
      end
  end

  defp valid_verified_recheck_message?(message, authority) do
    Enum.all?(@verified_recheck_message_keys, &canonical_nonblank?(message[&1])) and
      message["actor_kind"] in @actor_kinds and
      message["workspace_id"] == authority["workspace_id"] and
      message["channel_id"] == authority["approved_channel_id"] and
      Regex.match?(@slack_ts, message["root_thread_ts"]) and
      Regex.match?(@slack_ts, message["message_ts"]) and
      message["actor_id"] not in [
        authority["app_id"],
        authority["bot_user_id"],
        authority["bot_id"]
      ]
  end

  defp valid_recheck_occurrence?(occurrence) do
    canonical_nonblank?(occurrence["entry_id"]) and
      canonical_nonblank?(occurrence["schedule_id"]) and
      is_integer(occurrence["scheduled_for_ms"]) and occurrence["scheduled_for_ms"] >= 0
  end

  defp recheck_event_id(authority, message, occurrence) do
    [
      "scheduled_recheck",
      authority["connect_generation"],
      authority["workspace_id"],
      authority["approved_channel_id"],
      message["root_thread_ts"],
      message["message_ts"],
      occurrence["entry_id"],
      occurrence["schedule_id"],
      Integer.to_string(occurrence["scheduled_for_ms"])
    ]
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("recheck:" <> &1))
  end

  defp resolve_slack_triage_receipt(key, desired, success_kind) do
    case CasRecord.get(key) do
      {:ok, %{"schema" => "comma.slack-triage-event-receipt.v3"} = current} ->
        cond do
          not valid_slack_triage_receipt?(current) ->
            {:error, :invalid_slack_triage_receipt}

          same_clickhouse_physical_source?(current, desired) ->
            {:ok, success_kind, current}

          true ->
            {:error, :triage_duplicate_payload_drift}
        end

      {:ok, %{"schema" => "comma.slack-triage-event-receipt.v2"} = current} ->
        cond do
          not valid_slack_triage_receipt?(current) ->
            {:error, :invalid_slack_triage_receipt}

          same_callback_receipt?(current, desired) ->
            {:ok, success_kind, current}

          true ->
            {:error, :triage_duplicate_payload_drift}
        end

      {:ok, %{"schema" => "comma.slack-triage-event-receipt.v1"} = current} ->
        case normalize_slack_triage_receipt(current) do
          {:ok, normalized} ->
            if stable_slack_triage_receipt(normalized) == stable_slack_triage_receipt(desired),
              do: {:ok, success_kind, normalized},
              else: {:error, :triage_duplicate_payload_drift}

          {:error, _invalid} ->
            {:error, :invalid_slack_triage_receipt}
        end

      {:ok, _legacy_or_unknown} ->
        {:error, :receipt_type_conflict}

      {:error, _reason} ->
        {:error, :slack_triage_receipt_unavailable}
    end
  end

  defp stable_slack_triage_receipt(receipt) do
    receipt
    |> Map.delete("created_at")
    |> update_in(["triage_event", "endpoint_provenance"], fn provenance ->
      Map.delete(provenance, "captured_at_ms")
    end)
  end

  defp same_callback_receipt?(current, desired) do
    # An already accepted occurrence keeps its exact historical event. Only new
    # occurrences gain the context pointer; never rewrite sealed source input.
    desired =
      if get_in(current, ["triage_event", "source_mode"]) == "scheduled_recheck" and
           not Map.has_key?(current["triage_event"], "recheck_context_ref") do
        update_in(desired, ["triage_event"], &Map.delete(&1, "recheck_context_ref"))
      else
        desired
      end

    stable_slack_triage_receipt(current) == stable_slack_triage_receipt(desired)
  end

  defp same_clickhouse_physical_source?(current, desired) do
    current["schema"] == "comma.slack-triage-event-receipt.v3" and
      desired["schema"] == "comma.slack-triage-event-receipt.v3" and
      current["connect_id"] == desired["connect_id"] and
      current["event_id"] == desired["event_id"] and
      get_in(current, ["triage_event", "endpoint_provenance", "message_ts_us"]) ==
        get_in(desired, ["triage_event", "endpoint_provenance", "message_ts_us"])
  end

  defp valid_slack_triage_authority?(authority) do
    Enum.all?(
      @slack_triage_authority_keys -- ["oauth_completed_at", "triage_enabled"],
      &canonical_nonblank?(authority[&1])
    ) and authority["provider"] == "slack" and authority["triage_enabled"] == true and
      is_integer(authority["oauth_completed_at"]) and authority["oauth_completed_at"] > 0
  end

  defp valid_slack_triage_receipt?(%{"schema" => "comma.slack-triage-event-receipt.v2"} = receipt) do
    event = receipt["triage_event"]
    provenance = is_map(event) && event["endpoint_provenance"]
    bucket = is_map(event) && event["bucket"]

    exact_keys?(receipt, @receipt_keys) and
      Enum.all?(
        ~w(connect_id event_id connect_generation receipt_ref source_message_ref),
        &canonical_nonblank?(receipt[&1])
      ) and
      is_integer(receipt["created_at"]) and receipt["created_at"] >= 0 and
      AddressingEvidence.validate(event, receipt["connect_id"]) == :ok and
      exact_keys?(bucket, @bucket_keys) and
      exact_keys?(provenance, @callback_provenance_keys) and
      provenance["schema"] == "comma.slack-endpoint-provenance.v1" and
      is_integer(provenance["captured_at_ms"]) and provenance["captured_at_ms"] >= 0 and
      is_binary(provenance["endpoint_revision_sha256"]) and
      Regex.match?(@lower_hex_64, provenance["endpoint_revision_sha256"]) and
      receipt["connect_generation"] == event["connect_generation"] and
      receipt["event_id"] == event["event_id"] and
      event["source_mode"] in [
        "callback",
        "historical_thread_reenactment",
        "periodic_patrol",
        "scheduled_recheck"
      ] and
      is_boolean(event["fast_path"]) and
      event["actor_kind"] in @actor_kinds and
      Enum.all?(~w(event_id connect_generation message_ts actor_id text source_mode), fn key ->
        canonical_nonblank?(event[key])
      end) and Regex.match?(@slack_ts, event["message_ts"]) and
      Enum.all?(~w(workspace_id channel_id thread_ts), &canonical_nonblank?(bucket[&1])) and
      Enum.all?(
        ~w(schema callback_api_app_id fast_path_bot_user_id endpoint_revision_sha256),
        fn key ->
          canonical_nonblank?(provenance[key])
        end
      )
  end

  defp valid_slack_triage_receipt?(%{"schema" => "comma.slack-triage-event-receipt.v3"} = receipt) do
    event = receipt["triage_event"]
    provenance = is_map(event) && event["endpoint_provenance"]
    bucket = is_map(event) && event["bucket"]

    exact_keys?(receipt, @receipt_keys) and
      Enum.all?(
        ~w(connect_id event_id connect_generation receipt_ref source_message_ref),
        &canonical_nonblank?(receipt[&1])
      ) and
      is_integer(receipt["created_at"]) and receipt["created_at"] >= 0 and
      AddressingEvidence.validate(event, receipt["connect_id"]) == :ok and
      valid_clickhouse_bucket?(bucket, event) and
      exact_keys?(provenance, @clickhouse_provenance_keys) and
      provenance["schema"] == "comma.slack-clickhouse-etl-provenance.v1" and
      provenance["table"] == "slack_messages" and
      is_integer(provenance["message_ts_us"]) and provenance["message_ts_us"] >= 0 and
      is_integer(provenance["observed_version"]) and provenance["observed_version"] >= 0 and
      is_integer(provenance["cursor_revision"]) and provenance["cursor_revision"] >= 0 and
      valid_iso8601?(provenance["ingest_at"]) and
      slack_ts_micros(event["message_ts"]) == {:ok, provenance["message_ts_us"]} and
      receipt["connect_generation"] == event["connect_generation"] and
      receipt["event_id"] == event["event_id"] and
      event["source_mode"] == "clickhouse_etl" and
      valid_clickhouse_addressing?(event, receipt["connect_id"]) and
      is_boolean(event["fast_path"]) and
      event["actor_kind"] in @actor_kinds and
      Enum.all?(~w(event_id connect_generation message_ts actor_id text source_mode), fn key ->
        canonical_nonblank?(event[key])
      end) and Regex.match?(@slack_ts, event["message_ts"]) and
      Enum.all?(~w(workspace_id channel_id thread_ts), &canonical_nonblank?(bucket[&1]))
  end

  defp valid_slack_triage_receipt?(_receipt), do: false

  defp valid_clickhouse_bucket?(bucket, event) do
    exact_keys?(bucket, @bucket_keys) or
      (exact_keys?(bucket, @bucket_keys ++ ["scope_kind"]) and
         bucket["scope_kind"] == "channel" and event["addressing_kind"] == "ambient" and
         event["trigger_kind"] == "none" and event["fast_path"] == false and
         is_binary(bucket["thread_ts"]) and Regex.match?(@slack_ts, bucket["thread_ts"]))
  end

  defp valid_v1_slack_triage_receipt?(receipt) do
    event = receipt["triage_event"]
    provenance = is_map(event) && event["endpoint_provenance"]
    bucket = is_map(event) && event["bucket"]

    exact_keys?(receipt, @receipt_keys) and
      receipt["schema"] == "comma.slack-triage-event-receipt.v1" and
      Enum.all?(
        ~w(connect_id event_id connect_generation receipt_ref source_message_ref),
        &canonical_nonblank?(receipt[&1])
      ) and
      is_integer(receipt["created_at"]) and receipt["created_at"] >= 0 and
      exact_keys?(event, @triage_event_v1_keys) and
      exact_keys?(bucket, @bucket_keys) and
      exact_keys?(provenance, @callback_provenance_keys) and
      provenance["schema"] == "comma.slack-endpoint-provenance.v1" and
      is_integer(provenance["captured_at_ms"]) and provenance["captured_at_ms"] >= 0 and
      is_binary(provenance["endpoint_revision_sha256"]) and
      Regex.match?(@lower_hex_64, provenance["endpoint_revision_sha256"]) and
      receipt["connect_generation"] == event["connect_generation"] and
      receipt["event_id"] == event["event_id"] and event["source_mode"] == "callback" and
      is_boolean(event["fast_path"]) and event["fast_path"] == direct_question?(event["text"]) and
      not mentions_bot?(event["text"], provenance["fast_path_bot_user_id"]) and
      Enum.all?(~w(event_id connect_generation message_ts actor_id text source_mode), fn key ->
        canonical_nonblank?(event[key])
      end) and Regex.match?(@slack_ts, event["message_ts"]) and
      Enum.all?(~w(workspace_id channel_id thread_ts), &canonical_nonblank?(bucket[&1])) and
      Enum.all?(
        ~w(schema callback_api_app_id fast_path_bot_user_id endpoint_revision_sha256),
        fn key -> canonical_nonblank?(provenance[key]) end
      )
  end

  defp verify_slack_triage_provenance(
         %{"schema" => "comma.slack-endpoint-provenance.v1"} = provenance,
         authority,
         endpoint_revision,
         created_at
       ) do
    if provenance["callback_api_app_id"] == authority["app_id"] and
         provenance["fast_path_bot_user_id"] == authority["bot_user_id"] and
         provenance["endpoint_revision_sha256"] == endpoint_revision and
         provenance["captured_at_ms"] == created_at,
       do: :ok,
       else: {:error, :invalid_slack_triage_receipt}
  end

  defp verify_slack_triage_provenance(
         %{"schema" => "comma.slack-clickhouse-etl-provenance.v1"},
         _authority,
         _endpoint_revision,
         _created_at
       ),
       do: :ok

  defp verify_slack_triage_provenance(
         _provenance,
         _authority,
         _endpoint_revision,
         _created_at
       ),
       do: {:error, :invalid_slack_triage_receipt}

  defp slack_ts_micros(value) when is_binary(value) do
    with [seconds, micros] <- String.split(value, ".", parts: 2),
         true <- byte_size(micros) in 1..6,
         {seconds, ""} when seconds >= 0 <- Integer.parse(seconds),
         {micros, ""} when micros >= 0 <-
           micros |> String.pad_trailing(6, "0") |> Integer.parse() do
      {:ok, seconds * 1_000_000 + micros}
    else
      _invalid -> :error
    end
  end

  defp slack_ts_micros(_value), do: :error

  defp valid_iso8601?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_iso8601?(_value), do: false

  defp expected_receipt_ref(receipt) do
    "s3://" <> Keys.ctl_im_slack_event_receipt(receipt["connect_id"], receipt["event_id"])
  end

  defp expected_source_message_ref(receipt) do
    event = receipt["triage_event"]
    bucket = event["bucket"]

    Enum.join(
      [
        event["connect_generation"],
        bucket["workspace_id"],
        bucket["channel_id"],
        bucket["thread_ts"],
        event["message_ts"]
      ],
      ":"
    )
  end

  defp hydrate_slack_triage_page(objects) do
    initial = %{
      receipts: [],
      connect_ids: MapSet.new(),
      authority_refs: MapSet.new(),
      legacy_count: 0,
      invalid_count: 0,
      unavailable_count: 0
    }

    objects
    |> Task.async_stream(&read_slack_triage_receipt/1,
      ordered: true,
      max_concurrency: @triage_receipt_read_concurrency,
      timeout: @triage_receipt_read_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce(initial, &merge_slack_triage_receipt/2)
    |> then(fn acc ->
      {:ok,
       %{
         acc
         | receipts: Enum.reverse(acc.receipts),
           connect_ids: acc.connect_ids |> MapSet.to_list() |> Enum.sort(),
           authority_refs: acc.authority_refs |> MapSet.to_list() |> Enum.sort()
       }}
    end)
  end

  defp read_slack_triage_receipt(%{key: key}) do
    if valid_slack_triage_receipt_key?(key, Keys.ctl_im_slack_event_receipts_prefix()) do
      hydrate_slack_triage_receipt(key)
    else
      :invalid
    end
  end

  defp hydrate_slack_triage_receipt(key) do
    case CasRecord.get(key) do
      {:ok, %{"schema" => schema} = receipt} when schema in @typed_receipt_schemas ->
        case normalize_slack_triage_receipt(receipt) do
          {:ok, normalized} ->
            if exact_receipt_storage_key?(normalized, key) do
              {:receipt, normalized}
            else
              :invalid
            end

          {:error, _invalid} ->
            :invalid
        end

      {:ok, _legacy_or_unknown} ->
        :legacy

      {:error, _reason} ->
        :unavailable
    end
  end

  defp merge_slack_triage_receipt({:ok, {:receipt, normalized}}, acc) do
    acc
    |> Map.update!(:receipts, &[normalized | &1])
    |> Map.update!(:connect_ids, &MapSet.put(&1, normalized["connect_id"]))
    |> Map.update!(:authority_refs, fn refs ->
      channel_id = get_in(normalized, ["triage_event", "bucket", "channel_id"])
      MapSet.put(refs, {normalized["connect_id"], channel_id})
    end)
  end

  defp merge_slack_triage_receipt({:ok, :invalid}, acc),
    do: Map.update!(acc, :invalid_count, &(&1 + 1))

  defp merge_slack_triage_receipt({:ok, :legacy}, acc),
    do: Map.update!(acc, :legacy_count, &(&1 + 1))

  defp merge_slack_triage_receipt({:ok, :unavailable}, acc),
    do: Map.update!(acc, :unavailable_count, &(&1 + 1))

  defp merge_slack_triage_receipt({:exit, _reason}, acc),
    do: Map.update!(acc, :unavailable_count, &(&1 + 1))

  defp exact_receipt_storage_key?(receipt, key) do
    expected = Keys.ctl_im_slack_event_receipt(receipt["connect_id"], receipt["event_id"])
    key == expected and receipt["receipt_ref"] == "s3://" <> expected
  end

  defp validate_slack_triage_page_objects(objects, start_after, next, prefix)
       when is_list(objects) do
    keys = Enum.map(objects, &Map.get(&1, :key))

    valid? =
      Enum.all?(keys, &valid_slack_triage_cursor_key?(&1, prefix)) and
        keys == Enum.sort(keys) and keys == Enum.uniq(keys) and
        (is_nil(start_after) or Enum.all?(keys, &(&1 > start_after))) and
        not (objects == [] and not is_nil(next))

    if valid?, do: :ok, else: {:error, :invalid_slack_triage_page}
  end

  defp validate_slack_triage_page_objects(_objects, _start_after, _next, _prefix),
    do: {:error, :invalid_slack_triage_page}

  defp valid_slack_triage_receipt_key?(key, prefix) when is_binary(key) do
    with true <- String.starts_with?(key, prefix),
         relative <- String.replace_prefix(key, prefix, ""),
         [connect_id, event_file] <- String.split(relative, "/", parts: 2),
         true <- canonical_nonblank?(connect_id),
         <<event_hash::binary-size(64), ".json">> <- event_file do
      Regex.match?(@lower_hex_64, event_hash)
    else
      _invalid -> false
    end
  end

  defp valid_slack_triage_receipt_key?(_key, _prefix), do: false

  # The ring cursor is an opaque raw S3 key. Any listed object under the
  # prefix — including a folder marker at exactly the prefix or a
  # malformed/trailing-space key — must remain a valid cursor position, so
  # one poison object is counted and skipped instead of pinning the page.
  defp valid_slack_triage_cursor_key?(key, prefix) when is_binary(key),
    do: String.starts_with?(key, prefix)

  defp valid_slack_triage_cursor_key?(_key, _prefix), do: false

  defp decode_slack_triage_cursor(nil, _prefix), do: {:ok, nil}

  defp decode_slack_triage_cursor("v1." <> encoded, prefix) do
    with {:ok, key} <- Base.url_decode64(encoded, padding: false),
         true <- valid_slack_triage_cursor_key?(key, prefix) do
      {:ok, key}
    else
      _invalid -> {:error, :invalid_slack_triage_cursor}
    end
  end

  defp decode_slack_triage_cursor(_cursor, _prefix),
    do: {:error, :invalid_slack_triage_cursor}

  defp next_slack_triage_cursor(_objects, nil), do: {:ok, nil}

  defp next_slack_triage_cursor(objects, _continuation) do
    case List.last(objects) do
      %{key: key} -> {:ok, "v1." <> Base.url_encode64(key, padding: false)}
      _missing -> {:error, :invalid_slack_triage_page}
    end
  end

  defp maybe_put_start_after(opts, nil), do: opts
  defp maybe_put_start_after(opts, key), do: Keyword.put(opts, :start_after, key)

  defp exact_keys?(value, keys) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

  defp canonical_nonblank?(value),
    do:
      is_binary(value) and value != "" and value == String.trim(value) and
        not String.contains?(value, <<0>>)

  defp valid_addressed_connect?(%{"addressing_kind" => "directed"} = event, connect_id),
    do: event["addressed_connect"] == connect_id

  defp valid_addressed_connect?(%{"addressing_kind" => "ambient"} = event, _connect_id),
    do: not Map.has_key?(event, "addressed_connect")

  defp valid_addressed_connect?(_event, _connect_id), do: false

  defp valid_clickhouse_addressing?(%{"actor_kind" => "human"} = event, connect_id) do
    event["addressing_kind"] == "ambient" and
      event["trigger_kind"] in ~w(none question_heuristic) and
      valid_addressed_connect?(event, connect_id)
  end

  defp valid_clickhouse_addressing?(%{"actor_kind" => "agent"} = event, connect_id) do
    valid_addressed_connect?(event, connect_id) and
      ((event["addressing_kind"] == "directed" and event["trigger_kind"] == "mention" and
          event["fast_path"] == true) or
         (event["addressing_kind"] == "ambient" and event["trigger_kind"] == "none" and
            event["fast_path"] == false and
            get_in(event, ["bucket", "thread_ts"]) == event["message_ts"]))
  end

  defp valid_clickhouse_addressing?(_event, _connect_id), do: false

  defp valid_authority_addressing?(%{"source_mode" => "clickhouse_etl"} = event, authority) do
    event["actor_id"] not in [authority["app_id"], authority["bot_user_id"], authority["bot_id"]] and
      case event["actor_kind"] do
        "human" ->
          not mentions_bot?(event["text"], authority["bot_user_id"])

        "agent" ->
          case event["addressing_kind"] do
            "directed" ->
              mentions_bot?(event["text"], authority["bot_user_id"])

            "ambient" ->
              get_in(event, ["bucket", "thread_ts"]) == event["message_ts"] and
                not mentions_bot?(event["text"], authority["bot_user_id"])

            _invalid ->
              false
          end

        _invalid ->
          false
      end
  end

  defp valid_authority_addressing?(_event, _authority), do: true

  defp trigger_kind(_verified, true), do: "mention"

  defp trigger_kind(%{"actor_kind" => "human", "text" => text}, false) do
    if direct_question?(text), do: "question_heuristic", else: "none"
  end

  defp trigger_kind(_verified, false), do: "none"

  defp maybe_put_addressed_connect(event, "directed", connect_id),
    do: Map.put(event, "addressed_connect", connect_id)

  defp maybe_put_addressed_connect(event, "ambient", _connect_id), do: event

  defp mentions_bot?(text, bot_user_id) when is_binary(text) and is_binary(bot_user_id) do
    bot_user_id = trim(bot_user_id)
    bot_user_id != "" and String.contains?(text, "<@#{bot_user_id}>")
  end

  defp mentions_bot?(_text, _bot_user_id), do: false

  defp direct_question?(text) when is_binary(text), do: String.ends_with?(text, ["?", "？"])
  defp direct_question?(_text), do: false

  defp delete(key), do: S3.delete(key)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp now, do: System.system_time(:millisecond)
end
