defmodule SalixAgent.InternalSessionFleet do
  @moduledoc """
  Spawn-on-demand for internal session actors.

  Actor identity is `{agent_id, session_id}`. This fleet is a node-local helper
  and may only start session actors on the current owner node for `agent_id`.
  Cross-node routing must happen before this module is called.
  """

  alias SalixAgent.InternalSessionActor

  @spec ensure_started(String.t(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(agent_id, session_id, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:agent_id, agent_id)
      |> Keyword.put(:session_id, session_id)

    with :ok <- require_session_id(session_id),
         :ok <- SalixAgent.Control.ensure_not_stopped(agent_id),
         :ok <- ensure_agent_owner_local(agent_id, opts),
         {:ok, agent} <- SalixAgent.Control.get_record(agent_id) do
      start_for_agent(agent, session_id, opts)
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # A Router has one internal runtime owner. Route actor creation through that
  # owner so its canonical read and DynamicSupervisor start are one mailbox
  # operation with respect to canonical cutover. Historical Router sessions
  # remain readable but cannot resume compute after a cutover. Modeled in
  # tla/salix/RouterCanonicalSessionSwitch.tla.
  defp start_for_agent(%{"role" => "router"} = agent, session_id, opts) do
    with {:ok, router_owner} <- SalixAgent.AgentActor.ensure_started(agent) do
      SalixAgent.AgentRoleActor.ensure_canonical_session_started(
        router_owner,
        session_id,
        opts
      )
    end
  end

  defp start_for_agent(_agent, _session_id, opts),
    do: SalixAgent.Fleet.start_session_actor(InternalSessionActor, opts)

  defp durable_router_session_admission(agent_id, session_id) do
    case SalixAgent.Control.get_record(agent_id) do
      {:ok, %{"role" => "router", "router_session_id" => ^session_id}} ->
        :ok

      {:ok, %{"role" => "router", "router_session_id" => canonical_session_id}} ->
        {:error, {:retired_router_session, canonical_session_id}}

      {:ok, _agent} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp require_session_id(session_id) do
    if SalixStore.Ids.valid_session_id?(session_id), do: :ok, else: {:error, :invalid_session_id}
  end

  @spec wake(String.t(), String.t()) :: :ok | {:error, term()}
  def wake(agent_id, session_id) do
    # An archived agent refuses a wake. Past that, a resident actor already
    # passed the canonical-session check when its Router owner started it and
    # re-checks at every commit; a wake only nudges it, so the durable
    # canonical re-read is for actors that must be started.
    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id) do
      case Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id)) do
        [{_pid, _value}] ->
          InternalSessionActor.wake(agent_id, session_id)

        [] ->
          with {:ok, _pid} <- ensure_started(agent_id, session_id) do
            InternalSessionActor.wake(agent_id, session_id)
          end
      end
    end
  end

  @spec run_round(String.t(), String.t(), map(), keyword(), keyword()) ::
          {:ok, map(), term()} | {:error, term()}
  def run_round(agent_id, session_id, context, run_opts, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(context) and
             is_list(run_opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    start_opts = opts |> Keyword.drop([:timeout]) |> Keyword.put(:process_on_init, false)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id),
         :ok <- durable_router_session_admission(agent_id, session_id) do
      case Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id)) do
        # The owner runs a direct round from its mailbox, never inside one of
        # its own callbacks.
        [{pid, _}] when pid == self() ->
          {:error, :session_owner_reentry}

        _ ->
          with {:ok, pid} <- ensure_started(agent_id, session_id, start_opts) do
            InternalSessionActor.run_round(pid, context, direct_round_opts(run_opts), timeout)
          end
      end
    end
  end

  defp direct_round_opts(opts) do
    await_completion? =
      Keyword.get(opts, :__round_run_delegate__, false) and
        Keyword.get(opts, :async_llm, false) != true

    opts
    |> Keyword.delete(:__round_run_delegate__)
    # An actor entrypoint may never let a caller opt back into running a
    # user-selected provider in the session actor mailbox.
    |> Keyword.put(:async_llm, true)
    |> then(fn opts ->
      if await_completion?,
        do: Keyword.put(opts, :__round_run_await_completion__, true),
        else: opts
    end)
  end

  @spec compact_session(
          String.t(),
          String.t(),
          :compact | :maybe_compact,
          map(),
          keyword(),
          keyword()
        ) ::
          {:ok, map(), SalixAgent.Compaction.compact_result()} | {:error, term()}
  def compact_session(agent_id, session_id, mode, context, compact_opts, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and mode in [:compact, :maybe_compact] and
             is_map(context) and is_list(compact_opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    start_opts = opts |> Keyword.drop([:timeout]) |> Keyword.put(:process_on_init, false)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id) do
      case Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id)) do
        [{pid, _}] when pid == self() ->
          {:error, :session_owner_reentry}

        _ ->
          with {:ok, pid} <- ensure_started(agent_id, session_id, start_opts) do
            InternalSessionActor.compact_session(pid, mode, context, compact_opts, timeout)
          end
      end
    end
  end

  @spec commit_tool_results(String.t(), String.t(), map(), map(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def commit_tool_results(agent_id, session_id, context, pending, results, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(context) and
             is_map(pending) and is_list(results) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    start_opts = opts |> Keyword.drop([:timeout]) |> Keyword.put(:process_on_init, false)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id) do
      case Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id)) do
        [{pid, _}] when pid == self() ->
          {:error, :session_owner_reentry}

        _ ->
          with {:ok, pid} <- ensure_started(agent_id, session_id, start_opts) do
            InternalSessionActor.commit_tool_results(pid, context, pending, results, timeout)
          end
      end
    end
  end

  @spec stage_delivery(String.t(), String.t(), map(), keyword()) ::
          {:ok, :committed | :duplicate} | {:error, term()}
  def stage_delivery(agent_id, session_id, entry, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(entry) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    # A delivery is followed by an activation: an actor born for it starts
    # its round configuration build as soon as it is bound.
    start_opts =
      opts
      |> Keyword.drop([:timeout])
      |> Keyword.put(:process_on_init, false)
      |> Keyword.put(:prewarm_round_config, true)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id),
         :ok <- admit_router_stage(session_id, opts) do
      case Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id)) do
        [{pid, _}] when pid == self() ->
          InternalSessionActor.stage_delivery_in_owner(agent_id, session_id, entry)

        # A resident actor passed the canonical-session check when its Router
        # owner started it, and a canonical switch stops it before retiring
        # the session; staging into it needs no second durable read.
        [{pid, _}] ->
          InternalSessionActor.stage_delivery(pid, entry, timeout)

        [] ->
          with {:ok, pid} <- ensure_started(agent_id, session_id, start_opts) do
            InternalSessionActor.stage_delivery(pid, entry, timeout)
          end
      end
    end
  end

  defp admit_router_stage(session_id, opts) do
    case Keyword.get(opts, :router_owner) do
      pid when is_pid(pid) -> SalixAgent.AgentRoleActor.admit_canonical_session(pid, session_id)
      _other -> :ok
    end
  end

  @spec stage_wait_timeout(String.t(), String.t(), map(), keyword()) ::
          {:ok, :committed | :duplicate | :ignored} | {:error, term()}
  def stage_wait_timeout(agent_id, session_id, entry, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(entry) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    start_opts = opts |> Keyword.drop([:timeout]) |> Keyword.put(:process_on_init, false)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id) do
      case Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id)) do
        [{pid, _}] when pid == self() ->
          InternalSessionActor.stage_wait_timeout_in_owner(agent_id, session_id, entry)

        _ ->
          with {:ok, pid} <- ensure_started(agent_id, session_id, start_opts) do
            InternalSessionActor.stage_wait_timeout(pid, entry, timeout)
          end
      end
    end
  end

  @spec stage_control(String.t(), String.t(), map(), keyword()) ::
          {:ok, :committed} | {:error, term()}
  def stage_control(agent_id, session_id, entry, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(entry) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    start_opts = opts |> Keyword.drop([:timeout]) |> Keyword.put(:process_on_init, false)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id) do
      case Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id)) do
        [{pid, _}] when pid == self() ->
          InternalSessionActor.stage_control_in_owner(agent_id, session_id, entry)

        _ ->
          with {:ok, pid} <- ensure_started(agent_id, session_id, start_opts) do
            InternalSessionActor.stage_control(pid, entry, timeout)
          end
      end
    end
  end

  @spec fork_session(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, SalixAgent.InternalSession.t()} | {:error, term()}
  def fork_session(agent_id, source_session_id, target_session_id, attrs, opts \\ [])
      when is_binary(agent_id) and is_binary(source_session_id) and is_binary(target_session_id) and
             is_map(attrs) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    start_opts = opts |> Keyword.drop([:timeout]) |> Keyword.put(:process_on_init, false)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id) do
      case Registry.lookup(
             SalixAgent.Registry,
             InternalSessionActor.key(agent_id, target_session_id)
           ) do
        [{pid, _}] when pid == self() ->
          InternalSessionActor.fork_session_in_owner(
            agent_id,
            source_session_id,
            target_session_id,
            attrs
          )

        _ ->
          with {:ok, pid} <- ensure_started(agent_id, target_session_id, start_opts) do
            InternalSessionActor.fork_session(
              pid,
              source_session_id,
              target_session_id,
              attrs,
              timeout
            )
          end
      end
    end
  end

  @spec seed_session(
          String.t(),
          SalixAgent.InternalSession.t(),
          String.t(),
          map(),
          keyword()
        ) ::
          {:ok, SalixAgent.InternalSession.t()} | {:error, term()}
  def seed_session(agent_id, source_session, target_session_id, attrs, opts \\ [])
      when is_binary(agent_id) and is_binary(target_session_id) and is_map(attrs) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    start_opts = opts |> Keyword.drop([:timeout]) |> Keyword.put(:process_on_init, false)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id) do
      case Registry.lookup(
             SalixAgent.Registry,
             InternalSessionActor.key(agent_id, target_session_id)
           ) do
        [{pid, _}] when pid == self() ->
          InternalSessionActor.seed_session_in_owner(
            agent_id,
            source_session,
            target_session_id,
            attrs
          )

        _ ->
          with {:ok, pid} <- ensure_started(agent_id, target_session_id, start_opts) do
            InternalSessionActor.seed_session(
              pid,
              source_session,
              target_session_id,
              attrs,
              timeout
            )
          end
      end
    end
  end

  @spec seed_transcript(String.t(), String.t(), map(), keyword()) ::
          {:ok, SalixAgent.InternalSession.t(), non_neg_integer()} | {:error, term()}
  def seed_transcript(agent_id, session_id, event, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(event) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    start_opts = opts |> Keyword.drop([:timeout]) |> Keyword.put(:process_on_init, false)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id) do
      case Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id)) do
        [{pid, _}] when pid == self() ->
          InternalSessionActor.seed_transcript_in_owner(agent_id, session_id, event)

        _ ->
          with {:ok, pid} <- ensure_started(agent_id, session_id, start_opts) do
            InternalSessionActor.seed_transcript(pid, event, timeout)
          end
      end
    end
  end

  @spec execute_tool(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_tool(agent_id, session_id, tool_name, attrs, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_name) and
             is_map(attrs) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id),
         {:ok, pid} <- ensure_started(agent_id, session_id) do
      InternalSessionActor.execute_tool(pid, tool_name, attrs, timeout)
    end
  end

  @spec complete_async_tool_call(String.t(), String.t(), String.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete_async_tool_call(agent_id, session_id, tool_call_id, result, meta, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_call_id) and
             is_map(result) and is_map(meta) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id),
         {:ok, pid} <- ensure_started(agent_id, session_id) do
      InternalSessionActor.complete_async_tool_call(pid, tool_call_id, result, meta, timeout)
    end
  end

  @spec update_async_tool_call_progress(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_async_tool_call_progress(agent_id, session_id, tool_call_id, progress, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_binary(tool_call_id) and
             is_map(progress) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    with :ok <- SalixAgent.Control.ensure_not_stopped(agent_id),
         {:ok, pid} <- ensure_started(agent_id, session_id) do
      InternalSessionActor.update_async_tool_call_progress(pid, tool_call_id, progress, timeout)
    end
  end

  defp ensure_agent_owner_local(agent_id, opts) do
    ensure_agent_server_owner_local(agent_id, opts)
  end

  defp ensure_agent_server_owner_local(agent_id, opts) do
    case Registry.lookup(SalixAgent.Registry, agent_id) do
      [{pid, _}] when node(pid) == node() ->
        :ok

      [{pid, _}] ->
        {:error, {:agent_owner_remote, node(pid)}}

      [] ->
        ensure_agent_server_owner_started_local(agent_id, opts)
    end
  end

  defp ensure_agent_server_owner_started_local(agent_id, opts) do
    case SalixAgent.Placement.ensure_started(agent_id, agent_owner_start_opts(opts)) do
      {:ok, pid} when node(pid) == node() ->
        :ok

      {:ok, pid} ->
        {:error, {:agent_owner_remote, node(pid)}}

      {:error, _} = err ->
        err
    end
  end

  defp agent_owner_start_opts(opts) do
    [create: false, startup_mode: agent_owner_startup_mode(opts)]
  end

  defp agent_owner_startup_mode(opts) do
    if Keyword.get(opts, :process_on_init, true), do: :active, else: :passive
  end
end
