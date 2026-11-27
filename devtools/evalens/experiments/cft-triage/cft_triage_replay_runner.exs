# Runs Evalens CFT Triage scenarios through production Elixir modules:
# - `worker_participation`: SalixAgent.SlackParticipationPrompt + SalixIM.Triage.Investigation.valid_decision?/1
# - `native_evaluator`: Salix.Bindings.TriageEvaluator.evaluate/2
#
# Supports single-item mode (`--input <payload.json>`) and batch mode (`--batch-dataset <dataset.json>`).

Application.ensure_all_started(:jason)
Application.ensure_all_started(:req)

defmodule EvalensCftProvider do
  def complete(messages, _tools, opts) do
    base_url = Map.get(opts, "base_url") || Map.get(opts, :base_url)
    model = Map.get(opts, "model") || Map.get(opts, :model) || "codex"
    before_send = Map.get(opts, :before_send)

    payload = %{
      "model" => model,
      "messages" =>
        Enum.map(messages, fn m ->
          role = Map.get(m, :role) || Map.get(m, "role") || "user"
          role_str = if to_string(role) == "summary", do: "system", else: to_string(role)
          content = Map.get(m, :content) || Map.get(m, "content") || ""
          %{"role" => role_str, "content" => content}
        end)
    }

    payload_bytes = Jason.encode!(payload)
    if is_function(before_send, 1), do: before_send.(payload_bytes)

    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

    case Req.post(url, body: payload_bytes, headers: [{"content-type", "application/json"}], receive_timeout: 120_000, retry: :transient, max_retries: 2) do
      {:ok, %Req.Response{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        {:final, text}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule EvalensCftTriageRunner do
  alias SalixAgent.SlackParticipationPrompt
  alias SalixIM.Triage.Investigation

  def main(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          input: :string,
          batch_dataset: :string,
          out: :string,
          model: :string,
          base_url: :string,
          revision: :string,
          concurrency: :integer
        ]
      )

    out_path = Keyword.fetch!(opts, :out)
    model = Keyword.get(opts, :model, "codex")
    base_url = Keyword.get(opts, :base_url) || System.fetch_env!("CFT_TRIAGE_EVAL_BASE_URL")
    revision = Keyword.get(opts, :revision, "HEAD")
    concurrency = Keyword.get(opts, :concurrency, 4)

    cond do
      Keyword.has_key?(opts, :input) ->
        payload = opts |> Keyword.fetch!(:input) |> File.read!() |> Jason.decode!()
        obs = run_payload(payload, base_url, model)
        File.write!(out_path, Jason.encode!(%{"observation" => obs}))

      Keyword.has_key?(opts, :batch_dataset) ->
        dataset = opts |> Keyword.fetch!(:batch_dataset) |> File.read!() |> Jason.decode!()
        items = dataset["items"] || []

        payloads =
          Enum.flat_map(items, fn item ->
            case item["input"] do
              %{"kind" => "counterfactual_pair", "base" => b, "variant" => v} -> [b, v]
              %{"payload" => p} -> [p]
              _ -> []
            end
          end)

        observations =
          payloads
          |> Task.async_stream(
            fn payload ->
              id = payload_id(payload)
              obs = run_payload(payload, base_url, model)
              IO.puts(:stderr, "[cft-runner] done #{id} -> #{obs["communicationKind"]}(d=#{obs["delegationCount"]}) in #{obs["latencyMs"]}ms")
              obs
            end,
            max_concurrency: concurrency,
            timeout: 180_000,
            ordered: true
          )
          |> Enum.map(fn
            {:ok, obs} -> obs
            {:exit, reason} -> raise "batch worker crashed: #{inspect(reason)}"
          end)

        File.write!(
          out_path,
          Jason.encode!(%{
            "revision" => revision,
            "model" => model,
            "observations" => observations
          })
        )

      true ->
        raise "Either --input or --batch-dataset is required"
    end
  end

  defp payload_id(%{"layer" => "worker_participation", "worker" => w}), do: w["itemId"]
  defp payload_id(%{"layer" => "native_evaluator", "native" => n}), do: n["itemId"]

  defp run_payload(%{"layer" => "worker_participation", "worker" => worker}, base_url, model) do
    t0 = System.monotonic_time(:millisecond)
    system_prompt = build_worker_system_prompt()
    user_prompt = build_worker_user_prompt(worker)

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_prompt}
    ]

    prompt_bytes = byte_size(system_prompt) + byte_size(user_prompt)

    raw_text =
      case EvalensCftProvider.complete(messages, [], %{"base_url" => base_url, "model" => model}) do
        {:final, text} -> text
        {:error, reason} -> raise "worker_participation provider error for #{worker["itemId"]}: #{inspect(reason)}"
      end

    decision = parse_json_object!(raw_text, worker["itemId"])
    valid? = Investigation.valid_decision?(decision)
    latency_ms = max(System.monotonic_time(:millisecond) - t0, 0)

    normalize_worker_observation(worker["itemId"], decision, valid?, prompt_bytes, latency_ms)
  end

  defp run_payload(%{"layer" => "native_evaluator", "native" => native}, base_url, model) do
    t0 = System.monotonic_time(:millisecond)
    model_input = native["modelInput"] || %{}

    unless is_binary(model_input["canonical_snapshot_bytes"]) do
      raise "native_evaluator item #{native["itemId"]} missing modelInput.canonical_snapshot_bytes"
    end

    eval_opts = [
      provider: EvalensCftProvider,
      provider_name: "evalens-openai",
      provider_opts: %{
        "protocol" => "openai",
        "base_url" => base_url,
        "api_key" => "local",
        "model" => model
      },
      transport_receipt: fn payload_bytes ->
        %{
          payload_sha256: :crypto.hash(:sha256, payload_bytes) |> Base.encode16(case: :lower),
          request_count: 1
        }
      end
    ]

    latency_fn = fn -> max(System.monotonic_time(:millisecond) - t0, 0) end

    case Salix.Bindings.TriageEvaluator.evaluate(model_input, eval_opts) do
      {:ok, decision, proof} ->
        prompt_bytes =
          if is_binary(proof["provider_payload_bytes"]),
            do: byte_size(proof["provider_payload_bytes"]),
            else: byte_size(model_input["canonical_snapshot_bytes"])

        normalize_native_observation(native["itemId"], decision, true, prompt_bytes, latency_fn.())

      {:error, {:provider_error, reason}} ->
        raise "native_evaluator provider error for #{native["itemId"]}: #{inspect(reason)}"

      {:error, reason} ->
        # Model failed strict TriageEvaluator contract validation; record explicitly as validationPassed=false.
        %{
          "itemId" => native["itemId"],
          "layer" => "native_evaluator",
          "communicationKind" => "silence",
          "silenceReason" => "low_confidence",
          "explanation" => "contract_validation_failed:#{inspect(reason)}",
          "delegationCount" => 0,
          "delegationTasks" => [],
          "contextCandidates" => [],
          "validationPassed" => false,
          "promptBytes" => byte_size(model_input["canonical_snapshot_bytes"]),
          "llmCalls" => 1,
          "latencyMs" => latency_fn.()
        }
    end
  end

  defp build_worker_system_prompt do
    protocol =
      if function_exported?(SlackParticipationPrompt, :triage_investigation_instructions, 0) do
        SlackParticipationPrompt.triage_investigation_instructions()
      else
        SlackParticipationPrompt.worker_instructions()
      end

    """
    #{protocol}

    ## Offline Replay Completion Format

    All authorized source reads (`read_source`, `read_context`, and any bounded workspace lookup findings) are already provided in the user message below. Do NOT attempt tool calls.
    Decide the exact `decision` JSON object that you would pass to `im_api.internal.triage.complete`.
    Return ONLY one raw JSON object (no markdown fences, no commentary) matching one of:
    - {"kind":"reply","text":"...","source_refs":["<ref>"]} (optional "context_candidates":[...])
    - {"kind":"reaction","emoji":"<allowed_emoji>","source_refs":["<one_ref>"]} (optional "context_candidates":[...])
    - {"kind":"silence","reason_code":"already_handled|no_useful_addition|insufficient_evidence","reason":"...","source_refs":["<ref>"]} (optional "context_candidates":[...])
    Copy source_refs strictly from the provided messages or context_sources.
    """
  end

  defp build_worker_user_prompt(worker) do
    snapshot = %{
      "channel_id" => worker["channelId"],
      "thread_ts" => worker["threadTs"],
      "target_route" => worker["targetRoute"] || "none",
      "is_scheduled_recheck" => worker["isRecheck"] == true,
      "recheck_context_refs" => worker["recheckContextRefs"] || [],
      "task_command" => worker["taskCommand"],
      "messages" => worker["messages"] || [],
      "channel_context" => worker["channelContext"],
      "stillfail_coordination" => worker["stillfailCoordination"],
      "context_sources" => worker["contextSources"] || [],
      "workspace_findings" => worker["workspaceFindings"] || [],
      "expression_context" => worker["expressionContext"]
    }

    "Frozen CFT Triage Worker snapshot:\n" <> Jason.encode!(snapshot, pretty: true)
  end

  defp parse_json_object!(raw_text, item_id) do
    trimmed = String.trim(raw_text)

    json =
      cond do
        String.starts_with?(trimmed, "{") ->
          trimmed

        match = Regex.named_captures(~r/```(?:json)?[ \t]*\r?\n(?<json>\{[\s\S]*?\})\r?\n```/i, trimmed) ->
          match["json"]

        match = Regex.run(~r/\{[\s\S]*\}/, trimmed) ->
          hd(match)

        true ->
          raise "no JSON object in worker output for #{item_id}: #{String.slice(trimmed, 0, 240)}"
      end

    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      other -> raise "invalid JSON in worker output for #{item_id}: #{inspect(other)}"
    end
  end

  defp normalize_worker_observation(item_id, decision, valid?, prompt_bytes, latency_ms) do
    kind = decision["kind"]
    silence_reason = normalize_silence_reason(decision["reason_code"])
    candidates = normalize_candidates(decision["context_candidates"])

    compact(%{
      "itemId" => item_id,
      "layer" => "worker_participation",
      "communicationKind" => kind,
      "silenceReason" => if(kind == "silence", do: silence_reason || "no_useful_addition"),
      "replyText" => if(kind == "reply", do: decision["text"]),
      "reactionEmoji" => if(kind == "reaction", do: decision["emoji"]),
      "explanation" => if(kind == "silence", do: decision["reason"]),
      "delegationCount" => 0,
      "delegationTasks" => [],
      "contextCandidates" => candidates,
      "validationPassed" => valid?,
      "promptBytes" => prompt_bytes,
      "llmCalls" => 1,
      "latencyMs" => latency_ms
    })
  end

  defp normalize_native_observation(item_id, decision, valid?, prompt_bytes, latency_ms) do
    comm = decision["communication"] || %{}
    kind = comm["kind"] || "silence"
    delegs = decision["delegations"] || []
    candidates = normalize_candidates(decision["context_candidates"])

    compact(%{
      "itemId" => item_id,
      "layer" => "native_evaluator",
      "communicationKind" => kind,
      "silenceReason" => if(kind == "silence", do: normalize_silence_reason(comm["reason"])),
      "replyText" => if(kind == "reply", do: comm["text"]),
      "reactionEmoji" => if(kind == "reaction", do: comm["emoji"]),
      "explanation" => if(kind == "silence", do: comm["explanation"]),
      "delegationCount" => length(delegs),
      "delegationTasks" => Enum.map(delegs, &to_string(&1["task"] || "")),
      "contextCandidates" => candidates,
      "validationPassed" => valid?,
      "promptBytes" => prompt_bytes,
      "llmCalls" => 1,
      "latencyMs" => latency_ms
    })
  end

  @valid_silence_reasons ~w(
    no_useful_addition already_handled insufficient_evidence no_actionable_request
    already_answered stale_or_changed outside_authority low_confidence duplicate worker_pending
  )

  defp normalize_silence_reason(r) when r in @valid_silence_reasons, do: r
  defp normalize_silence_reason(_), do: nil

  defp normalize_candidates(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"kind" => kind, "subject" => subject, "value" => value} = c
      when kind in ~w(project_fact decision follow_up follow_up_resolution) ->
        conf = if c["confidence"] == "explicit", do: "explicit", else: "inferred"

        entry =
          compact(%{
            "kind" => kind,
            "subject" => to_string(subject),
            "value" => to_string(value),
            "confidence" => conf,
            "followUpBasis" => c["follow_up_basis"],
            "recheckAfterHours" =>
              if(is_integer(c["recheck_after_hours"]) and c["recheck_after_hours"] > 0,
                do: c["recheck_after_hours"]
              ),
            "resolutionBasis" => c["resolution_basis"]
          })

        [entry]

      _ ->
        []
    end)
  end

  defp normalize_candidates(_), do: []

  defp compact(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end

EvalensCftTriageRunner.main(System.argv())
