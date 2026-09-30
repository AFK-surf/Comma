defmodule SalixAgent.SessionWorkIndex do
  @moduledoc """
  Durable per-agent index of sessions that may need recovery or wake.

  The index is not the source of truth. Each entry only says that AgentServer
  should consider waking `{runtime_kind, session_id}`; the session actor must
  re-read its own durable state before doing work.

  `mark/5` writes the per-session object and, for discoverable work, the
  Postgres candidate projection before the matching session-state CAS. Eager
  work uses a bounded keyset lane; wait-only work uses an exact-deadline-ordered
  deferred lane. Existing PG candidate addresses and agent-local markers are the
  two bounded address sources for explicit pre-cutover release certification;
  cluster cold discovery never scans S3. AgentServer's bounded compatibility
  fast path still reads its own local markers until cleanup. Stable cleanup
  deletes the exact-address PG candidate before its token-fenced local marker,
  so a PG failure retains the local fail-closed hint.

  Callback deadlines use the deferred lane even without a model wait. If eager
  work shares that candidate, zero makes it due immediately in the same lane.
  Every reason change mints a fresh token; the session-state
  CAS decides which token is durable. Recovery treats content ETags and absence
  as non-authoritative cleanup hints because a paused writer may still land
  after delete/recreate or an A→B→A content cycle.

  `tla/salix/SessionActivation.tla` owns the abstract mark-before-CAS
  activation and stable-first cleanup cell. The concrete single local marker
  → Postgres candidate → Session CAS admission, immutable
  `storage_revision` retirement, and release backfill/cutover are modeled in
  `tla/salix/SessionWorkProjection.tla`. Eager/deferred recovery ordering is
  modeled independently in `tla/salix/SessionWorkRecoveryLane.tla`.
  Executable tests retain the concrete keyset SQL and exact-target wake
  adapter obligations. Recovery only retires one exact candidate after the
  authoritative revision proves its CAS base was superseded. Otherwise
  unprovable rows remain fail closed.
  """

  alias SalixStore.{Ids, Keys, S3, SessionWorkCandidates}

  @runtime_kinds ~w(internal external)
  @work_reasons ~w(
    unacked_queue_item
    active_round
    process_local_background_tool_run
    external_callback_tool_call
    capability_deadline
    runtime_failure_reply
    wait_deadline
    runtime_wait
    provider_cutover_parked
    llm_retry
    stable_input_pending
    provider_reply_obligation
    transcript_continuation
    visible_reply_repair
    visible_reply_commit
  )
  @deferred_or_external_reasons ~w(external_callback_tool_call capability_deadline wait_deadline llm_retry runtime_wait provider_cutover_parked)
  @default_agent_page_size 100
  @default_discovery_page_size 100
  @max_discovery_page_size 128

  @type runtime_kind :: :internal | :external | String.t()
  @type index_record :: %{
          String.t() => term()
        }
  @type recovery_record :: index_record()

  @spec new_token() :: String.t()
  def new_token, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @spec mark(String.t(), runtime_kind(), String.t(), [String.t()], keyword()) ::
          {:ok, index_record()} | {:error, term()}
  def mark(agent_id, runtime_kind, session_id, reasons, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_list(reasons) do
    with true <- Ids.valid_session_id?(session_id),
         {:ok, runtime_kind} <- normalize_runtime_kind(runtime_kind),
         {:ok, reasons} <- normalize_reasons(reasons) do
      rec =
        %{
          "agent_id" => agent_id,
          "session_id" => session_id,
          "runtime_kind" => runtime_kind,
          "token" => new_token(),
          "reasons" => reasons,
          "updated_at" => opts[:updated_at] || now()
        }
        |> put_optional("cas_base", opts[:cas_base])
        |> put_optional("base_revision", opts[:base_revision])
        |> put_optional("device_runtime_id", opts[:device_runtime_id])
        |> put_optional("recover_after_ms", opts[:recover_after_ms])

      with true <- valid_cas_base?(rec["cas_base"]),
           true <- valid_recover_after?(rec["recover_after_ms"]),
           {:ok, _} <-
             SystemsObservability.Trace.with_span(
               :salix_work_index_write,
               %{
                 component: "salix_agent",
                 surface: SystemsObservability.Context.current_surface()
               },
               fn ->
                 S3.put(
                   Keys.agent_session_work_index(agent_id, runtime_kind, session_id),
                   Jason.encode!(rec)
                 )
               end
             ),
           :ok <-
             SystemsObservability.Trace.with_span(
               :salix_discovery_write,
               %{
                 component: "salix_agent",
                 surface: SystemsObservability.Context.current_surface()
               },
               fn -> put_discovery(put_optional(rec, "workload_id", opts[:workload_id])) end
             ) do
        {:ok, rec}
      end
    else
      false -> {:error, :invalid_session_id}
      {:error, _} = error -> error
    end
  end

  @spec list(String.t()) :: {:ok, [index_record()]} | {:error, term()}
  def list(agent_id) when is_binary(agent_id) do
    prefix = Keys.agent_session_work_index_prefix(agent_id)

    with {:ok, objects} <- S3.list_all(prefix) do
      records =
        objects
        |> Enum.filter(&String.ends_with?(&1.key, ".json"))
        |> Enum.flat_map(&load_record/1)
        |> Enum.filter(&valid_record?(agent_id, &1))
        |> Enum.sort_by(&{&1["runtime_kind"], &1["session_id"]})

      {:ok, records}
    end
  end

  @doc """
  Return one bounded page from an agent's local recovery index.

  This is the interactive AgentServer fast path, not the completeness
  authority. Eager/deferred global discovery owns cold recovery, and
  callback-only work owns its explicit callback wake. The opaque continuation
  token lets later AgentServer wakes rotate through local cleanup without an
  unbounded request-path scan.
  """
  @spec list_page(String.t(), keyword()) ::
          {:ok, %{records: [index_record()], next: String.t() | nil}} | {:error, term()}
  def list_page(agent_id, opts \\ []) when is_binary(agent_id) do
    prefix = Keys.agent_session_work_index_prefix(agent_id)

    max_keys =
      opts
      |> Keyword.get(:max_keys, @default_agent_page_size)
      |> clamp_page_size()

    list_opts =
      [max_keys: max_keys]
      |> maybe_put_continuation_token(opts[:continuation_token])

    with {:ok, %{objects: objects, next: next}} <- S3.list(prefix, list_opts) do
      records =
        objects
        |> Enum.filter(&String.ends_with?(&1.key, ".json"))
        |> Enum.flat_map(&load_record/1)
        |> Enum.filter(&valid_record?(agent_id, &1))
        |> Enum.sort_by(&{&1["runtime_kind"], &1["session_id"]})

      {:ok, %{records: records, next: next}}
    end
  end

  @doc """
  Return one bounded page from the eager Postgres discovery projection.
  """
  @spec list_discovery(keyword()) ::
          {:ok, %{records: [recovery_record()], eof: boolean(), next: String.t() | nil}}
          | {:error, term()}
  def list_discovery(opts \\ []) do
    max_keys =
      opts
      |> Keyword.get(:max_keys, @default_discovery_page_size)
      |> clamp_page_size()

    with {:ok, cursor} <- decode_cursor(opts[:continuation_token], :eager),
         {:ok, %{records: records, eof: eof}} <-
           SessionWorkCandidates.list_eager(
             limit: max_keys,
             after: cursor,
             group_id: opts[:group_id],
             workload_id: opts[:workload_id]
           ) do
      {:ok, page_result(records, eof, :eager)}
    end
  end

  @doc """
  Return one bounded oldest-first page of deferred records whose exact deadline
  is due. Future records are never hydrated, so outstanding waits do not dilute
  eager recovery or cause per-sweep session reads.

  A pre-CAS false positive may remain until its deadline; once due, Recovery
  validates both its token and CAS base against session state. A token mismatch
  alone is not proof that a paused mark-first writer cannot still commit.
  """
  @spec list_due_discovery(integer(), keyword()) ::
          {:ok, %{records: [recovery_record()], eof: boolean(), next: String.t() | nil}}
          | {:error, term()}
  def list_due_discovery(now_ms, opts \\ []) when is_integer(now_ms) do
    max_keys =
      opts
      |> Keyword.get(:max_keys, @default_discovery_page_size)
      |> clamp_page_size()

    with {:ok, cursor} <- decode_cursor(opts[:continuation_token], :deferred),
         {:ok, %{records: records, eof: eof}} <-
           SessionWorkCandidates.list_due(now_ms, limit: max_keys, after: cursor) do
      {:ok, page_result(records, eof, :deferred)}
    end
  end

  @doc false
  @spec cursor(index_record(), :eager | :deferred) :: String.t()
  def cursor(record, lane) when lane in [:eager, :deferred] do
    payload =
      %{
        "lane" => Atom.to_string(lane),
        "agent_id" => record["agent_id"],
        "runtime_kind" => record["runtime_kind"],
        "session_id" => record["session_id"],
        "candidate_token" => record["token"]
      }
      |> put_optional("due_at_ms", record["recover_after_ms"])

    payload |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  @spec immediate_recovery_reasons?([term()]) :: boolean()
  def immediate_recovery_reasons?(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(&to_string/1)
    |> Enum.any?(&(&1 not in @deferred_or_external_reasons))
  end

  def immediate_recovery_reasons?(_reasons), do: false

  @doc """
  Whether a reason set needs a cluster-wide discovery record.

  Callback and wait deadlines need discovery even when no round is active.
  Timers are the fast path; the record remains the deadline backstop.
  """
  @spec discoverable_reasons?([term()]) :: boolean()
  def discoverable_reasons?(reasons) when is_list(reasons) do
    normalized = Enum.map(reasons, &to_string/1)

    immediate_recovery_reasons?(normalized) or
      Enum.any?(
        ~w(wait_deadline llm_retry capability_deadline runtime_wait provider_cutover_parked),
        &(&1 in normalized)
      )
  end

  def discoverable_reasons?(_reasons), do: false

  @doc """
  Return the time at which Recovery should wake deferred work.

  Eager work with a capability deadline stays in the deadline lane, due
  immediately (zero), so unrelated eager pages cannot hide an expired callback.
  Other eager work clears the delay.
  """
  @spec recover_after_ms([term()], map() | nil) :: integer() | nil
  def recover_after_ms(reasons, wait) when is_list(reasons) do
    normalized = Enum.map(reasons, &to_string/1)
    eager = normalized -- @deferred_or_external_reasons

    case {eager,
          Enum.any?(
            ~w(wait_deadline llm_retry capability_deadline runtime_wait),
            &(&1 in normalized)
          ), wait_deadline_ms(wait)} do
      {[], true, deadline_ms} when is_integer(deadline_ms) -> deadline_ms
      {[_ | _], true, _} -> if "capability_deadline" in normalized, do: 0, else: nil
      _ -> nil
    end
  end

  def recover_after_ms(_reasons, _wait), do: nil

  @doc false
  @spec discovery_ref(
          String.t(),
          runtime_kind(),
          String.t(),
          String.t() | nil,
          [term()],
          map() | nil
        ) :: index_record() | nil
  def discovery_ref(_agent_id, _runtime_kind, _session_id, token, _reasons, _wait)
      when token in [nil, ""],
      do: nil

  def discovery_ref(agent_id, runtime_kind, session_id, token, reasons, wait)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(token) do
    with {:ok, runtime_kind} <- normalize_runtime_kind(runtime_kind),
         {:ok, reasons} <- normalize_reasons(reasons) do
      %{
        "agent_id" => agent_id,
        "runtime_kind" => runtime_kind,
        "session_id" => session_id,
        "token" => token,
        "reasons" => reasons
      }
      |> put_optional("recover_after_ms", recover_after_ms(reasons, wait))
    else
      _ -> nil
    end
  end

  @spec delete_discovery(index_record()) :: :ok | {:error, term()}
  def delete_discovery(%{
        "token" => token,
        "agent_id" => agent_id,
        "runtime_kind" => runtime_kind,
        "session_id" => session_id
      }) do
    SessionWorkCandidates.delete_scoped(token, %{
      agent_id: agent_id,
      runtime_kind: runtime_kind,
      session_id: session_id
    })
  end

  def delete_discovery(nil), do: :ok
  def delete_discovery(_record), do: {:error, :invalid_discovery_record}

  @doc """
  Discard the exact work-index generation from a session-state CAS attempt that
  definitively failed before commit.

  This is a writer-side rollback, not recovery inference. Only the
  token-addressed Postgres candidate is deleted. The agent-local index is
  a session-addressed slot shared by concurrent generations, so deleting it
  could erase the committed generation's recovery hint; a false-positive local
  record is safe and will be replaced by the next mark or stable cleanup.
  Ambiguous state writes must not call this function because their generation
  may have committed.
  """
  @spec discard_uncommitted(
          String.t(),
          runtime_kind(),
          String.t(),
          String.t() | nil,
          [term()],
          map() | nil
        ) :: :ok | {:error, term()}
  def discard_uncommitted(
        _agent_id,
        _runtime_kind,
        _session_id,
        token,
        _reasons,
        _wait
      )
      when token in [nil, ""],
      do: :ok

  def discard_uncommitted(agent_id, runtime_kind, session_id, token, reasons, wait)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(token) do
    with true <- Ids.valid_session_id?(session_id),
         {:ok, runtime_kind} <- normalize_runtime_kind(runtime_kind) do
      case delete_discovery(
             discovery_ref(agent_id, runtime_kind, session_id, token, reasons, wait)
           ) do
        :ok -> :ok
        {:error, reason} -> {:error, {:discovery_cleanup_failed, reason}}
      end
    else
      false -> {:error, :invalid_session_id}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec reconcile_local_after_rejection(
          String.t(),
          runtime_kind(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          [term()],
          map() | nil
        ) :: :ok | {:error, term()}
  def reconcile_local_after_rejection(
        _agent_id,
        _runtime_kind,
        _session_id,
        rejected_token,
        _authoritative_token,
        _authoritative_reasons,
        _authoritative_wait
      )
      when rejected_token in [nil, ""],
      do: :ok

  def reconcile_local_after_rejection(
        agent_id,
        runtime_kind,
        session_id,
        rejected_token,
        authoritative_token,
        authoritative_reasons,
        authoritative_wait
      )
      when is_binary(agent_id) and is_binary(session_id) and is_binary(rejected_token) do
    with true <- Ids.valid_session_id?(session_id),
         {:ok, runtime_kind} <- normalize_runtime_kind(runtime_kind),
         {:ok, authoritative} <-
           authoritative_local_record(
             agent_id,
             runtime_kind,
             session_id,
             authoritative_token,
             authoritative_reasons,
             authoritative_wait
           ) do
      reconcile_local_record(
        Keys.agent_session_work_index(agent_id, runtime_kind, session_id),
        rejected_token,
        authoritative
      )
    else
      false -> {:error, :invalid_session_id}
      {:error, _} = error -> error
    end
  end

  defp authoritative_local_record(
         _agent_id,
         _runtime_kind,
         _session_id,
         token,
         _reasons,
         _wait
       )
       when token in [nil, ""],
       do: {:ok, nil}

  defp authoritative_local_record(agent_id, runtime_kind, session_id, token, reasons, wait) do
    with {:ok, reasons} <- normalize_reasons(reasons) do
      {:ok,
       agent_id
       |> discovery_ref(runtime_kind, session_id, token, reasons, wait)
       |> Map.put("updated_at", now())}
    end
  end

  defp reconcile_local_record(key, rejected_token, authoritative) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, %{"token" => ^rejected_token}} ->
            write_local_authority(key, authoritative, if_match: etag)

          {:ok, _other_generation} ->
            :ok

          {:error, _} = error ->
            error
        end

      {:error, :not_found} ->
        write_local_authority(key, authoritative, if_none_match: "*")

      {:error, _} = error ->
        error
    end
  end

  defp write_local_authority(key, nil, opts) do
    case opts[:if_match] do
      nil ->
        :ok

      etag ->
        case S3.delete(key, if_match: etag) do
          :ok -> :ok
          {:error, :precondition_failed} -> :ok
          {:error, _} = error -> error
        end
    end
  end

  defp write_local_authority(key, record, opts) when is_map(record) do
    case S3.put(key, Jason.encode!(record), opts) do
      {:ok, _etag} -> :ok
      {:error, :precondition_failed} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Whether the current Router configuration permanently excludes this session.
  Canonical switches allocate fresh session IDs. A retired session remains
  readable, but cannot resume compute. An unavailable or invalid configuration
  is not proof of retirement and must not authorize projection cleanup.
  """
  @spec retired_router_session?(index_record()) :: boolean()
  def retired_router_session?(%{
        "agent_id" => agent_id,
        "runtime_kind" => "internal",
        "session_id" => session_id
      }) do
    case SalixAgent.Control.get_record(agent_id) do
      {:ok, %{"role" => "router", "router_session_id" => canonical}} ->
        Ids.valid_session_id?(canonical) and canonical != session_id

      _ ->
        false
    end
  end

  def retired_router_session?(_record), do: false

  @doc """
  Delete one stale listed generation from the exact Postgres candidate and,
  when possible, from the token-fenced agent-local marker.

  The local delete is token-fenced. If a newer generation already owns the
  per-agent key it is preserved while the listed old beacon is removed. An
  ambiguous local read/delete failure retains the beacon so a later bounded
  scan can retry. A malformed listed body can only delete its allowlisted
  beacon because it cannot safely identify a local record.
  """
  @spec delete_stale_record(index_record()) ::
          {:ok, :deleted | :missing | :stale | :invalid} | {:error, term()}
  def delete_stale_record(
        %{
          "agent_id" => agent_id,
          "runtime_kind" => runtime_kind,
          "session_id" => session_id,
          "token" => token
        } = record
      )
      when is_binary(agent_id) and is_binary(session_id) and is_binary(token) do
    with true <- Ids.valid_session_id?(session_id),
         {:ok, runtime_kind} <- normalize_runtime_kind(runtime_kind) do
      case delete_discovery(record) do
        :ok ->
          case delete_local_if_token(agent_id, runtime_kind, session_id, token) do
            {{:ok, _status} = result, _record} -> result
            {{:error, _reason}, _record} -> {:ok, :stale}
          end

        {:error, _} = error ->
          error
      end
    else
      false -> {:error, :invalid_session_id}
      {:error, _} = error -> error
    end
  end

  def delete_stale_record(_record), do: {:error, :invalid_discovery_record}

  @spec delete_if_token(String.t(), runtime_kind(), String.t(), String.t() | nil) ::
          {:ok, :deleted | :missing | :stale | :no_token} | {:error, term()}
  def delete_if_token(_agent_id, _runtime_kind, _session_id, token) when token in [nil, ""],
    do: {:ok, :no_token}

  def delete_if_token(agent_id, runtime_kind, session_id, token)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(token) do
    with true <- Ids.valid_session_id?(session_id),
         {:ok, runtime_kind} <- normalize_runtime_kind(runtime_kind),
         :ok <-
           SessionWorkCandidates.delete_scoped(token, %{
             agent_id: agent_id,
             runtime_kind: runtime_kind,
             session_id: session_id
           }) do
      {local_result, _record} =
        delete_local_if_token(agent_id, runtime_kind, session_id, token)

      local_result
    else
      false -> {:error, :invalid_session_id}
      {:error, _} = error -> error
    end
  end

  defp delete_local_if_token(agent_id, runtime_kind, session_id, token) do
    key = Keys.agent_session_work_index(agent_id, runtime_kind, session_id)

    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, %{"token" => ^token} = record} ->
            case S3.delete(key, if_match: etag) do
              :ok -> {{:ok, :deleted}, record}
              {:error, :precondition_failed} -> {{:ok, :stale}, nil}
              {:error, _} = err -> {err, nil}
            end

          {:ok, _other} ->
            {{:ok, :stale}, nil}

          {:error, _} = err ->
            {err, nil}
        end

      {:error, :not_found} ->
        {{:ok, :missing}, nil}

      {:error, _} = err ->
        {err, nil}
    end
  end

  defp load_record(%{key: key}) do
    case S3.get(key) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, rec} when is_map(rec) -> [rec]
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  defp valid_record?(agent_id, rec) do
    is_binary(agent_id) and rec["agent_id"] == agent_id and
      rec["runtime_kind"] in @runtime_kinds and
      Ids.valid_session_id?(rec["session_id"]) and
      is_binary(rec["token"]) and
      is_list(rec["reasons"]) and
      Enum.all?(rec["reasons"], &(&1 in @work_reasons)) and
      valid_cas_base?(rec["cas_base"]) and
      valid_base_revision?(rec["base_revision"]) and
      valid_recover_after?(rec["recover_after_ms"])
  end

  defp put_discovery(record) do
    if discoverable_reasons?(record["reasons"]) do
      SessionWorkCandidates.insert(record)
    else
      :ok
    end
  end

  defp page_result(records, true, _lane), do: %{records: records, eof: true, next: nil}

  defp page_result(records, false, lane) do
    %{records: records, eof: false, next: records |> List.last() |> cursor(lane)}
  end

  defp clamp_page_size(size) when is_integer(size),
    do: size |> max(1) |> min(@max_discovery_page_size)

  defp clamp_page_size(_size), do: @default_discovery_page_size

  defp maybe_put_continuation_token(opts, token) when is_binary(token) and token != "",
    do: Keyword.put(opts, :continuation_token, token)

  defp maybe_put_continuation_token(opts, _token), do: opts

  defp normalize_runtime_kind(kind) when kind in [:internal, "internal"], do: {:ok, "internal"}
  defp normalize_runtime_kind(kind) when kind in [:external, "external"], do: {:ok, "external"}
  defp normalize_runtime_kind(kind), do: {:error, {:invalid_runtime_kind, kind}}

  defp normalize_reasons(reasons) do
    normalized =
      reasons
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    invalid = normalized -- @work_reasons

    cond do
      normalized == [] -> {:error, :empty_work_index_reasons}
      invalid != [] -> {:error, {:invalid_work_index_reasons, invalid}}
      true -> {:ok, normalized}
    end
  end

  defp wait_deadline_ms(wait) when is_map(wait) do
    wait["deadline_ms"] || wait[:deadline_ms]
  end

  defp wait_deadline_ms(_wait), do: nil

  defp valid_recover_after?(nil), do: true
  defp valid_recover_after?(value), do: is_integer(value)

  # Optional for rolling-deploy compatibility with records written before the
  # CAS-base field existed. Missing or mismatched generations remain fail-safe
  # retained: a captured content ETag is metadata, not cleanup proof.
  defp valid_cas_base?(nil), do: true
  defp valid_cas_base?(value), do: is_binary(value) and value != ""

  defp valid_base_revision?(nil), do: true
  defp valid_base_revision?(value), do: is_binary(value) and value != ""

  defp decode_cursor(nil, _lane), do: {:ok, nil}
  defp decode_cursor("", _lane), do: {:ok, nil}

  defp decode_cursor(token, lane) when is_binary(token) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, payload} <- Jason.decode(json),
         true <- payload["lane"] == Atom.to_string(lane),
         true <- valid_cursor_payload?(payload, lane) do
      cursor = %{
        agent_id: payload["agent_id"],
        runtime_kind: payload["runtime_kind"],
        session_id: payload["session_id"],
        candidate_token: payload["candidate_token"]
      }

      cursor =
        if lane == :deferred,
          do: Map.put(cursor, :due_at_ms, payload["due_at_ms"]),
          else: cursor

      {:ok, cursor}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_token, _lane), do: {:error, :invalid_cursor}

  defp valid_cursor_payload?(payload, lane) do
    Enum.all?(~w(agent_id runtime_kind session_id candidate_token), fn key ->
      is_binary(payload[key]) and payload[key] != ""
    end) and (lane == :eager or is_integer(payload["due_at_ms"]))
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp now, do: System.system_time(:second)
end
