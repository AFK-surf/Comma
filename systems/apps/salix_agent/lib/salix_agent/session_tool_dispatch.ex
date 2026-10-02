defmodule SalixAgent.SessionToolDispatch do
  @moduledoc """
  The authorization boundary for runtime-owned canonical tool execution.

  Internal rounds, direct internal session calls, and JavaScript host calls all
  pass through this module. Recommendation runs are restricted to their allowed
  tools; ordinary session calls execute independently of diagnostic-repair
  state and return their real provider result.

  `RecommendationPolicy` and the optional `InspectorPolicy` decide whether the
  tool may run at all in this session. `SalixAgent.IFC.Check` then decides
  whether the *content* this effect declares may reach the destination its
  parameters name (`docs/verification.md` §9); it calls
  the pure kernel once per effect and turns a refusal into a `guidance`
  result. Both refusals are archived with the call that caused them.
  """

  alias SalixAgent.IFC
  alias SalixAgent.{Tools, VisibleReplyPolicy}

  @doc false
  def execute(calls, ctx) when is_list(calls) and is_map(ctx) do
    calls = Tools.prepare_for_dispatch(calls, ctx)
    # Carry the whole round's label into each dependency, before it can finish
    # asynchronously and bypass the returned-batch stamping below.
    ctx = Map.put(ctx, :ifc_round_label, IFC.Check.round_label(calls, ctx))
    {decisions, executable} = authorize(calls, ctx)
    archive_withheld(calls, decisions, ctx)

    executable
    |> Tools.execute(Map.put(ctx, :calls_prepared, true))
    |> SalixAgent.TerminalReply.stamp_results(executable)
    |> merge_results(decisions)
    |> IFC.Check.stamp_results(calls, ctx)
    |> VisibleReplyPolicy.label_results()
  end

  @doc false
  def execute_with_async_window(calls, ctx) when is_list(calls) and is_map(ctx) do
    calls = Tools.prepare_for_dispatch(calls, ctx)
    # Carry the whole round's label into each dependency, before it can finish
    # asynchronously and bypass the returned-batch stamping below.
    ctx = Map.put(ctx, :ifc_round_label, IFC.Check.round_label(calls, ctx))
    {decisions, executable} = authorize(calls, ctx)
    archive_withheld(calls, decisions, ctx)

    # The model response and committed intent are complete here. Only the same
    # calls that passed source, destination and IFC authorization may appear.
    SalixAgent.SendMessageDraftStream.publish_terminal_reply(executable, ctx)

    {executed, pending} =
      Tools.execute_with_async_window(executable, Map.put(ctx, :calls_prepared, true))

    results =
      executed
      |> SalixAgent.TerminalReply.stamp_results(executable)
      |> merge_results(decisions)
      |> IFC.Check.stamp_results(calls, ctx)
      |> VisibleReplyPolicy.label_results()

    {results, pending}
  end

  @doc false
  def plan_async_intent(calls, ctx) do
    calls = Tools.prepare_for_dispatch(calls, ctx)
    ctx = Map.put(ctx, :ifc_round_label, IFC.Check.round_label(calls, ctx))
    {decisions, executable} = authorize(calls, ctx)

    if Enum.all?(decisions, &match?({:execute, _}, &1)) do
      case Tools.planned_async_results(executable, ctx) do
        {:ok, results} ->
          {:ok,
           results |> IFC.Check.stamp_results(calls, ctx) |> VisibleReplyPolicy.label_results()}

        :fallback ->
          :fallback
      end
    else
      :fallback
    end
  end

  defp authorize(calls, ctx) do
    decisions =
      calls
      |> Enum.map(fn call ->
        if SalixAgent.RecommendationPolicy.allowed_tool?(
             ctx,
             call[:name] || call["name"],
             call[:args] || call["args"] || %{}
           ) and SalixAgent.GuestPolicy.allowed_tool?(ctx, call[:name] || call["name"]) do
          case SalixAgent.TerminalReply.authorize(call, ctx) do
            {:ok, call} ->
              {:execute, call}

            {:error, reason} ->
              {:blocked,
               SalixAgent.InternalSession.presentation_policy(
                 :terminal_guidance,
                 {recommendation_policy_result(call), reason, ctx[:visible_reply_phase]}
               )}
          end
        else
          {:blocked, recommendation_policy_result(call)}
        end
      end)
      |> Enum.map(fn
        {:execute, call} = decision ->
          if SalixAgent.InspectorPolicy.allowed_tool?(
               ctx,
               call[:name] || call["name"],
               call[:args] || call["args"] || %{}
             ) do
            decision
          else
            {:blocked,
             Map.put(
               recommendation_policy_result(call),
               :content,
               SalixAgent.InspectorPolicy.refusal()
             )}
          end

        blocked ->
          blocked
      end)
      |> authorize_triage(ctx)
      |> authorize_organization(ctx)
      |> IFC.Check.authorize(ctx)

    executable =
      Enum.flat_map(decisions, fn
        {:execute, call} -> [call]
        {:blocked, _result} -> []
      end)

    {decisions, executable}
  end

  defp authorize_triage(decisions, ctx) do
    if ctx[:triage_scopes] not in [nil, []] or
         get_in(ctx, [:trusted_origin, "triage_investigation"]) do
      module = Application.get_env(:salix_agent, :triage_investigation_authority_mod)

      Enum.map(decisions, fn
        {:execute, call} ->
          if module && module.authorize_call(call, ctx) == :ok do
            {:execute, call}
          else
            {:blocked,
             Map.put(
               recommendation_policy_result(call),
               :content,
               "This Triage assignment permits research and completion in its assigned Task only. Its current authority could not authorize this call."
             )}
          end

        blocked ->
          blocked
      end)
    else
      decisions
    end
  end

  defp authorize_organization(decisions, ctx) do
    if ctx[:organization_scopes] not in [nil, []] or
         get_in(ctx, [:trusted_origin, "meeting_preparation"]) do
      module = Application.get_env(:salix_agent, :meeting_preparation_mod)

      Enum.map(decisions, fn
        {:execute, call} ->
          authorization = module && module.authorize_organization_call(call, ctx)

          if authorization == :ok do
            {:execute, call}
          else
            guidance =
              case authorization do
                {:error, :meeting_preparation_operation_not_permitted} ->
                  "This meeting authorization does not permit this tool. Call an allowed meeting or research tool directly through call, without script.run. This refusal does not indicate that the meeting is stale or obsolete."

                {:error, :meeting_preparation_incomplete} ->
                  "Meeting preparation is incomplete. Read meeting.preparation.read_status, save the shared report, and finish all personal_context pages. Each recipient needs a saved review, with or without advice. A basic reminder alone does not complete research. Continue other recipients after a failure. Repair remaining failures or complete with outcome failed."

                _ ->
                  "The current meeting authorization could not be validated. Use only the current assigned meeting Task."
              end

            {:blocked,
             Map.merge(recommendation_policy_result(call), %{
               content: guidance,
               error: false,
               error_class: nil,
               status: "guidance",
               diagnostic_visibility: "model_only"
             })}
          end

        blocked ->
          blocked
      end)
    else
      decisions
    end
  end

  # Withheld calls never reach the Tools seam: `authorize/2` filters them out
  # and `merge_results/2` splices the synthesized refusals back in afterwards.
  # So without this, a call the model MADE and the loop REFUSED was archived
  # nowhere — neither the request nor the refusal — which is exactly the intent
  # an auditor most wants to see.
  #
  # Archived separately from the executed set rather than by widening the seam,
  # so nothing is double-archived.
  defp archive_withheld(calls, decisions, ctx) do
    withheld =
      calls
      |> Enum.zip(decisions)
      |> Enum.flat_map(fn
        {call, {:blocked, result}} -> [%{"call" => call, "refusal" => result}]
        {_call, {:execute, _}} -> []
      end)

    SalixAgent.EventArchive.Emit.withheld_tool_calls(ctx, withheld)
  end

  defp recommendation_policy_result(call) do
    name = to_string(call[:name] || call["name"] || "")

    %{
      id: call[:id] || call["id"],
      name: name,
      content: "tool is not authorized for this recommendation run",
      error: true,
      error_class: "forbidden",
      status: "error",
      call_index: call[:call_index] || call["call_index"],
      events: []
    }
  end

  defp merge_results(executed, decisions) do
    {results, []} =
      Enum.map_reduce(decisions, executed, fn
        {:blocked, result}, remaining -> {result, remaining}
        {:execute, _call}, [result | remaining] -> {result, remaining}
      end)

    results
  end
end
