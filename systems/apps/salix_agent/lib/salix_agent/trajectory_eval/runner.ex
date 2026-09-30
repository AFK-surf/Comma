defmodule SalixAgent.TrajectoryEval.Runner do
  @moduledoc """
  Post-round trajectory eval orchestration.

  `maybe_eval_async/3` is called from the round chokepoint after a round
  settles (`:final`) or fails. It is a pure side channel: gated by
  `:salix_agent, :trajectory_eval` config (`enabled`, `sample_rate`,
  `window_limit`), runs on `SalixAgent.TaskSup` off the session owner
  process, and swallows every failure. It must never affect the round.

  The eval itself reads the committed session, scores the activation window
  with `SalixAgent.TrajectoryEval`, persists the entry for the dashboard
  (`TrajectoryEval.Store`) and hands a fact to the analytics recorder seam
  (`TrajectoryEval.Recorder`).

  Repeated identical results are debounced: the store merges consecutive
  same-signature entries (see `Store.append/3`) and the recorder fact is only
  emitted when the signature *changes* — a session settling the same flagged
  way round after round produces one analytics row, not a flood. Persistence
  is escalated instead: crossing #{inspect([3, 10, 25, 50, 100])} repeats of a
  flagged result logs a warning.

  The L2 LLM judge (`TrajectoryEval.Judge`) piggybacks on the same debounce:
  it runs only on signature changes, only when `judge_enabled` is set, and —
  for clean windows — only at `judge_clean_sample_rate`. Judge failures are
  logged and never affect the stored L1 entry.

  `judge_enabled`, `judge_clean_sample_rate` and `judge_provider` (which model
  judges) are resolved per tenant: the global `:salix_agent,:trajectory_eval`
  config is the default, and a tenant's dashboard override (via
  `TrajectoryEval.TenantSettings`) wins for the keys it sets. The judge spends
  the tenant's LLM credit, so each tenant opts in independently; the free L1
  gate stays purely global. `judge_provider` names an entry in the
  `TrajectoryEval.JudgeProviders` allowlist. With nothing selected anywhere the
  judge inherits the agent template's analyze model; but a selection that no
  longer resolves (ops revoked the model out from under a tenant) SKIPS the
  paid judge rather than quietly substituting a different provider.

  Because that gate is paid, it FAILS CLOSED: when the per-tenant seam is
  configured but the tenant's setting can't be read (control-plane error, or an
  unresolvable tenant), the judge is skipped rather than run under the global
  default — an outage must never override an explicit opt-out. L1 is persisted
  regardless.
  """

  require Logger

  alias SalixAgent.{
    AgentRuntimeConfig,
    DependencyRunner,
    InternalSession,
    InternalSessionStore,
    TrajectoryEval
  }

  alias SalixAgent.TrajectoryEval.{Judge, JudgeProviders, Recorder, Store, TenantSettings}

  @evaluator "heuristic"
  @evaluator_version "1"

  @spec maybe_eval_async(map(), String.t(), term()) :: :ok | :skip
  def maybe_eval_async(context, session_id, outcome) do
    cfg = config()

    cond do
      not eligible_outcome?(outcome) ->
        :skip

      not Keyword.get(cfg, :enabled, false) ->
        :skip

      not sampled?(l1_rate(Keyword.get(cfg, :sample_rate, 1.0))) ->
        :skip

      true ->
        agent_id = context.agent_id

        _ =
          Task.Supervisor.start_child(SalixAgent.TaskSup, fn ->
            eval_now(agent_id, session_id, outcome, :dependency)
          end)

        :ok
    end
  end

  @doc """
  Evaluate the current activation window of a committed session and persist
  the results. Safe to call directly (tests, backfills); errors are returned,
  not raised.
  """
  @spec eval_now(String.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def eval_now(agent_id, session_id, outcome),
    do: eval_now(agent_id, session_id, outcome, :inline)

  defp eval_now(agent_id, session_id, outcome, judge_mode) do
    with {:ok, state} <- InternalSessionStore.read(agent_id, session_id) do
      result =
        TrajectoryEval.evaluate(InternalSession.get(state, :messages),
          window_limit: Keyword.get(config(), :window_limit)
        )

      entry = entry(result, outcome)

      with {:ok, stored} <- Store.append(agent_id, session_id, entry) do
        case stored["repeats"] || 1 do
          1 ->
            _ = Recorder.record(fact(agent_id, session_id, state, result, outcome))
            _ = maybe_judge(agent_id, session_id, state, result, outcome, stored, judge_mode)

          repeats ->
            maybe_warn_persistent(agent_id, session_id, stored, repeats)
        end

        {:ok, stored}
      end
    end
  rescue
    exception ->
      Logger.warning(
        "trajectory eval failed agent=#{agent_id} session=#{session_id}: " <>
          Exception.message(exception)
      )

      {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp eligible_outcome?(:final), do: true
  defp eligible_outcome?({:error, _}), do: true
  defp eligible_outcome?(_), do: false

  # Escalation for findings that persist across settles (a debounced entry is
  # otherwise silent): warn when the repeat count crosses a threshold. Clean
  # results repeating is a healthy long-lived session — never warned.
  @escalation_repeats [3, 10, 25, 50, 100]

  defp maybe_warn_persistent(agent_id, session_id, stored, repeats) do
    findings = stored["findings"] || []

    if findings != [] and repeats in @escalation_repeats do
      metrics = Enum.map_join(findings, ",", & &1["metric"])

      Logger.warning(
        "trajectory eval finding persists across #{repeats} settles " <>
          "agent=#{agent_id} session=#{session_id} metrics=#{metrics} " <>
          "since=#{stored["first_evaluated_at"]}"
      )
    end

    :ok
  end

  # ---- L2 LLM judge ----

  defp maybe_judge(agent_id, session_id, state, result, outcome, stored, judge_mode) do
    {tenant_id, group_id} = tenant_group(agent_id)
    tenant = tenant_id || tenant_from_context(state)

    case judge_config(tenant) do
      :unavailable ->
        # Fail closed: the judge spends the tenant's LLM credit, so it must not
        # run when the tenant's own on/off choice can't be read. Treating an
        # outage as the global default would silently override an explicit
        # opt-out. L1 is already persisted; only the paid step is skipped.
        Logger.warning(
          "trajectory judge skipped (tenant settings unavailable) " <>
            "agent=#{agent_id} session=#{session_id}"
        )

        :skip

      {:ok, cfg} ->
        clean? = result.findings == []

        cond do
          not cfg.judge_enabled ->
            :skip

          # A model WAS selected but is no longer in the allowlist (ops revoked
          # or renamed it). Inheriting the template model here would silently
          # send this transcript to a *different* paid provider than the one
          # that was approved — so keep L1 and skip the paid judge instead.
          match?({:invalid, _source, _value}, cfg.judge_provider) ->
            Logger.warning(
              "trajectory judge skipped (selected model not in the allowlist) " <>
                "agent=#{agent_id} session=#{session_id}"
            )

            :skip

          clean? and not sampled?(cfg.judge_clean_sample_rate) ->
            :skip

          true ->
            judge_args = [
              agent_id,
              session_id,
              state,
              result,
              outcome,
              stored,
              tenant_id,
              group_id,
              provider_key(cfg.judge_provider)
            ]

            case judge_mode do
              :dependency -> schedule_judge(tenant || "agent:" <> agent_id, judge_args)
              :inline -> apply(__MODULE__, :run_judge_inline, judge_args)
            end
        end
    end
  end

  defp provider_key({:ok, key, _source}), do: key
  defp provider_key(nil), do: nil

  defp schedule_judge(tenant_id, judge_args) do
    [agent_id, session_id, _state, _result, _outcome, stored | _rest] = judge_args
    signature = stored["signature"] || stored[:signature] || stored["evaluated_at"]

    case DependencyRunner.start(
           :llm,
           tenant_id,
           fn -> apply(__MODULE__, :run_judge_inline, judge_args) end,
           key: {:trajectory_judge, agent_id, session_id, signature},
           label: {:trajectory_judge, agent_id, session_id}
         ) do
      :ok ->
        :ok

      {:error, :dependency_already_running} ->
        :skip

      {:error, :dependency_saturated} ->
        :skip

      {:error, reason} ->
        Logger.warning(
          "trajectory judge dependency could not start agent=#{agent_id} " <>
            "session=#{session_id}: #{inspect(reason)}"
        )

        :error
    end
  end

  @doc false
  def run_judge_inline(
        agent_id,
        session_id,
        state,
        result,
        outcome,
        stored,
        tenant_id,
        group_id,
        judge_provider
      ) do
    case Judge.run(agent_id, session_id, state, result, judge_provider: judge_provider) do
      {:ok, judge} ->
        _ = Store.attach_judge(agent_id, session_id, stored, judge)

        _ =
          Recorder.record(
            judge_fact(agent_id, session_id, state, judge, result, outcome, tenant_id, group_id)
          )

        :ok

      {:error, reason} ->
        Logger.warning(
          "trajectory judge failed agent=#{agent_id} session=#{session_id}: " <> inspect(reason)
        )

        :error
    end
  end

  # Effective judge gate: the global config default, with the tenant's dashboard
  # override winning per key. Returns `:unavailable` when the per-tenant seam is
  # configured but the tenant's setting can't be read (or the tenant can't be
  # resolved) — the caller fails closed. With no seam configured (`:no_impl`),
  # there is no per-tenant opt-out to honor, so the global default applies.
  defp judge_config(tenant_id) do
    global = config()

    case TenantSettings.resolve(tenant_id) do
      :no_impl -> {:ok, effective_config(global, %{})}
      {:ok, overrides} -> {:ok, effective_config(global, overrides)}
      {:error, _reason} -> :unavailable
    end
  end

  defp effective_config(global, overrides) do
    %{
      judge_enabled:
        pick_bool(overrides["judge_enabled"], Keyword.get(global, :judge_enabled, false)),
      judge_clean_sample_rate:
        clean_rate(overrides, Keyword.get(global, :judge_clean_sample_rate, 0.0)),
      # The shared missing/known/invalid contract — the dashboard resolves the
      # SAME function, so what the page claims is what this gate does. An
      # invalid selection (revoked tenant pick, or a stale explicit global)
      # skips the paid judge above rather than substituting a model; only a
      # truly absent selection inherits the template analyze model.
      judge_provider:
        JudgeProviders.resolve_selection(
          overrides["judge_provider"],
          Keyword.get(global, :judge_provider)
        )
    }
  end

  defp pick_bool(value, _default) when is_boolean(value), do: value
  defp pick_bool(_value, default), do: default

  # Resolve the paid clean-window sample rate. A *missing* override inherits the
  # (validated) global default; a *present-but-invalid* override fails closed to
  # 0.0 rather than silently inheriting a possibly-higher global — an explicit
  # `-1`/`2` must not become maximum paid sampling. An invalid global is 0.0.
  defp clean_rate(overrides, global_value) do
    case Map.fetch(overrides, "judge_clean_sample_rate") do
      :error -> if probability?(global_value), do: global_value, else: 0.0
      {:ok, value} -> if probability?(value), do: value, else: 0.0
    end
  end

  # The free L1 rate has no per-tenant override; an invalid config value keeps
  # L1 running (default 1.0) rather than silently disabling it.
  defp l1_rate(value), do: if(probability?(value), do: value, else: 1.0)

  # Sample with probability `rate`: run iff U < rate, skip iff U >= rate. The
  # endpoints are decided WITHOUT the RNG (0.0 never runs, 1.0 always runs) so
  # correctness never depends on the exact open/closed range of :rand.uniform/0,
  # which can return 0.0 for some generator states.
  defp sampled?(rate) when rate <= 0.0, do: false
  defp sampled?(rate) when rate >= 1.0, do: true
  defp sampled?(rate), do: :rand.uniform() < rate

  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1

  # The authoritative tenant comes from the control record (tenant_group/1);
  # fall back to the session's billing context so the gate still resolves for
  # sessions whose agent record can't be read at eval time.
  defp tenant_from_context(state) do
    case InternalSession.get(state, :billing_context) do
      %{} = billing_context -> billing_context["salix_tenant_id"]
      _other -> nil
    end
  end

  defp judge_fact(agent_id, session_id, state, judge, result, outcome, tenant_id, group_id) do
    findings =
      for verdict <- judge["verdicts"] || [] do
        %{
          metric: verdict["metric"],
          score: verdict["score"],
          hits: 1,
          verdict: verdict["verdict"],
          reason: verdict["reason"],
          evidence: [%{quote: verdict["evidence"]}]
        }
      end

    %{
      agent_id: agent_id,
      session_id: session_id,
      tenant_id: tenant_id,
      group_id: group_id,
      billing_context: InternalSession.get(state, :billing_context) || %{},
      outcome: outcome_label(outcome),
      evaluator: "judge",
      evaluator_version: judge["prompt_version"],
      window: result.window,
      findings: findings
    }
  end

  defp entry(result, outcome) do
    %{
      "evaluated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "evaluator" => @evaluator,
      "evaluator_version" => @evaluator_version,
      "outcome" => outcome_label(outcome),
      "window" => stringify(result.window),
      "findings" => Enum.map(result.findings, &stringify/1)
    }
  end

  defp fact(agent_id, session_id, state, result, outcome) do
    {tenant_id, group_id} = tenant_group(agent_id)
    billing_context = InternalSession.get(state, :billing_context) || %{}

    %{
      agent_id: agent_id,
      session_id: session_id,
      tenant_id: tenant_id,
      group_id: group_id,
      billing_context: billing_context,
      outcome: outcome_label(outcome),
      evaluator: @evaluator,
      evaluator_version: @evaluator_version,
      window: result.window,
      findings: result.findings
    }
  end

  defp tenant_group(agent_id) do
    case AgentRuntimeConfig.resolve(agent_id) do
      {:ok, runtime_config} -> {runtime_config[:tenant_id], runtime_config[:group_id]}
      {:error, _} -> {nil, nil}
    end
  end

  defp outcome_label(:final), do: "final"
  defp outcome_label({:error, _}), do: "error"
  defp outcome_label(other), do: inspect(other)

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  defp config, do: Application.get_env(:salix_agent, :trajectory_eval, [])
end
