defmodule SalixAgent.TrajectoryEval do
  @moduledoc """
  L1 heuristic trajectory scoring over a session transcript window.

  Pure functions only: no I/O, no LLM calls, no clock reads. The runner
  (`SalixAgent.TrajectoryEval.Runner`) slices the transcript and persists the
  findings; this module just detects behavioural signals in the slice.

  Two signal families:

    * Text signals over assistant messages — confusion/backtracking markers
      ("wait", "let me reconsider", 「等等」) and shortcut/goal-degradation
      markers ("simpler approach", "as a workaround", 「先跳过」).
    * Structural signals over the tool-call sequence — loops of identical
      calls with identical results, repeated errors of one tool, alternating
      A-B-A-B patterns, and abnormally long activation streaks. Thresholds
      mirror the OpenHands stuck detector defaults (4 / 3 / 6).

  The evaluation window is the transcript slice after the last user message,
  capped at `window_limit` messages, so cross-round loops within one
  activation are visible while settled history is not re-flagged.
  """

  @window_limit 60

  @tool_loop_threshold 4
  @tool_error_loop_threshold 3
  @alternating_threshold 6
  @excessive_turns_threshold 12

  @evidence_quote_max_chars 160

  # Sentence-initial backtracking markers. "wait" excludes the imperative
  # "wait for/until/while/on ..." usage, which is a legitimate instruction.
  @confusion_regex ~r/^(?:wait(?!\s+(?:for|until|while|on))|hold on|hmm+|actually|oh no|scratch that|let me (?:reconsider|rethink|re-think|start over)|i was wrong|that['’]?s (?:not right|wrong)|等等|等一下|不对|咦|重新想)(?:$|[\s,，.。!！?？:：…-])/iu

  @shortcut_regex ~r/simpler (?:approach|way|method|solution)|simplif(?:y|ied) (?:the )?approach|as a workaround|work(?:ing)? around (?:this|the|it)|skip (?:this|that|it) for now|for now[,，]|instead of (?:fixing|debugging|investigating)|quick(?:\s|-)?(?:hack|fix)|hacky|temporar(?:y|ily) (?:fix|workaround|solution)|先跳过|绕过(?:这个|该)?问题|暂时先|简化(?:一下)?(?:方案|做法|处理)|换(?:个|一种)?更简单/iu

  @sentence_split_regex ~r/(?<=[.!?…。！？\n])\s*/u

  @type finding :: %{
          metric: String.t(),
          score: float(),
          hits: non_neg_integer(),
          evidence: [%{message_id: non_neg_integer() | nil, quote: String.t()}]
        }

  @doc """
  Evaluate a transcript window. Returns findings plus window metadata.

  `messages` is the full session transcript in order (`State.messages`);
  the window slice is computed here.
  """
  @spec evaluate([map()], keyword()) :: %{findings: [finding()], window: map()}
  def evaluate(messages, opts \\ []) when is_list(messages) do
    window = window(messages, opts)
    calls = tool_call_sequence(window)

    findings =
      Enum.reject(
        [
          text_finding("confusion", @confusion_regex, window),
          text_finding("shortcut", @shortcut_regex, window),
          tool_loop_finding(calls),
          tool_error_loop_finding(calls),
          alternating_loop_finding(calls),
          excessive_turns_finding(window)
        ],
        &is_nil/1
      )

    %{findings: findings, window: window_meta(window)}
  end

  @doc "Transcript slice after the last user message, capped at the window limit."
  @spec window([map()], keyword()) :: [map()]
  def window(messages, opts \\ []) when is_list(messages) do
    limit = opts[:window_limit] || @window_limit

    messages
    |> Enum.reverse()
    |> Enum.take_while(fn m -> field(m, :role) != "user" end)
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  # ---- text signals ----

  defp text_finding(metric, regex, window) do
    hits =
      for msg <- window,
          field(msg, :role) == "assistant",
          text = message_text(msg),
          text != "",
          quote <- text_hits(text, regex) do
        %{message_id: field(msg, :id), quote: quote}
      end

    case hits do
      [] ->
        nil

      hits ->
        scale = if metric == "confusion", do: 3, else: 2

        %{
          metric: metric,
          score: min(1.0, length(hits) / scale),
          hits: length(hits),
          evidence: Enum.take(hits, 5)
        }
    end
  end

  # Both regexes are applied per sentence: the confusion regex is anchored to
  # the sentence start, the shortcut regex may match anywhere within it.
  defp text_hits(text, regex) do
    text
    |> String.split(@sentence_split_regex, trim: true)
    |> Enum.filter(&Regex.match?(regex, &1))
    |> Enum.map(&clip_quote/1)
  end

  defp clip_quote(sentence) do
    sentence
    |> String.trim()
    |> String.slice(0, @evidence_quote_max_chars)
  end

  # ---- structural signals ----

  # One entry per issued tool call, in transcript order, joined to its result.
  defp tool_call_sequence(window) do
    results =
      for msg <- window,
          field(msg, :role) == "tool",
          id = field(msg, :tool_call_id),
          into: %{} do
        {id,
         %{
           status: field(msg, :status),
           error_class: field(msg, :error_class),
           content: message_text(msg),
           message_id: field(msg, :id)
         }}
      end

    for msg <- window,
        field(msg, :role) == "assistant",
        call <- field(msg, :tool_calls) || [] do
      name = call["name"] || call[:name]
      args = call["args"] || call[:args] || %{}
      result = results[call["id"] || call[:id]]

      %{
        name: name,
        fingerprint: :erlang.phash2({name, args}),
        result_fingerprint: result && :erlang.phash2(result.content),
        error?: result_error?(result),
        message_id: (result && result.message_id) || field(msg, :id),
        summary: call_summary(name, args)
      }
    end
  end

  defp result_error?(nil), do: false
  defp result_error?(result), do: result.status == "error" or not is_nil(result.error_class)

  defp call_summary(name, args) do
    args_preview =
      case Jason.encode(args) do
        {:ok, json} -> String.slice(json, 0, 80)
        _ -> ""
      end

    "#{name} #{args_preview}"
  end

  defp tool_loop_finding(calls) do
    {run, last} =
      max_run(calls, fn a, b ->
        a.fingerprint == b.fingerprint and a.result_fingerprint == b.result_fingerprint and
          not is_nil(a.result_fingerprint)
      end)

    structural_finding("tool_loop", run, @tool_loop_threshold, last)
  end

  # A successful call in between breaks the streak: runs are counted only over
  # consecutive erroring calls of the same tool.
  defp tool_error_loop_finding(calls) do
    {run, last} =
      max_run(calls, fn a, b -> a.error? and b.error? and a.name == b.name end)

    run = if last && last.error?, do: run, else: 0
    structural_finding("tool_error_loop", run, @tool_error_loop_threshold, last)
  end

  defp alternating_loop_finding(calls) do
    {run, last} = max_alternating_run(calls)
    structural_finding("alternating_loop", run, @alternating_threshold, last)
  end

  # Longest A-B-A-B stretch (A != B) in the call sequence, with the call that
  # ends it. A stretch of n calls satisfying fp[i] == fp[i-2] != fp[i-1]
  # yields run length n.
  defp max_alternating_run(calls) when length(calls) < 3, do: {0, nil}

  defp max_alternating_run(calls) do
    calls
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.reduce({0, nil, 0}, fn [a, b, c], {best, best_last, run} ->
      run =
        if a.fingerprint == c.fingerprint and a.fingerprint != b.fingerprint,
          do: max(run + 1, 3),
          else: 0

      if run > best, do: {run, c, run}, else: {best, best_last, run}
    end)
    |> then(fn {best, best_last, _run} -> {best, best_last} end)
  end

  defp structural_finding(metric, run, threshold, last) when run >= threshold do
    %{
      metric: metric,
      score: min(1.0, 0.6 + 0.1 * (run - threshold)),
      hits: run,
      evidence: [
        %{
          message_id: last && last.message_id,
          quote: "#{metric} run of #{run}" <> if(last, do: ": #{last.summary}", else: "")
        }
      ]
    }
  end

  defp structural_finding(_metric, _run, _threshold, _last), do: nil

  # Longest run of adjacent items satisfying `same?/2`, with the item that
  # ends the run. A single item counts as a run of 1.
  defp max_run(items, same?) do
    items
    |> Enum.reduce({0, nil, 0, nil}, fn item, {best, best_last, run, prev} ->
      run = if prev != nil and same?.(prev, item), do: run + 1, else: 1

      if run > best,
        do: {run, item, run, item},
        else: {best, best_last, run, item}
    end)
    |> then(fn {best, best_last, _run, _prev} -> {best, best_last} end)
  end

  defp excessive_turns_finding(window) do
    turns = Enum.count(window, fn m -> field(m, :role) == "assistant" end)

    if turns >= @excessive_turns_threshold do
      %{
        metric: "excessive_turns",
        score: min(1.0, turns / (2 * @excessive_turns_threshold)),
        hits: turns,
        evidence: [
          %{message_id: nil, quote: "#{turns} assistant turns since the last user message"}
        ]
      }
    end
  end

  # ---- window metadata ----

  defp window_meta(window) do
    ids = for m <- window, id = field(m, :id), do: id

    round_id =
      window
      |> Enum.reverse()
      |> Enum.find_value(fn m ->
        if field(m, :role) == "assistant", do: field(m, :round_id)
      end)

    %{
      message_count: length(window),
      from_message_id: List.first(ids),
      to_message_id: List.last(ids),
      round_id: round_id
    }
  end

  # ---- message access (atom or string keys) ----

  defp field(msg, key) when is_map(msg), do: msg[key] || msg[Atom.to_string(key)]

  defp message_text(msg) do
    case field(msg, :content) do
      text when is_binary(text) ->
        text

      blocks when is_list(blocks) ->
        blocks
        |> Enum.map(fn
          %{"text" => text} when is_binary(text) -> text
          %{text: text} when is_binary(text) -> text
          _ -> ""
        end)
        |> Enum.join("\n")

      _ ->
        ""
    end
  end
end
