defmodule Salix.Bindings.ClickHouseTriageThreadReader do
  @moduledoc """
  Bounded current-state thread context for Slack Triage.

  The binding resolves the narrow `salix_im` read port to its analytics
  implementation. It never calls Slack and never accepts a tenant, workspace,
  or channel from message content; all three come from the already-validated
  product authority.
  """

  alias SalixIM.Provider.Slack.{MessageReferences, TaskCards}

  alias SalixIM.Triage.{
    CanonicalJSON,
    ChannelBatch,
    ClickHouseReader,
    FileAttachments,
    IdentityContract,
    IdentityFence
  }

  @limit 200
  @max_bytes 1_048_576
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @identity_option_keys ~w(
    identity_fence_handle
    identity_profile_sha256
    request_selector_sha256
    source_origin_sha256
    source_observation_sha256
  )a

  @spec read(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(authority, connect, opts \\ [])

  def read(authority, connect, opts)
      when is_map(authority) and is_map(connect) and is_list(opts) do
    if Keyword.has_key?(opts, :identity_fence_handle) do
      read_observed(authority, connect, opts)
    else
      read_unobserved(authority, connect, opts)
    end
  end

  def read(_authority, _connect, _opts), do: {:error, :invalid_triage_clickhouse_authority}

  @doc "Stable code identity for the configured CH current-state read boundary."
  @spec observed_read_origin_sha256() :: {:ok, String.t()} | {:error, term()}
  def observed_read_origin_sha256 do
    reader = ClickHouseReader.impl()

    with true <- is_atom(reader),
         {^reader, object_code, _path} when is_binary(object_code) <-
           :code.get_object_code(reader),
         {:ok, bytes} <-
           CanonicalJSON.encode(%{
             "schema" => "comma.clickhouse-thread-read-origin.v1",
             "reader_module" => Atom.to_string(reader),
             "reader_object_code_sha256" => CanonicalJSON.sha256(object_code)
           }) do
      {:ok, CanonicalJSON.sha256(bytes)}
    else
      _invalid -> {:error, :clickhouse_read_origin_unavailable}
    end
  end

  defp read_unobserved(authority, connect, opts) do
    keys = Keyword.keys(opts)
    reader = Keyword.get(opts, :reader, ClickHouseReader.impl())

    with true <-
           Keyword.keyword?(opts) and length(keys) == length(Enum.uniq(keys)) and
             Enum.sort(keys) in [[], [:reader]],
         true <- is_atom(reader),
         {:ok, snapshot} <- read_snapshot(authority, connect, reader, opts) do
      {:ok, thread(snapshot)}
    else
      false -> {:error, :triage_clickhouse_context_truncated}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :triage_clickhouse_context_unavailable}
  catch
    :exit, _reason -> {:error, :triage_clickhouse_context_unavailable}
  end

  defp read_observed(authority, connect, opts) do
    reader = ClickHouseReader.impl()
    handle = opts[:identity_fence_handle]

    claim = %{
      "schema" => "comma.triage-source-observation-claim.v2",
      "identity_profile_sha256" => opts[:identity_profile_sha256],
      "request_selector_sha256" => opts[:request_selector_sha256],
      "source_origin_sha256" => opts[:source_origin_sha256],
      "source_observation_sha256" => opts[:source_observation_sha256]
    }

    with :ok <- validate_identity_options(opts),
         true <- is_atom(reader),
         {:ok, current_origin} <- observed_read_origin_sha256(),
         true <- current_origin == opts[:source_origin_sha256],
         :ok <- IdentityFence.claim_observation(handle, claim),
         :proceed <- IdentityFence.mark_transport_started(handle) do
      case read_snapshot(authority, connect, reader, opts) do
        {:ok, snapshot} ->
          commit_observed_success(handle, claim, snapshot, ChannelBatch.operation(authority))

        {:error, reason} ->
          commit_observed_error(handle, claim, reason, ChannelBatch.operation(authority))
      end
    else
      {:error, :invalid_identity_thread_reader_options} = error -> error
      {:error, :invalid_triage_clickhouse_authority} = error -> error
      _denied -> {:error, :identity_fence_denied}
    end
  rescue
    _exception -> {:error, :identity_diagnostic_indeterminate_transport}
  catch
    _kind, _reason -> {:error, :identity_diagnostic_indeterminate_transport}
  end

  defp read_snapshot(authority, connect, reader, opts) do
    channel_id = trim(authority["channel_id"])
    thread_ts = trim(authority["thread_ts"])

    scope = %{
      "tenant_id" => connect["tenant_id"],
      "workspace_id" => connect["workspace_id"],
      "channel_id" => channel_id
    }

    with true <- channel_id != "" and thread_ts != "",
         true <- channel_id == connect["approved_channel_id"],
         {:ok, page} <- read_page(reader, scope, authority, opts),
         true <- page.complete? == true do
      reactions = Enum.group_by(page.reactions, & &1["message_ts_us"])

      {:ok,
       %{
         "schema" =>
           if(ChannelBatch.channel?(authority),
             do: "comma.triage-clickhouse-channel-snapshot.v1",
             else: "comma.triage-clickhouse-thread-snapshot.v2"
           ),
         "complete" => true,
         "messages" =>
           Enum.map(
             page.messages,
             &project_message(&1, reactions[&1["message_ts_us"]] || [], connect, authority)
           )
       }}
    else
      false -> {:error, :triage_clickhouse_context_truncated}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_triage_clickhouse_authority}
    end
  end

  defp read_page(reader, scope, %{"scope_kind" => "channel"}, opts) do
    reader.read_channel(scope, opts[:source_window], limit: @limit, max_bytes: @max_bytes)
  end

  defp read_page(reader, scope, authority, _opts) do
    reader.read_thread(scope, authority["thread_ts"], limit: @limit, max_bytes: @max_bytes)
  end

  defp thread(snapshot) do
    %{
      "checked_at" =>
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      "messages" => snapshot["messages"],
      "source_snapshot" => snapshot_summary(snapshot)
    }
  end

  defp commit_observed_success(handle, claim, snapshot, operation) do
    with {:ok, snapshot_bytes} <- CanonicalJSON.encode(snapshot),
         snapshot_sha256 = CanonicalJSON.sha256(snapshot_bytes),
         {:ok, classified_bytes} <- CanonicalJSON.encode(snapshot["messages"]),
         receipt = success_receipt(claim, snapshot, snapshot_sha256, operation),
         result = %{
           "schema" => "comma.triage-source-read-result.v1",
           "kind" => "success",
           "receipt" => receipt,
           "canonical_snapshot_bytes" => snapshot_bytes,
           "canonical_snapshot_sha256" => snapshot_sha256,
           "classified_private_messages_sha256" => CanonicalJSON.sha256(classified_bytes),
           "reason_code" => nil
         },
         :ok <- IdentityFence.commit_transport(handle, result) do
      {:ok,
       thread(snapshot)
       |> Map.put("identity_private_observation", %{
         "source_snapshot" => snapshot,
         "receipt" => receipt
       })}
    else
      _denied -> {:error, :identity_fence_denied}
    end
  end

  defp commit_observed_error(handle, claim, _reason, operation) do
    receipt = error_receipt(claim, operation)

    result = %{
      "schema" => "comma.triage-source-read-result.v1",
      "kind" => "attempted_error",
      "receipt" => receipt,
      "canonical_snapshot_bytes" => nil,
      "canonical_snapshot_sha256" => nil,
      "classified_private_messages_sha256" => nil,
      "reason_code" => "source_unavailable"
    }

    case IdentityFence.commit_transport(handle, result) do
      :ok -> {:error, :triage_clickhouse_context_unavailable}
      _denied -> {:error, :identity_fence_denied}
    end
  end

  defp success_receipt(claim, snapshot, snapshot_sha256, operation) do
    %{
      "schema" => "comma.clickhouse-thread-read-receipt.v1",
      "operation" => operation,
      "request_selector_sha256" => claim["request_selector_sha256"],
      "source_origin_sha256" => claim["source_origin_sha256"],
      "outcome" => "success",
      "typed_reason" => nil,
      "canonical_snapshot_sha256" => snapshot_sha256,
      "message_count" => length(snapshot["messages"]),
      "reaction_count" => Enum.reduce(snapshot["messages"], 0, &(length(&1["reactions"]) + &2)),
      "complete" => true
    }
  end

  defp error_receipt(claim, operation) do
    %{
      "schema" => "comma.clickhouse-thread-read-receipt.v1",
      "operation" => operation,
      "request_selector_sha256" => claim["request_selector_sha256"],
      "source_origin_sha256" => claim["source_origin_sha256"],
      "outcome" => "source_unavailable",
      "typed_reason" => "source_unavailable",
      "canonical_snapshot_sha256" => nil,
      "message_count" => nil,
      "reaction_count" => nil,
      "complete" => nil
    }
  end

  defp validate_identity_options(opts) do
    keys = Keyword.keys(opts)

    valid? =
      Keyword.keyword?(opts) and length(keys) == length(Enum.uniq(keys)) and
        Enum.sort(keys) in [
          Enum.sort(@identity_option_keys),
          Enum.sort([:source_window | @identity_option_keys])
        ] and
        Enum.all?(@identity_option_keys -- [:identity_fence_handle], fn key ->
          is_binary(opts[key]) and Regex.match?(@sha256, opts[key])
        end)

    if valid?, do: :ok, else: {:error, :invalid_identity_thread_reader_options}
  end

  defp snapshot_summary(snapshot) do
    %{
      "schema" => snapshot["schema"],
      "complete" => true,
      "message_count" => length(snapshot["messages"]),
      "reaction_count" => Enum.reduce(snapshot["messages"], 0, &(length(&1["reactions"]) + &2))
    }
  end

  # IdentityContract requires this exact classified key set. Payload may overlay
  # existing Slack fields and must not introduce extra snapshot keys.
  defp project_message(row, reactions, connect, authority) do
    message = slack_payload(row)

    raw = %{
      "ts" => slack_string(message, "ts", row["message_ts"]),
      "text" =>
        slack_string(message, "text", row["text"]) <>
          MessageReferences.content_suffix(message) <>
          TaskCards.content_suffix(message),
      "subtype" => slack_string(message, "subtype", row["subtype"]),
      "user" =>
        slack_string(
          message,
          "user",
          if(row["actor_kind"] == "user", do: row["actor_id"], else: "")
        ),
      "bot_id" =>
        slack_string(
          message,
          "bot_id",
          if(row["actor_kind"] == "bot", do: row["actor_id"], else: "")
        ),
      "app_id" =>
        slack_string(
          message,
          "app_id",
          if(row["actor_kind"] == "app", do: row["actor_id"], else: "")
        ),
      "bot_profile_name" => actor_label(row),
      "file_attachments" => FileAttachments.from_slack(message["files"])
    }

    raw =
      if ChannelBatch.channel?(authority) do
        root = if trim(row["thread_ts"]) == "", do: row["message_ts"], else: row["thread_ts"]
        Map.put(raw, "root_thread_ts", root)
      else
        raw
      end

    raw
    |> Map.put("actor_kind", IdentityContract.actor_kind(raw, connect))
    |> Map.put("actor_id", row["actor_id"])
    |> Map.put("message_ts_us", row["message_ts_us"])
    |> Map.put("observed_version", row["version"])
    |> Map.put(
      "reactions",
      Enum.map(reactions, fn reaction ->
        %{"name" => reaction["reaction"], "count" => reaction["count"]}
      end)
    )
  end

  defp slack_string(message, key, fallback) do
    case message[key] do
      value when is_binary(value) -> value
      _missing -> fallback
    end
  end

  defp slack_payload(%{"payload" => json}) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _invalid -> %{}
    end
  end

  defp slack_payload(_row), do: %{}

  defp actor_label(%{"actor_kind" => kind, "actor_label" => label})
       when kind in ["bot", "app"] and is_binary(label) and label != "",
       do: label

  defp actor_label(_row), do: ""

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
