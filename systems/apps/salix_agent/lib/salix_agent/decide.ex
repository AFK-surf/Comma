defmodule SalixAgent.Decide do
  @moduledoc "Bounded typed decisions for integer-C scripts and background Loops."

  @max_args 12 * 1024
  @key ~r/\A[A-Za-z0-9_-]{1,64}\z/

  def guidance do
    "Use decide inside scripts and background Loops that repeatedly classify runtime data or select sources. " <>
      "Complete judgments you can already make in the current conversation yourself. " <>
      "Do not call decide to outsource your reasoning or create a script for one isolated judgment. " <>
      "Its benefit is processing later data without waking you. Handle uncertainty, no match, and errors in the program."
  end

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["state", "questions"],
      "properties" => %{
        "state" => %{"type" => ["string", "object", "array"]},
        "questions" => %{
          "type" => "object",
          "minProperties" => 1,
          "maxProperties" => 8,
          "additionalProperties" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["type", "instructions"],
            "properties" => %{
              "type" => %{"type" => "string", "enum" => ["choice", "noul", "score"]},
              "instructions" => %{"type" => "string", "minLength" => 1},
              "criteria" => %{
                "type" => ["object", "array"],
                "description" =>
                  "choice: 2-32 keys mapped to descriptions; score: 2-10 ordered descriptions; noul: optional true/false descriptions. Keys: 1-64 ASCII letters, digits, underscores or hyphens."
              }
            }
          }
        }
      }
    }
  end

  def defs do
    [{"decide", guidance() <> " " <> contract(), schema(), &call/2, 5, [safety: "write"]}]
  end

  def contract do
    "Supply state and 1-8 independent typed questions, within 12 KiB. " <>
      "Results contain model and answers. choice returns choice, probabilities_bp and confidence_bp. " <>
      "noul returns probability_bp. score returns score_milli, probabilities_bp and confidence_bp. " <>
      "Probabilities and confidence use floor(value * 10000); scores use floor(level mean * 1000). " <>
      "Confidence is not correctness or the winning probability. Include a none option when needed. " <>
      "Errors return {error: {code}}. No retries, source reads, or automatic model fallback."
  end

  @doc "A compilable SDK example. Threshold 8000 is illustrative, not calibrated."
  def example_program(kind) when kind in [:script, :loop] do
    args = %{
      "state" => "Find meeting decisions",
      "questions" => %{
        "source" => %{
          "type" => "choice",
          "instructions" => "Choose a source or none",
          "criteria" => %{"meetings" => "Meeting decisions", "none" => "No suitable source"}
        }
      }
    }

    params = if kind == :script, do: %{"tool" => "decide", "args" => args}, else: args
    capability = if kind == :script, do: "salix.call", else: "decide"
    publish = if kind == :script, do: "script.result", else: "loop.state.put"
    field = if kind == :script, do: "value", else: "state"

    unpack =
      if kind == :loop do
        """
          sf_handle content = sf_json_get(value, "content");
          sf_i64 n = sf_json_read_string(content, buffer, sizeof(buffer));
          sf_drop(content); sf_drop(value);
          if (n < 0) return 3;
          value = sf_json_parse(buffer, (sf_u64)n);
        """
      else
        ""
      end

    receive_value =
      if kind == :script do
        """
        sf_handle ok = sf_json_get(reply, "ok");
        sf_i64 success = sf_json_bool(ok);
        sf_drop(ok);
        if (success != 1) { sf_drop(reply); return 1; }
        sf_handle value = sf_json_get(reply, "value");
        sf_drop(reply);
        """
      else
        "sf_handle value = reply;"
      end

    finish = if kind == :script, do: "return 0;", else: "for (;;) { sf_sleep_ms(1000); }"

    """
    #include "spinfoam.h"
    static const char REQUEST[] = #{Jason.encode!(Jason.encode!(params))};
    static char buffer[16384];
    SF_MAIN sf_i64 main(void) {
      sf_handle request = sf_json_parse(REQUEST, sizeof(REQUEST) - 1);
      sf_handle reply = sf_host_call("#{capability}", request, 10000);
      sf_drop(request);
      if (reply < 0) return reply;
    #{receive_value}
    #{unpack}
      sf_handle error = sf_json_get(value, "error");
      if (error >= 0) { sf_drop(error); sf_drop(value); return 2; }
      sf_handle answers = sf_json_get(value, "answers");
      sf_handle source = sf_json_get(answers, "source");
      sf_handle confidence = sf_json_get(source, "confidence_bp");
      sf_i64 bp = 0;
      sf_i64 parsed = sf_json_i64(confidence, &bp);
      sf_drop(confidence);
      if (parsed < 0) { sf_drop(source); sf_drop(answers); sf_drop(value); return 4; }
      sf_handle selected = bp >= 8000 ? sf_json_get(source, "choice") : sf_json_string("none");
      sf_handle decision = sf_json_object();
      sf_json_set(decision, "source", selected);
      sf_handle out = sf_json_object();
      sf_json_set(out, "#{field}", decision);
      sf_drop(decision);
      sf_handle stored = sf_host_call("#{publish}", out, 5000);
      sf_drop(out); sf_drop(selected); sf_drop(source); sf_drop(answers); sf_drop(value);
      if (stored < 0) return stored;
      sf_drop(stored);
      #{finish}
    }
    """
  end

  defp admit(ctx, nil), do: SalixAgent.Decide.Limits.admit(ctx.tenant_id, ctx.group_id)

  defp admit(ctx, deadline),
    do: SalixAgent.Decide.Limits.admit_until(ctx.tenant_id, ctx.group_id, deadline)

  def call(args, ctx, opts \\ []) do
    case run(args, ctx, opts[:admission_deadline], entrypoint: "decide", actor_type: "tool") do
      {:ok, answer} -> Jason.encode!(answer)
      {:error, code} -> Jason.encode!(%{"error" => %{"code" => code}})
    end
  end

  @doc """
  A decision requested by server code rather than an Agent tool call.

  `ctx` names the Agent, Session, Tenant and Group the request is attributed to
  and carries their `billing_context`. `opts` requires `:entrypoint`, the
  metering entrypoint, and takes `:admission_deadline` (monotonic ms). The
  result is `{:ok, answer}` or `{:error, code}` with the codes of `call/3`.
  """
  def system_call(args, ctx, opts) do
    entrypoint = Keyword.fetch!(opts, :entrypoint)
    run(args, ctx, opts[:admission_deadline], entrypoint: entrypoint, actor_type: "system")
  end

  @doc false
  def miniskill_call(args, ctx, deadline) do
    run(args, ctx, deadline,
      entrypoint: "miniskill",
      actor_type: "system",
      profile: :miniskill,
      deadline: deadline
    )
  end

  defp run(args, ctx, deadline, metering) do
    started = System.monotonic_time()

    result =
      with :ok <- validate(args, metering[:profile]),
           {:ok, config} <- config(),
           {:ok, ctx} <- context(ctx),
           :ok <- admit(ctx, deadline) do
        SalixAgent.LLM.decide(
          args,
          config
          |> Map.put(:deadline, metering[:deadline])
          |> Map.put(:profile, metering[:profile]),
          ctx,
          metering
        )
      end

    outcome =
      case result do
        {:ok, _, _} -> "ok"
        {:error, :timeout} -> "timeout"
        {:error, :rate_limited} -> "over_budget"
        {:error, %{decide_error: :timeout}} -> "timeout"
        {:error, %{decide_error: :rate_limited}} -> "over_budget"
        {:error, _} -> "error"
      end

    Salix.Telemetry.emit_operation(
      "salix_agent",
      "decide",
      "salix",
      outcome,
      System.monotonic_time() - started
    )

    case result do
      {:ok, answer, _meta} -> {:ok, answer}
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  defp error_code(%{decide_error: code}), do: error_code(code)

  defp error_code({:billing_unavailable, _}), do: "billing_unavailable"

  defp error_code(code)
       when code in [
              :invalid_request,
              :not_configured,
              :context_unavailable,
              :rate_limited,
              :unavailable,
              :timeout,
              :provider_error,
              :invalid_response,
              :result_too_large
            ],
       do: Atom.to_string(code)

  defp error_code(_), do: "unavailable"

  def config do
    cfg = Application.get_env(:salix_agent, :decide, [])
    endpoint = Keyword.get(cfg, :endpoint, "https://api.typesafe.ai/v1/systemone")
    key = Keyword.get(cfg, :api_key)
    model = Keyword.get(cfg, :model, "jev-1.13.0")
    uri = if is_binary(endpoint), do: URI.parse(endpoint), else: %URI{}

    if text?(key) and text?(model) and byte_size(model) <= 128 and
         uri.scheme in ["http", "https"] and text?(uri.host) and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok,
       %{
         api_key: key,
         endpoint: endpoint,
         model: model,
         provider: "typesafe",
         protocol: "decisions"
       }}
    else
      {:error, :not_configured}
    end
  rescue
    _ -> {:error, :not_configured}
  end

  defp context(ctx) do
    if Enum.all?([:agent_id, :session_id, :tenant_id, :group_id], &text?(ctx[&1])) do
      case ctx do
        %{billing_context: billing} when is_map(billing) ->
          {:ok, ctx}

        _ ->
          case SalixAgent.InternalSessionStore.read(ctx.agent_id, ctx.session_id) do
            {:ok, session} ->
              billing = SalixAgent.InternalSession.get(session, :billing_context) || %{}
              {:ok, Map.put(ctx, :billing_context, billing)}

            _ ->
              {:error, :context_unavailable}
          end
      end
    else
      {:error, :context_unavailable}
    end
  rescue
    _ -> {:error, :context_unavailable}
  catch
    :exit, _ -> {:error, :context_unavailable}
  end

  def validate(args), do: validate(args, nil)

  def validate(args, profile) when is_map(args) do
    max_args = if profile == :miniskill, do: 64 * 1024, else: @max_args
    # The encoded request bounds candidate/question cardinality. The public tool stays at eight.
    max_questions = if profile == :miniskill, do: max_args, else: 8

    with true <- Enum.sort(Map.keys(args)) == ["questions", "state"],
         true <- is_binary(args["state"]) or is_map(args["state"]) or is_list(args["state"]),
         {:ok, encoded} <- Jason.encode(args),
         true <- byte_size(encoded) <= max_args,
         questions when is_map(questions) and map_size(questions) in 1..max_questions//1 <-
           args["questions"],
         true <- Enum.all?(questions, fn {key, q} -> valid_key?(key) and question?(q) end) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def validate(_, _), do: {:error, :invalid_request}

  defp question?(q) when is_map(q) do
    Enum.all?(Map.keys(q), &(&1 in ["type", "instructions", "criteria"])) and
      text?(q["instructions"]) and criteria?(q["type"], q["criteria"])
  end

  defp question?(_), do: false

  defp criteria?("choice", c) when is_map(c) and map_size(c) in 2..32,
    do: Enum.all?(c, fn {k, v} -> valid_key?(k) and text?(v) end)

  defp criteria?("score", c) when is_list(c), do: length(c) in 2..10 and Enum.all?(c, &text?/1)
  defp criteria?("noul", nil), do: true

  defp criteria?("noul", %{"true" => yes, "false" => no} = c),
    do: map_size(c) == 2 and text?(yes) and text?(no)

  defp criteria?(_, _), do: false
  defp valid_key?(k), do: is_binary(k) and Regex.match?(@key, k)
  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  def decode(body, questions, max_bytes \\ 15 * 1024) do
    with %{"model" => model, "answers" => answers, "usage" => usage} <- body,
         true <- text?(model) and byte_size(model) <= 128 and is_map(answers),
         true <- MapSet.new(Map.keys(answers)) == MapSet.new(Map.keys(questions)),
         true <- valid_usage?(usage),
         {:ok, normalized} <- normalize_answers(questions, answers) do
      result = %{"model" => model, "answers" => normalized}
      encoded = Jason.encode!(result)
      # Loops carry JSON text inside a JSON envelope. Check the escaped form too.
      envelope =
        Jason.encode!(%{
          "ok" => true,
          "value" => %{"tool" => "decide", "error" => false, "content" => encoded}
        })

      if byte_size(envelope) <= max_bytes,
        do:
          {:ok, result,
           %{
             "model" => model,
             "usage" => %{
               "prompt_tokens" => usage["input_tokens"],
               "completion_tokens" => usage["output_tokens"]
             }
           }},
        else: {:error, :result_too_large}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp valid_usage?(%{"input_tokens" => i, "output_tokens" => o}),
    do: is_integer(i) and i >= 0 and is_integer(o) and o >= 0

  defp valid_usage?(_), do: false

  defp normalize_answers(questions, answers) do
    Enum.reduce_while(questions, {:ok, %{}}, fn {key, question}, {:ok, acc} ->
      case answer(question, answers[key]) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        _ -> {:halt, {:error, :invalid_response}}
      end
    end)
  end

  defp answer(%{"type" => "noul"}, %{"type" => "noul", "noul" => p}) do
    if probability?(p),
      do: {:ok, %{"type" => "noul", "probability_bp" => scaled(p, 10000)}},
      else: :error
  end

  defp answer(%{"type" => type, "criteria" => criteria}, %{"type" => type} = a)
       when type in ["choice", "score"] do
    keys =
      if type == "choice",
        do: Map.keys(criteria),
        else: Enum.map(0..(length(criteria) - 1), &Integer.to_string/1)

    p = a["probabilities"]

    with true <- probability?(a["confidence"]),
         true <- distribution?(p, keys),
         true <- valid_value?(type, a, criteria) do
      value = %{
        "type" => type,
        "confidence_bp" => scaled(a["confidence"], 10000),
        "probabilities_bp" => Map.new(p, fn {k, v} -> {k, scaled(v, 10000)} end)
      }

      value =
        if type == "choice",
          do: Map.put(value, "choice", a["choice"]),
          else: Map.put(value, "score_milli", scaled(a["score"], 1000))

      {:ok, value}
    else
      _ -> :error
    end
  end

  defp answer(_, _), do: :error

  # Jev rounds each probability to two decimals, so a faithful distribution can
  # miss 1 by up to 0.005 per option: seven options often sum to 0.99. The
  # 1.0e-9 only absorbs binary float error at that bound.
  defp distribution?(p, keys) when is_map(p) do
    values = Map.values(p)

    MapSet.new(Map.keys(p)) == MapSet.new(keys) and Enum.all?(values, &probability?/1) and
      abs(Enum.sum(values) - 1) <= 0.005 * length(values) + 1.0e-9
  end

  defp distribution?(_, _), do: false

  defp valid_value?("choice", a, criteria) do
    Map.has_key?(criteria, a["choice"]) and
      a["probabilities"][a["choice"]] == Enum.max(Map.values(a["probabilities"]))
  end

  defp valid_value?("score", a, criteria) do
    score = a["score"]

    mean =
      Enum.reduce(a["probabilities"], 0, fn {k, p}, sum -> sum + String.to_integer(k) * p end)

    is_number(score) and score >= 0 and score <= length(criteria) - 1 and
      abs(mean - score) <= 0.01
  end

  defp probability?(v), do: is_number(v) and v >= 0 and v <= 1
  defp scaled(v, scale), do: floor(v * scale)
end
