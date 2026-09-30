defmodule SalixAgent.ExternalSessionFleet do
  @moduledoc """
  Node-local routing for external session actors.

  Agent placement is resolved before the `{agent_id, session_id}` actor starts;
  every session command then uses the same route.
  """

  alias SalixAgent.ExternalSessionActor

  def ensure_started(agent_id, session_id, opts \\ []) do
    opts = opts |> Keyword.put(:agent_id, agent_id) |> Keyword.put(:session_id, session_id)

    with :ok <- require_session_id(session_id),
         :ok <- SalixAgent.Control.ensure_not_stopped(agent_id),
         :ok <- ensure_agent_owner_local(agent_id, opts) do
      SalixAgent.Fleet.start_session_actor(ExternalSessionActor, opts)
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  def wake(agent_id, session_id) do
    with {:ok, _pid} <- ensure_started(agent_id, session_id),
         do: ExternalSessionActor.wake(agent_id, session_id)
  end

  def stage_delivery(agent_id, session_id, delivery, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.stage_delivery(pid, delivery, timeout)
      end)

  def consult(agent_id, session_id, query, request_id, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.consult(
          pid,
          query,
          request_id,
          Keyword.fetch!(opts, :requester_agent_id),
          timeout
        )
      end)

  def begin_session(agent_id, session_id, tenant_id, runtime, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.begin_session(pid, tenant_id, runtime, timeout)
      end)

  def update_session(agent_id, session_id, attrs, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.update_session(pid, attrs, timeout)
      end)

  def accept_session(agent_id, session_id, attrs, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.accept_session(pid, attrs, timeout)
      end)

  def complete_session(agent_id, session_id, attrs \\ %{}, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.complete_session(pid, attrs, timeout)
      end)

  def fail_session(agent_id, session_id, reason, attrs \\ %{}, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.fail_session(pid, reason, attrs, timeout)
      end)

  def append_event(agent_id, session_id, attrs, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.append_event(pid, attrs, timeout)
      end)

  def commit_session_events(agent_id, session_id, events, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.commit_session_events(pid, events, timeout)
      end)

  def commit_connector_event(
        %{"agent_id" => agent_id, "session_id" => session_id} = capability,
        params,
        opts \\ []
      ),
      do:
        call(agent_id, session_id, opts, fn pid, timeout ->
          ExternalSessionActor.commit_connector_event(pid, capability, params, timeout)
        end)

  def stage_wait_timeout(agent_id, session_id, delivery, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.stage_wait_timeout(pid, delivery, timeout)
      end)

  def execute_tool(agent_id, session_id, tool_name, attrs, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.execute_tool(pid, tool_name, attrs, timeout)
      end)

  def complete_async_tool_call(agent_id, session_id, tool_call_id, result, meta, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.complete_async_tool_call(
          pid,
          tool_call_id,
          result,
          meta,
          timeout
        )
      end)

  def update_async_tool_call_progress(agent_id, session_id, tool_call_id, progress, opts \\ []),
    do:
      call(agent_id, session_id, opts, fn pid, timeout ->
        ExternalSessionActor.update_async_tool_call_progress(
          pid,
          tool_call_id,
          progress,
          timeout
        )
      end)

  defp call(agent_id, session_id, opts, command) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    start_opts = opts |> Keyword.drop([:timeout]) |> Keyword.put(:process_on_init, false)

    with {:ok, pid} <- ensure_started(agent_id, session_id, start_opts) do
      if pid == self(),
        do: {:error, :reentrant_external_session_call},
        else: command.(pid, timeout)
    end
  end

  defp require_session_id(session_id) do
    if SalixStore.Ids.valid_session_id?(session_id), do: :ok, else: {:error, :invalid_session_id}
  end

  defp ensure_agent_owner_local(agent_id, opts) do
    case Registry.lookup(SalixAgent.Registry, agent_id) do
      [{pid, _}] when node(pid) == node() ->
        :ok

      [{pid, _}] ->
        {:error, {:agent_owner_remote, node(pid)}}

      [] ->
        ensure_agent_owner_started_local(agent_id, opts)
    end
  end

  defp ensure_agent_owner_started_local(agent_id, opts) do
    startup_mode = if Keyword.get(opts, :process_on_init, true), do: :active, else: :passive

    case SalixAgent.Placement.ensure_started(agent_id, create: false, startup_mode: startup_mode) do
      {:ok, pid} when node(pid) == node() ->
        :ok

      {:ok, pid} ->
        {:error, {:agent_owner_remote, node(pid)}}

      {:error, _} = error ->
        error
    end
  end
end
