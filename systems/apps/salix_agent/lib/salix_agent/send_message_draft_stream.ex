defmodule SalixAgent.SendMessageDraftStream do
  @moduledoc """
  Incrementally projects text from an exact internal send.

  Provider tool deltas remain opaque JSON until this module can decode a safe
  structural prefix and prove the exact target conversation. It returns only
  semantic text; raw fragments and parser diagnostics never leave this module.
  """

  @dispatcher "call"
  @target "im_api.internal.send_message"
  @connect_id "internal"
  @max_arguments_bytes 256 * 1_024
  @max_tool_calls 16

  defstruct calls: %{}, published_call: nil, published_text: nil

  @type action :: :noop | {:publish, String.t()}
  @type t :: %__MODULE__{
          calls: map(),
          published_call: term() | nil,
          published_text: String.t() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Consumes one provider tool-argument delta.

  A publication is returned only when the accumulated JSON prefix establishes
  the tool envelope, target API, internal connect, exact conversation and one
  plain-text content block. Raw `end_turn` deltas never publish a draft.
  """
  @spec consume(t(), term(), map()) :: {t(), action()}
  def consume(state, delta, scope)

  def consume(%__MODULE__{} = state, delta, scope) when is_map(scope) do
    with {:ok, key, name, fragment} <- normalize_delta(delta),
         true <- Map.has_key?(state.calls, key) or map_size(state.calls) < @max_tool_calls,
         {:ok, call} <- append_fragment(Map.get(state.calls, key), name, fragment) do
      state = %{state | calls: Map.put(state.calls, key, call)}
      maybe_publish(state, key, scope)
    else
      _ -> {state, :noop}
    end
  end

  def consume(%__MODULE__{} = state, _delta, _scope), do: {state, :noop}

  @doc """
  Whether the completed response is exactly one eligible source-bound send.

  This is the handoff guard used to keep a streamed participant draft alive
  until that tool has executed. Message authority still belongs to the normal
  provider call and Conversation owner.
  """
  @spec exact_source_send?([term()], map() | nil, term()) :: boolean()
  def exact_source_send?([call], scope, :clean) when is_map(call) and is_map(scope) do
    exact_canonical_send?(call, scope)
  end

  def exact_source_send?(_calls, _scope, _phase), do: false

  @doc false
  def publish_terminal_reply(
        [%{name: @target, args: params, terminal_reply: binding}],
        %{terminal_decision_outcome: outcome, visible_reply_phase: :clean} = ctx
      )
      when is_map(binding) and outcome in ["done", "blocked"] do
    scope = ctx[:visible_reply_scope]
    args = %{"tool" => @target, "params" => params}

    with true <- is_map(scope),
         {:ok, text} <- source_text(args, scope),
         :ok <- SalixAgent.VisibleReply.authorize(ctx.agent_id, scope) do
      SalixAgent.VisibleReply.publish_delta(ctx.agent_id, ctx.session_id, scope, text, nil)
    else
      _ -> :ok
    end
  end

  def publish_terminal_reply(_calls, _ctx), do: :ok

  defp exact_canonical_send?(call, scope) do
    with {:ok, args} <- send_arguments(text(value(call, "name")), value(call, "args")),
         {:ok, _text} <- source_text(args, scope) do
      true
    else
      _ -> false
    end
  end

  defp maybe_publish(%{published_call: nil} = state, key, scope) do
    candidates =
      state.calls
      |> Enum.flat_map(fn {candidate_key, call} ->
        case projected_text(call, scope) do
          {:ok, text} -> [{candidate_key, text}]
          :pending -> []
        end
      end)

    case candidates do
      [{^key, text}] -> publish(state, key, text)
      [_single_other] -> {state, :noop}
      _ -> {state, :noop}
    end
  end

  defp maybe_publish(%{published_call: key} = state, key, scope) do
    case projected_text(Map.fetch!(state.calls, key), scope) do
      {:ok, text} -> publish(state, key, text)
      :pending -> {state, :noop}
    end
  end

  defp maybe_publish(state, _key, _scope), do: {state, :noop}

  defp publish(%{published_text: text} = state, _key, text), do: {state, :noop}

  defp publish(state, key, text) do
    {%{state | published_call: key, published_text: text}, {:publish, text}}
  end

  defp projected_text(%{name: name, disabled?: false, arguments: arguments}, scope) do
    with {:ok, decoded} <- decode_json_prefix(arguments),
         {:ok, args} <- send_arguments(name, decoded) do
      source_text(args, scope)
    else
      _ -> :pending
    end
  end

  defp projected_text(_call, _scope), do: :pending

  defp send_arguments(@dispatcher, args) when is_map(args), do: {:ok, args}
  defp send_arguments(_name, _args), do: :error

  defp source_text(args, scope) do
    with @target <- text(value(args, "tool")),
         params when is_map(params) <- value(args, "params"),
         @connect_id <- text(value(params, "connect_id")),
         conversation_id when is_binary(conversation_id) <- value(params, "conversation_id"),
         true <- conversation_id == value(scope, "conversation_id"),
         {:ok, text} <- plain_text_content(value(params, "content")),
         true <- text != "" do
      {:ok, text}
    else
      _ -> :pending
    end
  end

  defp plain_text_content([block]) when is_map(block) do
    case {text(value(block, "type")), value(block, "text")} do
      {"text", text} when is_binary(text) -> {:ok, text}
      _ -> :error
    end
  end

  defp plain_text_content(_content), do: :error

  defp normalize_delta(delta) when is_map(delta) do
    fragment = value(delta, "fragment")
    name = present(value(delta, "name"))
    id = present(value(delta, "id"))
    index = value(delta, "index")

    key =
      cond do
        is_integer(index) and index >= 0 -> {:index, index}
        is_binary(id) -> {:id, id}
        true -> :default
      end

    if is_binary(fragment), do: {:ok, key, name, fragment}, else: :error
  end

  defp normalize_delta(_delta), do: :error

  defp append_fragment(nil, name, fragment) do
    append_fragment(%{name: name, arguments: "", disabled?: false}, name, fragment)
  end

  defp append_fragment(%{disabled?: true} = call, _name, _fragment), do: {:ok, call}

  defp append_fragment(call, name, fragment) do
    with {:ok, call} <- merge_name(call, name),
         arguments <- call.arguments <> fragment,
         true <- byte_size(arguments) <= @max_arguments_bytes do
      {:ok, %{call | arguments: arguments}}
    else
      _ -> {:ok, %{call | disabled?: true}}
    end
  end

  defp merge_name(%{name: nil} = call, name), do: {:ok, %{call | name: name}}
  defp merge_name(call, nil), do: {:ok, call}
  defp merge_name(%{name: name} = call, name), do: {:ok, call}
  defp merge_name(_call, _name), do: :error

  # Complete only the lexical JSON prefix that the provider has already sent.
  # Jason remains the structural decoder; this scanner merely closes an open
  # string/container so a text value can be observed before the response ends.
  defp decode_json_prefix(arguments) do
    with true <- byte_size(arguments) <= @max_arguments_bytes,
         {:ok, completed} <- complete_json_prefix(arguments),
         {:ok, decoded} <- Jason.decode(completed),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp complete_json_prefix(arguments) when is_binary(arguments) do
    case scan_json(arguments, 0, [], :outside) do
      {:ok, stack, :outside} ->
        {:ok, arguments <> List.to_string(stack)}

      {:ok, stack, {:string, :plain, _escape_start}} ->
        {:ok, arguments <> "\"" <> List.to_string(stack)}

      {:ok, stack, {:string, _incomplete_escape, escape_start}} ->
        prefix = binary_part(arguments, 0, escape_start)
        {:ok, prefix <> "\"" <> List.to_string(stack)}

      :error ->
        :error
    end
  end

  defp scan_json(binary, offset, stack, mode) when offset == byte_size(binary),
    do: {:ok, stack, mode}

  defp scan_json(binary, offset, stack, :outside) do
    byte = :binary.at(binary, offset)

    case byte do
      ?{ -> scan_json(binary, offset + 1, [?} | stack], :outside)
      ?[ -> scan_json(binary, offset + 1, [?] | stack], :outside)
      ?} -> close_container(binary, offset, stack, ?})
      ?] -> close_container(binary, offset, stack, ?])
      ?" -> scan_json(binary, offset + 1, stack, {:string, :plain, offset})
      _ -> scan_json(binary, offset + 1, stack, :outside)
    end
  end

  defp scan_json(binary, offset, stack, {:string, :plain, _escape_start} = mode) do
    byte = :binary.at(binary, offset)

    cond do
      byte == ?" -> scan_json(binary, offset + 1, stack, :outside)
      byte == ?\\ -> scan_json(binary, offset + 1, stack, {:string, :escape, offset})
      byte < 0x20 -> :error
      true -> scan_json(binary, offset + 1, stack, mode)
    end
  end

  defp scan_json(binary, offset, stack, {:string, :escape, escape_start}) do
    case :binary.at(binary, offset) do
      ?u ->
        scan_json(binary, offset + 1, stack, {:string, {:unicode, 0}, escape_start})

      byte when byte in [?", ?\\, ?/, ?b, ?f, ?n, ?r, ?t] ->
        scan_json(binary, offset + 1, stack, {:string, :plain, offset + 1})

      _ ->
        :error
    end
  end

  defp scan_json(binary, offset, stack, {:string, {:unicode, count}, escape_start}) do
    if hex?(:binary.at(binary, offset)) do
      if count == 3,
        do: scan_json(binary, offset + 1, stack, {:string, :plain, offset + 1}),
        else: scan_json(binary, offset + 1, stack, {:string, {:unicode, count + 1}, escape_start})
    else
      :error
    end
  end

  defp close_container(binary, offset, [expected | stack], expected),
    do: scan_json(binary, offset + 1, stack, :outside)

  defp close_container(_binary, _offset, _stack, _actual), do: :error

  defp hex?(byte), do: byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || atom_value(map, key)
  end

  defp value(_map, _key), do: nil

  defp atom_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
