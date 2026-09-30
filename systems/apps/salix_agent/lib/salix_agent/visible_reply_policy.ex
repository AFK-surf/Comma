defmodule SalixAgent.VisibleReplyPolicy do
  @moduledoc """
  Adapter for kernel presentation plans and external tool-schema validation.

  Lean owns diagnostic disclosure, repair transitions, and scheduled Task
  containment. ToolDisclosure and Tools retain authority over callable tools
  and provider parameter schemas.
  """

  alias SalixAgent.InternalSession
  alias SalixAgent.{ToolDisclosure, Tools}

  def model_only, do: "model_only"
  def user_reportable, do: "user_reportable"
  def safe_failure_summary, do: "I couldn't complete that reply safely. Please try again."

  def phase(session), do: InternalSession.query(session, :visible_reply_phase)
  def guard(session), do: InternalSession.query(session, :visible_reply_guard)
  def repair_required?(phase), do: policy(:repair_required?, phase)
  def repair_budget, do: policy(:repair_budget, nil)

  def append_repair_reminder(messages, phase),
    do: policy(:append_repair_reminder, {messages, phase})

  def sanitize_activity_calls(calls, phase), do: policy(:sanitize_activity_calls, {calls, phase})
  def label_results(results), do: policy(:label_results, results)
  def label_result(result), do: policy(:label_result, result)
  def stamp_result_origin(result, phase), do: policy(:stamp_result_origin, {result, phase})

  def inherit_result_origin(result, source) when is_map(source),
    do:
      policy(
        :inherit_result_origin,
        {result, Map.take(source, [:visible_reply_origin, "visible_reply_origin"])}
      )

  def inherit_result_origin(result, _source), do: result

  def stamp_pending_origin(pending, phase) do
    patch = policy(:pending_origin_patch, phase)
    Enum.map(pending, &Map.merge(&1, patch))
  end

  def repair_origin?(value), do: policy(:repair_origin?, value)
  def model_only_result?(result), do: policy(:model_only_result?, result)
  def user_reportable_result?(result), do: policy(:user_reportable_result?, result)
  def private_result?(result), do: policy(:private_result?, result)
  def target_tool(call), do: policy(:target_tool, call)
  def transition(phase, results), do: policy(:transition, {phase, results})
  def no_tool_transition(phase), do: policy(:no_tool_transition, phase)

  def transition_events(transition, session_id, hwm),
    do: policy(:transition_events, {transition, session_id, hwm})

  def sanitize_context(messages, phase), do: policy(:sanitize_context, {messages, phase})

  def async_completion_events(events, session, result, opts \\ []),
    do:
      InternalSession.query(
        session,
        :async_completion_events,
        {events, result, Keyword.get(opts, :diagnostic_hwm)}
      )

  def sanitize_scheduled_task_failure_call(call, ctx) when is_map(call) and is_map(ctx) do
    with {:ok, sanitized} <- scheduled({:sanitize, call, projection(ctx), restricted?(ctx)}),
         :ok <- preflight_scheduled_task_failure_call(sanitized, ctx) do
      {:ok, sanitized}
    else
      _ -> :not_scheduled_task_failure
    end
  end

  def sanitize_scheduled_task_failure_call(_call, _ctx), do: :not_scheduled_task_failure

  def sanitize_scheduled_task_failure_calls(calls, ctx) when is_list(calls) and is_map(ctx) do
    with {:ok, sanitized} <-
           scheduled({:sanitize_calls, calls, projection(ctx), restricted?(ctx)}),
         true <- Enum.all?(sanitized, &(preflight_scheduled_task_failure_call(&1, ctx) == :ok)) do
      {:ok, sanitized}
    else
      _ -> :not_scheduled_task_failure
    end
  end

  def sanitize_scheduled_task_failure_calls(_calls, _ctx), do: :not_scheduled_task_failure

  def scheduled_task_failure_call_id?(id), do: scheduled({:call_id?, id})

  def scheduled_task_failure_call(origin, call \\ nil, ctx \\ %{}),
    do: scheduled({:call, origin, call, restricted?(ctx)})

  def mark_scheduled_task_failure_result(result), do: scheduled({:mark_result, result})

  defp projection(ctx),
    do:
      Map.take(ctx, [
        :visible_reply_phase,
        :trusted_origin,
        :trusted_origins,
        "visible_reply_phase",
        "trusted_origin",
        "trusted_origins"
      ])

  defp restricted?(ctx), do: SalixAgent.InspectorPolicy.restricted?(ctx)
  defp policy(operation, args), do: InternalSession.presentation_policy(operation, args)
  defp scheduled(args), do: InternalSession.scheduled_presentation(args)

  defp preflight_scheduled_task_failure_call(call, ctx) do
    name = call |> value("name") |> to_string() |> String.trim()
    args = value(call, "args")
    target = target_tool(call)

    if value(ctx, "llm_tool_envelope") == true do
      cond do
        name != "call" ->
          {:error, "scheduled Task failure calls must use the outer call envelope"}

        not is_map(args) ->
          {:error, "call arguments must be an object"}

        target == "" ->
          {:error, "'tool' is required"}

        not is_map(value(args, "params")) ->
          {:error, "'params' is required and must be a JSON object"}

        not ToolDisclosure.callable?(ctx, target) ->
          {:error, "tool is not callable in this session"}

        true ->
          Tools.validate_tool_params(target, value(args, "params"), ctx)
      end
    else
      cond do
        not is_map(args) ->
          {:error, "tool arguments must be an object"}

        target == "" ->
          {:error, "tool name is required"}

        not ToolDisclosure.callable?(ctx, target) ->
          {:error, "tool is not callable in this session"}

        true ->
          Tools.validate_tool_params(target, args, ctx)
      end
    end
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end
end
