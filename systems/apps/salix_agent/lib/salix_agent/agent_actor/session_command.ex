defmodule SalixAgent.AgentActor.SessionCommand do
  @moduledoc """
  The external-runtime command surface, and the archive seam for it.

  Every agent actor — worker, router, meeting — funnels its external-runtime
  calls through this module, so this is where boundaries 1 and 6 are archived
  for agents whose loop runs off-node. Instrumenting the three actors instead
  would mean three chances to forget, and the first version of this archive
  forgot exactly that way on the internal side.

  ## What an external runtime cannot archive, stated plainly

  Boundaries 2 and 3 — the provider request and response — happen inside the
  customer's own runtime. Nothing in this system observes them, and no seam
  here can. For an external-runtime agent the archive is therefore a record of
  what CROSSED the boundary with us (deliveries in, committed events and tool
  traffic out), not of the conversation with the model. `mix
  salix.archive.verify` reports a contiguous run for such a session; that says
  nothing about provider traffic, because none was ever expected.

  Tool traffic is the exception and IS covered: `SessionToolExecution` dispatches
  through `SalixAgent.Tools`, so boundaries 4 and 5 reach the same seam an
  internal round does.
  """

  alias SalixAgent.{
    Control,
    ExternalSessionFleet,
    InternalSessionFleet,
    MemoryConsultationRuntime
  }

  alias SalixAgent.AgentActor.SessionDelivery
  alias SalixAgent.EventArchive.Emit

  def execute_session_tool(agent_id, session_id, tool_name, attrs, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_name) and
             is_map(attrs) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         {:ok, runtime_kind} <- runtime_kind(agent_id) do
      case runtime_kind do
        "external" ->
          with :ok <- ensure_external_runtime(agent_id) do
            ExternalSessionFleet.execute_tool(agent_id, session_id, tool_name, attrs, opts)
          end

        _ ->
          InternalSessionFleet.execute_tool(agent_id, session_id, tool_name, attrs, opts)
      end
    end
  end

  def complete_async_tool_call(agent_id, session_id, tool_call_id, result, meta, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_call_id) and
             is_map(result) and is_map(meta) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         {:ok, runtime_kind} <- runtime_kind(agent_id) do
      case runtime_kind do
        "external" ->
          with :ok <- ensure_external_runtime(agent_id) do
            ExternalSessionFleet.complete_async_tool_call(
              agent_id,
              session_id,
              tool_call_id,
              result,
              meta,
              opts
            )
          end

        _ ->
          InternalSessionFleet.complete_async_tool_call(
            agent_id,
            session_id,
            tool_call_id,
            result,
            meta,
            opts
          )
      end
    end
  end

  def update_async_tool_call_progress(agent_id, session_id, tool_call_id, progress, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_call_id) and
             is_map(progress) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         {:ok, runtime_kind} <- runtime_kind(agent_id) do
      case runtime_kind do
        "external" ->
          with :ok <- ensure_external_runtime(agent_id) do
            ExternalSessionFleet.update_async_tool_call_progress(
              agent_id,
              session_id,
              tool_call_id,
              progress,
              opts
            )
          end

        _ ->
          InternalSessionFleet.update_async_tool_call_progress(
            agent_id,
            session_id,
            tool_call_id,
            progress,
            opts
          )
      end
    end
  end

  def commit_connector_event(
        %{"agent_id" => agent_id, "session_id" => session_id} = capability,
        params,
        opts \\ []
      )
      when is_binary(agent_id) and is_binary(session_id) and is_map(params) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         :ok <- ensure_external_runtime(agent_id) do
      ExternalSessionFleet.commit_connector_event(capability, params, opts)
    end
  end

  def begin_external_session(agent_id, session_id, tenant_id, runtime, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tenant_id) and
             is_map(runtime) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         :ok <- ensure_external_runtime(agent_id) do
      ExternalSessionFleet.begin_session(agent_id, session_id, tenant_id, runtime, opts)
    end
  end

  def update_external_session(agent_id, session_id, attrs, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         :ok <- ensure_external_runtime(agent_id) do
      ExternalSessionFleet.update_session(agent_id, session_id, attrs, opts)
    end
  end

  def accept_external_session(agent_id, session_id, attrs, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         :ok <- ensure_external_runtime(agent_id) do
      ExternalSessionFleet.accept_session(agent_id, session_id, attrs, opts)
    end
  end

  def complete_external_session(agent_id, session_id, attrs, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         :ok <- ensure_external_runtime(agent_id) do
      ExternalSessionFleet.complete_session(agent_id, session_id, attrs, opts)
    end
  end

  def fail_external_session(agent_id, session_id, reason, attrs \\ %{}, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         :ok <- ensure_external_runtime(agent_id) do
      ExternalSessionFleet.fail_session(agent_id, session_id, reason, attrs, opts)
    end
  end

  def append_external_event(agent_id, session_id, attrs, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    # Archive boundary 6, external-runtime arm: an off-node loop's output. See
    # the moduledoc for what this arm can and cannot stand in for.
    Emit.external_runtime_events(agent_id, session_id, :append, [attrs])

    with :ok <- Control.ensure_not_stopped(agent_id),
         :ok <- ensure_external_runtime(agent_id) do
      ExternalSessionFleet.append_event(agent_id, session_id, attrs, opts)
    end
  end

  def commit_external_session_events(agent_id, session_id, events, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_list(events) do
    Emit.external_runtime_events(agent_id, session_id, :commit, events)

    with :ok <- Control.ensure_not_stopped(agent_id),
         :ok <- ensure_external_runtime(agent_id) do
      ExternalSessionFleet.commit_session_events(agent_id, session_id, events, opts)
    end
  end

  def stage_external_delivery(agent_id, session_id, delivery, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(delivery) do
    # Archive boundary 1 for external-runtime agents. This path does NOT go
    # through `SessionDelivery.stage/3`, which is where the internal side is
    # archived — `AgentActor.stage_external_delivery/4` reaches the fleet from
    # here instead. Every external ingress was therefore unarchived: the whole
    # inbound surface of every external-runtime agent, invisibly.
    #
    # Archived BEFORE the control checks, for the same reason boundary 1 is
    # archived at stage time on the internal side: what was offered to the loop
    # is the record, including what a stopped agent or a runtime mismatch then
    # refuses.
    Emit.delivery(agent_id, delivery, session_id: session_id)

    with :ok <- Control.ensure_not_stopped(agent_id),
         :ok <- ensure_external_runtime(agent_id) do
      case ExternalSessionFleet.stage_delivery(agent_id, session_id, delivery, opts) do
        {:ok, :committed} -> {:ok, :external}
        # A same-source-id retry whose first attempt already committed: the
        # ledger answers duplicate, which IS this facade's success — the
        # delivery is durably staged (#870).
        {:ok, :duplicate} -> {:ok, :external}
        {:error, _} = err -> err
      end
    end
  end

  def consult_worker_session(agent_id, session_id, question, request_id, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(question) and
             is_binary(request_id) do
    with :ok <- Control.ensure_not_stopped(agent_id),
         {:ok, runtime_kind} <- SessionDelivery.session_birth_runtime(agent_id, session_id) do
      case runtime_kind do
        :external ->
          with {:ok, requester_agent_id} <- Keyword.fetch(opts, :requester_agent_id) do
            agent_id
            |> ExternalSessionFleet.consult(
              session_id,
              question,
              request_id,
              Keyword.put(opts, :requester_agent_id, requester_agent_id)
            )
            |> consultation_runtime_result("external")
          end

        :internal ->
          agent_id
          |> MemoryConsultationRuntime.consult_internal(session_id, question)
          |> consultation_runtime_result("internal")

        :new ->
          {:error, :not_found}
      end
    end
  end

  defp consultation_runtime_result({:ok, result}, runtime_kind) when is_map(result),
    do: {:ok, Map.put(result, "runtime_kind", runtime_kind)}

  defp consultation_runtime_result({:error, _reason} = error, _runtime_kind), do: error

  defp runtime_kind(agent_id) do
    case Control.get_record(agent_id) do
      {:ok, agent} -> {:ok, Control.runtime_kind(agent)}
      {:error, _} = err -> err
    end
  end

  defp ensure_external_runtime(agent_id) do
    with {:ok, agent} <- Control.get_record(agent_id) do
      if Control.external_runtime?(agent) do
        :ok
      else
        {:error, {:bad_request, "operation is only available for external runtime agents"}}
      end
    end
  end
end
