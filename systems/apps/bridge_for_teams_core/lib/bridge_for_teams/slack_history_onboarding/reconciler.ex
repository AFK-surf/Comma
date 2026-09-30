defmodule BridgeForTeams.SlackHistoryOnboarding.Reconciler do
  @moduledoc """
  Bounded, restart-safe driver for Slack-history import runs.

  PostgreSQL run state, page receipts/checkpoints, snapshot identity, and
  derivation leases own correctness. This process is only a doorbell: each
  invocation advances at most one durable transition. A crash loses no
  accepted work. Another replica may repeat an external read, but only a result
  accepted by the existing generation, receipt-hash, and derivation-lease
  fences can advance persisted state.

  Protocol transitions remain anchored by `tla/salix/SlackHistoryImport.tla`;
  this driver introduces no second workflow state machine.
  """

  use GenServer

  import Ecto.Query
  require Logger

  alias BridgeForTeams.{Repo, SlackHistoryImports}
  alias BridgeForTeams.Schema.SlackHistoryImportRun
  alias BridgeForTeams.SourcedContext.{Derivations, SlackAcquisition}

  @name __MODULE__
  @default_interval_ms 5_000
  @active_states ~w(created acquiring paused acquired deriving)
  @settled_states ~w(preview_ready committed canceled rolled_back failed_terminal stale_source)

  @derivation_evidence_fields [
    :model_provider,
    :model_id,
    :model_revision,
    :prompt_template_id,
    :prompt_revision,
    :policy_revision,
    :schema_revision
  ]

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    if enabled?(), do: GenServer.start_link(__MODULE__, opts, name: @name), else: :ignore
  end

  @doc "Wake the background driver after a run is created."
  @spec notify(Ecto.UUID.t()) :: :ok
  def notify(run_id) when is_binary(run_id) do
    if Process.whereis(@name), do: GenServer.cast(@name, {:run, run_id})
    :ok
  end

  def notify(_run_id), do: :ok

  @doc "Whether the production background driver is configured to run."
  @spec configured?() :: boolean()
  def configured?, do: enabled?()

  @doc "Whether the driver has an approved processor and immutable extraction evidence."
  @spec processor_configured?() :: boolean()
  def processor_configured? do
    valid_derivation_evidence?(config(:derivation_evidence, nil)) and
      valid_processor?(Application.get_env(:bridge_for_teams_core, :sourced_context_processor))
  end

  @doc "Advance one selected or oldest runnable import by at most one durable step."
  @spec run_once(keyword()) :: {:ok, map()} | {:error, term()}
  def run_once(opts \\ []) do
    with {:ok, run} <- select_run(opts) do
      advance(run, opts)
    end
  end

  @doc "Deterministic local/test helper; production scheduling still calls `run_once/1`."
  @spec run_until_idle(keyword()) :: {:ok, map()} | {:error, term()}
  def run_until_idle(opts \\ []) do
    max_steps = Keyword.get(opts, :max_steps, 20)

    if is_integer(max_steps) and max_steps > 0,
      do: do_run_until_idle(opts, max_steps),
      else: {:error, :invalid_step_bound}
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms))

    state = %{
      interval_ms: interval_ms,
      task: nil,
      timer_ref: nil,
      preferred_run_id: nil
    }

    {:ok, schedule_drain(state, 0)}
  end

  @impl true
  def handle_cast({:run, run_id}, %{task: nil} = state) do
    {:noreply, start_drain(%{state | preferred_run_id: run_id})}
  end

  def handle_cast({:run, run_id}, state),
    do: {:noreply, %{state | preferred_run_id: state.preferred_run_id || run_id}}

  @impl true
  def handle_info(:drain, %{task: nil} = state),
    do: {:noreply, start_drain(%{state | timer_ref: nil})}

  def handle_info(:drain, state), do: {:noreply, %{state | timer_ref: nil}}

  def handle_info({ref, result}, %{task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    log_result(result)

    delay = if match?({:ok, %{advanced?: true}}, result), do: 0, else: state.interval_ms
    next_state = %{state | task: nil, preferred_run_id: nil}
    {:noreply, schedule_drain(next_state, delay)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state) do
    Logger.warning("slack_history_reconciler_worker_down reason=#{reason_class(reason)}")
    {:noreply, state |> Map.put(:task, nil) |> schedule_drain(state.interval_ms)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp start_drain(state) do
    state = cancel_scheduled_drain(state)
    preferred_run_id = state.preferred_run_id

    task =
      Task.Supervisor.async_nolink(BridgeForTeams.TaskSupervisor, fn ->
        if preferred_run_id, do: run_once(run_id: preferred_run_id), else: run_once()
      end)

    %{state | task: task.ref}
  end

  defp schedule_drain(state, delay_ms) do
    state = cancel_scheduled_drain(state)
    %{state | timer_ref: Process.send_after(self(), :drain, delay_ms)}
  end

  defp cancel_scheduled_drain(%{timer_ref: nil} = state), do: state

  defp cancel_scheduled_drain(%{timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | timer_ref: nil}
  end

  defp do_run_until_idle(opts, remaining) do
    with {:ok, run} <- current_run(opts) do
      if run.state in @settled_states do
        {:ok, %{run_id: run.id, state: run.state, steps_remaining: remaining}}
      else
        case run_once(opts) do
          {:ok, %{state: state}} when state in @settled_states ->
            {:ok, %{run_id: run.id, state: state, steps_remaining: remaining - 1}}

          {:ok, _result} when remaining > 1 ->
            do_run_until_idle(opts, remaining - 1)

          {:ok, result} ->
            {:error, {:step_bound_reached, result}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp current_run(opts) do
    case Keyword.get(opts, :run_id) do
      id when is_binary(id) -> SlackHistoryImports.get_run(id)
      _missing -> {:error, :run_id_required}
    end
  end

  defp select_run(opts) do
    case Keyword.get(opts, :run_id) do
      id when is_binary(id) -> SlackHistoryImports.get_run(id)
      nil -> oldest_runnable()
      _invalid -> {:error, :invalid_run_id}
    end
  end

  defp oldest_runnable do
    now = DateTime.utc_now()

    case Repo.one(
           from(run in SlackHistoryImportRun,
             where:
               run.state in ^@active_states and
                 (run.state != "paused" or run.paused_reason != "bound_reached") and
                 (is_nil(run.retry_not_before) or run.retry_not_before <= ^now),
             order_by: [asc: run.updated_at, asc: run.id],
             limit: 1
           )
         ) do
      nil -> {:error, :no_runnable_import}
      run -> SlackHistoryImports.get_run(run.id)
    end
  end

  defp advance(%SlackHistoryImportRun{state: "created"} = run, _opts) do
    transition_result(run, SlackHistoryImports.start_acquisition(run.id, run.generation))
  end

  defp advance(%SlackHistoryImportRun{state: "acquiring"} = run, _opts) do
    case SlackAcquisition.acquire_one_page(run.id, run.generation) do
      {:ok, :ready_to_finalize} ->
        transition_result(
          run,
          SlackAcquisition.finalize(run.id, run.generation, "slack-normalization:v1")
        )

      {:ok, _receipt} ->
        latest_result(run.id, true)

      {:ok, next_run, _event} ->
        result(run, next_run, true)

      {:error, reason} ->
        normalize_race(run.id, reason)
    end
  end

  defp advance(%SlackHistoryImportRun{state: "paused", resume_phase: "acquiring"} = run, _opts) do
    if run.paused_reason == "bound_reached",
      do: result(run, run, false),
      else: transition_result(run, SlackHistoryImports.resume(run.id, run.generation))
  end

  defp advance(%SlackHistoryImportRun{state: "acquired"} = run, opts) do
    with {:ok, evidence} <- derivation_evidence(opts),
         {:ok, evidence} <- Derivations.prepare_evidence(run.id, evidence, opts) do
      attrs =
        evidence
        |> Map.put(:expected_generation, run.generation)
        |> Map.put(:requested_by_user_id, run.requested_by_user_id)
        |> Map.put(:client_request_id, derivation_request_id(evidence))

      case Derivations.request(run.id, attrs) do
        {:ok, %{run: next_run}} -> result(run, next_run, true)
        {:error, reason} -> normalize_race(run.id, reason)
      end
    end
  end

  defp advance(%SlackHistoryImportRun{state: "deriving"} = run, opts) do
    process_derivation(run, opts)
  end

  defp advance(%SlackHistoryImportRun{state: "paused", resume_phase: "deriving"} = run, opts) do
    process_derivation(run, opts)
  end

  defp advance(%SlackHistoryImportRun{} = run, _opts) do
    {:ok, %{run_id: run.id, state: run.state, advanced?: false}}
  end

  defp process_derivation(run, opts) do
    processor_opts =
      case Keyword.fetch(opts, :processor) do
        {:ok, processor} -> [processor: processor]
        :error -> []
      end

    worker_id = "slack-history:#{node()}:#{System.unique_integer([:positive])}"

    case Derivations.process(run.derivation_id, worker_id, processor_opts) do
      {:ok, %{run: next_run}} -> result(run, next_run, true)
      {:error, reason} -> normalize_race(run.id, reason)
    end
  end

  defp transition_result(run, {:ok, next_run, _event}), do: result(run, next_run, true)
  defp transition_result(run, {:error, reason}), do: normalize_race(run.id, reason)

  defp result(previous, next, advanced?) do
    {:ok,
     %{
       run_id: next.id,
       previous_state: previous.state,
       state: next.state,
       generation: next.generation,
       advanced?: advanced?
     }}
  end

  defp latest_result(run_id, advanced?) do
    with {:ok, latest} <- SlackHistoryImports.get_run(run_id) do
      {:ok,
       %{
         run_id: latest.id,
         state: latest.state,
         generation: latest.generation,
         advanced?: advanced?
       }}
    end
  end

  defp normalize_race(run_id, reason)
       when reason in [:stale_run_generation, :stale_derivation_lease, :derivation_not_processing] do
    latest_result(run_id, false)
  end

  defp normalize_race(run_id, {:invalid_transition, _state, _command}),
    do: latest_result(run_id, false)

  defp normalize_race(_run_id, reason), do: {:error, reason}

  defp derivation_evidence(opts) do
    evidence =
      Keyword.get(opts, :derivation_evidence) ||
        config(:derivation_evidence, nil)

    if is_map(evidence), do: {:ok, evidence}, else: {:error, :derivation_not_configured}
  end

  defp derivation_request_id(evidence) do
    digest =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(evidence, [:deterministic]))
      |> Base.encode16(case: :lower)

    "initial-preview:" <> binary_part(digest, 0, 32)
  end

  defp log_result({:ok, %{advanced?: false}}), do: :ok

  defp log_result({:ok, %{run_id: run_id, state: state}}) do
    Logger.info("slack_history_reconciler_advanced run_id=#{run_id} state=#{state}")
  end

  defp log_result({:error, :no_runnable_import}), do: :ok

  defp log_result({:error, reason}) do
    Logger.warning("slack_history_reconciler_failed reason=#{reason_class(reason)}")
  end

  defp reason_class({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(%{__struct__: module}), do: module |> Module.split() |> List.last()
  defp reason_class(_reason), do: "external_error"

  defp config(key, default) do
    :bridge_for_teams_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp valid_derivation_evidence?(evidence) when is_map(evidence) do
    Enum.all?(@derivation_evidence_fields, fn field ->
      case Map.get(evidence, field, Map.get(evidence, Atom.to_string(field))) do
        value when is_binary(value) -> String.trim(value) != "" and byte_size(value) <= 256
        _other -> false
      end
    end)
  end

  defp valid_derivation_evidence?(_evidence), do: false

  defp valid_processor?(processor) do
    is_atom(processor) and not is_nil(processor) and Code.ensure_loaded?(processor) and
      function_exported?(processor, :derive, 1)
  end

  defp enabled?, do: config(:enabled, false)
end
