defmodule SalixAgent.LLM.Mock do
  @moduledoc """
  A scriptable LLM for tests. A script is a list of `SalixAgent.LLM.result`
  tuples consumed in order across successive `complete/2` calls.

  Set a script with `script/1` (process-agnostic — stored in an Agent keyed by
  nothing, so tests run `async: false`). `{:final, content}` entries are legacy
  fixture shorthand: when dequeued, the mock returns an assistant response with
  one `end_turn(outcome: "done")` call. An exhausted script uses that same
  explicit-done response. Use `{:assistant, content, []}` when a test needs to
  exercise a genuine missing completion decision, or `{:raw, response}` when a
  seam test needs the response tuple unchanged.

  Also implements the optional `complete_stream/3` and `complete_stream/4`
  callbacks: assistant text fires `on_delta`, and tool arguments fire
  `on_tool_delta`, in 2-3 ordered chunks before the response is returned. This
  exercises the same separate transcript/tool streams as a real provider
  without HTTP. A script entry may be wrapped as
  `{:reasoning_summary, text, response}` or `{:reasoning, text, response}`. The
  former fires a public-summary event; the legacy latter is fail-closed as
  private raw reasoning. Both unwrap transparently on non-streaming paths, and
  nested `{:final, ...}` shorthand is normalized without losing provider or
  trace metadata.
  """
  @behaviour SalixAgent.LLM

  use Agent

  def start_link(_ \\ []) do
    case Agent.start_link(fn -> [] end, name: __MODULE__) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "Install responses; `{:final, ...}` is shorthand for an explicit done decision."
  def script(responses) when is_list(responses) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> responses end)
  end

  @impl true
  def complete(messages, tools) do
    case next_entry(messages, tools) do
      {:reasoning, _reasoning, response} -> response
      {:reasoning_summary, _summary, response} -> response
      response -> response
    end
  end

  @impl true
  def complete_stream(messages, tools, on_delta) when is_function(on_delta, 1) do
    complete_stream(messages, tools, on_delta, [])
  end

  @impl true
  def complete_stream(messages, tools, on_delta, opts) when is_function(on_delta, 1) do
    {reasoning_delta, response} =
      case next_entry(messages, tools) do
        {:reasoning, reasoning, response} ->
          {SalixAgent.LLM.ReasoningDelta.private_reasoning(reasoning), response}

        {:reasoning_summary, summary, response} ->
          {SalixAgent.LLM.ReasoningDelta.public_summary(summary), response}

        response ->
          {nil, response}
      end

    on_reasoning = opt(opts, :on_reasoning_delta)

    if reasoning_delta && is_function(on_reasoning, 1) do
      on_reasoning.(reasoning_delta)
    end

    case response do
      {:final, text} -> stream_text(text, on_delta)
      {:assistant, text, _calls} -> stream_text(text, on_delta)
      {:assistant, text, _calls, _provider_meta} -> stream_text(text, on_delta)
      {:assistant, text, _calls, _provider_meta, _trace_meta} -> stream_text(text, on_delta)
      _other -> :ok
    end

    stream_tool_calls(response, opt(opts, :on_tool_delta))

    response
  end

  defp next_entry(_messages, _tools) do
    ensure_started()

    __MODULE__
    |> Agent.get_and_update(fn
      [next | rest] -> {next, rest}
      [] -> {{:final, "done"}, []}
    end)
    |> normalize_script_entry()
  end

  defp normalize_script_entry({:reasoning, reasoning, response}),
    do: {:reasoning, reasoning, normalize_script_entry(response)}

  defp normalize_script_entry({:reasoning_summary, summary, response}),
    do: {:reasoning_summary, summary, normalize_script_entry(response)}

  defp normalize_script_entry({:raw, response}), do: response

  defp normalize_script_entry({:final, content}),
    do: {:assistant, content, [done_call()]}

  # A three-element final carries trace metadata. Keep it in the five-element
  # assistant shape's trace slot rather than accidentally reclassifying it as
  # provider metadata.
  defp normalize_script_entry({:final, content, trace_meta}),
    do: {:assistant, content, [done_call()], nil, trace_meta}

  defp normalize_script_entry({:final, content, provider_meta, trace_meta}),
    do: {:assistant, content, [done_call()], provider_meta, trace_meta}

  defp normalize_script_entry(response), do: response

  defp done_call do
    %{
      id: "mock_end_turn_#{System.unique_integer([:positive, :monotonic])}",
      name: "end_turn",
      args: %{"outcome" => "done"}
    }
  end

  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp opt(_opts, _key), do: nil

  # Fire `on_delta` with 2-3 ordered chunks whose concatenation is `text`.
  defp stream_text(text, on_delta) when is_binary(text) do
    text
    |> chunk3()
    |> Enum.each(on_delta)
  end

  defp stream_text(_non_binary, _on_delta), do: :ok

  defp stream_tool_calls(_response, on_tool_delta) when not is_function(on_tool_delta, 1),
    do: :ok

  defp stream_tool_calls(response, on_tool_delta) do
    response
    |> response_tool_calls()
    |> Enum.with_index()
    |> Enum.each(fn {call, index} ->
      call
      |> Map.get(:args, Map.get(call, "args", %{}))
      |> encode_tool_arguments()
      |> chunk3()
      |> Enum.each(fn fragment ->
        on_tool_delta.(%{
          index: index,
          id: Map.get(call, :id, Map.get(call, "id")),
          name: Map.get(call, :name, Map.get(call, "name")),
          fragment: fragment
        })
      end)
    end)
  end

  defp response_tool_calls({:assistant, _text, calls}) when is_list(calls), do: calls

  defp response_tool_calls({:assistant, _text, calls, _provider_meta}) when is_list(calls),
    do: calls

  defp response_tool_calls({:assistant, _text, calls, _provider_meta, _trace_meta})
       when is_list(calls),
       do: calls

  defp response_tool_calls(_response), do: []

  defp encode_tool_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_tool_arguments(arguments), do: Jason.encode!(arguments)

  defp chunk3(""), do: []

  defp chunk3(text) do
    graphemes = String.graphemes(text)
    size = max(div(length(graphemes) + 2, 3), 1)

    graphemes
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _ -> :ok
    end
  end
end
