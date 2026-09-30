defmodule SalixAgent.AgentActor.SessionDelivery do
  @moduledoc false

  alias SalixAgent.{
    Control,
    ExternalSessionFleet,
    ExternalSessionStore,
    InternalSessionFleet,
    InternalSessionStore,
    SessionBirth
  }

  @type wake_target :: %{runtime: :internal | :external, session_id: String.t()}
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
      # A wait_timeout was armed by a live session, so the session-grain
      # resolution below should always find its birth store; the :new
      # fallback only covers a session deleted under an in-flight timer,
      # where the store answers its own not-found.
      case birth do
        :internal -> commit_internal_wait_timeout(agent_id, session_id, entry, opts)
        :external -> commit_external_wait_timeout(agent_id, session_id, entry, opts)
        :new -> place_new_session(agent_id, session_id, entry, opts, :wait_timeout)
      end
    end
  end

  # Runtime authority is the SESSION, fixed at its birth (owner ruling
  # 2026-08-15, plan clause 2b): the agent record's mutable runtime_config
  # governs only NEW-session placement. So routing resolves the session
  # first — a delivery addressed to an existing session goes to the store
  # that session was born in, regardless of what the agent record says
  # today (#873 round 5: routing every later delivery off the agent record
  # split one session id across both stores after a flip). Only when the
  # session exists in neither store is this new-session placement, where
  # the agent record and the admission fence apply.
  defp do_stage(agent_id, entry, opts) do
    with {:ok, session_id} <- require_session_id(entry.payload) do
      case {internal_only_entry?(entry), Keyword.get(opts, :router_owner)} do
        {true, owner} when is_pid(owner) ->
          # The Router owner fences this exact canonical Session inside
          # InternalSessionFleet.stage_delivery/4. Router Sessions are created
          # with their internal birth marker, so another storage probe cannot
          # change the routing decision.
          stage_internal_delivery(agent_id, session_id, entry, opts)

        _ ->
          with {:ok, birth} <- session_birth_runtime(agent_id, session_id) do
            case birth do
              :internal -> stage_internal_delivery(agent_id, session_id, entry, opts)
              :external -> stage_external_delivery(agent_id, session_id, entry, opts)
              :new -> place_new_session(agent_id, session_id, entry, opts, :delivery)
            end
          end
      end
    end
  end

  # New-session placement (the session exists in neither store): the ONLY
  # routing read of the mutable agent record — and, since round 6, the read
  # decides nothing by itself: the create-once BIRTH MARKER does
  # (SalixAgent.SessionBirth). The claim runs BEFORE any store create, so
  # two concurrent first deliveries astride a runtime flip serialize on the
  # marker's single-object CAS: the winner's side is recorded durably and
  # the loser places on the recorded side, instead of each creating the id
  # in its own store (the round-6 birth-overlap repro;
  # RpcDeliver_NoBirthAuthority.cfg is the retired behavior's expected
  # violation, AtMostOneBirthStore holds in Safety).
  #
  # The ADMISSION fence still lives here: an entry flagged internal-only
  # (the facade classified the agent internal) refuses (:runtime_changed)
  # BEFORE claiming anything, and the facade re-classifies once inside the
  # same deadline (#843 owner-reproduced race). A lost claim then delivers
  # to the session's true birth side regardless of the entry's stale
  # classification — same rule as an existing session.
  defp place_new_session(agent_id, session_id, entry, opts, kind) do
    with {:ok, agent_side} <- runtime_kind(agent_id),
         :ok <- admission_fence(agent_side, entry),
         {:ok, side} <- SessionBirth.claim(agent_id, session_id, agent_side) do
      case {side, kind} do
        {:internal, :wait_timeout} ->
          commit_internal_wait_timeout(agent_id, session_id, entry, opts)

        {:external, :wait_timeout} ->
          commit_external_wait_timeout(agent_id, session_id, entry, opts)

        {:internal, :delivery} ->
          stage_internal_delivery(agent_id, session_id, entry, opts)

        {:external, :delivery} ->
          stage_external_delivery(agent_id, session_id, entry, opts)
      end
    end
  end

  defp admission_fence(:external, entry),
    do: if(internal_only_entry?(entry), do: {:error, :runtime_changed}, else: :ok)

  defp admission_fence(:internal, _entry), do: :ok

  # Which store was this session born in? Existence in a store IS the
  # durable birth record — sessions are created exactly once, by the
  # single-object CAS of their own store. Probe order is fixed
  # (internal, then external) so a legacy pre-fix split id — one id
  # wrongly present in both stores — resolves deterministically instead
  # of following the mutable agent record.
  #
  # FAIL-CLOSED (#873 round 7, deploy/error-semantics ruling): `:new` is a
  # positive claim — BOTH stores answered a confirmed not-found. A probe
  # ERROR is not absence: one transient 503 on the old side after a
  # runtime flip would otherwise re-birth an existing (pre-marker,
  # markerless) session in the other store. Uncertainty refuses the
  # delivery with the §1.8 retryable unavailable row — zero writes, the
  # same-id retry resolves it.
  @doc false
  @spec session_birth_runtime(String.t(), String.t()) ::
          {:ok, :internal | :external | :new} | {:error, term()}
  def session_birth_runtime(agent_id, session_id) do
    # A resident actor with a durable revision is proof of the internal
    # store; a registered actor still creating its session is not, and that
    # case keeps the probe (#873 round 8: a fork target racing a flip).
    if SalixAgent.InternalSessionActor.resident_durable?(agent_id, session_id) do
      {:ok, :internal}
    else
      probe_session_birth_runtime(agent_id, session_id)
    end
  end

  defp probe_session_birth_runtime(agent_id, session_id) do
    case InternalSessionStore.probe(agent_id, session_id) do
      :present ->
        {:ok, :internal}

      :absent ->
        case ExternalSessionStore.probe(agent_id, session_id) do
          :present -> {:ok, :external}
          :absent -> {:ok, :new}
          {:error, reason} -> {:error, {:unavailable, {:session_probe, reason}}}
        end

      {:error, reason} ->
        {:error, {:unavailable, {:session_probe, reason}}}
    end
  end

  defp internal_only_entry?(entry),
    do: entry[:require_runtime] == :internal or entry["require_runtime"] == :internal

  defp commit_internal_wait_timeout(agent_id, session_id, entry, opts) do
    case InternalSessionFleet.stage_wait_timeout(agent_id, session_id, entry, opts) do
      {:ok, :committed} -> {:ok, :committed, wake_targets(session_id, entry, :internal)}
      {:ok, :duplicate} -> {:ok, :duplicate}
      {:ok, :ignored} -> {:ok, :ignored}
      {:error, _} = err -> err
    end
  end

  defp commit_external_wait_timeout(agent_id, session_id, entry, opts) do
    case ExternalSessionFleet.stage_wait_timeout(
           agent_id,
           session_id,
           external_delivery(entry),
           opts
         ) do
      {:ok, :committed} -> {:ok, :committed, wake_targets(session_id, entry, :external)}
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

  defp stage_external_delivery(agent_id, session_id, entry, opts) do
    case ExternalSessionFleet.stage_delivery(
           agent_id,
           session_id,
           external_delivery(entry),
           opts
         ) do
      {:ok, :committed} ->
        {:ok, :committed, wake_targets(session_id, entry, :external)}

      {:ok, :duplicate} ->
        {:ok, :duplicate}

      # Only reachable in the birth-marker crash window: the marker says
      # external, the winner never created the session, and the agent
      # record has left external — the store's own gate declines. The
      # binding is gone and the session was never born, so the truthful
      # terminal answer is the comma-31 read_only family (plan §1.8 row);
      # nothing was written on either side.
      {:error, :external_runtime_declined_delivery} ->
        {:error, :external_session_read_only}

      {:error, _} = err ->
        err
    end
  end

  defp stage_internal_control(agent_id, session_id, entry, control_kind, opts) do
    case require_internal_runtime(agent_id, session_id, control_kind) do
      :ok ->
        case InternalSessionFleet.stage_control(agent_id, session_id, entry, passive_opts(opts)) do
          {:ok, :committed} -> {:ok, :committed, []}
          {:error, _} = err -> err
        end

      :external_runtime ->
        {:ok, :ignored}

      {:error, _} = err ->
        err
    end
  end

  defp passive_opts(opts), do: Keyword.put(opts, :process_on_init, false)

  # Internal control entries follow the same session-grain authority as
  # deliveries: a control op addressed to an internal-born session applies
  # there even after the agent record flipped external, and one addressed
  # to an external-born session is ignored even if the agent record now
  # says internal (the old agent-record read would have CREATED an internal
  # shell for that id — the same split the round-5 finding reproduced for
  # deliveries). Only a session that exists in neither store (session_create,
  # or a control op racing deletion) falls back to the agent record.
  defp require_internal_runtime(agent_id, session_id, control_kind) do
    case session_birth_runtime(agent_id, session_id) do
      {:error, _} = err ->
        err

      {:ok, :internal} ->
        :ok

      {:ok, :external} ->
        log_internal_control_ignored(agent_id, control_kind)
        :external_runtime

      {:ok, :new} ->
        case runtime_kind(agent_id) do
          {:ok, :internal} ->
            # Internal control ops CREATE missing sessions (the fleet's
            # ensure_started path), so a creating op must claim the birth
            # marker like any other new-session placement — losing to an
            # external birth means ignore, never an internal shell.
            case SessionBirth.claim(agent_id, session_id, :internal) do
              {:ok, :internal} ->
                :ok

              {:ok, :external} ->
                log_internal_control_ignored(agent_id, control_kind)
                :external_runtime

              {:error, _} = err ->
                err
            end

          {:ok, :external} ->
            log_internal_control_ignored(agent_id, control_kind)
            :external_runtime

          {:error, _} = err ->
            err
        end
    end
  end

  defp log_internal_control_ignored(agent_id, control_kind) do
    CommaLog.log("absorb_internal_control_ignored", %{
      agent_id: agent_id,
      kind: control_kind,
      runtime: "external"
    })
  end

  defp runtime_kind(agent_id) do
    case Control.get_record(agent_id) do
      {:ok, agent} ->
        if Control.runtime_kind(agent) == "external", do: {:ok, :external}, else: {:ok, :internal}

      {:error, _} = err ->
        err
    end
  end

  defp wake_targets(_session_id, %{conversation_scan_only: true}, _runtime), do: []

  defp wake_targets(session_id, %{payload: payload}, runtime)
       when runtime in [:internal, :external] do
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

  defp external_delivery(entry) do
    payload = entry.payload || %{}

    payload =
      payload
      |> stringify()
      |> normalize_legacy_schedule_role()

    %{
      source_message_id: entry.source_message_id,
      payload: payload
    }
    |> Map.merge(Map.take(entry, [:conversation_source, :conversation_scan_only]))
  end

  # Agent schedules have always represented user input. Older durable inbox
  # entries predate the explicit external-runtime role contract, so repair only
  # that known missing field at the delivery boundary. Explicit roles,
  # including invalid blank values, still go through normal validation.
  defp normalize_legacy_schedule_role(%{"kind" => "schedule"} = payload) do
    if Map.has_key?(payload, "role"),
      do: payload,
      else: Map.put(payload, "role", "user")
  end

  defp normalize_legacy_schedule_role(payload), do: payload

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

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
