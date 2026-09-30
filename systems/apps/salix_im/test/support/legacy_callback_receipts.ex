defmodule SalixIM.TestSupport.LegacyCallbackReceipts do
  @moduledoc """
  Test-only writer for historical callback v2 receipts.

  Production keeps the v2 decoder for durable recovery but intentionally has
  no callback producer. Compatibility tests use this fixture to seed old data
  without reopening that production entry point.
  """

  alias SalixIM.Provider.Slack.EndpointRevision
  alias SalixStore.{CasRecord, Keys}

  @authority_keys ~w(
    provider tenant_id group_id connect_id connect_generation workspace_id
    approved_channel_id inbound_agent_id app_id bot_user_id bot_id oauth_completed_at
    triage_enabled
  )
  @verified_keys ~w(
    provider_event_id callback_app_id workspace_id channel_id root_thread_ts
    message_ts event_type actor_id actor_kind text
  )

  def record_root(authority, verified, opts \\ []), do: record(authority, verified, :root, opts)
  def record_reply(authority, verified, opts \\ []), do: record(authority, verified, :reply, opts)

  defp record(authority, verified, kind, opts)
       when is_map(authority) and is_map(verified) and is_list(opts) do
    with :ok <- validate_authority(authority, kind),
         :ok <- validate(authority, verified, kind),
         {:ok, endpoint_revision} <- EndpointRevision.sha256(authority) do
      receipt =
        receipt(
          authority,
          verified,
          endpoint_revision,
          Keyword.get(opts, :created_at, System.system_time(:millisecond))
        )

      key = Keys.ctl_im_slack_event_receipt(receipt["connect_id"], receipt["event_id"])

      case CasRecord.create(key, receipt) do
        {:ok, created} ->
          {:ok, :created, created}

        {:error, :exists} ->
          resolve_existing(key, receipt, :duplicate)

        {:error, _reason} ->
          resolve_existing(key, receipt, :created)
      end
    end
  end

  defp record(_authority, _verified, :root, _opts), do: {:error, :invalid_slack_triage_root}
  defp record(_authority, _verified, :reply, _opts), do: {:error, :invalid_slack_triage_reply}

  defp validate_authority(authority, kind) do
    valid? =
      Enum.sort(Map.keys(authority)) == Enum.sort(@authority_keys) and
        authority["provider"] == "slack" and authority["triage_enabled"] == true and
        is_integer(authority["oauth_completed_at"]) and authority["oauth_completed_at"] > 0 and
        Enum.all?(@authority_keys -- ["oauth_completed_at", "triage_enabled"], fn key ->
          nonblank?(authority[key])
        end)

    if valid?, do: :ok, else: invalid(kind)
  end

  defp validate(authority, verified, kind) do
    root_ts = verified["root_thread_ts"]
    message_ts = verified["message_ts"]

    valid? =
      Enum.sort(Map.keys(verified)) == Enum.sort(@verified_keys) and
        Enum.all?(@verified_keys, &nonblank?(verified[&1])) and
        verified["callback_app_id"] == authority["app_id"] and
        verified["workspace_id"] == authority["workspace_id"] and
        verified["channel_id"] == authority["approved_channel_id"] and
        verified["actor_kind"] in ~w(human agent) and
        verified["event_type"] in ~w(message app_mention) and
        valid_slack_ts?(root_ts) and valid_slack_ts?(message_ts) and
        case kind do
          :root -> root_ts == message_ts
          :reply -> root_ts != message_ts
        end

    if valid?, do: :ok, else: invalid(kind)
  end

  defp resolve_existing(key, desired, success_kind) do
    case CasRecord.get(key) do
      {:ok, %{"schema" => schema} = current}
      when schema in [
             "comma.slack-triage-event-receipt.v1",
             "comma.slack-triage-event-receipt.v2"
           ] ->
        case SalixIM.ProviderReceipts.normalize_slack_triage_receipt(current) do
          {:ok, normalized} ->
            if equivalent?(normalized, desired),
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

  defp receipt(authority, verified, endpoint_revision, created_at) do
    event_id = verified["provider_event_id"]
    root_ts = verified["root_thread_ts"]
    message_ts = verified["message_ts"]

    addressed? =
      verified["event_type"] == "app_mention" or
        String.contains?(verified["text"], "<@#{authority["bot_user_id"]}>")

    trigger_kind =
      cond do
        addressed? ->
          "mention"

        verified["actor_kind"] == "human" and String.ends_with?(verified["text"], ["?", "？"]) ->
          "question_heuristic"

        true ->
          "none"
      end

    addressing_kind = if(addressed?, do: "directed", else: "ambient")

    triage_event =
      %{
        "event_id" => event_id,
        "connect_generation" => authority["connect_generation"],
        "message_ts" => message_ts,
        "actor_id" => verified["actor_id"],
        "actor_kind" => verified["actor_kind"],
        "text" => verified["text"],
        "event_type" => verified["event_type"],
        "addressing_kind" => addressing_kind,
        "trigger_kind" => trigger_kind,
        "fast_path" => trigger_kind != "none",
        "bucket" => %{
          "workspace_id" => authority["workspace_id"],
          "channel_id" => authority["approved_channel_id"],
          "thread_ts" => root_ts
        },
        "endpoint_provenance" => %{
          "schema" => "comma.slack-endpoint-provenance.v1",
          "captured_at_ms" => created_at,
          "callback_api_app_id" => verified["callback_app_id"],
          "fast_path_bot_user_id" => authority["bot_user_id"],
          "endpoint_revision_sha256" => endpoint_revision
        },
        "source_mode" => "callback"
      }
      |> maybe_put_addressed_connect(addressing_kind, authority["connect_id"])

    key = Keys.ctl_im_slack_event_receipt(authority["connect_id"], event_id)

    %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "connect_id" => authority["connect_id"],
      "event_id" => event_id,
      "connect_generation" => authority["connect_generation"],
      "created_at" => created_at,
      "receipt_ref" => "s3://" <> key,
      "source_message_ref" =>
        Enum.join(
          [
            authority["connect_generation"],
            authority["workspace_id"],
            authority["approved_channel_id"],
            root_ts,
            message_ts
          ],
          ":"
        ),
      "triage_event" => triage_event
    }
  end

  defp equivalent?(left, right) do
    left
    |> put_in(["created_at"], right["created_at"])
    |> put_in(
      ["triage_event", "endpoint_provenance", "captured_at_ms"],
      get_in(right, ["triage_event", "endpoint_provenance", "captured_at_ms"])
    )
    |> Kernel.==(right)
  end

  defp maybe_put_addressed_connect(event, "directed", connect_id),
    do: Map.put(event, "addressed_connect", connect_id)

  defp maybe_put_addressed_connect(event, "ambient", _connect_id), do: event

  defp invalid(:root), do: {:error, :invalid_slack_triage_root}
  defp invalid(:reply), do: {:error, :invalid_slack_triage_reply}

  defp valid_slack_ts?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9]+\.[0-9]{6}\z/, value)

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end

defmodule SalixIM.TestSupport.HistoricalProviderReceipts do
  @moduledoc """
  Test facade that keeps historical callback-v2 recovery coverage explicit.

  Current ClickHouse receipt APIs delegate to the production module; the two
  removed callback producers delegate only to the test-only legacy writer.
  """

  alias SalixIM.TestSupport.LegacyCallbackReceipts

  defdelegate record_slack_triage_root(authority, verified),
    to: LegacyCallbackReceipts,
    as: :record_root

  defdelegate record_slack_triage_reply(authority, verified),
    to: LegacyCallbackReceipts,
    as: :record_reply

  defdelegate record_slack(connect_id, event_id), to: SalixIM.ProviderReceipts
  defdelegate delete_slack(connect_id, event_id), to: SalixIM.ProviderReceipts
  defdelegate list_slack_triage_page(selector, cursor, limit), to: SalixIM.ProviderReceipts
  defdelegate normalize_slack_triage_receipt(receipt), to: SalixIM.ProviderReceipts

  defdelegate record_slack_triage_clickhouse(authority, verified, cursor_revision),
    to: SalixIM.ProviderReceipts

  defdelegate record_slack_triage_recheck(authority, verified, occurrence),
    to: SalixIM.ProviderReceipts

  defdelegate verify_slack_triage_receipt(authority, receipt), to: SalixIM.ProviderReceipts
end
