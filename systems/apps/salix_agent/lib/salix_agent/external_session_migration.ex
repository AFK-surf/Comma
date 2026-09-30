defmodule SalixAgent.ExternalSessionMigration do
  @moduledoc false

  alias SalixAgent.{
    AgentControl,
    ExternalRuntime,
    ExternalSessionActor,
    ExternalSessionFleet,
    ExternalSessionStore,
    RuntimeBindingResolver
  }

  alias SalixStore.Repo

  # Operator steps share one existing Postgres transaction lock. A step scans
  # one page or transfers one chunk; it never creates a queue or background job.
  # Serial steps also bound physical-host transfers when registrations differ.
  def run(agent_id, tenant_id, target, operation_id, opts \\ []) do
    with true <-
           is_binary(operation_id) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,128}\z/, operation_id),
         true <- is_map(target) do
      started = System.monotonic_time()
      result = run_step(agent_id, tenant_id, target, operation_id, opts)
      emit_step(result, started)
      result
    else
      _ -> {:error, :invalid_migration_operation}
    end
  end

  # This is the destructive alternative to migration for an owner-approved
  # Worker that cannot be moved. Permanent archive closes every Salix runtime
  # entrypoint first. One call then removes one exact connected-runtime
  # Session from its owning Connector; callers repeat with the Session ids from
  # the bounded status page.
  def archive_unmigratable(agent_id, tenant_id, source, session_id, operation_id)
      when is_map(source) and is_binary(session_id) and is_binary(operation_id) do
    with true <- Regex.match?(~r/\A[a-zA-Z0-9_-]{1,128}\z/, operation_id),
         {:ok, agent} <- AgentControl.get_including_archived(agent_id, tenant_id),
         true <- agent["role"] == "worker",
         true <- agent["runtime_config"] == source,
         true <- source["kind"] in ~w(external connected_runtime),
         true <- source["provider"] in ~w(codex claude pi),
         true <- is_binary(source["device_runtime_id"]) and source["device_runtime_id"] != "",
         {:ok, state} <- ExternalSessionStore.get_session_record(agent_id, session_id),
         true <- get_in(state, ["runtime", "binding"]) == source,
         token when is_binary(token) and token != "" <- state["runtime_capability_token"],
         {:ok, archived} <- AgentControl.archive_permanently(agent_id, tenant_id),
         {:ok, binding} <-
           RuntimeBindingResolver.resolve(source, agent["tenant_id"], agent["group_id"]),
         {:ok, %{"phase" => "discarded"} = result} <-
           ExternalRuntime.migration(%{
             action: "discard",
             binding: Map.merge(source, binding),
             params: %{
               "operation_id" => operation_id,
               "session_id" => session_id,
               "provider" => source["provider"],
               "source" => source["device_runtime_id"],
               "destination" => "permanent-archive:" <> agent_id,
               "capability_token" => token
             },
             tenant_id: agent["tenant_id"],
             group_id: agent["group_id"],
             timeout: 1_800_000
           }) do
      {:ok,
       %{
         phase: result["phase"],
         archived_at: archived["archived_at"],
         agent_id: agent_id,
         session_id: session_id
       }}
    else
      false -> {:error, :archive_discard_scope_mismatch}
      nil -> {:error, :archive_discard_scope_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :archive_discard_unconfirmed}
    end
  end

  def archive_unmigratable(_, _, _, _, _), do: {:error, :invalid_migration_operation}

  defp run_step(agent_id, tenant_id, target, operation_id, opts) do
    Repo.transaction(
      fn ->
        case Repo.query!("SELECT pg_try_advisory_xact_lock(4412741, 3)").rows do
          [[true]] -> step(agent_id, tenant_id, target, operation_id, opts)
          _ -> {:error, :migration_transfer_busy}
        end
      end,
      timeout: 1_830_000
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_step(result, started) do
    Salix.Telemetry.emit_operation(
      "salix_agent",
      "external_session_migration",
      SystemsObservability.Context.current_surface(),
      if(match?({:ok, _}, result), do: :ok, else: :error),
      System.monotonic_time() - started
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp step(agent_id, tenant_id, target, operation_id, opts) do
    with {:ok, agent} <- AgentControl.get(agent_id, tenant_id),
         {:ok, agent} <- freeze(agent, target, operation_id),
         freeze = agent["session_admission"] do
      cond do
        freeze == nil ->
          phase =
            if agent["runtime_config"]["workload_id"] == target["workload_id"],
              do: "committed",
              else: "cancelled"

          {:ok, %{phase: phase, complete: true}}

        Keyword.get(opts, :cancel, false) or freeze["cancel_phase"] != nil ->
          cancel_batch(agent, operation_id)

        is_binary(freeze["session_id"]) ->
          with {:ok, state} <-
                 ExternalSessionStore.get_session_record(agent_id, freeze["session_id"]) do
            session_step(agent, state, operation_id, opts)
          end

        true ->
          select_session(agent, operation_id)
      end
    end
  end

  defp freeze(agent, target, operation_id) do
    cond do
      agent["binding_command_id"] == operation_id and agent["session_admission"] == nil ->
        {:ok, agent}

      true ->
        existing = agent["session_admission"] || %{}
        source = existing["source"] || agent["runtime_config"]
        target = Map.put_new(target, "binding_revision", (source["binding_revision"] || 0) + 1)

        case AgentControl.freeze_session_creation(
               agent["agent_id"],
               agent["tenant_id"],
               operation_id,
               source,
               target
             ) do
          {:ok, %{record: record}} ->
            {:ok, record}

          {:error, {:session_admission_pending, %{"kind" => "birth"}}} ->
            with {:ok, current} <- AgentControl.get_record(agent["agent_id"]),
                 {:ok, _} <- ExternalSessionStore.complete_reserved_birth(current),
                 {:ok, %{record: record}} <-
                   AgentControl.freeze_session_creation(
                     agent["agent_id"],
                     agent["tenant_id"],
                     operation_id,
                     source,
                     target
                   ),
                 do: {:ok, record}

          error ->
            error
        end
    end
  end

  defp select_session(agent, operation_id) do
    freeze = agent["session_admission"]
    cursor = freeze["cursor"]

    with {:ok, %{records: records, next: next}} <-
           ExternalSessionStore.migration_page(agent["agent_id"], cursor) do
      unfinished =
        Enum.find(records, fn state ->
          get_in(state, ["migration", "phase"]) != "committed" and
            get_in(state, ["runtime", "binding", "workload_id"]) !=
              freeze["target"]["workload_id"]
        end)

      cond do
        unfinished != nil ->
          with {:ok, %{record: selected}} <-
                 AgentControl.select_migration_session(
                   agent["agent_id"],
                   agent["tenant_id"],
                   operation_id,
                   unfinished["session_id"],
                   cursor
                 ) do
            session_step(selected, unfinished, operation_id, [])
          end

        next != nil ->
          with {:ok, _} <-
                 AgentControl.select_migration_session(
                   agent["agent_id"],
                   agent["tenant_id"],
                   operation_id,
                   nil,
                   next
                 ),
               do: {:ok, %{phase: "scanning", complete: false}}

        true ->
          with {:ok, _} <-
                 AgentControl.finish_session_migration(
                   agent["agent_id"],
                   agent["tenant_id"],
                   operation_id,
                   freeze["target"]
                 ),
               do: {:ok, %{phase: "committed", complete: true}}
      end
    end
  end

  defp session_step(agent, state, operation_id, opts) do
    session_id = state["session_id"]

    with {:ok, pid} <-
           ExternalSessionFleet.ensure_started(agent["agent_id"], session_id,
             process_on_init: false
           ),
         {:ok, state} <- begin_migration(agent, state, operation_id, pid) do
      result =
        if Keyword.get(opts, :cancel, false) or
             get_in(state, ["migration", "error"]) == "cancelling" do
          cancel(agent, state, operation_id, pid)
        else
          advance(agent, state, operation_id, pid, opts)
        end

      case result do
        {:error, reason} = error ->
          if get_in(state, ["migration", "error"]) != "cancelling" do
            _ =
              ExternalSessionActor.migration_command(pid, operation_id, :error, %{
                "error" => inspect(reason, limit: 5, printable_limit: 500)
              })
          end

          error

        other ->
          other
      end
    end
  end

  defp begin_migration(
         _agent,
         %{"migration" => %{"operation_id" => operation_id}} = state,
         operation_id,
         _pid
       ),
       do: {:ok, state}

  defp begin_migration(agent, state, operation_id, pid) do
    source = get_in(state, ["runtime", "binding"])
    target = get_in(agent, ["session_admission", "target"])
    provider = source["provider"]

    if source["kind"] in ~w(external connected_runtime) and provider in ~w(codex claude pi) and
         provider == get_in(target, ["runtime_spec", "provider"]) do
      ExternalSessionActor.migration_command(pid, operation_id, :begin, %{
        "source" => source,
        "target" => target
      })
    else
      {:error, :unsupported_session_migration_source}
    end
  end

  defp advance(agent, state, operation_id, pid, opts) do
    case state["migration"]["phase"] do
      "draining" ->
        with :ok <- deadline(state),
             {:ok, %{"phase" => "prepared"}} <- transport(agent, state, :source, "prepare", %{}),
             {:ok, staged} <- ExternalSessionActor.migration_command(pid, operation_id, :staged) do
          progress(staged)
        end

      "staged" ->
        with :ok <- deadline(state),
             {:ok, target} <- transport(agent, state, :target, "status", %{}) do
          if target["phase"] == "staged" do
            with {:ok, retiring} <-
                   ExternalSessionActor.migration_command(pid, operation_id, :retiring),
                 do: progress(retiring)
          else
            offset = target["next_offset"] || 0

            with {:ok, chunk} <- transport(agent, state, :source, "export", %{"offset" => offset}),
                 {:ok, receipt} <-
                   transport(
                     agent,
                     state,
                     :target,
                     "import",
                     Map.take(chunk, ~w(data offset done))
                   ) do
              {:ok,
               %{
                 session_id: state["session_id"],
                 phase: "staged",
                 transferred: receipt["next_offset"],
                 complete: false
               }}
            end
          end
        end

      "retiring" ->
        with {:ok, status} <- transport(agent, state, :source, "status", %{}),
             :ok <- retire_source(agent, state, status),
             {:ok, %{"phase" => "activated"}} <-
               transport(agent, state, :target, "import", %{
                 "activate" => true,
                 "repair" => Keyword.get(opts, :repair, false)
               }),
             {:ok, committed} <-
               ExternalSessionActor.migration_command(pid, operation_id, :commit) do
          _ =
            ExternalSessionStore.revoke_runtime_capability_by_hash(
              state["runtime_capability_token_hash"]
            )

          ExternalSessionActor.wake(agent["agent_id"], state["session_id"])
          progress(committed)
        end

      "committed" ->
        with {:ok, _} <-
               AgentControl.select_migration_session(
                 agent["agent_id"],
                 agent["tenant_id"],
                 operation_id,
                 nil,
                 agent["session_admission"]["cursor"]
               ),
             do: {:ok, %{session_id: state["session_id"], phase: "committed", complete: false}}
    end
  end

  defp retire_source(_agent, _state, %{"phase" => "retired"}), do: :ok

  defp retire_source(agent, state, %{"phase" => "prepared"}) do
    case transport(agent, state, :source, "retire", %{}) do
      {:ok, %{"phase" => "retired"}} -> :ok
      {:error, reason} -> {:error, {:retire_outcome_unknown, reason}}
      _ -> {:error, :retire_unconfirmed}
    end
  end

  defp retire_source(_, _, _), do: {:error, :source_seal_missing_after_retiring}

  # A preflight pass excludes irreversible Sessions before any source is resumed.
  # Creation remains frozen throughout both bounded, replayable passes.
  defp cancel_batch(agent, operation_id) do
    freeze = agent["session_admission"]
    phase = freeze["cancel_phase"] || "checking"

    with {:ok, %{records: records, next: next}} <-
           ExternalSessionStore.migration_page(agent["agent_id"], freeze["cancel_cursor"]) do
      migrations =
        Enum.filter(records, &(get_in(&1, ["migration", "operation_id"]) == operation_id))

      cond do
        Enum.any?(migrations, &(get_in(&1, ["migration", "phase"]) in ~w(retiring committed))) ->
          with {:ok, _} <- cancel_cursor(agent, operation_id, nil, nil),
               do: {:error, :migration_requires_forward_repair}

        phase == "checking" ->
          with {:ok, _} <-
                 cancel_cursor(
                   agent,
                   operation_id,
                   if(next, do: "checking", else: "cancelling"),
                   next
                 ),
               do: {:ok, %{phase: "checking_cancellation", complete: false}}

        migrations != [] ->
          state = hd(migrations)

          with {:ok, pid} <-
                 ExternalSessionFleet.ensure_started(agent["agent_id"], state["session_id"],
                   process_on_init: false
                 ) do
            cancel(agent, state, operation_id, pid)
          end

        next != nil ->
          with {:ok, _} <- cancel_cursor(agent, operation_id, "cancelling", next),
               do: {:ok, %{phase: "cancelling", complete: false}}

        true ->
          with {:ok, _} <- cancel_cursor(agent, operation_id, :complete, nil),
               do: {:ok, %{phase: "cancelled", complete: true}}
      end
    end
  end

  defp cancel_cursor(agent, operation_id, phase, cursor),
    do:
      AgentControl.cancel_session_migration(
        agent["agent_id"],
        agent["tenant_id"],
        operation_id,
        phase,
        cursor
      )

  defp cancel(agent, state, operation_id, pid) do
    if state["migration"]["phase"] in ~w(draining staged) do
      with {:ok, _} <-
             ExternalSessionActor.migration_command(pid, operation_id, :error, %{
               "error" => "cancelling"
             }),
           {:ok, %{"phase" => "cancelled"}} <-
             transport(agent, state, :target, "prepare", %{"cancel" => true}),
           {:ok, %{"phase" => "cancelled"}} <-
             transport(agent, state, :source, "prepare", %{"cancel" => true}),
           {:ok, _} <- ExternalSessionActor.migration_command(pid, operation_id, :cancel) do
        ExternalSessionActor.wake(agent["agent_id"], state["session_id"])
        {:ok, %{session_id: state["session_id"], phase: "cancelled", complete: false}}
      end
    else
      {:error, :migration_requires_forward_repair}
    end
  end

  defp transport(agent, state, side, action, extra) do
    migration = state["migration"]
    stable = migration[Atom.to_string(side)]

    resolved =
      if side == :source,
        do: RuntimeBindingResolver.resolve(stable, agent["tenant_id"], agent["group_id"]),
        else: {:ok, stable}

    with {:ok, binding} <- resolved do
      params = %{
        "operation_id" => migration["operation_id"],
        "session_id" => state["session_id"],
        "provider" => migration["source"]["provider"],
        "source" => migration["source"]["device_runtime_id"],
        "destination" => migration["target"]["workload_id"],
        "deadline" => migration["deadline"]
      }

      params =
        if side == :source,
          do: Map.put(params, "capability_token", state["runtime_capability_token"]),
          else: params

      ExternalRuntime.migration(%{
        action: action,
        binding: Map.merge(stable, binding),
        params: Map.merge(params, extra),
        tenant_id: agent["tenant_id"],
        group_id: agent["group_id"],
        timeout: 1_800_000
      })
    end
  end

  defp deadline(state) do
    if System.system_time(:millisecond) < state["migration"]["deadline"],
      do: :ok,
      else: {:error, :migration_deadline_elapsed}
  end

  defp progress(state),
    do:
      {:ok,
       %{session_id: state["session_id"], phase: state["migration"]["phase"], complete: false}}
end
