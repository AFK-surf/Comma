defmodule SalixIM.LiveLlmTriageWorkerLoopTest do
  @moduledoc """
  Real-model multi-turn Triage Worker tool-loop regressions against production
  prompts, tool specs, decision validation, and read-only Composio authority.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{LiveLlmTestSupport, SlackParticipationPrompt, ToolDisclosure}
  alias SalixIM.Triage.Investigation

  @moduletag :live_llm
  @moduletag timeout: 180_000
  @max_rounds 12
  @cases Jason.decode!(File.read!(Path.join(__DIR__, "fixtures/triage_worker_loop.json")))

  @readonly_composio_slugs ~w(
    GITHUB_GET_A_REPOSITORY
    GITHUB_LIST_PULL_REQUESTS
    GITHUB_GET_A_PULL_REQUEST
    GITHUB_LIST_COMMITS
    GITHUB_GET_AN_ISSUE
    GITHUB_LIST_REPOSITORY_ISSUES
    GITHUB_SEARCH_ISSUES_AND_PULL_REQUESTS
    GITHUB_LIST_RELEASES
    GITHUB_GET_THE_LATEST_RELEASE
    LINEAR_GET_LINEAR_ISSUE
    LINEAR_LIST_LINEAR_ISSUES
    NOTION_SEARCH_NOTION_PAGE
    NOTION_FETCH_BLOCK_METADATA
    NOTION_FETCH_BLOCK_CONTENTS
  )

  setup_all do
    {:ok, llm: LiveLlmTestSupport.llm_config!()}
  end

  for sample <- @cases do
    @sample sample
    test "live LLM triage worker loop: #{sample["name"]}", %{llm: llm} do
      tools = ToolDisclosure.internal_llm_specs("worker")

      messages = [
        %{
          role: "system",
          content:
            SlackParticipationPrompt.triage_investigation_instructions() <>
              """

              ## Runtime envelope

              Call business tools through the outer `call` tool with `tool` set to the canonical tool name and `params` set to its JSON object arguments. Finish the turn by calling `end_turn` with `outcome: "done"` once `im_api.internal.triage.complete` has been accepted.
              """
        },
        %{role: "user", content: @sample["command"]}
      ]

      state = %{
        sample: @sample,
        tool_calls: [],
        complete_errors: 0,
        accepted_decision: nil
      }

      final_state = run_loop(messages, tools, llm, state, 1)

      assert is_map(final_state.accepted_decision),
             "Expected im_api.internal.triage.complete to be accepted; tool_calls=#{inspect(final_state.tool_calls)}"

      decision = final_state.accepted_decision
      assert decision["kind"] in @sample["allowed_kinds"], inspect(decision)

      if @sample["allowed_reason_codes"] != [] do
        assert decision["reason_code"] in @sample["allowed_reason_codes"], inspect(decision)
      end

      if decision["kind"] == "reply" do
        text = decision["text"] || ""
        assert String.trim(text) != "", inspect(decision)

        for pattern <- @sample["required_reply_patterns"] || [] do
          assert Regex.match?(Regex.compile!(pattern), text),
                 "Expected reply to match #{inspect(pattern)}, got: #{inspect(text)}"
        end

        for forbidden <- @sample["forbidden_reply_substrings"] || [] do
          refute String.contains?(text, forbidden),
                 "Expected reply not to leak #{inspect(forbidden)}, got: #{inspect(text)}"
        end
      end

      for required_tool <- @sample["required_tools"] || [] do
        assert required_tool in final_state.tool_calls,
               "Expected tool #{inspect(required_tool)} in #{inspect(final_state.tool_calls)}"
      end

      follow_ups =
        decision
        |> Map.get("context_candidates", [])
        |> Enum.filter(&(&1["kind"] == "follow_up"))

      if @sample["forbid_follow_up"] == true do
        assert follow_ups == [], "Expected no follow_up, got: #{inspect(follow_ups)}"
      end

      if @sample["expected_follow_up_hours"] != [] do
        hours = Enum.map(follow_ups, & &1["recheck_after_hours"])

        assert Enum.any?(hours, &(&1 in @sample["expected_follow_up_hours"])),
               "Expected follow_up hours in #{inspect(@sample["expected_follow_up_hours"])}, got: #{inspect(follow_ups)}"
      end

      assert length(final_state.tool_calls) <= @sample["max_tool_calls"],
             "Tool call count #{length(final_state.tool_calls)} exceeded #{@sample["max_tool_calls"]}: #{inspect(final_state.tool_calls)}"

      assert final_state.complete_errors <= @sample["max_complete_errors"],
             "complete errors #{final_state.complete_errors} exceeded #{@sample["max_complete_errors"]}"
    end
  end

  defp run_loop(_messages, _tools, _llm, state, round) when round > @max_rounds, do: state

  defp run_loop(messages, tools, llm, state, round) do
    case apply(SalixLlm.Provider, :complete, [messages, tools, llm]) do
      {:final, _text, _usage} ->
        state

      {:final, _text, _state, _usage} ->
        state

      tuple when is_tuple(tuple) and elem(tuple, 0) == :assistant ->
        {text, tool_calls} = extract_assistant(tuple)
        handle_assistant_turn(messages, tools, llm, state, round, text, tool_calls)

      other ->
        flunk("Unexpected LLM response in round #{round}: #{inspect(other)}")
    end
  end

  defp extract_assistant({:assistant, text, tool_calls}), do: {text, tool_calls}
  defp extract_assistant({:assistant, text, tool_calls, _usage}), do: {text, tool_calls}
  defp extract_assistant({:assistant, text, tool_calls, _state, _usage}), do: {text, tool_calls}

  defp handle_assistant_turn(_messages, _tools, _llm, state, _round, _text, []), do: state

  defp handle_assistant_turn(messages, tools, llm, state, round, text, tool_calls) do
    assistant_msg = %{
      role: "assistant",
      content: text || "",
      tool_calls:
        Enum.map(tool_calls, fn tc ->
          %{"id" => tc.id, "name" => tc.name, "args" => tc.args}
        end)
    }

    {tool_msgs, next_state, ended?} =
      Enum.reduce(tool_calls, {[], state, false}, fn tc, {msgs, acc, done?} ->
        {out, acc, stop?} = dispatch_outer(tc, acc)
        msg = %{role: "tool", tool_call_id: tc.id, content: Jason.encode!(out)}
        {msgs ++ [msg], acc, done? or stop?}
      end)

    if ended? do
      next_state
    else
      run_loop(messages ++ [assistant_msg | tool_msgs], tools, llm, next_state, round + 1)
    end
  end

  defp dispatch_outer(%{name: "end_turn"}, state),
    do: {%{"ok" => true, "ended" => true}, state, true}

  defp dispatch_outer(%{name: "wait_for"}, state),
    do: {%{"ok" => true, "waited" => true}, state, false}

  defp dispatch_outer(%{name: "call", args: args}, state) when is_map(args) do
    tool = to_string(args["tool"] || "")
    params = if is_map(args["params"]), do: args["params"], else: %{}
    {out, next_state} = dispatch_tool(tool, params, state)
    next_state = %{next_state | tool_calls: next_state.tool_calls ++ [tool]}
    {out, next_state, false}
  end

  defp dispatch_outer(%{name: name}, state),
    do: {%{"error" => "unsupported_outer_tool: #{name}"}, state, false}

  defp dispatch_tool("im_api.internal.triage.read_source", _params, state) do
    {state.sample["source_response"], state}
  end

  defp dispatch_tool("im_api.internal.triage.read_context", _params, state) do
    {%{"entries" => []}, state}
  end

  defp dispatch_tool("im_api.internal.triage.read_memory", _params, state) do
    {%{"exists" => false, "content" => ""}, state}
  end

  defp dispatch_tool("im_api.internal.triage.complete", params, state) do
    cleaned = Map.delete(params, "connect_id")
    expected_snapshot = state.sample["source_response"]["source_snapshot"]

    cond do
      Enum.sort(Map.keys(cleaned)) != ["decision", "source_snapshot"] ->
        {%{
           "error" =>
             "invalid_triage_completion: expected params with exact keys source_snapshot (non-empty string) and decision (object)"
         }, %{state | complete_errors: state.complete_errors + 1}}

      cleaned["source_snapshot"] != expected_snapshot ->
        {%{"error" => "invalid_triage_source_snapshot"},
         %{state | complete_errors: state.complete_errors + 1}}

      not Investigation.valid_decision?(cleaned["decision"]) ->
        {%{
           "error" =>
             "invalid_triage_completion: decision failed validation (check exact keys for reply, reaction, or silence)"
         }, %{state | complete_errors: state.complete_errors + 1}}

      true ->
        {%{
           "accepted" => true,
           "delivery_status" => "pending",
           "next_action" => "The public result is durably queued. End this investigation turn."
         }, %{state | accepted_decision: cleaned["decision"]}}
    end
  end

  defp dispatch_tool("im_api.slack.get_channel_history", _params, state) do
    before = get_in(state.sample, ["source_response", "channel_context", "before"]) || []
    {%{"messages" => Enum.reverse(before), "has_more" => false}, state}
  end

  defp dispatch_tool("im_api.slack.get_thread_replies", _params, state) do
    {%{"messages" => state.sample["source_response"]["messages"] || [], "has_more" => false},
     state}
  end

  defp dispatch_tool(tool, _params, state)
       when tool in ["im_api.slack.search", "im_api.slack.message_search"] do
    {%{"messages" => state.sample["slack_search_messages"] || [], "has_more" => false}, state}
  end

  defp dispatch_tool("im_api.slack.get_user_info", params, state) do
    uid = params["user"] || params["user_id"] || "U_UNKNOWN"
    {%{"user" => %{"id" => uid, "name" => String.downcase(uid)}}, state}
  end

  defp dispatch_tool("im_api.internal.station_task.list", _params, state) do
    {%{"tasks" => state.sample["station_tasks"] || [], "has_more" => false}, state}
  end

  defp dispatch_tool("composio.list_connections", _params, state) do
    {%{"connections" => state.sample["composio_connections"] || []}, state}
  end

  defp dispatch_tool("composio.list_tools", _params, state) do
    {%{"tools" => Enum.map(@readonly_composio_slugs, &%{"slug" => &1})}, state}
  end

  defp dispatch_tool("composio.get_tool", params, state) do
    slug = params["tool_slug"] || ""

    if slug in @readonly_composio_slugs do
      {%{"slug" => slug, "parameters" => %{"type" => "object"}}, state}
    else
      {%{"error" => "triage_investigation_scope_denied"}, state}
    end
  end

  defp dispatch_tool("composio.execute", params, state) do
    slug = params["tool_slug"]
    arguments = params["arguments"]

    cond do
      slug not in @readonly_composio_slugs or not is_map(arguments) ->
        {%{"error" => "triage_investigation_scope_denied"}, state}

      slug in ["GITHUB_GET_A_PULL_REQUEST", "GITHUB_LIST_PULL_REQUESTS"] and
          is_map(state.sample["composio_pr_data"]) ->
        {%{"successful" => true, "data" => state.sample["composio_pr_data"]}, state}

      true ->
        {%{"successful" => true, "data" => %{}}, state}
    end
  end

  defp dispatch_tool("im_api.internal.send_message", _params, state) do
    {%{"ok" => true, "message_id" => "msg_internal_note"}, state}
  end

  defp dispatch_tool("help", params, state) do
    tool = to_string(params["tool"] || "")
    {%{"tool" => tool, "manual" => tool_manual(tool)}, state}
  end

  defp dispatch_tool(other, _params, state) do
    {%{"error" => "triage_investigation_scope_denied: #{other}"}, state}
  end

  defp tool_manual("im_api.internal.triage.complete") do
    "Required params: connect_id=\"internal\", source_snapshot, decision (reply: {kind,text,source_refs}; reaction: {kind,emoji,source_refs:[one]}; silence: {kind,reason,reason_code,source_refs}; optional context_candidates)."
  end

  defp tool_manual("composio.execute") do
    "Required params: tool_slug (read-only allowlist), arguments (object), optional connected_account_id."
  end

  defp tool_manual(name), do: "Call #{name} with its JSON object parameters."
end
