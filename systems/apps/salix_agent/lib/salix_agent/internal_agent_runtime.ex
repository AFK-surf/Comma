defmodule SalixAgent.InternalAgentRuntime do
  @moduledoc """
  Internal agent runtime boundary.

  The internal runtime exposes Salix-managed session APIs: session listing,
  tracing, forking, compaction, and tool error shaping. Actual per-session
  execution is owned by `InternalSessionActor`.
  """

  require Logger

  alias SalixAgent.{
    AgentActor,
    ContextProviders,
    Control,
    InternalSession,
    InternalSessionFleet,
    InternalSessionStore,
    Placement,
    Round,
    SessionActivity
  }

  @session_trace_limit_default 100
  @max_session_trace_limit 500
  @session_trace_field_max_bytes 8 * 1024
  @session_trace_archive_window_seconds 30 * 24 * 60 * 60
  @session_trace_skill_entry_file "SKILL.md"
  @project_knowledge_use_limit_default 50
  @project_knowledge_use_limit_max 100
  @project_knowledge_session_limit_default 50
  @project_knowledge_session_limit_max 100
  @project_knowledge_object_limit 1_000
  @project_knowledge_page_limit 10
  @project_knowledge_page_size 100
  @compact_control_stage_timeout_ms 10_000
  @compact_result_settlement_allowance_ms 30_000
  @compact_result_poll_sleep_ms 250

  @spec list_sessions(String.t(), boolean()) :: {:ok, [map()]} | {:error, term()}
  def list_sessions(agent_id, include_hidden \\ false) when is_binary(agent_id) do
    with {:ok, sessions} <- InternalSessionStore.list(agent_id) do
      sessions =
        sessions
        |> Enum.map(&session_json(agent_id, &1))
        |> Enum.reject(&(&1["hidden"] == true and not include_hidden))
        |> Enum.sort_by(& &1["created_at"], :desc)

      {:ok, sessions}
    end
  end

  @spec get_session_summary(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_session_summary(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) do
    with {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
      {:ok,
       session_json(agent_id, session) |> put_optional("wait", InternalSession.wait(session))}
    end
  end

  @doc """
  Runtime status for one internal session: which model it is configured to
  run on, and how much of that model's context window its live context
  currently occupies.

  The window and the used-token estimate both come from `SalixAgent.Compaction`
  so this surface reports exactly what the auto-compaction trigger measures,
  rather than a second estimate that could disagree with it.

  Provider config is resolved live (`LlmResolver`, willow's activation-time
  read), so a template edit shows up here on the next call. An unresolvable
  template degrades instead of failing: this is a diagnostic surface, and the
  session's own context facts are still true. `model` and `context_tokens` are
  then absent — reporting the 128000 default as if it were this agent's window
  would misstate the denominator.
  """
  @spec session_status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def session_status(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) do
    with {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
      status =
        %{
          "agent_id" => agent_id,
          "session_id" => InternalSession.session_id(session),
          "runtime_kind" => "internal",
          "status" => to_string(InternalSession.status(session)),
          "activity_status" => to_string(InternalSession.activity_status(session)),
          "message_count" => InternalSession.total_message_count(session),
          "compacted_through" => InternalSession.compacted_through(session) || 0,
          "estimated_context_tokens" => SalixAgent.Compaction.context_tokens_used(session),
          "context_bytes" => InternalSession.context_byte_size(session)
        }
        |> Map.merge(session_status_llm(agent_id))

      {:ok, status}
    end
  end

  # The window is reported ONLY alongside the model it belongs to. An agent
  # with no template-backed config resolves `{:ok, nil}` -> `{:ok, []}`, and
  # `context_window/1` answers the 128000 default for that — a real number, but
  # not a statement about THIS agent. Emitting it without a model would put a
  # confident denominator under a usage figure nothing sized, so an unresolved
  # model drops both, exactly like a resolver error.
  defp session_status_llm(agent_id) do
    case SalixAgent.LlmResolver.resolve_runtime(agent_id) do
      {:ok, llm_opts} ->
        case llm_opt(llm_opts, :model) do
          model when is_binary(model) and model != "" ->
            %{
              "model" => model,
              "context_tokens" => SalixAgent.Compaction.context_window(llm_opts)
            }
            |> put_optional("provider", llm_opt(llm_opts, :provider))

          _unresolved ->
            %{}
        end

      {:error, reason} ->
        Logger.warning(
          "session status could not resolve provider config: #{inspect(reason)}",
          agent_id: agent_id
        )

        %{}
    end
  end

  defp llm_opt(opts, key) when is_map(opts), do: opts[Atom.to_string(key)] || opts[key]
  defp llm_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp llm_opt(_opts, _key), do: nil

  @spec get_session_activity(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_session_activity(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) do
    case SalixAgent.InternalSessionActor.activity_snapshot(agent_id, session_id) do
      :not_resident ->
        with {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
          {:ok, project_session_activity(agent_id, session)}
        end

      result ->
        result
    end
  end

  @doc false
  def project_session_activity(agent_id, session) do
    activity =
      agent_id
      |> session_json(session)
      |> Map.put("wait", InternalSession.wait(session))
      |> SessionActivity.project()

    Map.put(
      activity,
      "_active_source_message_ids",
      InternalSession.current_activation_key(session)
    )
  end

  @spec get_session_messages(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_session_messages(agent_id, session_id, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) do
    scope = Keyword.get(opts, :history, :window)

    with {:ok, session} <- InternalSessionStore.read(agent_id, session_id),
         {:ok, transcript} <- InternalSessionStore.transcript(agent_id, session, scope) do
      {:ok,
       %{
         "session_id" => session_id,
         "status" => to_string(InternalSession.status(session)),
         "activity_status" => to_string(InternalSession.activity_status(session)),
         "activity_status_updated_at" =>
           InternalSession.get(session, :activity_status_updated_at),
         "last_ack_message_id" => InternalSession.last_ack_message_id(session),
         "messages" => Enum.map(transcript.messages, &session_message_json/1),
         "archived_through" => transcript.archived_through,
         "history_truncated" => transcript.truncated?
       }
       |> compact()}
    end
  end

  @doc """
  List durable, accepted uses of project knowledge for one Agent.

  Project-knowledge runtime messages are committed in the same session CAS as
  the assistant response that consumed them. This read therefore projects the
  session authority directly instead of maintaining a second mutable usage
  ledger. Work is bounded by both result and session limits; `complete: false`
  means the returned uses are an honest lower bound.
  """
  @spec list_project_knowledge_uses(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def list_project_knowledge_uses(agent_id, opts \\ []) when is_binary(agent_id) do
    limit =
      clamp_limit(
        opts[:limit],
        @project_knowledge_use_limit_default,
        @project_knowledge_use_limit_max
      )

    session_limit =
      clamp_limit(
        opts[:session_limit],
        @project_knowledge_session_limit_default,
        @project_knowledge_session_limit_max
      )

    assertion_ids = normalize_assertion_ids(opts[:assertion_ids])

    if MapSet.size(assertion_ids) == 0 do
      {:ok,
       %{
         "uses" => [],
         "complete" => true,
         "history_truncated" => false,
         "sessions_scanned" => 0
       }}
    else
      list_project_knowledge_uses(agent_id, assertion_ids, limit, session_limit)
    end
  end

  defp list_project_knowledge_uses(agent_id, assertion_ids, limit, session_limit) do
    fold =
      InternalSessionStore.reduce_sessions_bounded(
        agent_id,
        {[], 0, true, false},
        fn session, {uses, scanned, complete, truncated} ->
          scanned = scanned + 1
          session_truncated = (InternalSession.archived_through(session) || 0) > 0
          remaining = max(limit - length(uses), 0)

          session_uses =
            session
            |> InternalSession.masked_messages()
            |> project_knowledge_uses(InternalSession.session_id(session), assertion_ids)
            |> Enum.take(remaining)

          uses = uses ++ session_uses
          truncated = truncated or session_truncated

          cond do
            length(uses) >= limit ->
              {:halt, {uses, scanned, false, truncated}}

            scanned >= session_limit ->
              {:halt, {uses, scanned, false, truncated}}

            true ->
              {:cont, {uses, scanned, complete, truncated}}
          end
        end,
        page_size: @project_knowledge_page_size,
        max_objects: @project_knowledge_object_limit,
        max_pages: @project_knowledge_page_limit
      )

    with {:ok, {uses, sessions_scanned, complete, history_truncated}, prefix_exhausted} <- fold do
      uses = Enum.sort_by(uses, &{&1["used_at"] || 0, &1["retrieval_id"]}, :desc)

      {:ok,
       %{
         "uses" => uses,
         "complete" => complete and prefix_exhausted and not history_truncated,
         "history_truncated" => history_truncated,
         "sessions_scanned" => sessions_scanned
       }}
    end
  end

  @spec session_records(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def session_records(agent_id, session_id, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) do
    scope = Keyword.get(opts, :history, :window)

    with {:ok, limit} <- parse_session_trace_limit(Keyword.get(opts, :limit)),
         {:ok, before} <- parse_session_trace_before(Keyword.get(opts, :before)),
         {:ok, session} <- InternalSessionStore.read(agent_id, session_id),
         {:ok, transcript} <- InternalSessionStore.transcript(agent_id, session, scope) do
      eligible =
        transcript.messages
        |> Enum.sort_by(&message_sort_key/1)
        |> Enum.filter(&(is_nil(before) or message_sort_key(&1) < before))

      has_more = length(eligible) > limit
      page = Enum.take(eligible, -limit)

      {:ok,
       %{
         "runtime_kind" => "internal",
         "session_id" => session_id,
         "status" => to_string(InternalSession.status(session)),
         "activity_status" => to_string(InternalSession.activity_status(session)),
         "activity_status_updated_at" =>
           InternalSession.get(session, :activity_status_updated_at),
         "records" => Enum.map(page, &session_message_json/1),
         "has_more" => has_more,
         "archived_through" => transcript.archived_through,
         "history_truncated" => transcript.truncated?
       }
       |> compact()
       |> put_optional("next_before", if(has_more, do: session_trace_cursor(hd(page))))}
    end
  end

  @spec session_billing_context(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def session_billing_context(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) do
    with {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
      {:ok, InternalSession.get(session, :billing_context) || %{}}
    end
  end

  @spec get_async_tool_call(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def get_async_tool_call(agent_id, session_id, tool_call_id)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_call_id) do
    with {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
      case InternalSession.lookup_async_call(session, tool_call_id) do
        {:ok, record} ->
          {:ok, record}

        {:archived, seq} ->
          InternalSessionStore.fetch_archived_record(agent_id, session_id, session, seq)

        :not_found ->
          # Owner ruling (2026-08-06): archived history is not served by bare
          # id — the explicit not_found IS the contract, data stays
          # seq-addressable in the archive.
          {:error, :not_found}
      end
    end
  end

  @spec search_messages(String.t(), term(), term()) :: {:ok, map()} | {:error, term()}
  def search_messages(agent_id, query, limit \\ 20) when is_binary(agent_id) do
    q = String.downcase(to_string(query || ""))
    limit = clamp_limit(limit, 20, 100)

    # Search is a LIVE-WINDOW surface by contract (owner 2026-08-07): the
    # archive is cold data and a fan-out over every chunk would make
    # `limit` bound nothing. Session states stream through an
    # early-stopping fold, so an early hit bounds the state GETs too. The
    # masked window keeps redacted content out of results, and the response
    # says whether archived history was not searched.
    fold =
      InternalSessionStore.reduce_sessions(agent_id, {[], 0, false}, fn session,
                                                                        {results, count,
                                                                         archived?} ->
        archived? = archived? or (InternalSession.archived_through(session) || 0) > 0
        hit_session_id = InternalSession.session_id(session)

        hit_created_at =
          InternalSession.get(session, :last_activity_at) ||
            InternalSession.get(session, :created_at) || 0

        hits =
          Enum.flat_map(InternalSession.masked_messages(session), fn msg ->
            content = stringify_content(msg[:content])

            if q != "" and String.contains?(String.downcase(content), q) do
              [
                %{
                  "message_id" => msg[:id],
                  "role" => msg[:role],
                  "session_id" => hit_session_id,
                  "created_at" => msg[:created_at] || hit_created_at,
                  "snippet" => highlight_snippet(content, q),
                  "score" => 1
                }
              ]
            else
              []
            end
          end)

        results = results ++ Enum.take(hits, limit - count)
        count = length(results)

        # NOTE the halt is scope-honest: once `limit` hits we stop reading
        # states, so `archived_not_searched` reflects only the sessions
        # actually visited — a partial answer never claims global facts.
        if count >= limit,
          do: {:halt, {results, count, archived?}},
          else: {:cont, {results, count, archived?}}
      end)

    with {:ok, {results, _count, archived_not_searched}} <- fold do
      {:ok,
       %{
         "results" => results,
         "scope" => "live_window",
         "archived_not_searched" => archived_not_searched
       }}
    end
  end

  @spec fork_session(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fork_session(agent_id, session_id, attrs)
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    # The fork identity is CALLER-STABLE by contract (owner 2026-08-08):
    # only the caller can hold a key across a lost response, so a
    # server-minted key can never make a retry idempotent. No key — with or
    # without an explicit target — is a caller-fixable 400, never a fork.
    if is_binary(attrs["fork_request_id"] || attrs[:fork_request_id]) do
      route_to_owner(agent_id, :fork_session_local, [agent_id, session_id, attrs])
    else
      {:error, :fork_identity_required}
    end
  end

  @doc false
  # The fork target address is re-derivable from the caller's idempotent
  # identity — an explicit target_session_id, or a target id derived from
  # (source, fork_request_id). The system never mints a random target id:
  # with the identity stored only inside the target object, an unaddressable
  # target would be unfindable after a lost response, and a blind retry
  # would create a second fork.
  def fork_session_local(agent_id, session_id, attrs)
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    explicit_target = attrs["target_session_id"] || attrs[:target_session_id]
    request_id = attrs["fork_request_id"] || attrs[:fork_request_id]

    attrs =
      Map.drop(attrs, ["session_id", :session_id, "target_session_id", :target_session_id])

    cond do
      is_binary(explicit_target) and explicit_target != "" ->
        fork_session_addressed(agent_id, session_id, explicit_target, request_id, attrs)

      is_binary(request_id) and request_id != "" ->
        target = derive_fork_target_id(session_id, request_id)
        fork_session_addressed(agent_id, session_id, target, request_id, attrs)

      true ->
        {:error, :fork_identity_required}
    end
  end

  @doc false
  def derive_fork_target_id(source_session_id, fork_request_id) do
    body =
      :crypto.hash(:sha256, source_session_id <> "\n" <> fork_request_id)
      |> :binary.decode_unsigned()
      |> rem(10_000_000_000_000_000_000)
      |> Integer.to_string()
      |> String.pad_leading(19, "0")

    "ses1_" <> body
  end

  defp fork_session_addressed(agent_id, session_id, target_id, request_id, attrs) do
    attrs =
      attrs
      |> Map.merge(%{"created_at" => attrs["created_at"] || now()})
      |> then(fn attrs ->
        if is_binary(request_id), do: Map.put(attrs, "fork_request_id", request_id), else: attrs
      end)

    case InternalSessionFleet.fork_session(agent_id, session_id, target_id, attrs) do
      {:ok, session} ->
        {:ok, session_json(agent_id, session)}

      {:error, :exists} ->
        settle_existing_fork(agent_id, session_id, target_id, request_id)

      {:error, _} = error ->
        error
    end
  end

  # Settlement is by the PERSISTED identity — (source_session_id,
  # fork_request_id), never recomputed bytes: created_at, the storage
  # revision, and the source snapshot all drift between attempts, so a byte
  # comparison would misjudge our own success. The source is part of the
  # identity: a different source colliding on the same explicit target and
  # request key must NOT adopt the existing fork's transcript.
  defp settle_existing_fork(agent_id, source_session_id, target_id, request_id) do
    with {:ok, session} <- InternalSessionStore.read(agent_id, target_id) do
      cond do
        is_binary(request_id) and
          InternalSession.get(session, :fork_request_id) == request_id and
          InternalSession.get(session, :source_session_id) == source_session_id and
            InternalSession.get(session, :source_agent_id) == agent_id ->
          {:ok, session_json(agent_id, session)}

        true ->
          {:error, :fork_target_conflict}
      end
    end
  end

  @spec compact_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def compact_session(agent_id, session_id) when is_binary(agent_id) and is_binary(session_id) do
    with {:ok, _session} <- get_session_summary(agent_id, session_id) do
      source_id = "session:compact:" <> session_id <> ":" <> random_id()
      payload = %{kind: "session_compact", session_id: session_id}

      with {:ok, _} <-
             deliver_control(
               agent_id,
               payload,
               source_id
             ),
           {:ok, session} <-
             wait_for_session_match(
               agent_id,
               session_id,
               &(compact_result_for(&1, source_id) != nil)
             ) do
        case compact_result_for(session, source_id) do
          %{} = result -> compact_api_result(result)
          nil -> {:error, :compact_result_missing}
        end
      end
    end
  end

  @spec microcompact_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def microcompact_session(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) do
    route_to_owner(agent_id, :microcompact_session_local, [agent_id, session_id])
  end

  @doc false
  def microcompact_session_local(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) do
    entry = %{
      payload: %{kind: "session_microcompact", session_id: session_id},
      source_message_id: "session:microcompact:" <> session_id <> ":" <> random_id()
    }

    with {:ok, _session} <- InternalSessionStore.read(agent_id, session_id),
         {:ok, :committed} <-
           InternalSessionFleet.stage_control(agent_id, session_id, entry, timeout: :infinity) do
      {:ok, %{"status" => "microcompacted"}}
    end
  end

  @spec emergency_compact_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def emergency_compact_session(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) do
    route_to_owner(agent_id, :emergency_compact_session_local, [agent_id, session_id])
  end

  @doc false
  def emergency_compact_session_local(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) do
    entry = %{
      payload: %{kind: "session_emergency_compact", session_id: session_id},
      source_message_id: "session:emergency-compact:" <> session_id <> ":" <> random_id()
    }

    with {:ok, _session} <- InternalSessionStore.read(agent_id, session_id),
         {:ok, :committed} <-
           InternalSessionFleet.stage_control(agent_id, session_id, entry, timeout: :infinity),
         {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
      # The kernel answers the recorded redaction watermark, or the transcript
      # head for a session written before format 2 recorded one; `nil` means a
      # format-2 session committed the control entry without a result.
      case InternalSession.query(session, :emergency_compact_through_id) do
        through_id when is_integer(through_id) ->
          {:ok, SalixAgent.EmergencyCompact.result(through_id)}

        nil ->
          {:error, :emergency_compact_result_missing}
      end
    end
  end

  @spec seed_transcript(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def seed_transcript(agent_id, session_id, attrs)
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    route_to_owner(agent_id, :seed_transcript_local, [agent_id, session_id, attrs])
  end

  @doc false
  def seed_transcript_local(agent_id, session_id, attrs)
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    with {:ok, event} <- transcript_seed_event(session_id, attrs),
         {:ok, session, before_count} <-
           InternalSessionFleet.seed_transcript(agent_id, session_id, event) do
      {:ok, transcript_seed_result(agent_id, session, event, before_count)}
    end
  end

  @spec execute_session_tool(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def execute_session_tool(agent_id, session_id, tool_name, attrs)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_name) and
             is_map(attrs) do
    SalixAgent.execute_session_tool(agent_id, session_id, tool_name, attrs)
  end

  @spec session_trace(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def session_trace(agent_id, session_id, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) do
    scope = Keyword.get(opts, :history, :window)

    with {:ok, limit} <- parse_session_trace_limit(Keyword.get(opts, :limit)),
         {:ok, sessions} <- InternalSessionStore.list(agent_id),
         sessions_by_id <- Map.new(sessions, &{InternalSession.session_id(&1), &1}),
         session when not is_nil(session) <- Map.get(sessions_by_id, session_id) do
      lineage = session_trace_lineage(sessions_by_id, session_id)

      lineage_transcripts =
        Enum.map(lineage, fn lineage_session ->
          case InternalSessionStore.transcript(agent_id, lineage_session, scope) do
            {:ok, transcript} ->
              transcript

            # Trace is a diagnostic surface: an unreadable archive degrades
            # that lineage member to its window rather than failing the trace.
            {:error, _reason} ->
              archived_through = InternalSession.archived_through(lineage_session) || 0

              %{
                messages: InternalSession.masked_messages(lineage_session),
                archived_through: archived_through,
                truncated?: archived_through > 0
              }
          end
        end)

      history_truncated = Enum.any?(lineage_transcripts, & &1.truncated?)

      messages =
        lineage_transcripts
        |> Enum.flat_map(& &1.messages)
        |> Enum.map(&ContextProviders.strip_llm_private_metadata/1)
        |> Enum.sort_by(&message_sort_key/1)

      tool_index = assistant_tool_call_index(messages)
      terminal_tool_index = runtime_tool_terminal_index(messages)

      all_tool_messages =
        messages
        |> Enum.filter(&(msg_value(&1, :role) == "tool"))
        |> Enum.sort_by(&message_sort_key/1)

      has_more = length(all_tool_messages) > limit

      tool_messages =
        all_tool_messages
        |> Enum.take(-limit)
        |> Enum.sort_by(&message_sort_key/1)

      usage = session_trace_usage(messages)

      trace_id =
        messages |> Enum.find_value(&(msg_value(&1, :trace_id) || nil)) |> to_string_or_empty()

      round_stages = Enum.flat_map(messages, &session_trace_round_stage(&1, session_id, trace_id))

      {tool_calls, tool_stages, skill_reads, critical} =
        Enum.reduce(tool_messages, {[], [], [], nil}, fn msg, {calls, stages, reads, critical} ->
          {tool_call, stage} =
            session_trace_tool_call_and_stage(
              msg,
              tool_index,
              terminal_tool_index,
              session_id,
              trace_id
            )

          reads = append_skill_reads(reads, tool_call, msg)
          critical = session_trace_critical(critical, stage)
          {[tool_call | calls], [stage | stages], reads, critical}
        end)

      trace =
        %{
          "usage" => usage,
          "has_more" => has_more,
          "tool_calls" => Enum.reverse(tool_calls),
          "skill_reads" => skill_reads,
          "stages" => round_stages ++ Enum.reverse(tool_stages),
          "history_truncated" => history_truncated
        }
        |> put_optional_nonblank("trace_id", trace_id)
        |> put_optional("critical_path", critical)

      trace =
        if messages == [] and all_tool_messages == [] and session_trace_archived?(session) do
          trace
          |> Map.put("archived", true)
          |> Map.put("reason", "session trace archived")
          |> Map.update!("stages", fn
            [] -> [session_trace_archived_stage(session, session_id, trace_id)]
            stages -> stages
          end)
        else
          trace
        end

      {:ok, trace}
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @spec tool_error_results([map()], term(), String.t()) :: [map()]
  def tool_error_results(calls, reason, error_class \\ "tool_error") when is_list(calls) do
    Round.tool_error_results(calls, reason, error_class)
  end

  defp deliver_control(agent_id, payload, source_id) do
    with {:ok, _agent} <- Control.get(agent_id) do
      try do
        case AgentActor.stage_delivery(
               agent_id,
               %{payload: payload, source_message_id: source_id},
               timeout: @compact_control_stage_timeout_ms,
               process_on_init: false
             ) do
          {:ok, :committed, _wake_targets} ->
            {:ok, :committed}

          {:ok, :duplicate} ->
            {:ok, :duplicate}

          {:ok, :ignored} ->
            {:error, {:bad_request, "operation is only available for internal runtime agents"}}

          {:error, _} = err ->
            err
        end
      catch
        :exit, reason -> {:error, {:compact_control_delivery_failed, reason}}
      end
    end
  end

  defp route_to_owner(agent_id, local_fun, args) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         {:ok, pid} <-
           Placement.ensure_started(agent_id, create: false) do
      owner_node = node(pid)

      if owner_node == node() do
        apply(__MODULE__, local_fun, args)
      else
        :erpc.call(owner_node, __MODULE__, local_fun, args, :infinity)
      end
    end
  end

  defp parse_session_trace_limit(raw) when raw in [nil, ""],
    do: {:ok, @session_trace_limit_default}

  defp parse_session_trace_limit(raw) do
    case Integer.parse(String.trim(to_string(raw))) do
      {value, ""} when value > 0 and value <= @max_session_trace_limit ->
        {:ok, value}

      {value, ""} when value > @max_session_trace_limit ->
        {:error, {:bad_request, "limit must be <= #{@max_session_trace_limit}"}}

      _ ->
        {:error, {:bad_request, "limit must be a positive integer"}}
    end
  end

  defp parse_session_trace_before(raw) when raw in [nil, ""], do: {:ok, nil}

  defp parse_session_trace_before(raw) do
    with [created_at, id] <- String.split(to_string(raw), ":", parts: 2),
         {created_at, ""} <- Integer.parse(created_at),
         {id, ""} <- Integer.parse(id) do
      {:ok, {created_at, id}}
    else
      _ -> {:error, {:bad_request, "before is invalid"}}
    end
  end

  defp session_trace_lineage(sessions, session_id) do
    session_trace_lineage(sessions, session_id, MapSet.new(), [])
  end

  defp session_trace_lineage(_sessions, nil, _seen, acc), do: acc
  defp session_trace_lineage(_sessions, "", _seen, acc), do: acc

  defp session_trace_lineage(sessions, session_id, seen, acc) do
    cond do
      MapSet.member?(seen, session_id) ->
        Enum.reverse(acc)

      session = Map.get(sessions, session_id) ->
        source_session_id = InternalSession.query(session, :lineage_source_session_id)

        session_trace_lineage(
          sessions,
          source_session_id,
          MapSet.put(seen, session_id),
          [session | acc]
        )

      true ->
        Enum.reverse(acc)
    end
  end

  defp session_trace_usage(messages) do
    prompt = sum_message_int(messages, :input_tokens)
    completion = sum_message_int(messages, :output_tokens)

    %{
      "prompt_tokens" => prompt,
      "completion_tokens" => completion,
      "total_tokens" => prompt + completion,
      "cache_read_input_tokens" => sum_message_int(messages, :cache_read_input_tokens),
      "cache_write_input_tokens" => sum_message_int(messages, :cache_write_input_tokens)
    }
  end

  defp sum_message_int(messages, key) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + int_value(msg_value(msg, key)) end)
  end

  defp session_trace_round_stage(msg, session_id, trace_id) do
    if msg_value(msg, :role) == "assistant" do
      [
        %{
          "name" => "salix.session.round",
          "start_time" => format_unix_timestamp(msg_value(msg, :created_at)),
          "status" => "completed",
          "trace_id" => msg_value(msg, :trace_id) || trace_id,
          "attributes" => %{"salix.session_id" => session_id}
        }
        |> strip_blank_values()
      ]
    else
      []
    end
  end

  defp assistant_tool_call_index(messages) do
    messages
    |> Enum.filter(&(msg_value(&1, :role) == "assistant"))
    |> Enum.flat_map(fn msg ->
      msg
      |> msg_value(:tool_calls)
      |> List.wrap()
      |> Enum.filter(&is_map/1)
    end)
    |> Map.new(fn call -> {tool_call_id(call), call} end)
  end

  defp session_trace_tool_call_and_stage(
         msg,
         tool_index,
         terminal_tool_index,
         session_id,
         trace_id
       ) do
    call_id = to_string_or_empty(msg_value(msg, :tool_call_id))
    parent_call = Map.get(tool_index, call_id, %{})
    terminal = Map.get(terminal_tool_index, call_id, %{})

    terminal_result =
      case terminal["result"] do
        %{} = result -> result
        _malformed_or_absent -> %{}
      end

    name =
      first_present([
        terminal["tool_name"],
        msg_value(msg, :tool_name),
        tool_call_name(parent_call),
        "tool"
      ])

    status =
      first_present([
        terminal_tool_trace_status(terminal["status"]),
        msg_value(msg, :status),
        if(msg_value(msg, :error), do: "error"),
        "completed"
      ])

    timestamp =
      case msg_value(msg, :execution_timing) do
        %{"started_at_ms" => started_at_ms} when is_integer(started_at_ms) ->
          DateTime.from_unix!(started_at_ms, :millisecond) |> DateTime.to_iso8601()

        _ ->
          format_unix_timestamp(msg_value(msg, :started_at) || msg_value(msg, :created_at))
      end

    duration_ms = int_value(terminal_result["duration_ms"] || msg_value(msg, :duration_ms))
    input_raw = first_present([msg_value(msg, :input), tool_call_input(parent_call), ""])

    output_raw =
      first_present([
        terminal_result["output"],
        terminal_result["content"],
        nested_map_value(terminal, "result_page", "content"),
        msg_value(msg, :output),
        msg_value(msg, :content),
        ""
      ])

    {input, input_truncated} = truncate_utf8(input_raw, @session_trace_field_max_bytes)
    {output, output_truncated} = truncate_utf8(output_raw, @session_trace_field_max_bytes)

    tool_call =
      %{
        "call_id" => call_id,
        "name" => name,
        "status" => status,
        "timestamp" => timestamp,
        "duration_ms" => duration_ms,
        "error_class" =>
          terminal_result["error_class"] || terminal["error_class"] ||
            msg_value(msg, :error_class),
        "error_message" =>
          terminal_result["error_message"] || terminal["error_message"] ||
            msg_value(msg, :error_message),
        "input" => input,
        "input_truncated" => input_truncated,
        "output" => output,
        "output_truncated" => output_truncated
      }
      |> strip_blank_values()

    stage =
      %{
        "name" => "salix.tool.execute",
        "start_time" => timestamp,
        "duration_ms" => duration_ms,
        "status" => status,
        "trace_id" => msg_value(msg, :trace_id) || trace_id,
        "attributes" => %{
          "tool.name" => name,
          "tool.call_id" => call_id,
          "salix.session_id" => session_id
        }
      }
      |> strip_blank_values()

    {tool_call, stage}
  end

  # Zero-wait tools persist their immediate `async_running` provider row as a
  # role=tool message, then commit the exact terminal as a role=runtime
  # continuation. Trace is a terminal execution projection, so correlate that
  # continuation by tool_call_id instead of reporting the early row forever.
  defp runtime_tool_terminal_index(messages) do
    messages
    |> Enum.filter(&(msg_value(&1, :role) == "runtime"))
    |> Enum.reduce(%{}, fn message, index ->
      case runtime_tool_terminal(message) do
        {tool_call_id, terminal} -> Map.put(index, tool_call_id, terminal)
        nil -> index
      end
    end)
  end

  defp runtime_tool_terminal(message) do
    # Terminal provenance comes only from the durable message envelope. Runtime
    # content is model/user-visible JSON and may be supplied by transcript seed
    # or another untrusted input surface; it can describe a result, but it can
    # never mint the terminal type or correlation identity used by trace.
    with type when type in ["tool_call_completed", "tool_call_failed"] <-
           msg_value(message, :type),
         tool_call_id when is_binary(tool_call_id) and tool_call_id != "" <-
           msg_value(message, :source_tool_call_id),
         content when is_binary(content) <- msg_value(message, :content),
         {:ok, payload} when is_map(payload) <- Jason.decode(content) do
      source_refs = map_value_or_empty(payload, "source_refs")

      terminal =
        payload
        |> Map.put("tool_call_id", tool_call_id)
        |> Map.put("status", if(type == "tool_call_failed", do: "failed", else: "completed"))
        |> Map.put_new("error_class", source_refs["error_class"])
        |> Map.put_new("error_message", source_refs["error_message"])

      {tool_call_id, terminal}
    else
      _ -> nil
    end
  end

  defp terminal_tool_trace_status(status) when status in ["failed", :failed, "error", :error],
    do: "error"

  defp terminal_tool_trace_status(status) when status in ["completed", :completed],
    do: "completed"

  defp terminal_tool_trace_status(status) when status in ["guidance", :guidance],
    do: "guidance"

  defp terminal_tool_trace_status(status) when status in ["cancelled", :cancelled],
    do: "cancelled"

  defp terminal_tool_trace_status(_status), do: nil

  defp map_value_or_empty(map, key) when is_map(map) do
    case map[key] do
      %{} = value -> value
      _other -> %{}
    end
  end

  defp nested_map_value(map, key, nested_key),
    do: map |> map_value_or_empty(key) |> Map.get(nested_key)

  defp append_skill_reads(reads, tool_call, msg) do
    existing = MapSet.new(Enum.map(reads, & &1["path"]))

    tool_call
    |> extract_skill_read_paths()
    |> Enum.reject(&MapSet.member?(existing, &1))
    |> Enum.map(fn path ->
      %{
        "path" => path,
        "timestamp" =>
          tool_call["timestamp"] || format_unix_timestamp(msg_value(msg, :created_at))
      }
      |> strip_blank_values()
    end)
    |> then(&(reads ++ &1))
  end

  defp extract_skill_read_paths(%{"name" => "fs.read_file", "input" => input}) do
    with {:ok, %{"path" => path}} <- Jason.decode(input),
         path <- trim(path),
         true <- String.ends_with?(path, @session_trace_skill_entry_file) do
      [path]
    else
      _ -> []
    end
  end

  defp extract_skill_read_paths(_), do: []

  defp session_trace_critical(nil, stage), do: stage

  defp session_trace_critical(current, stage) do
    if int_value(stage["duration_ms"]) > int_value(current["duration_ms"]),
      do: stage,
      else: current
  end

  defp session_trace_archived?(session) do
    last_activity = InternalSession.get(session, :last_activity_at) || 0
    last_activity > 0 and last_activity < now() - @session_trace_archive_window_seconds
  end

  defp session_trace_archived_stage(session, session_id, trace_id) do
    %{
      "name" => "salix.session.archived",
      "start_time" => format_unix_timestamp(InternalSession.get(session, :last_activity_at)),
      "status" => "archived",
      "trace_id" => trace_id,
      "attributes" => %{
        "salix.session_id" => session_id,
        "archive.window" => "#{@session_trace_archive_window_seconds}s"
      }
    }
    |> strip_blank_values()
  end

  defp message_sort_key(msg),
    do: {int_value(msg_value(msg, :created_at)), int_value(msg_value(msg, :id))}

  defp session_trace_cursor(msg) do
    {created_at, id} = message_sort_key(msg)
    "#{created_at}:#{id}"
  end

  defp tool_call_id(call), do: to_string_or_empty(call["call_id"] || call["id"])
  defp tool_call_name(call), do: call["name"] || get_in(call, ["function", "name"])

  defp tool_call_input(call) do
    cond do
      is_binary(call["arguments"]) ->
        call["arguments"]

      is_map(call["arguments"]) ->
        Jason.encode!(call["arguments"])

      is_binary(get_in(call, ["function", "arguments"])) ->
        get_in(call, ["function", "arguments"])

      true ->
        ""
    end
  end

  defp truncate_utf8(value, max_bytes) do
    value = to_string_or_empty(value)

    if max_bytes <= 0 or byte_size(value) <= max_bytes do
      {value, false}
    else
      i = utf8_truncation_index(value, max_bytes)
      {binary_part(value, 0, i), true}
    end
  end

  defp utf8_truncation_index(_value, 0), do: 0

  defp utf8_truncation_index(value, index) do
    byte = :binary.at(value, index)

    if byte >= 0x80 and byte < 0xC0 do
      utf8_truncation_index(value, index - 1)
    else
      index
    end
  end

  defp format_unix_timestamp(value) do
    case int_value(value) do
      # Session execution measurements use epoch milliseconds; older transcript
      # and Session metadata timestamps use epoch seconds.
      n when n >= 1_000_000_000_000 ->
        DateTime.from_unix!(n, :millisecond) |> DateTime.to_iso8601()

      n when n > 0 ->
        DateTime.from_unix!(n) |> DateTime.to_iso8601()

      _ ->
        ""
    end
  end

  defp strip_blank_values(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, %{}} -> false
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp first_present(values) do
    Enum.find_value(values, fn
      nil -> nil
      "" -> nil
      value -> value
    end)
  end

  defp int_value(v) when is_integer(v), do: v
  defp int_value(v) when is_float(v), do: trunc(v)

  defp int_value(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp int_value(_), do: 0

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value) when is_binary(value), do: value
  defp to_string_or_empty(value), do: to_string(value)

  defp msg_value(msg, key), do: Map.get(msg, key) || Map.get(msg, to_string(key))

  # Control state lives in an explicit field under format 2 (events archive
  # out of the hot object); the scan remains as the format-1 fallback.
  defp compact_result_for(session, source_id),
    do: InternalSession.query(session, :compact_result_for, source_id)

  defp compact_api_result(%{} = result) do
    if msg_value(result, :status) == "failed_hard" do
      {:error, {:compact_failed_hard, msg_value(result, :reason) || "compact failed"}}
    else
      compact_processed_api_result(result)
    end
  end

  defp compact_processed_api_result(%{} = result) do
    body =
      result
      |> Map.take(["status", "reason"])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, body}
  end

  defp wait_for_session_match(agent_id, session_id, predicate) do
    # Use the same configured budget as the actor-owned dependency. Allow
    # bounded time for dispatch and durable result settlement around that job.
    deadline_ms =
      monotonic_ms() + SalixAgent.DependencyJob.timeout_ms(:compaction) +
        @compact_result_settlement_allowance_ms

    wait_for_session_match(agent_id, session_id, predicate, deadline_ms)
  end

  defp wait_for_session_match(agent_id, session_id, predicate, deadline_ms) do
    case InternalSessionStore.read(agent_id, session_id) do
      {:ok, session} ->
        if predicate.(session) do
          {:ok, session}
        else
          continue_waiting_for_session_match(agent_id, session_id, predicate, deadline_ms)
        end

      {:error, _} ->
        continue_waiting_for_session_match(agent_id, session_id, predicate, deadline_ms)
    end
  end

  defp continue_waiting_for_session_match(agent_id, session_id, predicate, deadline_ms) do
    remaining_ms = deadline_ms - monotonic_ms()

    if remaining_ms <= 0 do
      {:error, :compact_result_wait_timeout}
    else
      Process.sleep(min(@compact_result_poll_sleep_ms, remaining_ms))
      wait_for_session_match(agent_id, session_id, predicate, deadline_ms)
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp transcript_seed_event(session_id, attrs) do
    attrs = string_keys(attrs)
    source_id = first_present([attrs["source_id"], attrs["seed_id"], attrs["eval_seed_id"]])

    case attrs["entries"] do
      entries when is_list(entries) and entries != [] ->
        normalize_transcript_seed_entries(entries, source_id)
        |> case do
          {:ok, entries} ->
            event =
              %{
                "type" => "transcript_seed",
                "session_id" => session_id,
                "source_id" => source_id,
                "created_at" => attrs["created_at"] || now(),
                "entries" => entries
              }
              |> put_optional_nonblank("source_id", source_id)

            {:ok, event}

          {:error, _} = err ->
            err
        end

      _ ->
        {:error, {:bad_request, "entries must be a non-empty array"}}
    end
  end

  defp normalize_transcript_seed_entries(entries, source_id) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case normalize_transcript_seed_entry(entry, index, source_id) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _} = err -> err
    end
  end

  defp normalize_transcript_seed_entry(raw_entry, index, source_id) when is_map(raw_entry) do
    entry = string_keys(raw_entry)
    role = trim(entry["role"])

    with :ok <- validate_transcript_seed_role(role, index),
         {:ok, tool_calls} <- normalize_transcript_seed_tool_calls(entry, role, index),
         {:ok, tool_call_id} <- transcript_seed_tool_call_id(entry, role, index) do
      cond do
        transcript_seed_content(entry, role)
        |> missing_transcript_seed_content?(role, tool_calls) ->
          bad_seed_entry(index, "content is required")

        true ->
          source_message_id =
            first_present([
              entry["source_message_id"],
              entry["source_id"],
              if(source_id, do: "#{source_id}:#{index}")
            ])

          dedupe_key =
            first_present([
              entry["dedupe_key"],
              entry["source_message_id"],
              entry["source_id"],
              source_message_id,
              tool_call_id
            ])

          if blank?(dedupe_key) do
            bad_seed_entry(index, "source_id, source_message_id, or dedupe_key is required")
          else
            normalized =
              %{
                "role" => role,
                "content" => transcript_seed_content(entry, role),
                "source_message_id" => source_message_id,
                "dedupe_key" => dedupe_key,
                "created_at" => entry["created_at"] || now()
              }
              |> put_optional_nonblank(
                "runtime_message_id",
                runtime_message_id(entry, role, dedupe_key)
              )
              |> put_optional("tool_calls", tool_calls)
              |> put_optional_nonblank("tool_call_id", tool_call_id)
              |> put_optional_nonblank("tool_name", tool_result_name(entry, role))
              |> put_optional("status", if(role == "tool", do: entry["status"]))
              |> put_optional("duration_ms", if(role == "tool", do: entry["duration_ms"]))
              |> put_optional("input", if(role == "tool", do: entry["input"]))
              |> put_optional("output", if(role == "tool", do: entry["output"]))
              |> put_optional("error_class", if(role == "tool", do: entry["error_class"]))
              |> put_optional("error_message", if(role == "tool", do: entry["error_message"]))
              |> put_optional("started_at", if(role == "tool", do: entry["started_at"]))
              |> put_optional("completed_at", if(role == "tool", do: entry["completed_at"]))
              |> put_optional_nonblank(
                "type",
                if(role == "runtime", do: entry["type"] || "eval_seed")
              )
              |> put_optional_nonblank(
                "summary",
                if(role == "runtime", do: entry["summary"] || entry["content"])
              )
              |> put_optional_nonblank(
                "source",
                if(role == "runtime", do: entry["source"] || source_id)
              )
              |> put_optional("source_refs", entry["source_refs"])
              |> put_optional("model", if(role == "assistant", do: entry["model"]))
              |> put_optional(
                "provider_meta",
                if(role == "assistant", do: entry["provider_meta"])
              )
              |> put_optional("input_tokens", if(role == "assistant", do: entry["input_tokens"]))
              |> put_optional(
                "output_tokens",
                if(role == "assistant", do: entry["output_tokens"])
              )
              |> put_optional(
                "cache_read_input_tokens",
                if(role == "assistant", do: entry["cache_read_input_tokens"])
              )
              |> put_optional(
                "cache_write_input_tokens",
                if(role == "assistant", do: entry["cache_write_input_tokens"])
              )
              |> put_optional("turn_id", entry["turn_id"])
              |> put_optional("round_id", entry["round_id"])
              |> put_optional("request_id", entry["request_id"])
              |> put_optional("trace_id", entry["trace_id"])

            {:ok, normalized}
          end
      end
    end
  end

  defp normalize_transcript_seed_entry(_raw_entry, index, _source_id),
    do: bad_seed_entry(index, "entry must be an object")

  defp bad_seed_entry(index, message),
    do: {:error, {:bad_request, "entries[#{index - 1}]: #{message}"}}

  defp validate_transcript_seed_role(role, index) do
    if role in ["user", "assistant", "runtime", "summary", "tool"] do
      :ok
    else
      bad_seed_entry(index, "role must be one of user, assistant, runtime, summary, tool")
    end
  end

  defp transcript_seed_content(entry, "runtime"), do: entry["content"] || entry["summary"]
  defp transcript_seed_content(entry, _role), do: entry["content"]

  defp missing_transcript_seed_content?(content, "assistant", tool_calls) do
    blank?(content) and not non_empty_list?(tool_calls)
  end

  defp missing_transcript_seed_content?(content, _role, _tool_calls), do: blank?(content)

  defp runtime_message_id(entry, "runtime", dedupe_key) do
    first_present([
      entry["runtime_message_id"],
      entry["source_message_id"],
      entry["source_id"],
      dedupe_key
    ])
  end

  defp runtime_message_id(_entry, _role, _dedupe_key), do: nil

  defp normalize_transcript_seed_tool_calls(entry, "assistant", index) do
    case entry["tool_calls"] do
      nil ->
        {:ok, nil}

      [] ->
        {:ok, nil}

      calls when is_list(calls) ->
        calls
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {call, call_index}, {:ok, acc} ->
          case normalize_transcript_seed_tool_call(call, index, call_index) do
            {:ok, call} -> {:cont, {:ok, [call | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, calls} -> {:ok, Enum.reverse(calls)}
          {:error, _} = err -> err
        end

      _other ->
        bad_seed_entry(index, "assistant tool_calls must be an array")
    end
  end

  defp normalize_transcript_seed_tool_calls(entry, _role, index) do
    case entry["tool_calls"] do
      nil -> {:ok, nil}
      [] -> {:ok, nil}
      _other -> bad_seed_entry(index, "tool_calls are only supported on assistant entries")
    end
  end

  defp normalize_transcript_seed_tool_call(raw_call, entry_index, call_index)
       when is_map(raw_call) do
    call = string_keys(raw_call)
    function = if is_map(call["function"]), do: string_keys(call["function"]), else: %{}

    id =
      first_present([
        call["id"],
        call["tool_call_id"],
        call["tool_use_id"],
        call["call_id"]
      ])

    name =
      first_present([
        call["name"],
        function["name"]
      ])

    args = first_present([call["args"], call["input"], call["arguments"], function["arguments"]])

    cond do
      blank?(id) ->
        bad_seed_entry(entry_index, "tool_calls[#{call_index - 1}].id is required")

      blank?(name) ->
        bad_seed_entry(entry_index, "tool_calls[#{call_index - 1}].name is required")

      true ->
        case normalize_transcript_seed_tool_args(args, entry_index, call_index) do
          {:ok, args} -> {:ok, %{"id" => id, "name" => name, "args" => args}}
          {:error, _} = err -> err
        end
    end
  end

  defp normalize_transcript_seed_tool_call(_raw_call, entry_index, call_index),
    do: bad_seed_entry(entry_index, "tool_calls[#{call_index - 1}] must be an object")

  defp normalize_transcript_seed_tool_args(nil, _entry_index, _call_index), do: {:ok, %{}}

  defp normalize_transcript_seed_tool_args(args, _entry_index, _call_index) when is_map(args),
    do: {:ok, args}

  defp normalize_transcript_seed_tool_args(args, entry_index, call_index) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _decoded} ->
        bad_seed_entry(
          entry_index,
          "tool_calls[#{call_index - 1}].arguments must decode to an object"
        )

      {:error, _} ->
        bad_seed_entry(entry_index, "tool_calls[#{call_index - 1}].arguments must be valid JSON")
    end
  end

  defp normalize_transcript_seed_tool_args(_args, entry_index, call_index),
    do: bad_seed_entry(entry_index, "tool_calls[#{call_index - 1}].args must be an object")

  defp transcript_seed_tool_call_id(entry, "tool", index) do
    id = first_present([entry["tool_call_id"], entry["tool_use_id"], entry["call_id"]])

    if blank?(id) do
      bad_seed_entry(index, "tool_call_id is required for tool entries")
    else
      {:ok, id}
    end
  end

  defp transcript_seed_tool_call_id(_entry, _role, _index), do: {:ok, nil}

  defp tool_result_name(entry, "tool"),
    do: first_present([entry["tool_name"], entry["name"]])

  defp tool_result_name(_entry, _role), do: nil

  defp non_empty_list?(value), do: is_list(value) and value != []

  defp transcript_seed_result(agent_id, session, event, before_count) do
    requested = length(event["entries"] || [])
    # Both sides of the subtraction are WHOLE-transcript counts: measuring
    # against the live window reports every archived seed as appended_count 0
    # / skipped_count = requested, and an idempotent replay after archival
    # would answer with a window that no longer holds the messages at all.
    appended = max(InternalSession.total_message_count(session) - before_count, 0)

    %{
      "agent_id" => agent_id,
      "session_id" => InternalSession.session_id(session),
      "runtime_kind" => "internal",
      "source_id" => event["source_id"],
      "requested_count" => requested,
      "appended_count" => appended,
      "skipped_count" => max(requested - appended, 0),
      "message_count" => InternalSession.total_message_count(session),
      "last_message_id" => max((InternalSession.next_message_id(session) || 1) - 1, 0),
      "compacted_through" => InternalSession.compacted_through(session) || 0,
      "summary_sequence" => InternalSession.get(session, :summary_sequence) || 0
    }
    |> put_optional_nonblank("source_id", event["source_id"])
  end

  # The listing projection is a kernel query. It reports the WHOLE transcript
  # (the live window plus every archived span, summed from the format's
  # per-span counts, no archive read), the highest id ever minted rather than
  # the window's max, and the persisted fork settlement identity a caller that
  # lost the fork response can re-derive the same target from.
  defp session_json(agent_id, session),
    do: InternalSession.query(session, :session_json, agent_id)

  defp session_message_json(msg) do
    msg
    |> message_map()
    |> ContextProviders.strip_llm_private_metadata()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp project_knowledge_uses(messages, session_id, assertion_ids) do
    messages
    |> Enum.sort_by(&(message_value(&1, :message_id) || 0))
    |> Enum.with_index()
    |> Enum.flat_map(fn {message, index} ->
      if project_knowledge_message?(message) do
        assertions = project_knowledge_assertions(message)

        matching_assertions =
          if MapSet.size(assertion_ids) == 0 do
            assertions
          else
            Enum.filter(assertions, &MapSet.member?(assertion_ids, &1["id"]))
          end

        if matching_assertions == [] do
          []
        else
          assistant = next_assistant(messages, index)

          [
            %{
              "session_id" => session_id,
              "retrieval_id" =>
                message_value(message, :runtime_message_id) ||
                  get_in(message_value(message, :source_refs, %{}), ["retrieval_id"]),
              "used_at" => message_value(message, :created_at),
              "assertions" => matching_assertions,
              "assistant_message_id" => message_value(assistant, :id),
              "assistant_excerpt" => assistant_excerpt(assistant)
            }
            |> compact()
          ]
        end
      else
        []
      end
    end)
  end

  defp project_knowledge_message?(message) do
    message_value(message, :role) == "runtime" and
      message_value(message, :type) == "project_knowledge"
  end

  defp project_knowledge_assertions(message) do
    case message_value(message, :source_refs, %{}) do
      %{"assertions" => assertions} when is_list(assertions) ->
        Enum.flat_map(assertions, fn assertion ->
          id = assertion["id"] || assertion[:id]
          sources = assertion["sources"] || assertion[:sources] || []

          if is_binary(id) and id != "" and is_list(sources) do
            [%{"id" => id, "sources" => sources}]
          else
            []
          end
        end)

      _other ->
        []
    end
  end

  defp next_assistant(messages, index) do
    messages
    |> Enum.drop(index + 1)
    |> Enum.find(&(message_value(&1, :role) == "assistant"))
  end

  defp assistant_excerpt(nil), do: nil

  defp assistant_excerpt(message) do
    case message_value(message, :content) do
      content when is_binary(content) -> String.slice(content, 0, 280)
      _other -> nil
    end
  end

  defp normalize_assertion_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.take(100)
    |> MapSet.new()
  end

  defp normalize_assertion_ids(_ids), do: MapSet.new()

  defp message_value(message, key, default \\ nil)

  defp message_value(nil, _key, default), do: default

  defp message_value(%_{} = message, key, default),
    do: message |> Map.from_struct() |> message_value(key, default)

  defp message_value(message, key, default) when is_map(message),
    do: Map.get(message, key, Map.get(message, to_string(key), default))

  defp message_value(_message, _key, default), do: default

  defp message_map(%_{} = msg), do: Map.from_struct(msg)
  defp message_map(msg) when is_map(msg), do: msg

  defp stringify_content(content) when is_binary(content), do: content
  defp stringify_content(content), do: Jason.encode!(content)

  defp highlight_snippet(content, q) do
    lower = String.downcase(content)

    case :binary.match(lower, q) do
      {idx, len} ->
        start = max(idx - 80, 0)
        stop = min(idx + len + 80, byte_size(content))
        prefix = binary_part(content, start, idx - start)
        match = binary_part(content, idx, len)
        suffix = binary_part(content, idx + len, stop - idx - len)
        prefix <> "«" <> match <> "»" <> suffix

      :nomatch ->
        String.slice(content, 0, 160)
    end
  end

  defp clamp_limit(nil, default, _max), do: default

  defp clamp_limit(value, default, max_value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 -> min(n, max_value)
      _ -> default
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp put_optional_nonblank(map, _key, nil), do: map
  defp put_optional_nonblank(map, _key, ""), do: map
  defp put_optional_nonblank(map, key, value), do: Map.put(map, key, value)

  defp now, do: System.system_time(:second)
  defp random_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp string_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
