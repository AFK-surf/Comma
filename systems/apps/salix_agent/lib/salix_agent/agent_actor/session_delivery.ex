defmodule SalixAgent.AgentActor.SessionDelivery do
  require SystemsRuntime.Proc

  @moduledoc false

  alias SalixAgent.{
    InternalSessionFleet,
    InternalSessionStore
  }

  @type wake_target :: %{runtime: :internal, session_id: String.t()}
  @type result ::
          {:ok, :committed, [wake_target()]}
          | {:ok, :duplicate}
          | {:ok, :ignored}
          | {:error, term()}

  @spec validate_payload(map()) :: :ok | {:error, :missing_session_id | :invalid_session_id}
  def validate_payload(payload) when is_map(payload) do
    case require_session_id(payload) do
      {:ok, _session_id} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec stage(String.t(), map(), keyword()) :: result()
  def stage(agent_id, entry, opts \\ []) do
    # Archive boundary 1, at STAGE time — so deliveries later deduped, dropped
    # or dead-lettered are still captured; the loop's inbound surface is what
    # was OFFERED to it, not only what it acted on.
    #
    # This wrapper exists so the emitter cannot be bypassed. It used to live in
    # the catch-all `do_stage/3` clause, which meant every kind-matched clause
    # ahead of it — session_create/update/fork/compact/log and wait_timeout —
    # archived nothing. session_log in particular is content-bearing: it is how
    # meeting runtime events enter a session.
    SalixAgent.EventArchive.Emit.delivery(agent_id, entry)

    do_stage(agent_id, entry, opts)
  end

  defp do_stage(agent_id, %{payload: %{kind: "session_create"}} = entry, opts) do
    with {:ok, session_id} <- require_session_id(entry.payload) do
      stage_internal_control(agent_id, session_id, entry, "session_create", opts)
    end
  end

  defp do_stage(agent_id, %{payload: %{kind: "session_update"}} = entry, opts) do
    with {:ok, session_id} <- require_session_id(entry.payload) do
      stage_internal_control(agent_id, session_id, entry, "session_update", opts)
    end
  end

  defp do_stage(agent_id, %{payload: %{kind: "session_fork"}} = entry, opts) do
    with {:ok, session_id} <- require_session_id(entry.payload) do
      stage_internal_control(agent_id, session_id, entry, "session_fork", opts)
    end
  end

  defp do_stage(agent_id, %{payload: %{kind: "session_compact"}} = entry, opts) do
    with {:ok, session_id} <- require_session_id(entry.payload) do
      stage_internal_control(agent_id, session_id, entry, "session_compact", opts)
    end
  end

  defp do_stage(agent_id, %{payload: %{kind: "session_log"}} = entry, opts) do
    with {:ok, session_id} <- require_session_id(entry.payload) do
      stage_internal_control(agent_id, session_id, entry, "session_log", opts)
    end
  end

  defp do_stage(agent_id, %{payload: %{kind: "wait_timeout"}} = entry, opts) do
    with {:ok, session_id} <- require_session_id(entry.payload),
         {:ok, birth} <- session_birth_runtime(agent_id, session_id) do
      # A wait_timeout was armed by a live session, so it should always find
      # its session; the :new fallback only covers a session deleted under an
      # in-flight timer, where the store answers its own not-found.
      case birth do
        :internal -> commit_internal_wait_timeout(agent_id, session_id, entry, opts)
        :retired -> {:ok, :ignored}
        :new -> place_new_session(agent_id, session_id, entry, opts, :wait_timeout)
      end
    end
  end

  # A delivery addressed to an existing session goes to that session. A
  # retired session (`SalixAgent.RetiredSessions`) is read-only. Only a
  # session that exists nowhere is a new-session placement.
  defp do_stage(agent_id, entry, opts) do
    with {:ok, session_id} <- require_session_id(entry.payload) do
      if SystemsRuntime.Proc.is_process(Keyword.get(opts, :router_owner)) do
        # The Router owner fences this exact canonical Session inside
        # InternalSessionFleet.stage_delivery/4. Router Sessions are created
        # with their birth marker, so another storage probe cannot change
        # the routing decision.
        stage_internal_delivery(agent_id, session_id, entry, opts)
      else
        with {:ok, birth} <- session_birth_runtime(agent_id, session_id) do
          case birth do
            :internal -> stage_internal_delivery(agent_id, session_id, entry, opts)
            :retired -> {:error, :session_read_only}
            :new -> place_new_session(agent_id, session_id, entry, opts, :delivery)
          end
        end
      end
    end
  end

  # Birth and first state/input are committed together by the Session Store.
  defp place_new_session(agent_id, session_id, entry, opts, :wait_timeout),
    do: commit_internal_wait_timeout(agent_id, session_id, entry, opts)

  defp place_new_session(agent_id, session_id, entry, opts, :delivery),
    do: stage_internal_delivery(agent_id, session_id, entry, opts)

  @doc false
  def session_birth_runtime(agent_id, session_id) do
    case InternalSessionStore.birth(agent_id, session_id) do
      {:ok, :deleted} -> {:error, :session_read_only}
      {:ok, _} = result -> result
      {:error, reason} -> {:error, {:unavailable, {:session_probe, reason}}}
    end
  end

  defp commit_internal_wait_timeout(agent_id, session_id, entry, opts) do
    case InternalSessionFleet.stage_wait_timeout(agent_id, session_id, entry, opts) do
      {:ok, :committed} -> {:ok, :committed, wake_targets(session_id, entry, :internal)}
      {:ok, :duplicate} -> {:ok, :duplicate}
      {:ok, :ignored} -> {:ok, :ignored}
      {:error, _} = err -> err
    end
  end

  defp stage_internal_delivery(agent_id, session_id, entry, opts) do
    case InternalSessionFleet.stage_delivery(agent_id, session_id, entry, opts) do
      {:ok, :activated} -> {:ok, :committed, []}
      {:ok, :committed} -> {:ok, :committed, wake_targets(session_id, entry, :internal)}
      {:ok, :duplicate} -> {:ok, :duplicate}
      {:error, _} = err -> err
    end
  end

  defp stage_internal_control(agent_id, session_id, entry, control_kind, opts) do
    case require_internal_runtime(agent_id, session_id, control_kind) do
      :ok ->
        case InternalSessionFleet.stage_control(agent_id, session_id, entry, passive_opts(opts)) do
          {:ok, :committed} -> {:ok, :committed, []}
          {:error, _} = err -> err
        end

      :retired ->
        {:ok, :ignored}

      {:error, _} = err ->
        err
    end
  end

  defp passive_opts(opts), do: Keyword.put(opts, :process_on_init, false)

  # Control entries follow the same session-grain authority as deliveries:
  # a control op addressed to a retired session is ignored. Internal control
  # ops CREATE missing sessions (the fleet's ensure_started path), so a
  # creating op claims the birth marker like any other new-session placement.
  defp require_internal_runtime(agent_id, session_id, control_kind) do
    result = session_birth_runtime(agent_id, session_id)

    case result do
      {:ok, kind} when kind in [:internal, :new] ->
        :ok

      {:ok, :retired} ->
        CommaLog.log("absorb_internal_control_ignored", %{
          agent_id: agent_id,
          kind: control_kind,
          runtime: "retired"
        })

        :retired

      {:error, _} = err ->
        err
    end
  end

  defp wake_targets(_session_id, %{conversation_scan_only: true}, _runtime), do: []

  defp wake_targets(session_id, %{payload: payload}, runtime) when runtime == :internal do
    if payload[:no_wake] == true or payload["no_wake"] == true do
      []
    else
      [
        %{
          runtime: runtime,
          session_id: session_id
        }
      ]
    end
  end

  defp require_session_id(payload) when is_map(payload) do
    case payload[:session_id] || payload["session_id"] do
      sid when is_binary(sid) ->
        sid = String.trim(sid)

        cond do
          sid == "" -> {:error, :missing_session_id}
          SalixStore.Ids.valid_session_id?(sid) -> {:ok, sid}
          true -> {:error, :invalid_session_id}
        end

      _ ->
        {:error, :missing_session_id}
    end
  end

  defp require_session_id(_payload), do: {:error, :missing_session_id}
end
