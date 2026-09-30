defmodule SalixIM.Triage.ClickHousePatrol do
  @moduledoc """
  Thin orchestration from scoped ClickHouse observations to durable receipts.

  This module deliberately owns no SQL and no queue. A durable patrol worker
  supplies the current authority and cursor. Each saved receipt enters the
  existing Triage admission transaction before the cursor advances. The global
  receipt ring recovers a crash between those two writes; new work does not
  wait for a scan of all historical provider receipts.

  Ambient admission is live Slack events only. The change stream is
  `slack_message_event_triggers`, written by the webhook outbox, not
  `ingest_source` on a reconstructed `slack_messages` row. History backfill
  never writes a trigger. An explicit `ingest_source = "backfill"` on a
  scripted row is still ineligible.

  Non-self bot roots may enter ambient evaluation (including operational alerts).
  Undirected bot replies remain excluded; this does not grant a thread subscription
  or bypass another route's ownership. Receipt validation enforces the same boundary.
  """

  alias SalixIM.Provider.Slack.{ConversationIngress, ThreadRouteOwner, TriageThreadSubscription}
  alias SalixIM.{ProviderConnects, ProviderReceipts, Triage.ClickHouseReader}
  alias SalixStore.TriagePatrolScanState

  @max_page 200
  @default_overlap_ms 5_000
  @body_subtypes ["", "bot_message", "file_share", "me_message", "thread_broadcast"]
  @slack_ts ~r/\A[0-9]+\.[0-9]{6}\z/

  @spec scan(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def scan(authority, cursor, opts \\ [])

  def scan(authority, scan_state, opts) when is_map(authority) and is_map(scan_state) do
    reader = Keyword.get(opts, :reader, ClickHouseReader.impl())
    limit = Keyword.get(opts, :limit, 50)
    cursor_revision = Keyword.get(opts, :cursor_revision)
    overlap_ms = Keyword.get(opts, :overlap_ms, @default_overlap_ms)
    thread_binding_port = Keyword.get(opts, :thread_binding_port, ConversationIngress)
    admission = Keyword.get(opts, :admission, &SalixIM.Triage.accept_current/2)

    authority_verifier =
      Keyword.get(opts, :authority_verifier, &ProviderConnects.verify_slack_triage_authority/1)

    scope = scope(authority)

    with true <- module_exports?(reader, tail: 1, list_changes: 3, latest_states: 2),
         true <- is_integer(limit) and limit in 1..@max_page,
         true <- is_integer(cursor_revision) and cursor_revision >= 0,
         true <- is_integer(overlap_ms) and overlap_ms in 0..300_000,
         true <- is_function(authority_verifier, 1),
         true <- is_function(admission, 2),
         true <-
           module_exports?(thread_binding_port,
             get_thread_binding: 4,
             task_thread_binding_record?: 1
           ),
         {:ok, active_state} <- prepare_pass(scan_state, scope, reader, overlap_ms),
         {:ok, window} <- TriagePatrolScanState.window(active_state),
         {:ok, page} <- reader.list_changes(scope, window, limit),
         {:ok, message_keys} <- message_keys(page),
         {:ok, latest_states} <- reader.latest_states(scope, message_keys),
         true <- Enum.all?(message_keys, &Map.has_key?(latest_states, &1)),
         {:ok, counts} <-
           settle(
             latest_states,
             message_keys,
             authority,
             cursor_revision,
             authority_verifier,
             thread_binding_port,
             admission
           ),
         {:ok, next_state} <- TriagePatrolScanState.advance(active_state, page) do
      {:ok,
       Map.merge(counts, %{
         settled: length(message_keys),
         next_scan_state: next_state,
         has_more?: page.has_more?
       })}
    else
      false -> {:error, :invalid_clickhouse_patrol}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_clickhouse_patrol}
    end
  end

  def scan(_authority, _cursor, _opts), do: {:error, :invalid_clickhouse_patrol}

  defp prepare_pass(scan_state, scope, reader, overlap_ms) do
    case TriagePatrolScanState.window(scan_state) do
      {:ok, _active_window} ->
        {:ok, scan_state}

      {:error, :invalid} ->
        with true <- TriagePatrolScanState.valid?(scan_state),
             {:ok, tail} <- reader.tail(scope),
             {:ok, active} <- TriagePatrolScanState.start_pass(scan_state, tail, overlap_ms) do
          {:ok, active}
        else
          false -> {:error, :invalid_clickhouse_scan_state}
          {:error, _reason} = error -> error
        end
    end
  end

  defp message_keys(%{rows: rows, next_cursor: next_cursor, has_more?: has_more?})
       when is_list(rows) and (is_map(next_cursor) or is_nil(next_cursor)) and
              is_boolean(has_more?) do
    keys = rows |> Enum.map(&Map.get(&1, "message_ts_us")) |> Enum.uniq()

    if Enum.all?(keys, &(is_integer(&1) and &1 >= 0)),
      do: {:ok, keys},
      else: {:error, :invalid_clickhouse_patrol_page}
  end

  defp message_keys(_page), do: {:error, :invalid_clickhouse_patrol_page}

  defp settle(
         states,
         keys,
         authority,
         cursor_revision,
         authority_verifier,
         thread_binding_port,
         admission
       ) do
    Enum.reduce_while(keys, {:ok, %{created: 0, duplicate: 0, ineligible: 0}}, fn key,
                                                                                  {:ok, counts} ->
      row = Map.fetch!(states, key)

      case verified_message(row, authority) do
        {:ok, message} ->
          case route_message(authority, message, thread_binding_port) do
            {:admit, route_scope} ->
              case authority_verifier.(authority) do
                :ok ->
                  case record_current_message(
                         authority,
                         message,
                         cursor_revision,
                         route_scope,
                         admission
                       ) do
                    {:ok, :created, _receipt} ->
                      {:cont, {:ok, Map.update!(counts, :created, &(&1 + 1))}}

                    {:ok, :duplicate, _receipt} ->
                      {:cont, {:ok, Map.update!(counts, :duplicate, &(&1 + 1))}}

                    {:conflict, _owner} ->
                      {:cont, {:ok, Map.update!(counts, :ineligible, &(&1 + 1))}}

                    {:error, reason} ->
                      {:halt, {:error, reason}}
                  end

                {:error, reason} ->
                  {:halt, {:error, reason}}

                _invalid ->
                  {:halt, {:error, :slack_triage_authority_unavailable}}
              end

            :ineligible ->
              {:cont, {:ok, Map.update!(counts, :ineligible, &(&1 + 1))}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        :ineligible ->
          {:cont, {:ok, Map.update!(counts, :ineligible, &(&1 + 1))}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp verified_message(row, authority) when is_map(row) do
    root_thread_ts = if row["thread_ts"] == "", do: row["message_ts"], else: row["thread_ts"]
    own_actor_ids = [authority["app_id"], authority["bot_user_id"], authority["bot_id"]]
    actor_kind = triage_actor_kind(row["actor_kind"])

    directed_agent? =
      actor_kind == "agent" and mentions_bot?(row["text"], authority["bot_user_id"])

    cond do
      row["tenant_id"] != authority["tenant_id"] or
        row["workspace_id"] != authority["workspace_id"] or
          row["channel_id"] != authority["approved_channel_id"] ->
        {:error, :clickhouse_scope_mismatch}

      backfill_source?(row) ->
        :ineligible

      row["deleted"] != false or is_nil(actor_kind) or
        row["actor_id"] in own_actor_ids or row["subtype"] not in @body_subtypes or
        not canonical_nonblank?(row["actor_id"]) or not canonical_nonblank?(row["text"]) or
        (actor_kind == "human" and mentions_bot?(row["text"], authority["bot_user_id"])) or
          (actor_kind == "agent" and not directed_agent? and root_thread_ts != row["message_ts"]) ->
        :ineligible

      not Regex.match?(@slack_ts, row["message_ts"]) or
        not Regex.match?(@slack_ts, root_thread_ts) or
        not valid_uint?(row["message_ts_us"]) or not valid_uint?(row["version"]) or
          not valid_iso8601?(row["ingest_at"]) ->
        {:error, :invalid_clickhouse_message}

      true ->
        {:ok,
         %{
           "workspace_id" => row["workspace_id"],
           "channel_id" => row["channel_id"],
           "root_thread_ts" => root_thread_ts,
           "message_ts" => row["message_ts"],
           "message_ts_us" => row["message_ts_us"],
           "observed_version" => row["version"],
           "ingest_at" => row["ingest_at"],
           "actor_id" => row["actor_id"],
           "actor_kind" => actor_kind,
           "text" => row["text"]
         }}
    end
  end

  defp verified_message(_row, _authority), do: {:error, :invalid_clickhouse_message}

  # Absent or blank is the live path: scripted readers and rows written before
  # `ingest_source` existed. Only an explicit backfill label is skipped.
  defp backfill_source?(%{"ingest_source" => source}) when is_binary(source),
    do: source == "backfill"

  defp backfill_source?(_row), do: false

  defp route_message(authority, message, thread_binding_port) do
    scope = %{
      "tenant_id" => authority["tenant_id"],
      "group_id" => authority["group_id"],
      "connect_id" => authority["connect_id"],
      "connect_generation" => authority["connect_generation"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"],
      "root_thread_ts" => message["root_thread_ts"]
    }

    root? = message["root_thread_ts"] == message["message_ts"]

    with :unbound <- task_thread_owner(scope, thread_binding_port) do
      route_unbound_message(authority, message, scope, root?)
    else
      :task -> :ineligible
      :unavailable -> {:error, :slack_route_unavailable}
    end
  end

  defp route_unbound_message(authority, message, scope, root?) do
    case {root?, ThreadRouteOwner.lookup(scope)} do
      {true, :unbound} ->
        claim_root(scope, message)

      {true, {:ok, :triage}} ->
        case TriageThreadSubscription.admission(authority, scope) do
          :admit -> :ineligible
          :ignore -> {:admit, scope}
          {:error, :unavailable} -> {:error, :slack_route_unavailable}
        end

      {true, {:ok, owner}} when owner in [:legacy, :assistant, :task] ->
        :ineligible

      {true, {:owned_elsewhere, _owner}} ->
        :ineligible

      {false, {:ok, :triage}} ->
        # Ordinary callbacks own follow-up after a confirmed reply. Before
        # participation, the frozen root batch already includes its context.
        :ineligible

      {false, :unbound} ->
        :ineligible

      {false, {:ok, _owner}} ->
        :ineligible

      {_root, {:owned_elsewhere, _owner}} ->
        :ineligible

      {_root, :unavailable} ->
        {:error, :slack_route_unavailable}
    end
  end

  defp task_thread_owner(scope, thread_binding_port) do
    case thread_binding_port.get_thread_binding(
           scope["group_id"],
           scope["connect_id"],
           scope["channel_id"],
           scope["root_thread_ts"]
         ) do
      {:ok, binding} ->
        if thread_binding_port.task_thread_binding_record?(binding), do: :task, else: :unbound

      {:error, :not_found} ->
        :unbound

      {:error, _reason} ->
        :unavailable

      _invalid ->
        :unavailable
    end
  rescue
    _exception -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  defp claim_root(scope, message) do
    with {:ok, false} <- peer_mentioned?(scope, message["text"]),
         {:ok, identity} <-
           ThreadRouteOwner.clickhouse_root_claim_identity(scope, message["message_ts_us"]),
         {:ok, :triage} <- ThreadRouteOwner.claim_triage(scope, identity) do
      {:admit, scope}
    else
      {:ok, true} -> :ineligible
      {:conflict, _owner} -> :ineligible
      _unavailable -> {:error, :slack_route_unavailable}
    end
  end

  defp record_current_message(authority, message, cursor_revision, route_scope, admission) do
    case ThreadRouteOwner.lookup_claim(route_scope) do
      {:ok, :triage, _claim_identity} ->
        with {:ok, kind, receipt} <-
               ProviderReceipts.record_slack_triage_clickhouse(
                 authority,
                 message,
                 cursor_revision
               ),
             :ok <- admit_receipt(admission, authority, receipt) do
          {:ok, kind, receipt}
        end

      {:ok, owner, _claim_identity} ->
        {:conflict, owner}

      :unavailable ->
        {:error, :slack_route_unavailable}
    end
  end

  defp admit_receipt(admission, authority, receipt) do
    case admission.(authority, receipt) do
      {:ok, status} when status in [:accepted, :duplicate] -> :ok
      _closed -> {:error, :triage_admission_unavailable}
    end
  rescue
    _exception -> {:error, :triage_admission_unavailable}
  catch
    :exit, _reason -> {:error, :triage_admission_unavailable}
  end

  defp peer_mentioned?(scope, text) do
    mentioned_user_ids =
      Regex.scan(~r/<@([A-Z0-9]+)>/, text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    if mentioned_user_ids == [] do
      {:ok, false}
    else
      authority = %{
        "tenant_id" => scope["tenant_id"],
        "group_id" => scope["group_id"],
        "connect_id" => scope["connect_id"],
        "workspace_id" => scope["workspace_id"],
        "approved_channel_id" => scope["channel_id"]
      }

      ProviderConnects.slack_triage_peer_mentioned?(authority, mentioned_user_ids)
    end
  end

  defp scope(authority) do
    %{
      "tenant_id" => authority["tenant_id"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"]
    }
  end

  defp mentions_bot?(text, bot_user_id),
    do: is_binary(text) and is_binary(bot_user_id) and String.contains?(text, "<@#{bot_user_id}>")

  defp triage_actor_kind("user"), do: "human"
  defp triage_actor_kind(kind) when kind in ["bot", "app"], do: "agent"
  defp triage_actor_kind(_kind), do: nil

  defp canonical_nonblank?(value),
    do:
      is_binary(value) and value != "" and value == String.trim(value) and
        not String.contains?(value, <<0>>)

  defp valid_uint?(value), do: is_integer(value) and value >= 0

  defp valid_iso8601?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_iso8601?(_value), do: false

  defp module_exports?(module, exports) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(exports, fn {function, arity} -> function_exported?(module, function, arity) end)
  end

  defp module_exports?(_module, _exports), do: false
end
