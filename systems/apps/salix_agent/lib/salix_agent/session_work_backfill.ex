defmodule SalixAgent.SessionWorkBackfill do
  @moduledoc """
  Exclusive, restart-safe release backfill for pre-projection Session work.

  Strategy v3 first pages every distinct Postgres candidate address, then pages
  the authoritative control-agent roster and reads each agent's raw local
  Session-work marker prefix exactly once. Both sources provide only an exact
  Session address; every projection is rebuilt from the current
  Internal/External Session. In the same Postgres transaction, that exact
  address is reconciled to either no candidates for stable authority or only
  the current authoritative token, then the expected row and durable cursor are
  persisted. Permanently unprojectable legacy entries advance the cursor but
  increment `uncovered_authoritative_work`. Final
  verification is a Postgres-only reconciliation between the captured expected
  set and the runtime projection; it never repeats the S3 authority scan. The
  terminal cutover marker remains impossible until both authoritative and
  projection gap counts are zero.

  The release/backfill actions are modeled in
  `tla/salix/SessionWorkProjection.tla`.
  """

  require Logger

  alias SalixAgent.{
    ExternalSessionStore,
    InternalSession,
    InternalSessionStore,
    SessionWorkIndex
  }

  alias SalixStore.{
    Ids,
    Keys,
    S3,
    SessionWorkBackfillState,
    SessionWorkBackfillExpectedCandidates,
    SessionWorkCandidates
  }

  @default_page_size 100

  @type result ::
          {:ok, %{status: :complete | :already_complete, processed: non_neg_integer()}}
          | {:error, term()}

  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    page_size = opts |> Keyword.get(:page_size, @default_page_size) |> bounded_page_size()

    with {:ok, state} <- SessionWorkBackfillState.load(),
         {:ok, false} <- SessionWorkBackfillState.terminal?() do
      continue(state, page_size)
    else
      {:ok, true} -> {:ok, %{status: :already_complete, processed: 0}}
      {:error, _} = error -> error
    end
  end

  defp continue(%{phase: "candidate_backfill"} = state, page_size) do
    opts = [limit: page_size] |> maybe_put_candidate_after(state)

    case SessionWorkCandidates.list_addresses(opts) do
      {:ok, %{addresses: addresses, eof: eof}} ->
        with {:ok, state} <- process_candidate_addresses(state, addresses) do
          if eof,
            do: begin_marker_backfill(state, page_size),
            else: continue(state, page_size)
        end

      {:error, reason} ->
        {:error, {:candidate_address_list_failed, reason}}
    end
  end

  defp continue(%{phase: "verify"} = state, _page_size), do: verify_projection(state)

  defp continue(
         %{phase: "backfill", current_agent_key: key} = state,
         page_size
       )
       when is_binary(key) and key != "" do
    with {:ok, agent_id} <- agent_id_from_control_key(key),
         {:ok, state} <- process_agent_markers(state, key, agent_id, page_size),
         {:ok, state} <- complete_agent(state, key) do
      continue(state, page_size)
    end
  end

  defp continue(%{phase: "backfill"} = state, page_size) do
    opts = [max_keys: page_size] |> maybe_put_start_after(state.agent_start_after)

    case S3.list(Keys.ctl_agents_prefix(), opts) do
      {:ok, %{objects: [], next: nil}} ->
        finish_backfill(state, page_size)

      {:ok, %{objects: [], next: next}} ->
        {:error, {:invalid_agent_roster_page, next}}

      {:ok, %{objects: objects, next: next}} ->
        with {:ok, state} <- process_roster_page(state, objects, page_size) do
          if is_nil(next), do: finish_backfill(state, page_size), else: continue(state, page_size)
        end

      {:error, reason} ->
        {:error, {:agent_roster_list_failed, reason}}
    end
  end

  defp process_roster_page(state, objects, page_size) do
    Enum.reduce_while(objects, {:ok, state}, fn %{key: key}, {:ok, current} ->
      result =
        case agent_id_from_control_key(key) do
          {:ok, agent_id} -> process_agent(current, key, agent_id, page_size)
          {:error, reason} -> advance_unprojectable_agent(current, key, reason)
        end

      case result do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp process_agent(_state, key, agent_id, page_size) do
    with {:ok, state} <-
           SessionWorkBackfillState.put(%{
             current_agent_key: key,
             marker_start_after: nil
           }),
         {:ok, state} <- process_agent_markers(state, key, agent_id, page_size) do
      complete_agent(state, key)
    end
  end

  defp complete_agent(_state, key) do
    SessionWorkBackfillState.put(%{
      agent_start_after: key,
      current_agent_key: nil,
      marker_start_after: nil
    })
  end

  defp process_agent_markers(state, roster_key, agent_id, page_size) do
    opts = [max_keys: page_size] |> maybe_put_start_after(state.marker_start_after)

    case S3.list(Keys.agent_session_work_index_prefix(agent_id), opts) do
      {:ok, %{objects: [], next: nil}} ->
        {:ok, state}

      {:ok, %{objects: [], next: next}} ->
        {:error, {:invalid_marker_page, roster_key, next}}

      {:ok, %{objects: objects, next: next}} ->
        with {:ok, state} <- process_marker_page(state, objects) do
          if is_nil(next),
            do: {:ok, state},
            else: process_agent_markers(state, roster_key, agent_id, page_size)
        end

      {:error, reason} ->
        {:error, {:marker_list_failed, roster_key, reason}}
    end
  end

  defp process_marker_page(state, objects) do
    Enum.reduce_while(objects, {:ok, state}, fn %{key: key}, {:ok, current} ->
      case classify_marker(key) do
        {:ok, action} ->
          attrs = %{
            marker_start_after: key,
            processed: current.processed + 1,
            uncovered_authoritative_work:
              current.uncovered_authoritative_work + uncovered_delta(action)
          }

          case persist_marker_action(action, attrs) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, {:progress_persist_failed, key, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:marker_backfill_failed, key, reason}}}
      end
    end)
  end

  defp process_candidate_addresses(state, addresses) do
    Enum.reduce_while(addresses, {:ok, state}, fn address, {:ok, current} ->
      case classify_candidate_address(address) do
        {:ok, action} ->
          attrs =
            address
            |> candidate_cursor_attrs()
            |> Map.merge(%{
              processed: current.processed + 1,
              uncovered_authoritative_work:
                current.uncovered_authoritative_work + uncovered_delta(action)
            })

          case persist_marker_action(action, attrs) do
            {:ok, next} ->
              {:cont, {:ok, next}}

            {:error, reason} ->
              {:halt, {:error, {:candidate_progress_persist_failed, address, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:candidate_backfill_failed, address, reason}}}
      end
    end)
  end

  defp classify_candidate_address(address) do
    if valid_candidate_address?(address) do
      case read_authority(address) do
        {:ok, authority} ->
          with {:ok, candidate} <- authoritative_candidate(address, authority) do
            if is_nil(candidate),
              do: {:ok, {:stable, address}},
              else: {:ok, {:candidate, candidate}}
          end

        {:error, {:authoritative_session_read_failed, :not_found}} ->
          {:ok, {:stable, address}}

        {:error, _} = error ->
          error
      end
    else
      retain_unprojectable_candidate_address(address, :invalid_candidate_address)
      {:ok, {:uncovered, :invalid_candidate_address}}
    end
  end

  defp valid_candidate_address?(%{
         agent_id: agent_id,
         runtime_kind: runtime_kind,
         session_id: session_id
       }) do
    Ids.valid_agent_id?(agent_id) and runtime_kind in ["internal", "external"] and
      Ids.valid_session_id?(session_id)
  end

  defp valid_candidate_address?(_address), do: false

  defp retain_unprojectable_candidate_address(address, reason) do
    Logger.warning(
      "session-work release backfill retained unprojectable PG candidate address " <>
        "address=#{inspect(address)} reason=#{inspect(reason)}"
    )

    :ok
  end

  defp classify_marker(key) do
    result =
      with {:ok, marker} <- read_marker(key),
           {:ok, address} <- marker_address(key, marker),
           {:ok, _marker_token} <- marker_token(marker) do
        case read_authority(address) do
          {:ok, authority} ->
            with {:ok, candidate} <- authoritative_candidate(address, authority) do
              if is_nil(candidate),
                do: {:ok, {:stable, address}},
                else: {:ok, {:candidate, candidate}}
            end

          {:error, {:authoritative_session_read_failed, :not_found}} ->
            retain_proven_absent_marker(key)
            {:ok, {:stable, address}}

          {:error, _} = error ->
            error
        end
      end

    case result do
      {:error, reason} when reason in [:invalid_marker_json, :invalid_marker] ->
        retain_unprojectable_marker(key, reason)
        {:ok, {:uncovered, reason}}

      {:error, reason}
      when reason in [
             :invalid_agent_id,
             :invalid_runtime_kind,
             :invalid_session_id,
             :marker_address_mismatch,
             :invalid_marker_token,
             :missing_authoritative_token,
             :invalid_authoritative_candidate
           ] ->
        retain_unprojectable_marker(key, reason)
        {:ok, {:uncovered, reason}}

      other ->
        other
    end
  end

  defp read_marker(key) do
    with {:ok, %{body: body}} <- S3.get(key) do
      case Jason.decode(body) do
        {:ok, marker} when is_map(marker) -> {:ok, marker}
        {:ok, _other} -> {:error, :invalid_marker}
        {:error, _reason} -> {:error, :invalid_marker_json}
      end
    end
  end

  defp retain_unprojectable_marker(key, reason) do
    Logger.warning(
      "session-work release backfill retained unprojectable marker " <>
        "key=#{inspect(key)} reason=#{inspect(reason)}"
    )

    :ok
  end

  defp retain_proven_absent_marker(key) do
    Logger.info(
      "session-work release backfill retained marker with no authoritative Session " <>
        "key=#{inspect(key)}"
    )

    :ok
  end

  defp uncovered_delta({:uncovered, _reason}), do: 1
  defp uncovered_delta(_action), do: 0

  defp persist_marker_action({:candidate, candidate}, attrs),
    do: SessionWorkBackfillState.persist_candidate(candidate, attrs)

  defp persist_marker_action({:stable, address}, attrs),
    do: SessionWorkBackfillState.persist_stable(address, attrs)

  defp persist_marker_action({:uncovered, _reason}, attrs),
    do: SessionWorkBackfillState.put(attrs)

  defp read_authority(%{runtime_kind: "internal", agent_id: agent_id, session_id: session_id}) do
    case InternalSessionStore.read_with_etag(agent_id, session_id) do
      {:ok, session, _etag} ->
        {:ok,
         %{
           token: InternalSession.work_index_token(session),
           reasons: InternalSession.work_reasons(session),
           wait: InternalSession.recovery_wait(session),
           storage_revision: InternalSession.storage_revision(session)
         }}

      {:error, reason} ->
        {:error, {:authoritative_session_read_failed, reason}}
    end
  end

  defp read_authority(%{runtime_kind: "external", agent_id: agent_id, session_id: session_id}) do
    case ExternalSessionStore.get_session_record_with_etag(agent_id, session_id) do
      {:ok, session, _etag} ->
        workload_id =
          case get_in(session, ["runtime", "binding"]) do
            %{"kind" => "compute_workload", "workload_id" => id} -> id
            _ -> nil
          end

        {:ok,
         %{
           token: session["work_index_token"],
           workload_id: workload_id,
           device_runtime_id: get_in(session, ["runtime", "binding", "device_runtime_id"]),
           reasons: ExternalSessionStore.work_reasons(session),
           wait: ExternalSessionStore.recovery_wait(session),
           storage_revision: session["storage_revision"]
         }}

      {:error, reason} ->
        {:error, {:authoritative_session_read_failed, reason}}
    end
  end

  defp authoritative_candidate(_address, %{reasons: []}), do: {:ok, nil}

  defp authoritative_candidate(address, authority) do
    cond do
      not SessionWorkIndex.discoverable_reasons?(authority.reasons) ->
        {:ok, nil}

      not (is_binary(authority.token) and authority.token != "") ->
        {:error, :missing_authoritative_token}

      true ->
        candidate =
          SessionWorkIndex.discovery_ref(
            address.agent_id,
            address.runtime_kind,
            address.session_id,
            authority.token,
            authority.reasons,
            authority.wait
          )

        if is_map(candidate) do
          {:ok,
           candidate
           |> Map.put("workload_id", Map.get(authority, :workload_id))
           |> Map.put("device_runtime_id", Map.get(authority, :device_runtime_id))
           |> Map.put("base_revision", authority.storage_revision)
           |> Map.put("updated_at", System.system_time(:second))}
        else
          {:error, :invalid_authoritative_candidate}
        end
    end
  end

  defp marker_address(key, marker) do
    agent_id = marker["agent_id"]
    runtime_kind = marker["runtime_kind"]
    session_id = marker["session_id"]

    cond do
      not Ids.valid_agent_id?(agent_id) ->
        {:error, :invalid_agent_id}

      runtime_kind not in ["internal", "external"] ->
        {:error, :invalid_runtime_kind}

      not Ids.valid_session_id?(session_id) ->
        {:error, :invalid_session_id}

      Keys.agent_session_work_index(agent_id, runtime_kind, session_id) != key ->
        {:error, :marker_address_mismatch}

      true ->
        {:ok, %{agent_id: agent_id, runtime_kind: runtime_kind, session_id: session_id}}
    end
  end

  defp marker_token(%{"token" => token}) when is_binary(token) and token != "",
    do: {:ok, token}

  defp marker_token(_marker), do: {:error, :invalid_marker_token}

  defp begin_marker_backfill(_state, page_size) do
    with {:ok, state} <-
           SessionWorkBackfillState.put(%{
             phase: "backfill",
             candidate_agent_start_after: nil,
             candidate_runtime_kind_start_after: nil,
             candidate_session_start_after: nil,
             agent_start_after: nil,
             current_agent_key: nil,
             marker_start_after: nil
           }) do
      continue(state, page_size)
    end
  end

  defp finish_backfill(_state, page_size) do
    with {:ok, state} <-
           SessionWorkBackfillState.put(%{
             phase: "verify",
             current_agent_key: nil,
             marker_start_after: nil,
             projection_gaps: 0
           }) do
      continue(state, page_size)
    end
  end

  defp verify_projection(_state) do
    with {:ok, projection_gaps} <- SessionWorkBackfillExpectedCandidates.uncovered_count(),
         {:ok, state} <- SessionWorkBackfillState.put(%{projection_gaps: projection_gaps}) do
      uncovered = state.uncovered_authoritative_work + projection_gaps

      if uncovered == 0 do
        evidence = %{
          "processed" => state.processed,
          "uncovered_authoritative_work" => 0,
          "projection_gaps" => 0,
          "strategy_version" => SessionWorkBackfillState.strategy_version(),
          "verified_at_ms" => System.system_time(:millisecond)
        }

        case SessionWorkBackfillState.mark_terminal(evidence) do
          :ok -> {:ok, %{status: :complete, processed: state.processed}}
          {:error, reason} -> {:error, {:terminal_marker_failed, reason}}
        end
      else
        {:error, {:uncovered_authoritative_work, uncovered}}
      end
    else
      {:error, reason} -> {:error, {:projection_verification_failed, reason}}
    end
  end

  defp advance_unprojectable_agent(state, key, reason) do
    Logger.warning(
      "session-work release backfill retained unprojectable agent roster entry " <>
        "key=#{inspect(key)} reason=#{inspect(reason)}"
    )

    SessionWorkBackfillState.put(%{
      agent_start_after: key,
      current_agent_key: nil,
      marker_start_after: nil,
      processed: state.processed + 1,
      uncovered_authoritative_work: state.uncovered_authoritative_work + 1
    })
  end

  defp agent_id_from_control_key(key) when is_binary(key) do
    prefix = Keys.ctl_agents_prefix()

    with true <- String.starts_with?(key, prefix),
         relative <- String.replace_prefix(key, prefix, ""),
         true <- String.ends_with?(relative, ".json"),
         false <- String.contains?(relative, "/"),
         agent_id <- String.trim_trailing(relative, ".json"),
         true <- Ids.valid_agent_id?(agent_id) do
      {:ok, agent_id}
    else
      _ -> {:error, {:invalid_control_agent_key, key}}
    end
  end

  defp bounded_page_size(value) when is_integer(value) and value > 0, do: min(value, 500)
  defp bounded_page_size(_value), do: @default_page_size

  defp maybe_put_start_after(opts, key) when is_binary(key) and key != "",
    do: Keyword.put(opts, :start_after, key)

  defp maybe_put_start_after(opts, _key), do: opts

  defp maybe_put_candidate_after(opts, %{
         candidate_agent_start_after: agent_id,
         candidate_runtime_kind_start_after: runtime_kind,
         candidate_session_start_after: session_id
       })
       when is_binary(agent_id) and is_binary(runtime_kind) and is_binary(session_id) do
    Keyword.put(opts, :after, %{
      agent_id: agent_id,
      runtime_kind: runtime_kind,
      session_id: session_id
    })
  end

  defp maybe_put_candidate_after(opts, _state), do: opts

  defp candidate_cursor_attrs(%{
         agent_id: agent_id,
         runtime_kind: runtime_kind,
         session_id: session_id
       }) do
    %{
      candidate_agent_start_after: agent_id,
      candidate_runtime_kind_start_after: runtime_kind,
      candidate_session_start_after: session_id
    }
  end
end
