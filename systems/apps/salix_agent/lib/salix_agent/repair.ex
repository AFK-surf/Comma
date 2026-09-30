defmodule SalixAgent.Repair do
  @moduledoc """
  Executes the kernel's restart plan against workspace and capability facts.
  The kernel selects recovery events, source settlement, capability states, and
  repair events. This adapter reads external facts and encodes recovered tool
  observations without re-executing tools.
  """

  require SalixAgent.InternalSession

  alias SalixAgent.{
    AgentWorkspace,
    AsyncToolResults,
    CapabilityRequestStore,
    InternalSession,
    SessionToolExecution,
    Tools,
    WorkspaceEvents
  }

  @spec plan_session(InternalSession.t(), keyword()) ::
          {[map()], non_neg_integer()} | {:error, term()}
  def plan_session(session, opts \\ []) when InternalSession.is_session(session) do
    live = opts |> Keyword.get(:live_process_tool_call_ids, []) |> Enum.map(&to_string/1)
    entry = %{"live" => live, "checkpoint" => nil}

    case InternalSession.query(session, :session_repair, entry, reader(session)) do
      {:ok, events, next_id} -> {events, next_id}
      {:error, _} = error -> error
    end
  end

  @doc """
  The reads of the kernel's crash repair: archived records and staged results
  for a committed runtime failure reply, capability reconciliation, and the
  restart requests that only this adapter can execute. A persisted runtime
  failure send consumes its budget before network I/O, so restart may settle a
  known receipt or an unknown outcome, but never resends.
  """
  def reader(session) do
    agent_id = InternalSession.agent_id(session)
    session_id = InternalSession.session_id(session)

    fn
      :clock ->
        System.system_time(:millisecond)

      :nonce ->
        System.unique_integer([:positive])

      {:archived_record, seq} ->
        case SalixAgent.InternalSessionStore.fetch_archived_record(
               agent_id,
               session_id,
               session,
               seq
             ) do
          {:ok, record} -> InternalSession.Command.external_error(record)
          _ -> nil
        end

      {:staged_result, attempt} ->
        staged_async_result(agent_id, session_id, attempt)
        |> InternalSession.Command.external_error()

      {:reconcile_capability, id, result} ->
        CapabilityRequestStore.reconcile_capability_request(agent_id, session_id, id, result)
        |> InternalSession.Command.external_error()

      {:capability_unknown, id, reason} ->
        require_log_failure(session, id, reason)

      # The restart plan runs over the session with the guard events applied.
      {:restart, request, guard} ->
        session
        |> InternalSession.apply_events(guard)
        |> execute(request)
        |> InternalSession.Command.external_error()
    end
  end

  defp execute(_session, {"guidance", call}),
    do: Tools.recoverable_envelope_guidance(call.source_call)

  defp execute(session, {"staged_result", record}),
    do:
      staged_async_result(
        InternalSession.agent_id(session),
        InternalSession.session_id(session),
        record
      )

  defp execute(session, {name, _payload} = request)
       when name in ["encode_missing", "encode_external"],
       do: InternalSession.query(session, :restart_encode, request)

  defp execute(session, {"encode_recovered", {record, result}}) do
    events =
      SessionToolExecution.recovered_internal_events(
        Map.put(record, "session_id", InternalSession.session_id(session)),
        result,
        session
      )

    events =
      case InternalSession.lookup_async_call(session, tool_call_id(record)) do
        {:ok, current} when is_map(current) ->
          if record["completion_mode"] == "external_callback" and
               current["completion_mode"] != "external_callback" do
            [
              sync_event(
                session,
                record,
                Map.take(record, [
                  "completion_mode",
                  "capability_request_id",
                  "capability_deadline_ms",
                  "capability_retry_at_ms",
                  "capability_error_since_ms"
                ])
              )
              | events
            ]
          else
            events
          end

        _ ->
          events
      end

    {events, SessionToolExecution.callback_handoff_result?(result)}
  end

  defp execute(_session, {"encode_failed", {record, result, true}}),
    do: AsyncToolResults.internal_poll_events(record, result)

  defp execute(session, {"encode_failed", {record, result, false}}) do
    [
      %{
        "type" => "async_tool_call_failed",
        "session_id" => InternalSession.session_id(session),
        "tool_call_id" => record["tool_call_id"],
        "error" => true,
        "error_class" => result[:error_class],
        "error_message" => result[:error_message],
        "completed_at" => System.system_time(:millisecond)
      }
      |> SalixAgent.ToolCallProvenance.inherit(record)
    ]
  end

  defp sync_event(session, record, fields) do
    Map.merge(fields, %{
      "type" => "capability_request_sync",
      "session_id" => InternalSession.session_id(session),
      "tool_call_id" => tool_call_id(record)
    })
  end

  defp require_log_failure(session, id, reason) do
    require Logger

    Logger.error("capability request reconciliation failed; operator recovery required",
      agent_id: InternalSession.agent_id(session),
      session_id: InternalSession.session_id(session),
      tool_call_id: id,
      reason: inspect(reason)
    )
  end

  defp staged_async_result(agent_id, sid, record) do
    with id when is_binary(id) and id != "" <- tool_call_id(record),
         operation_id <-
           WorkspaceEvents.operation_id(
             AsyncToolResults.operation_source(:internal),
             agent_id,
             sid,
             id
           ),
         {:ok, result} <- AgentWorkspace.operation_result(agent_id, operation_id),
         restored <- WorkspaceEvents.restore_operation_result(result),
         :ok <- SalixAgent.ToolSideEffects.validate_results([restored]) do
      {:ok, restored}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp tool_call_id(record), do: record["tool_call_id"] || record[:tool_call_id]
end
