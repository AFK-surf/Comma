#!/usr/bin/env elixir
# Local, zero-DB Prompt A/B evaluation runner.
#
# Run from `systems/`:
#   mix run --no-start scripts/prompt_ab_eval.exs --mode dump --out /tmp/base/dump.json
#   mix run --no-start scripts/prompt_ab_eval.exs --mode export --out /tmp/base/l2_bundle.json
#   mix run --no-start scripts/prompt_ab_eval.exs --mode l2 --out /tmp/base/l2.jsonl \
#       --base-url http://10.77.0.1:8180/v1 --model deepseek-flash --runs 3 --arm base
#   mix run --no-start scripts/prompt_ab_eval.exs --mode daily_brief --out /tmp/base/brief.jsonl \
#       --base-url http://10.77.0.1:8180/v1 --model deepseek-flash --runs 2 --arm base

defmodule PromptAbEval.OfflineIMProvider do
  @moduledoc false

  def list_connects(_agent_id, ctx \\ %{}) do
    base = [%{"connect_id" => "imc_internal", "provider" => "internal", "status" => "connected"}]

    connects =
      if ctx[:triage_investigation] || ctx["triage_investigation"] ||
           Process.get(:prompt_ab_triage, false) do
        base ++ [%{"connect_id" => "imc_test", "provider" => "slack", "status" => "connected"}]
      else
        base
      end

    {:ok, connects}
  end

  def provider_manual(platform), do: SalixIM.Provider.Manuals.manual(platform)
  def provider_manual(platform, _agent_id), do: SalixIM.Provider.Manuals.manual(platform)
  def provider_manual(platform, _agent_id, _ctx), do: SalixIM.Provider.Manuals.manual(platform)
end

defmodule PromptAbEval do
  alias SalixAgent.{BuiltinSkills, SkillProjection, SystemPromptDump, ToolDisclosure, ToolPolicy}

  @agent_id "agt1_0000000000000000001_0000000000000000002_0000000000000000003"
  @default_fixtures "apps/salix_agent/test/fixtures/prompt_ab/cases.json"
  @default_brief_fixtures_glob "apps/bridge_for_teams_core/test/fixtures/daily_brief/*.json"
  @max_rounds 12

  @switches [
    mode: :string,
    fixtures: :string,
    out: :string,
    base_url: :string,
    model: :string,
    api_key_env: :string,
    runs: :integer,
    max_tokens: :integer,
    arm: :string,
    cases: :string,
    dry_run: :boolean,
    timeout_ms: :integer
  ]

  def main(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if rest != [] or invalid != [] do
      IO.puts(:stderr, "Invalid options: #{inspect({rest, invalid})}")
      System.halt(2)
    end

    {:ok, _} = Application.ensure_all_started(:req)

    case opts[:mode] || "dump" do
      "dump" -> run_dump(opts)
      "export" -> run_export(opts)
      "l2" -> run_l2(opts)
      "daily_brief" -> run_daily_brief(opts)
      other -> raise "Unknown --mode #{inspect(other)} (expected dump|export|l2|daily_brief)"
    end
  end

  # ---- Export portable production-rendered L2 bundle (for running without Elixir) ----

  defp run_export(opts) do
    fixtures_path = opts[:fixtures] || @default_fixtures
    cases = fixtures_path |> File.read!() |> Jason.decode!()
    cases = filter_cases(cases, opts[:cases])

    exported_cases =
      Enum.map(cases, fn kase ->
        variant = kase["variant"] || %{}
        rendered = render_l2_variant(variant)
        disclosure = rendered.disclosure
        role = rendered.role

        help_index = build_help_index(disclosure)
        namespace_index = build_namespace_index(disclosure)
        {connects, provider_apis} = build_im_discovery(variant, disclosure)

        %{
          "name" => kase["name"],
          "category" => kase["category"],
          "hard_guardrail" => kase["hard_guardrail"] == true,
          "role" => role,
          "prompt" => rendered.prompt,
          "prompt_chars" => rendered.chars,
          "prompt_sha256" => rendered.sha256,
          "tools" => openai_tools(ToolDisclosure.internal_llm_specs(role)),
          "help_index" => help_index,
          "namespace_index" => namespace_index,
          "im_connects" => connects,
          "provider_apis" => provider_apis,
          "history_messages" => kase["history_messages"] || [],
          "user_messages" => kase["user_messages"] || [],
          "tool_stubs" => kase["tool_stubs"] || %{},
          "checks" => kase["checks"] || %{}
        }
      end)

    payload = %{
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "arm" => opts[:arm] || "cand",
      "cases" => exported_cases
    }

    json = Jason.encode!(payload)

    case opts[:out] do
      nil ->
        IO.puts(json)

      path ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write!(path, json)

        IO.puts(
          "Exported L2 bundle (#{length(exported_cases)} cases, #{byte_size(json)} B) to #{path}"
        )
    end
  end

  # ---- L0: Static Dump Matrix ----

  defp run_dump(opts) do
    entries = SystemPromptDump.matrix(builtin_skills: true)

    payload = %{
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "variants" => entries
    }

    json = Jason.encode!(payload, pretty: true)

    case opts[:out] do
      nil ->
        IO.puts(json)

      path ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write!(path, json)
        IO.puts("Wrote L0 dump matrix (#{length(entries)} variants) to #{path}")
    end
  end

  # ---- L2: Frozen Multi-Turn Tool-Loop A/B ----

  defp run_l2(opts) do
    fixtures_path = opts[:fixtures] || @default_fixtures
    cases = fixtures_path |> File.read!() |> Jason.decode!()
    cases = filter_cases(cases, opts[:cases])
    runs = opts[:runs] || 1
    arm = opts[:arm] || "cand"
    model = opts[:model] || "dry-run"
    dry_run? = opts[:dry_run] == true

    if not dry_run? and is_nil(opts[:base_url]) do
      raise "--base-url is required unless --dry-run is set"
    end

    rows =
      for kase <- cases, run_idx <- 1..runs do
        run_l2_case(kase, run_idx, arm, model, opts, dry_run?)
      end

    emit_jsonl(rows, opts[:out])
    passed = Enum.count(rows, & &1["pass"])
    IO.puts("L2 [#{arm} / #{model}]: #{passed}/#{length(rows)} passed")
  end

  defp run_l2_case(kase, run_idx, arm, model, opts, dry_run?) do
    variant = kase["variant"] || %{}
    rendered = render_l2_variant(variant)
    role = rendered.role
    disclosure = rendered.disclosure
    {connects, provider_apis} = build_im_discovery(variant, disclosure)
    tools = openai_tools(ToolDisclosure.internal_llm_specs(role))

    history =
      Enum.map(kase["history_messages"] || [], fn m ->
        %{"role" => m["role"], "content" => m["content"]}
      end)

    user_msgs =
      Enum.map(kase["user_messages"] || [], fn text ->
        %{"role" => "user", "content" => text}
      end)

    messages = [%{"role" => "system", "content" => rendered.prompt} | history] ++ user_msgs

    if dry_run? do
      %{
        "layer" => "l2",
        "arm" => arm,
        "model" => model,
        "case" => kase["name"],
        "category" => kase["category"],
        "hard_guardrail" => kase["hard_guardrail"] == true,
        "run" => run_idx,
        "pass" => true,
        "dry_run" => true,
        "prompt_chars" => rendered.chars,
        "prompt_sha256" => rendered.sha256,
        "rounds" => 0,
        "help_calls" => 0,
        "tool_calls" => [],
        "usage" => %{"prompt_tokens" => 0, "cached_tokens" => 0, "completion_tokens" => 0},
        "latency_ms" => 0,
        "checks" => []
      }
    else
      started = System.monotonic_time(:millisecond)

      init_state = %{
        kase: kase,
        disclosure: disclosure,
        im_connects: connects,
        provider_apis: provider_apis,
        tool_calls: [],
        tool_call_details: [],
        help_calls: 0,
        visible_outputs: [],
        triage_decision: nil,
        triage_errors: 0,
        plain_nudges: 0,
        rounds: 0,
        usage: %{"prompt_tokens" => 0, "cached_tokens" => 0, "completion_tokens" => 0},
        error: nil,
        transcript: []
      }

      final = loop_l2(messages, tools, opts, init_state, 1)
      elapsed = System.monotonic_time(:millisecond) - started
      checks = evaluate_l2_checks(kase["checks"] || %{}, final)
      all_pass? = is_nil(final.error) and Enum.all?(checks, & &1["pass"])

      %{
        "layer" => "l2",
        "arm" => arm,
        "model" => model,
        "case" => kase["name"],
        "category" => kase["category"],
        "hard_guardrail" => kase["hard_guardrail"] == true,
        "run" => run_idx,
        "pass" => all_pass?,
        "error" => final.error,
        "prompt_chars" => rendered.chars,
        "prompt_sha256" => rendered.sha256,
        "rounds" => final.rounds,
        "help_calls" => final.help_calls,
        "tool_calls" => final.tool_calls,
        "tool_call_details" => final.tool_call_details,
        "visible_outputs" => final.visible_outputs,
        "triage_decision" => final.triage_decision,
        "usage" => final.usage,
        "latency_ms" => elapsed,
        "checks" => checks
      }
    end
  end

  defp loop_l2(_messages, _tools, _opts, state, round) when round > @max_rounds do
    %{state | error: "max_rounds_exceeded"}
  end

  defp loop_l2(messages, tools, opts, state, round) do
    case chat_complete(messages, tools, opts) do
      {:error, reason} ->
        %{state | rounds: round, error: inspect(reason)}

      {:ok, resp} ->
        usage = add_usage(state.usage, extract_usage(resp))
        msg = get_in(resp, ["choices", Access.at(0), "message"]) || %{}
        text = msg["content"] || ""
        tool_calls = List.wrap(msg["tool_calls"])
        state = %{state | rounds: round, usage: usage}

        if tool_calls == [] do
          state =
            if String.trim(text) != "" do
              %{state | transcript: state.transcript ++ [%{"round" => round, "text" => text}]}
            else
              state
            end

          if not has_delivered_output?(state) and state.plain_nudges < 1 and round < @max_rounds do
            nudge = %{
              "role" => "user",
              "content" =>
                "Runtime notice: plain assistant text is not visible to the user. " <>
                  "Send your reply with im_api.internal.send_message (or end_turn with reply), " <>
                  "or call end_turn with no_reply=true if silence is deliberate."
            }

            next_messages = messages ++ [%{"role" => "assistant", "content" => text}, nudge]
            next_state = %{state | plain_nudges: state.plain_nudges + 1}
            loop_l2(next_messages, tools, opts, next_state, round + 1)
          else
            state
          end
        else
          assistant_msg = %{
            "role" => "assistant",
            "content" => text,
            "tool_calls" => tool_calls
          }

          {tool_msgs, next_state, ended?} =
            Enum.reduce(tool_calls, {[], state, false}, fn tc, {acc_msgs, acc_state, done?} ->
              tc_id = tc["id"] || "tc_#{round}_#{length(acc_msgs)}"
              fn_name = get_in(tc, ["function", "name"]) || ""
              raw_args = get_in(tc, ["function", "arguments"]) || "{}"
              args = decode_args(raw_args)

              {result_map, acc_state, stop?} = dispatch_outer(fn_name, args, acc_state)

              tool_msg = %{
                "role" => "tool",
                "tool_call_id" => tc_id,
                "content" => Jason.encode!(result_map)
              }

              {acc_msgs ++ [tool_msg], acc_state, done? or stop?}
            end)

          if ended? do
            next_state
          else
            loop_l2(messages ++ [assistant_msg | tool_msgs], tools, opts, next_state, round + 1)
          end
        end
    end
  end

  defp dispatch_outer("end_turn", args, state) do
    state =
      case args["reply"] do
        %{"tool" => tool, "params" => params} when is_binary(tool) and is_map(params) ->
          {_out, next_state} = dispatch_inner(tool, params, state)
          next_state

        _ ->
          state
      end

    if args["outcome"] == "done" and args["no_reply"] != true and
         not has_delivered_output?(state) do
      {%{
         "error" =>
           "done_without_reply: send the answer via im_api.internal.send_message " <>
             "or end_turn.reply, create a Task, or set no_reply=true"
       }, state, false}
    else
      {%{"ok" => true, "ended" => true, "outcome" => args["outcome"]}, state, true}
    end
  end

  defp dispatch_outer("wait_for", args, state) do
    # In production, wait_for suspends the current turn until an external event or
    # delegated Worker report wakes the session.
    {%{"ok" => true, "waiting" => true, "reason" => args["reason"]}, state, true}
  end

  defp dispatch_outer("call", args, state) do
    tool = to_string(args["tool"] || "")
    params = if is_map(args["params"]), do: args["params"], else: %{}
    {out, next_state} = dispatch_inner(tool, params, state)
    {out, next_state, false}
  end

  defp dispatch_outer(name, _args, state) do
    {%{"error" => "unsupported_outer_tool: #{name}"}, state, false}
  end

  defp has_delivered_output?(state) do
    state.visible_outputs != [] or not is_nil(state.triage_decision) or
      "im_api.internal.task.create" in state.tool_calls
  end

  defp dispatch_inner("help", params, state) do
    target = to_string(params["tool"] || "")
    state = record_call(state, "help", params)
    state = %{state | help_calls: state.help_calls + 1}

    entry =
      Enum.find(state.disclosure["tools"] || [], fn e ->
        e["name"] == target
      end)

    out =
      cond do
        is_map(entry) ->
          %{
            "tool" => target,
            "summary" => entry["summary"],
            "manual" => entry["manual"],
            "input_schema" => ToolDisclosure.entry_schema(entry) || %{}
          }

        target in ToolDisclosure.discovery_namespaces() ->
          matching =
            (state.disclosure["tools"] || [])
            |> Enum.filter(&String.starts_with?(&1["name"] || "", target <> "."))
            |> Enum.map(&%{"name" => &1["name"], "summary" => &1["summary"]})

          %{"namespace" => target, "tools" => matching}

        true ->
          %{"error" => "unknown tool: #{target}"}
      end

    {out, state}
  end

  defp dispatch_inner("im.connects_list", params, state) do
    state = record_call(state, "im.connects_list", params)
    provider = String.trim(to_string(params["provider"] || ""))

    connects =
      if provider == "" do
        state.im_connects
      else
        Enum.filter(state.im_connects, &(&1["provider"] == provider))
      end

    {%{"connects" => connects}, state}
  end

  defp dispatch_inner("im.provider_apis_list", params, state) do
    state = record_call(state, "im.provider_apis_list", params)
    provider = String.trim(to_string(params["provider"] || "internal"))
    apis = Map.get(state.provider_apis, provider, [])
    {%{"provider" => provider, "apis" => apis}, state}
  end

  defp dispatch_inner("im_api.internal.send_message", params, state) do
    text = extract_message_text(params["content"])
    state = record_call(state, "im_api.internal.send_message", params)

    state =
      if text != "",
        do: %{state | visible_outputs: state.visible_outputs ++ [text]},
        else: state

    {%{"ok" => true, "message_id" => "msg_#{length(state.tool_calls)}"}, state}
  end

  defp dispatch_inner("im_api.internal.triage.complete", params, state) do
    state = record_call(state, "im_api.internal.triage.complete", params)
    cleaned = Map.delete(params, "connect_id")

    expected_snapshot =
      get_in(state.kase, ["tool_stubs", "im_api.internal.triage.read_source", "source_snapshot"])

    valid_decision? =
      if Code.ensure_loaded?(SalixIM.Triage.Investigation) and
           function_exported?(SalixIM.Triage.Investigation, :valid_decision?, 1) do
        apply(SalixIM.Triage.Investigation, :valid_decision?, [cleaned["decision"]])
      else
        is_map(cleaned["decision"]) and cleaned["decision"]["kind"] in ~w(reply reaction silence)
      end

    cond do
      Enum.sort(Map.keys(cleaned)) != ["decision", "source_snapshot"] ->
        {%{
           "error" =>
             "invalid_triage_completion: expected exact keys source_snapshot and decision"
         }, %{state | triage_errors: state.triage_errors + 1}}

      is_binary(expected_snapshot) and cleaned["source_snapshot"] != expected_snapshot ->
        {%{"error" => "invalid_triage_source_snapshot"},
         %{state | triage_errors: state.triage_errors + 1}}

      not valid_decision? ->
        {%{"error" => "invalid_triage_completion: decision failed validation"},
         %{state | triage_errors: state.triage_errors + 1}}

      true ->
        decision = cleaned["decision"]

        state =
          if decision["kind"] == "reply" and is_binary(decision["text"]) do
            %{
              state
              | triage_decision: decision,
                visible_outputs: state.visible_outputs ++ [decision["text"]]
            }
          else
            %{state | triage_decision: decision}
          end

        {%{"accepted" => true, "delivery_status" => "pending"}, state}
    end
  end

  defp dispatch_inner(tool, params, state) do
    state = record_call(state, tool, params)
    stubs = state.kase["tool_stubs"] || %{}

    out =
      case Map.fetch(stubs, tool) do
        {:ok, response} ->
          resolve_stub_response(response, params)

        :error ->
          default_stub(tool, params)
      end

    {out, state}
  end

  defp resolve_stub_response(%{"match_rules" => rules} = stub, params) when is_list(rules) do
    serialized = Jason.encode!(params || %{})

    matched =
      Enum.find(rules, fn rule ->
        is_map(rule) and is_binary(rule["pattern"]) and
          Regex.match?(Regex.compile!(rule["pattern"]), serialized)
      end)

    cond do
      is_map(matched) -> matched["response"]
      Map.has_key?(stub, "default") -> stub["default"]
      true -> stub
    end
  end

  defp resolve_stub_response(stub, _params), do: stub

  defp default_stub("im_api.internal.triage.read_context", _params), do: %{"entries" => []}

  defp default_stub("im_api.internal.triage.read_memory", _params),
    do: %{"exists" => false, "content" => ""}

  defp default_stub(tool, _params)
       when tool in [
              "im_api.slack.get_channel_history",
              "im_api.slack.get_thread_replies",
              "im_api.slack.search",
              "im_api.slack.message_search"
            ],
       do: %{"messages" => [], "has_more" => false}

  defp default_stub("im_api.internal.station_task.list", _params),
    do: %{"tasks" => [], "has_more" => false}

  defp default_stub("im_api.slack.get_user_info", params) do
    uid = params["user"] || params["user_id"] || "U_UNKNOWN"
    %{"user" => %{"id" => uid, "name" => String.downcase(to_string(uid))}}
  end

  defp default_stub(tool, _params), do: %{"error" => "unstubbed_tool: #{tool}"}

  defp record_call(state, tool, params) do
    %{
      state
      | tool_calls: state.tool_calls ++ [tool],
        tool_call_details: state.tool_call_details ++ [%{"tool" => tool, "params" => params}]
    }
  end

  defp extract_message_text(content) when is_binary(content), do: content

  defp extract_message_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> [t]
      %{"text" => t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp extract_message_text(_), do: ""

  defp evaluate_l2_checks(spec, state) do
    combined_output =
      if is_list(spec["triage_allowed_kinds"]) and is_map(state.triage_decision) and
           is_binary(state.triage_decision["text"]) do
        state.triage_decision["text"]
      else
        Enum.join(state.visible_outputs, "\n\n")
      end

    checks = []

    checks =
      checks ++
        for tool <- spec["required_tools"] || [] do
          %{
            "check" => "required_tool:#{tool}",
            "pass" => tool in state.tool_calls
          }
        end

    checks =
      case spec["any_of_tools"] do
        list when is_list(list) and list != [] ->
          checks ++
            [
              %{
                "check" => "any_of_tools:#{Enum.join(list, "|")}",
                "pass" => Enum.any?(list, &(&1 in state.tool_calls))
              }
            ]

        _ ->
          checks
      end

    checks =
      checks ++
        for tool <- spec["forbidden_tools"] || [] do
          %{
            "check" => "forbidden_tool:#{tool}",
            "pass" => tool not in state.tool_calls
          }
        end

    checks =
      checks ++
        for rule <- spec["required_tool_arg_patterns"] || [] do
          tool = rule["tool"]
          re = Regex.compile!(rule["pattern"])

          matched? =
            Enum.any?(state.tool_call_details, fn detail ->
              detail["tool"] == tool and Regex.match?(re, Jason.encode!(detail["params"]))
            end)

          %{
            "check" => "tool_arg:#{tool}:#{rule["pattern"]}",
            "pass" => matched?
          }
        end

    checks =
      checks ++
        for pat <- spec["required_output_patterns"] || [] do
          re = Regex.compile!(pat)
          %{"check" => "output_match:#{pat}", "pass" => Regex.match?(re, combined_output)}
        end

    checks =
      checks ++
        for pat <- spec["forbidden_output_patterns"] || [] do
          re = Regex.compile!(pat)
          %{"check" => "output_forbid:#{pat}", "pass" => not Regex.match?(re, combined_output)}
        end

    checks =
      case spec["triage_allowed_kinds"] do
        kinds when is_list(kinds) and kinds != [] ->
          kind = state.triage_decision && state.triage_decision["kind"]

          checks ++
            [%{"check" => "triage_kind:#{Enum.join(kinds, "|")}", "pass" => kind in kinds}]

        _ ->
          checks
      end

    checks =
      case spec["triage_allowed_reason_codes"] do
        codes when is_list(codes) and codes != [] ->
          code = state.triage_decision && state.triage_decision["reason_code"]

          checks ++
            [%{"check" => "triage_reason:#{Enum.join(codes, "|")}", "pass" => code in codes}]

        _ ->
          checks
      end

    checks =
      if spec["triage_forbid_follow_up"] == true do
        follow_ups =
          (state.triage_decision || %{})
          |> Map.get("context_candidates", [])
          |> Enum.filter(&(&1["kind"] == "follow_up"))

        checks ++ [%{"check" => "triage_no_follow_up", "pass" => follow_ups == []}]
      else
        checks
      end

    checks =
      case spec["max_tool_calls"] do
        max when is_integer(max) ->
          checks ++
            [
              %{
                "check" => "max_tool_calls<=#{max}",
                "pass" => length(state.tool_calls) <= max
              }
            ]

        _ ->
          checks
      end

    checks
  end

  # ---- L1: Daily Brief Production-Messages Replay ----

  defp run_daily_brief(opts) do
    paths =
      case opts[:fixtures] do
        nil ->
          Path.wildcard(@default_brief_fixtures_glob) |> Enum.sort()

        path ->
          if File.dir?(path),
            do: Path.wildcard(Path.join(path, "*.json")) |> Enum.sort(),
            else: [path]
      end

    runs = opts[:runs] || 1
    arm = opts[:arm] || "cand"
    model = opts[:model] || "dry-run"
    dry_run? = opts[:dry_run] == true

    if not dry_run? and is_nil(opts[:base_url]) do
      raise "--base-url is required unless --dry-run is set"
    end

    rows =
      for path <- paths, run_idx <- 1..runs do
        kase = BridgeForTeams.DailyBrief.Replay.load!(path)
        run_daily_brief_case(kase, run_idx, arm, model, opts, dry_run?)
      end

    emit_jsonl(rows, opts[:out])
    passed = Enum.count(rows, & &1["pass"])
    IO.puts("L1 DailyBrief [#{arm} / #{model}]: #{passed}/#{length(rows)} passed")
  end

  defp run_daily_brief_case(kase, run_idx, arm, model, opts, dry_run?) do
    started = System.monotonic_time(:millisecond)

    {:ok, usage_agent} =
      Agent.start_link(fn ->
        %{"prompt_tokens" => 0, "cached_tokens" => 0, "completion_tokens" => 0, "calls" => 0}
      end)

    judge =
      if dry_run? do
        fn %{view: view} ->
          if view == :mine, do: {:ok, ~s({"items":[]})}, else: {:ok, "dry run"}
        end
      else
        fn %{view: view, input: input} ->
          {:ok, msgs} = Salix.Bindings.DailyBriefModel.messages(view, input)

          case chat_complete(msgs, [], opts) do
            {:ok, resp} ->
              u = extract_usage(resp)

              Agent.update(usage_agent, fn acc ->
                acc
                |> add_usage(u)
                |> Map.update("calls", 1, &(&1 + 1))
              end)

              text = get_in(resp, ["choices", Access.at(0), "message", "content"]) || ""
              {:ok, text}

            {:error, reason} ->
              {:error, reason}
          end
        end
      end

    scenarios = BridgeForTeams.DailyBrief.Replay.run(kase, judge)
    usage = Agent.get(usage_agent, & &1)
    Agent.stop(usage_agent)
    elapsed = System.monotonic_time(:millisecond) - started

    checks = Enum.flat_map(scenarios, &(&1["checks"] || []))
    all_pass? = dry_run? or (checks != [] and Enum.all?(checks, & &1["pass"]))

    %{
      "layer" => "l1_daily_brief",
      "arm" => arm,
      "model" => model,
      "case" => kase["name"],
      "category" => "daily_brief",
      "hard_guardrail" => true,
      "run" => run_idx,
      "pass" => all_pass?,
      "dry_run" => dry_run?,
      "rounds" => usage["calls"],
      "help_calls" => 0,
      "tool_calls" => [],
      "usage" => Map.take(usage, ["prompt_tokens", "cached_tokens", "completion_tokens"]),
      "latency_ms" => elapsed,
      "checks" => checks
    }
  end

  # ---- Helpers ----

  defp render_l2_variant(v) do
    role = v["role"] || "router"
    with_screens = Map.get(v, "with_screens", true)
    triage? = v["triage"] == true and role == "worker"
    cloud_vm_retired = v["cloud_vm_retired"]
    guest? = v["guest"] == true
    concise? = v["concise"] == true
    builtin_skills? = Map.get(v, "builtin_skills", true)

    ctx =
      %{
        agent_id: @agent_id,
        role: role,
        disabled_tools: if(with_screens, do: [], else: ["device.screens"]),
        recommendation_policy: :ordinary
      }
      |> then(fn m ->
        if is_boolean(cloud_vm_retired),
          do: Map.put(m, :cloud_vm_retired, cloud_vm_retired),
          else: m
      end)
      |> then(fn m ->
        if guest?, do: Map.put(m, :guest_policy, "restricted"), else: m
      end)
      |> then(fn m ->
        if triage?, do: Map.put(m, :triage_investigation, true), else: m
      end)

    prev_im = Application.get_env(:salix_agent, :im_provider_mod)
    Process.put(:prompt_ab_triage, triage?)
    Application.put_env(:salix_agent, :im_provider_mod, PromptAbEval.OfflineIMProvider)

    disclosure =
      try do
        role
        |> ToolDisclosure.materialize(:internal, ctx)
        |> then(fn d ->
          if is_boolean(cloud_vm_retired),
            do: Map.put(d, "cloud_vm_retired", cloud_vm_retired),
            else: d
        end)
        |> then(fn d ->
          if guest?, do: Map.put(d, "guest_policy", "restricted"), else: d
        end)
      after
        Process.delete(:prompt_ab_triage)

        if is_nil(prev_im),
          do: Application.delete_env(:salix_agent, :im_provider_mod),
          else: Application.put_env(:salix_agent, :im_provider_mod, prev_im)
      end

    skill_section =
      if builtin_skills? do
        case BuiltinSkills.snapshot() do
          {:ok, %{skills: skills}} when is_map(skills) and map_size(skills) > 0 ->
            skills
            |> Map.values()
            |> Enum.sort_by(&(&1["skill_id"] || ""))
            |> SkillProjection.render_prompt_section(role: role)

          _ ->
            ""
        end
      else
        ""
      end

    prompts =
      %{}
      |> then(fn m ->
        if is_binary(v["agent_prompt"]) do
          key = if role == "router", do: "router_system_prompt", else: "system_prompt"
          Map.put(m, key, v["agent_prompt"])
        else
          m
        end
      end)
      |> then(fn m ->
        if concise?, do: Map.put(m, "reply_style", "concise"), else: m
      end)

    prompt =
      ToolPolicy.compose_session_prompt(
        role,
        prompts,
        @agent_id,
        :internal,
        disclosure,
        skill_section
      )

    %{
      role: role,
      disclosure: disclosure,
      prompt: prompt,
      chars: String.length(prompt),
      sha256: :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
    }
  end

  defp build_help_index(disclosure) do
    Map.new(disclosure["tools"] || [], fn entry ->
      {entry["name"],
       %{
         "tool" => entry["name"],
         "summary" => entry["summary"],
         "manual" => entry["manual"],
         "input_schema" => ToolDisclosure.entry_schema(entry) || %{}
       }}
    end)
  end

  defp build_namespace_index(disclosure) do
    Map.new(ToolDisclosure.discovery_namespaces(), fn ns ->
      tools =
        (disclosure["tools"] || [])
        |> Enum.filter(&String.starts_with?(&1["name"] || "", ns <> "."))
        |> Enum.map(&%{"name" => &1["name"], "summary" => &1["summary"]})

      {ns, %{"namespace" => ns, "tools" => tools}}
    end)
  end

  defp build_im_discovery(v, disclosure) do
    triage? = v["triage"] == true and (v["role"] || "router") == "worker"

    connects =
      if triage? do
        [
          %{"connect_id" => "imc_internal", "provider" => "internal", "status" => "connected"},
          %{"connect_id" => "imc_test", "provider" => "slack", "status" => "connected"}
        ]
      else
        [%{"connect_id" => "imc_internal", "provider" => "internal", "status" => "connected"}]
      end

    providers = Enum.map(connects, & &1["provider"])

    provider_apis =
      Map.new(providers, fn provider ->
        prefix = "im_api." <> provider <> "."

        apis =
          (disclosure["tools"] || [])
          |> Enum.filter(&String.starts_with?(&1["name"] || "", prefix))
          |> Enum.map(&%{"tool" => &1["name"], "summary" => &1["summary"]})

        {provider, apis}
      end)

    {connects, provider_apis}
  end

  defp openai_tools(specs) do
    Enum.map(specs, fn spec ->
      %{
        "type" => "function",
        "function" => %{
          "name" => spec["name"],
          "description" => spec["description"],
          "parameters" => spec["input_schema"]
        }
      }
    end)
  end

  defp chat_complete(messages, tools, opts) do
    url = String.trim_trailing(opts[:base_url], "/") <> "/chat/completions"
    key = opts[:api_key_env] && System.get_env(opts[:api_key_env])
    headers = if is_binary(key) and key != "", do: [{"authorization", "Bearer #{key}"}], else: []

    body =
      %{
        "model" => opts[:model],
        "messages" => messages,
        "max_tokens" => opts[:max_tokens] || 4_096,
        "temperature" => 0
      }
      |> then(fn b -> if tools != [], do: Map.put(b, "tools", tools), else: b end)

    case Req.post(url,
           json: body,
           headers: headers,
           receive_timeout: opts[:timeout_ms] || 120_000
         ) do
      {:ok, %{status: status, body: resp}} when status in 200..299 and is_map(resp) ->
        {:ok, resp}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_usage(%{"usage" => u}) when is_map(u) do
    cached =
      get_in(u, ["prompt_tokens_details", "cached_tokens"]) ||
        u["cache_read_input_tokens"] ||
        0

    %{
      "prompt_tokens" => u["prompt_tokens"] || u["input_tokens"] || 0,
      "cached_tokens" => cached,
      "completion_tokens" => u["completion_tokens"] || u["output_tokens"] || 0
    }
  end

  defp extract_usage(_),
    do: %{"prompt_tokens" => 0, "cached_tokens" => 0, "completion_tokens" => 0}

  defp add_usage(a, b) do
    %{
      "prompt_tokens" => (a["prompt_tokens"] || 0) + (b["prompt_tokens"] || 0),
      "cached_tokens" => (a["cached_tokens"] || 0) + (b["cached_tokens"] || 0),
      "completion_tokens" => (a["completion_tokens"] || 0) + (b["completion_tokens"] || 0)
    }
  end

  defp decode_args(raw) when is_map(raw), do: raw

  defp decode_args(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_args(_), do: %{}

  defp filter_cases(cases, nil), do: cases

  defp filter_cases(cases, names_csv) do
    wanted =
      names_csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()

    Enum.filter(cases, &MapSet.member?(wanted, &1["name"]))
  end

  defp emit_jsonl(rows, nil) do
    Enum.each(rows, fn row -> IO.puts(Jason.encode!(row)) end)
  end

  defp emit_jsonl(rows, path) do
    path |> Path.dirname() |> File.mkdir_p!()
    body = Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n"
    File.write!(path, body)
  end
end

PromptAbEval.main(System.argv())
