defmodule SalixLlm.SiteProxy do
  @moduledoc """
  Raw OpenAI-chat-shaped LLM proxy for agent-hosted site APIs — the Salix
  counterpart of willow's `llmClient.Complete/CompleteStream` as used by
  `internal/api/site_llm.go`.

  Unlike the agent-round clients (which speak Salix conversation shapes),
  this takes the site client's OpenAI-style request (`messages`,
  `max_tokens`, `temperature`, `top_p`) verbatim, dispatches by the
  template-resolved protocol exactly like willow's `marshalRequest`, and
  normalizes every provider's response to willow's `ChatResponse` /
  `StreamChunk` JSON shapes:

    * `""` / `"chat_completions"` → `{base}/chat/completions` passthrough
      (model forced by the caller; `max_completion_tokens` for
      gpt-5/o1/o3/o4 models; `stream_options.include_usage` on streams)
    * `"anthropic"` → `{base}/v1/messages` (Salix's Anthropic URL
      convention, sharing `SalixLlm.Anthropic`'s URL and header construction so
      `auth_token` Bearer templates and `default_headers` work here too),
      response converted via willow's `anthropicResponseToChat` mapping
      (stop-reason → finish_reason, cache-aware usage)
    * `"responses"` → `{base}/responses`, output items → chat choices

  Streaming calls `on_chunk` with one normalized chunk map per SSE event and
  returns `{:ok, usage}` on clean completion or `{:error, reason, usage}`
  after a partial stream — the caller decides whether to emit `[DONE]`
  (willow: only on success) and bills whatever usage was observed. A stream
  that goes quiet is abandoned by `SalixLlm.StreamWatchdog` and reported as
  `{:error, {:stream_idle_timeout, meta}, usage}`.
  """

  alias SalixLlm.{ProviderConfig, SSE}

  @type req :: %{
          optional(:model) => String.t(),
          optional(:prompt_cache_key) => String.t(),
          optional(:messages) => [map()],
          optional(:max_tokens) => integer(),
          optional(:temperature) => number() | nil,
          optional(:top_p) => number() | nil
        }

  @receive_timeout 300_000

  @spec complete(map() | keyword() | nil, req(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete(llm_opts, req, opts \\ []) do
    cfg = ProviderConfig.resolve(llm_opts)
    {url, body, headers} = marshal(cfg, req, false)
    receive_timeout = receive_timeout(opts)

    case Req.post(url,
           json: body,
           headers: headers,
           receive_timeout: receive_timeout,
           retry: Keyword.get(opts, :retry, :transient)
         ) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, decode_response(cfg.protocol, SalixLlm.Http.normalize(resp))}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_timeout(opts) do
    case Keyword.get(opts, :receive_timeout, @receive_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @receive_timeout
    end
  end

  @spec stream(map() | keyword() | nil, req(), (map() -> any())) ::
          {:ok, map() | nil} | {:error, term(), map() | nil}
  def stream(llm_opts, req, on_chunk) when is_function(on_chunk, 1) do
    cfg = ProviderConfig.resolve(llm_opts)
    {url, body, headers} = marshal(cfg, req, true)

    decoder = stream_decoder(cfg.protocol)
    init = %{buffer: "", usage: nil, decoder: decoder, on_chunk: on_chunk, meta: %{}, error: nil}

    into = fn {:data, data}, {req_, resp} ->
      resp =
        if resp.status == 200 do
          st = Req.Response.get_private(resp, :site_proxy, init)
          Req.Response.put_private(resp, :site_proxy, consume(st, data))
        else
          resp
        end

      {:cont, {req_, resp}}
    end

    # `SalixLlm.StreamWatchdog` abandons a stream that stops producing events;
    # that surfaces as `{:error, {:stream_idle_timeout, _}, usage}` below, with
    # whatever usage the stream had reported before it went quiet.
    case SalixLlm.StreamWatchdog.post(url,
           json: body,
           headers: headers,
           receive_timeout: @receive_timeout,
           retry: false,
           into: into
         ) do
      {:ok, %{status: 200} = resp} ->
        st = Req.Response.get_private(resp, :site_proxy, init)

        # Every provider can fail *after* the 200 and the first chunks, by
        # emitting an error event on the open stream. That is a failed request:
        # the caller must skip `[DONE]` so clients see the truncation.
        case st.error do
          nil -> {:ok, st.usage}
          error -> {:error, {:stream_error, error}, st.usage}
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:http, status, resp_body}, nil}

      {:error, reason, partial} ->
        {:error, reason, partial_usage(partial, init)}
    end
  end

  # A stream that fails after it started — a stall, a dropped connection — has
  # often already reported usage: Anthropic sends the input and cache counters
  # on `message_start`. The contract is to bill what was observed.
  defp partial_usage(%Req.Response{status: 200} = resp, init),
    do: Req.Response.get_private(resp, :site_proxy, init).usage

  defp partial_usage(_partial, _init), do: nil

  # ---- request marshaling (willow marshalRequest) ----

  defp marshal(cfg, req, stream?) do
    case cfg.protocol do
      "anthropic" -> marshal_anthropic(cfg, req, stream?)
      "responses" -> marshal_responses(cfg, req, stream?)
      _ -> marshal_chat(cfg, req, stream?)
    end
  end

  defp bearer_headers(cfg) do
    [
      {"authorization", "Bearer #{cfg.api_key}"},
      {"content-type", "application/json"},
      {"accept-encoding", "identity"}
    ] ++ Enum.map(cfg.default_headers, fn {k, v} -> {k, v} end)
  end

  defp marshal_chat(cfg, req, stream?) do
    url = String.trim_trailing(cfg.base_url, "/") <> "/chat/completions"

    body =
      %{"model" => cfg.model, "messages" => req[:messages] || []}
      |> put_present("prompt_cache_key", req[:prompt_cache_key])
      |> put_present("temperature", req[:temperature])
      |> put_present("top_p", req[:top_p])
      |> put_chat_max_tokens(cfg.model, effective_max_tokens(cfg, req, nil))

    body =
      if stream? do
        body
        |> Map.put("stream", true)
        |> Map.put("stream_options", %{"include_usage" => true})
      else
        body
      end

    {url, body, bearer_headers(cfg)}
  end

  defp put_chat_max_tokens(body, _model, nil), do: body

  defp put_chat_max_tokens(body, model, max_tokens) do
    SalixMedia.OpenAICompat.put_chat_max_tokens(body, model, max_tokens)
  end

  defp marshal_anthropic(cfg, req, stream?) do
    {system, turns} = split_system(req[:messages] || [])

    body =
      %{
        "model" => cfg.model,
        # The Anthropic API requires max_tokens (willow defaults 4096).
        "max_tokens" => effective_max_tokens(cfg, req, 4096),
        "messages" => Enum.map(turns, &anthropic_message/1)
      }
      |> put_present("system", system)
      |> put_present("temperature", req[:temperature])
      |> put_present("top_p", req[:top_p])

    body = if stream?, do: Map.put(body, "stream", true), else: body

    {SalixLlm.Anthropic.url(cfg), body,
     SalixLlm.Anthropic.headers(cfg, [{"accept-encoding", "identity"}])}
  end

  defp marshal_responses(cfg, req, stream?) do
    url = String.trim_trailing(cfg.base_url, "/") <> "/responses"

    body =
      %{
        "model" => cfg.model,
        "input" =>
          Enum.map(req[:messages] || [], fn m ->
            %{"role" => message_field(m, "role") || "user", "content" => text_content(m)}
          end)
      }
      |> put_present("max_output_tokens", effective_max_tokens(cfg, req, nil))
      |> put_present("temperature", req[:temperature])
      |> put_present("top_p", req[:top_p])

    body = if stream?, do: Map.put(body, "stream", true), else: body

    {url, body, bearer_headers(cfg)}
  end

  defp effective_max_tokens(cfg, req, default) do
    case req[:max_tokens] do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        case cfg.max_tokens do
          n when is_integer(n) and n > 0 -> n
          _ -> default
        end
    end
  end

  defp put_present(body, _key, nil), do: body
  defp put_present(body, _key, ""), do: body
  defp put_present(body, key, value), do: Map.put(body, key, value)

  defp split_system(messages) do
    {system_msgs, turns} =
      Enum.split_with(messages, fn m -> message_field(m, "role") == "system" end)

    system =
      system_msgs
      |> Enum.map(&text_content/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    {(system != "" && system) || nil, turns}
  end

  defp anthropic_message(m) do
    role = if message_field(m, "role") == "assistant", do: "assistant", else: "user"
    %{"role" => role, "content" => text_content(m)}
  end

  # Content may be a plain string or an array of typed blocks (willow's
  # Message.Content json.RawMessage); join the text blocks.
  defp text_content(m) do
    case message_field(m, "content") do
      content when is_binary(content) ->
        content

      blocks when is_list(blocks) ->
        blocks
        |> Enum.map(fn
          %{"type" => "text", "text" => text} when is_binary(text) -> text
          _ -> ""
        end)
        |> Enum.join("\n")

      _ ->
        ""
    end
  end

  defp message_field(m, "role") when is_map(m), do: m["role"] || m[:role]
  defp message_field(m, "content") when is_map(m), do: m["content"] || m[:content]
  defp message_field(_m, _key), do: nil

  # ---- response decoding (willow decodeResponse) ----

  defp decode_response("anthropic", resp), do: anthropic_to_chat(resp)
  defp decode_response("responses", resp), do: responses_to_chat(resp)
  defp decode_response(_, resp), do: project_chat_response(resp)

  # Chat Completions: willow re-marshals through its ChatResponse struct,
  # which projects to the known fields — mirror that.
  defp project_chat_response(resp) when is_map(resp) do
    %{
      "id" => resp["id"] || "",
      "object" => resp["object"] || "",
      "choices" =>
        for choice <- List.wrap(resp["choices"]) do
          %{
            "index" => choice["index"] || 0,
            "message" => project_message(choice["message"] || %{}),
            "finish_reason" => choice["finish_reason"] || ""
          }
        end
    }
    |> put_usage(normalize_usage(resp["usage"]))
  end

  defp project_chat_response(resp),
    do: %{"id" => "", "object" => "", "choices" => [], "raw" => resp}

  defp project_message(msg) do
    # reasoning → reasoning_content (willow NormalizeReasoning).
    reasoning = msg["reasoning"] || msg["reasoning_content"]

    %{"role" => msg["role"] || "", "content" => msg["content"]}
    |> put_present("tool_call_id", msg["tool_call_id"])
    |> put_present("tool_calls", msg["tool_calls"])
    |> put_present("reasoning_content", reasoning)
    |> put_present("reasoning_details", msg["reasoning_details"])
  end

  defp anthropic_to_chat(resp) do
    text =
      resp["content"]
      |> List.wrap()
      |> Enum.map(fn
        %{"type" => "text", "text" => text} -> text
        _ -> ""
      end)
      |> Enum.join("")

    tool_calls =
      resp["content"]
      |> List.wrap()
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.with_index()
      |> Enum.map(fn {block, idx} ->
        %{
          "index" => idx,
          "id" => block["id"],
          "type" => "function",
          "function" => %{
            "name" => block["name"],
            "arguments" => Jason.encode!(block["input"] || %{})
          }
        }
      end)

    message =
      %{"role" => "assistant", "content" => text}
      |> then(fn m -> if tool_calls == [], do: m, else: Map.put(m, "tool_calls", tool_calls) end)

    %{
      "id" => resp["id"] || "",
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => anthropic_finish(resp["stop_reason"])
        }
      ]
    }
    |> put_usage(anthropic_usage(resp["usage"]))
  end

  defp anthropic_finish(reason) do
    case reason do
      r when r in ["end_turn", "stop_sequence", "", nil] -> "stop"
      "tool_use" -> "tool_calls"
      "max_tokens" -> "length"
      "refusal" -> "content_filter"
      other -> other
    end
  end

  @doc false
  def anthropic_usage(nil), do: nil

  def anthropic_usage(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    cache_read = usage["cache_read_input_tokens"] || 0

    cache_write =
      case usage["cache_creation"] do
        %{} = cc ->
          (cc["ephemeral_5m_input_tokens"] || 0) + (cc["ephemeral_1h_input_tokens"] || 0)

        _ ->
          usage["cache_creation_input_tokens"] || 0
      end

    prompt = input + cache_read + cache_write

    %{
      "prompt_tokens" => prompt,
      "completion_tokens" => output,
      "total_tokens" => prompt + output
    }
    |> then(fn u ->
      if cache_write > 0, do: Map.put(u, "cache_creation_input_tokens", cache_write), else: u
    end)
    |> then(fn u ->
      if cache_read > 0,
        do: Map.put(u, "prompt_tokens_details", %{"cached_tokens" => cache_read}),
        else: u
    end)
  end

  defp responses_to_chat(resp) do
    text =
      resp["output"]
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "message", "content" => content} -> List.wrap(content)
        _ -> []
      end)
      |> Enum.map(fn
        %{"type" => "output_text", "text" => text} -> text
        _ -> ""
      end)
      |> Enum.join("")

    %{
      "id" => resp["id"] || "",
      "object" => "chat.completion",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => "stop"
        }
      ]
    }
    |> put_usage(normalize_usage(resp["usage"]))
  end

  @doc false
  def normalize_usage(nil), do: nil

  def normalize_usage(usage) when is_map(usage) do
    prompt = usage["prompt_tokens"] || usage["input_tokens"] || 0
    completion = usage["completion_tokens"] || usage["output_tokens"] || 0
    total = usage["total_tokens"] || prompt + completion

    cached =
      get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0

    %{
      "prompt_tokens" => prompt,
      "completion_tokens" => completion,
      "total_tokens" => total
    }
    |> then(fn u ->
      case usage["cache_creation_input_tokens"] do
        n when is_integer(n) and n > 0 -> Map.put(u, "cache_creation_input_tokens", n)
        _ -> u
      end
    end)
    |> then(fn u ->
      if cached > 0,
        do: Map.put(u, "prompt_tokens_details", %{"cached_tokens" => cached}),
        else: u
    end)
  end

  def normalize_usage(_), do: nil

  defp put_usage(resp, nil), do: resp
  defp put_usage(resp, usage), do: Map.put(resp, "usage", usage)

  # ---- streaming decode ----

  defp stream_decoder("anthropic"), do: &decode_anthropic_event/2
  defp stream_decoder("responses"), do: &decode_responses_event/2
  defp stream_decoder(_), do: &decode_chat_event/2

  defp consume(st, data) do
    {lines, rest} = split_lines(st.buffer <> data)

    Enum.reduce(lines, %{st | buffer: rest}, fn line, acc ->
      case SSE.parse_data_line(line) do
        {:ok, event} ->
          case event_error(event) do
            nil ->
              {chunks, acc} = acc.decoder.(event, acc)
              Enum.each(chunks, acc.on_chunk)
              acc

            error ->
              %{acc | error: acc.error || error}
          end

        :error ->
          acc
      end
    end)
  end

  # Mid-stream provider failures: Anthropic `{"type":"error"}`, Responses
  # `response.failed`, chat-completions chunks carrying an `error` object.
  defp event_error(%{"type" => "error"} = event), do: event["error"] || event

  defp event_error(%{"type" => "response.failed"} = event),
    do: get_in(event, ["response", "error"]) || event

  defp event_error(%{"error" => %{} = error}), do: error
  defp event_error(_event), do: nil

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  # Chat Completions chunks pass through (projected to willow's StreamChunk
  # fields); usage rides the final chunk when stream_options.include_usage.
  defp decode_chat_event(event, st) do
    usage = normalize_usage(event["usage"]) || st.usage

    chunk =
      %{
        "id" => event["id"] || "",
        "object" => event["object"] || "chat.completion.chunk",
        "choices" =>
          for choice <- List.wrap(event["choices"]) do
            delta = choice["delta"] || %{}

            %{
              "index" => choice["index"] || 0,
              "delta" =>
                %{}
                |> put_present("role", delta["role"])
                |> put_present("content", delta["content"])
                |> put_present("tool_calls", delta["tool_calls"])
                |> put_present(
                  "reasoning_content",
                  delta["reasoning"] || delta["reasoning_content"]
                ),
              "finish_reason" => choice["finish_reason"]
            }
          end
      }
      |> put_usage(normalize_usage(event["usage"]))

    {[chunk], %{st | usage: usage}}
  end

  defp decode_anthropic_event(%{"type" => "message_start"} = event, st) do
    message = event["message"] || %{}
    meta = Map.put(st.meta, :id, message["id"] || "")
    usage = anthropic_usage(message["usage"])

    chunk = %{
      "id" => meta[:id],
      "object" => "chat.completion.chunk",
      "choices" => [
        %{"index" => 0, "delta" => %{"role" => "assistant"}, "finish_reason" => nil}
      ]
    }

    {[chunk], %{st | meta: meta, usage: usage || st.usage}}
  end

  defp decode_anthropic_event(%{"type" => "content_block_delta"} = event, st) do
    case event["delta"] do
      %{"type" => "text_delta", "text" => text} when is_binary(text) and text != "" ->
        chunk = %{
          "id" => st.meta[:id] || "",
          "object" => "chat.completion.chunk",
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}
          ]
        }

        {[chunk], st}

      _ ->
        {[], st}
    end
  end

  defp decode_anthropic_event(%{"type" => "message_delta"} = event, st) do
    # Final usage: input counters came on message_start; output arrives here.
    output = get_in(event, ["usage", "output_tokens"]) || 0
    base = st.usage || %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}

    usage =
      base
      |> Map.put("completion_tokens", output)
      |> Map.put("total_tokens", (base["prompt_tokens"] || 0) + output)

    finish = anthropic_finish(get_in(event, ["delta", "stop_reason"]))

    chunk =
      %{
        "id" => st.meta[:id] || "",
        "object" => "chat.completion.chunk",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => finish}]
      }
      |> put_usage(usage)

    {[chunk], %{st | usage: usage}}
  end

  defp decode_anthropic_event(_event, st), do: {[], st}

  defp decode_responses_event(%{"type" => "response.output_text.delta"} = event, st) do
    case event["delta"] do
      text when is_binary(text) and text != "" ->
        chunk = %{
          "id" => st.meta[:id] || "",
          "object" => "chat.completion.chunk",
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}
          ]
        }

        {[chunk], st}

      _ ->
        {[], st}
    end
  end

  defp decode_responses_event(%{"type" => "response.created"} = event, st) do
    {[], %{st | meta: Map.put(st.meta, :id, get_in(event, ["response", "id"]) || "")}}
  end

  defp decode_responses_event(%{"type" => "response.completed"} = event, st) do
    usage = normalize_usage(get_in(event, ["response", "usage"]))

    chunk =
      %{
        "id" => st.meta[:id] || "",
        "object" => "chat.completion.chunk",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      }
      |> put_usage(usage)

    {[chunk], %{st | usage: usage || st.usage}}
  end

  defp decode_responses_event(_event, st), do: {[], st}
end
