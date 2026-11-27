# Runs one Evalens ProactiveScenarioInput JSON through production
# CommaWeb.ProactiveCheck / RecommendationRenderer and writes
# `{"observations": [...]}` matching `MixRunnerOutputSchema` in `runner.ts`.

Application.ensure_all_started(:jason)
Application.ensure_all_started(:req)

defmodule EvalensProactiveRunner do
  alias Comma.Data.MemberSourceItem
  alias CommaWeb.{MemberPortrait, ProactiveCheck, ProactiveMatters, RecommendationRenderer}

  def main(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [input: :string, out: :string, model: :string, base_url: :string]
      )

    input = opts |> Keyword.fetch!(:input) |> File.read!() |> Jason.decode!()
    out_path = Keyword.fetch!(opts, :out)
    model = Keyword.get(opts, :model, "codex")
    base_url = Keyword.get(opts, :base_url) || System.fetch_env!("PROACTIVE_EVAL_BASE_URL")
    candidate_mode? = Code.ensure_loaded?(CommaWeb.ProactiveResearch)

    ctx = input["context"] || %{}
    items = input["items"] || []

    observations =
      Enum.map(items, &screen_one(&1, ctx, base_url, model, candidate_mode?))

    File.write!(out_path, Jason.encode!(%{"observations" => observations}))
  end

  defp screen_one(item, ctx, base_url, model, candidate_mode?) do
    t0 = System.monotonic_time(:millisecond)
    now = parse_now(item["screenedAt"] || item["firstSeenAt"])
    locale = ctx["locale"] || "en"
    timezone = ctx["timezone"] || "UTC"
    portrait = Enum.map(ctx["portraitStatements"] || [], &%{"text" => &1})

    home =
      Enum.map(ctx["home"] || [], fn m ->
        %{
          "kind" => "message",
          "actor_type" => m["from"] || "user",
          "content" => [%{"type" => "text", "text" => m["text"] || ""}]
        }
      end)

    matters = ctx["knownMatters"] || []
    notebook = ctx["notebook"]
    view = build_view(item, now, candidate_mode?)

    res =
      if candidate_mode? do
        screen_candidate(
          view,
          home,
          portrait,
          now,
          matters,
          notebook,
          ctx["poolItems"] || [],
          locale,
          timezone,
          base_url,
          model
        )
      else
        screen_baseline(view, home, portrait, now, matters, notebook, locale, timezone, base_url, model)
      end

    Map.merge(res, %{
      "itemId" => item["itemId"],
      "latencyMs" => max(System.monotonic_time(:millisecond) - t0, 0)
    })
  end

  defp parse_now(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.add(dt, 60, :second)
      _ -> DateTime.from_unix!(0)
    end
  end

  defp parse_now(_), do: DateTime.from_unix!(0)

  defp build_view(item, _now, _candidate_mode?) do
    first_seen =
      case item["firstSeenAt"] do
        iso when is_binary(iso) ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _} -> dt
            _ -> nil
          end

        _ ->
          nil
      end

    record =
      struct!(MemberSourceItem, %{
        id: item["itemId"],
        source_id: "evalens-#{item["toolkit"]}",
        toolkit: item["toolkit"],
        url: item["url"],
        app: item["app"] || item["toolkit"] || "",
        title: item["title"] || "",
        excerpt: item["excerpt"] || "",
        context: if(item["contextText"], do: %{"text" => item["contextText"]}, else: nil),
        relationship: item["relationship"],
        recipient: item["recipient"],
        facts: item["facts"] || %{},
        provider_ids: item["providerIds"] || %{},
        first_seen_at: first_seen
      })

    [grouped | _] = ProactiveMatters.group([ProactiveCheck.view(record)])
    grouped
  end

  defp screen_baseline(view, home, portrait, now, matters, notebook, locale, timezone, base_url, model) do
    input = ProactiveCheck.attention_input([view], home, portrait, now, matters, notebook)
    messages = RecommendationRenderer.attention_messages(input, locale, timezone, now)
    bytes = Enum.reduce(messages, 0, &(&2 + byte_size(&1.content)))

    with {:ok, text} <- call_llm(messages, base_url, model),
         {:ok, answer} <- decode(text),
         {:ok, decided} <- ProactiveCheck.decide(answer, view, now, matters) do
      format_decision(decided, now, nil, bytes, 1)
    else
      {:error, reason} -> raise "baseline screening failed: #{inspect(reason)}"
    end
  end

  defp screen_candidate(view, home, portrait, now, matters, notebook, pool, locale, timezone, base_url, model) do
    portrait_terms = MemberPortrait.targets(portrait)["terms"] || []
    view = apply(ProactiveCheck, :attach_portrait_terms, [view, portrait_terms])
    allow_investigate? = view["relationship"] != "in_your_junk_folder"

    pool_items =
      Enum.map(pool, fn p ->
        %{
          "app" => p["app"] || p["toolkit"],
          "toolkit" => p["toolkit"],
          "title" => p["title"],
          "excerpt" => p["excerpt"],
          "url" => p["url"],
          "context" => if(p["contextText"], do: %{"text" => p["contextText"]}, else: nil)
        }
      end)

    env = apply(CommaWeb.ProactiveResearch, :from_replay, [%{"pool_items" => pool_items}, view["url"]])

    local =
      if allow_investigate?,
        do: apply(CommaWeb.ProactiveResearch, :local_context, [view, env]),
        else: []

    input = ProactiveCheck.attention_input([view], home, portrait, now, matters, notebook)
    input = if local == [], do: input, else: Map.put(input, "relatedContext", local)

    messages =
      RecommendationRenderer.attention_messages(input, locale, timezone, now,
        allow_investigate: allow_investigate?
      )

    bytes = Enum.reduce(messages, 0, &(&2 + byte_size(&1.content)))

    with {:ok, text} <- call_llm(messages, base_url, model),
         {:ok, answer} <- decode(text),
         {:ok, round1} <-
           ProactiveCheck.decide(answer, view, now, matters,
             allow_investigate: allow_investigate?,
             related_context: local,
             notebook: notebook
           ) do
      case round1 do
        {:investigate, queries} ->
          findings = apply(CommaWeb.ProactiveResearch, :run, [queries, env, [allow_web_read: false]])
          messages2 =
            RecommendationRenderer.attention_messages(
              Map.put(input, "research", findings),
              locale,
              timezone,
              now,
              allow_investigate: false
            )

          bytes2 = Enum.reduce(messages2, 0, &(&2 + byte_size(&1.content)))
          research = %{"localMatches" => length(local), "queries" => queries}

          with {:ok, text2} <- call_llm(messages2, base_url, model),
               {:ok, answer2} <- decode(text2),
               {:ok, final} <-
                 ProactiveCheck.decide(answer2, view, now, matters,
                   allow_investigate: false,
                   related_context: local,
                   research: findings,
                   notebook: notebook
                 ) do
            format_decision(final, now, research, bytes + bytes2, 2)
          else
            {:error, reason} -> raise "candidate round 2 failed: #{inspect(reason)}"
          end

        other ->
          research = if local == [], do: nil, else: %{"localMatches" => length(local), "queries" => []}
          format_decision(other, now, research, bytes, 1)
      end
    else
      {:error, reason} -> raise "candidate round 1 failed: #{inspect(reason)}"
    end
  end

  defp format_decision(:unclear, _now, research, bytes, calls) do
    compact(%{
      "outcome" => "deferred",
      "decision" => "unclear",
      "research" => research,
      "promptBytes" => bytes,
      "llmCalls" => calls
    })
  end

  defp format_decision({:settle, decision, assessment}, _now, research, bytes, calls) do
    compact(%{
      "outcome" => "quiet",
      "decision" => decision,
      "role" => assessment["role"],
      "reason" => assessment["reason"],
      "research" => research,
      "promptBytes" => bytes,
      "llmCalls" => calls
    })
  end

  defp format_decision({:handoff, item, message}, now, research, bytes, calls) do
    pool =
      cond do
        get_in(item, ["assessment", "code"]) == true -> "code"
        get_in(item, ["assessment", "signal"]) == true -> "signal"
        ProactiveCheck.reserve_eligible?(item, now) -> "reserve"
        true -> "ordinary"
      end

    compact(%{
      "outcome" => "routed",
      "decision" => item["decision"],
      "role" => item["role"],
      "pool" => pool,
      "message" => message,
      "reason" => get_in(item, ["assessment", "reason"]),
      "research" => research,
      "promptBytes" => bytes,
      "llmCalls" => calls
    })
  end

  defp compact(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) or v == "" end)

  defp call_llm(messages, base_url, model) do
    payload = %{
      "model" => model,
      "messages" => Enum.map(messages, &%{"role" => to_string(&1.role), "content" => &1.content})
    }

    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

    case Req.post(url, json: payload, receive_timeout: 120_000, retry: :transient, max_retries: 2) do
      {:ok, %Req.Response{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        {:ok, text}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(text) when is_binary(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> Comma.RecommendationDraft.decode(json)
      _ -> {:error, :no_json_in_answer}
    end
  end
end

EvalensProactiveRunner.main(System.argv())
