defmodule CommaLog.Crash do
  @moduledoc false

  # Crash reports contain process state and the last message. Rebuild diagnostics
  # from the reason and stack instead of logging that report or discarding it all.
  @private_key ~r/(?:api[-_]?key|secret|token|password|authorization|credential|cookie|query[-_]?string|prompt|completion|tool[-_]?(?:arguments|result)|command)|\A(?:body|payload|content|messages?|state|args|arguments|data)\z/i
  @assignment ~r/((?:[\w-]*(?:api[-_]?key|secret|token|password|authorization|credential|cookie)[\w-]*)["']?\s*(?:=>|:|=)\s*)(?:"[^"\n]*(?:"|\z)|'[^'\n]*(?:'|\z)|[^\s,;&}\]]+)/i
  @payload_assignment ~r/((?:body|payload|prompt|completion|content|messages?|state|args|arguments)["']?\s*(?:=>|:|=)\s*)[^\n]*/i
  @bearer ~r/\b(Bearer|Basic)\s+[A-Za-z0-9+\/_=.-]+/i
  @known_token ~r/\b(?:sk-[A-Za-z0-9_-]+|xox[baprs]-[A-Za-z0-9-]+|gh[pousr]_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|glpat-[A-Za-z0-9_-]+)\b/
  @private_key_block ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/s
  @url_userinfo ~r{(https?://)[^\s/@]+@}i

  def reason(value) do
    {result, _budget} = sanitize(value, 0, {128, 8_192}, :diagnostic)
    result
  end

  def summary(%{"exception" => type, "message" => message}) when is_binary(message),
    do: type <> ": " <> message

  def summary(%{"exception" => type} = reason), do: type <> ": " <> render(reason)
  def summary(reason), do: render(reason)

  def stacktrace(stack) do
    stack
    |> Enum.take(32)
    |> Enum.flat_map(fn
      {module, function, args, location} when is_atom(module) and is_atom(function) ->
        arity = if is_list(args), do: length(Enum.take(args, 256)), else: args

        if is_integer(arity) and arity in 0..255 do
          frame = %{
            module: text(Atom.to_string(module), 256),
            function: text(Atom.to_string(function), 128),
            arity: arity
          }

          [source_location(frame, location)]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp source_location(frame, location) when is_list(location) do
    Enum.reduce(Enum.take(location, 16), frame, fn
      {:file, file}, acc when is_list(file) ->
        Map.put(acc, :file, file |> Enum.take(256) |> List.to_string() |> text(256))

      {:file, file}, acc when is_binary(file) ->
        Map.put(acc, :file, text(file, 256))

      {:line, line}, acc when is_integer(line) ->
        Map.put(acc, :line, line)

      _, acc ->
        acc
    end)
  end

  defp source_location(frame, _location), do: frame

  defp sanitize(_value, depth, {nodes, _bytes} = budget, _mode)
       when depth >= 8 or nodes <= 0,
       do: {"[truncated]", budget}

  defp sanitize(value, depth, {nodes, bytes}, mode),
    do: value(value, depth, {nodes - 1, bytes}, mode)

  defp value(%{__exception__: true, __struct__: type} = exception, depth, budget, mode)
       when mode != :matched_value do
    # Exception.message/1 can interpolate matched terms, arguments and map values.
    # Keep the exception's fields, but treat those values as data, not error text.
    {fields, budget} = fields(Map.from_struct(exception), depth, budget, :exception)
    {Map.put(Map.delete(fields, "__exception__"), "exception", inspect(type)), budget}
  end

  defp value(%_{} = struct, depth, budget, :matched_value),
    do: fields(Map.from_struct(struct), depth, budget, :matched_value)

  defp value(map, depth, budget, mode) when is_map(map),
    do: fields(map, depth, budget, mode)

  defp value({:http_error, status, body}, depth, budget, mode) when mode != :matched_value,
    do: values([:http_error, status, body], depth, budget, :value)

  defp value({kind, term}, depth, budget, _mode) when kind in [:badmatch, :case_clause],
    do: values([kind, term], depth, budget, :matched_value)

  defp value({key, value}, depth, budget, mode) when is_atom(key) or is_binary(key) do
    if Regex.match?(@private_key, to_string(key)) do
      {[key(key), "[redacted]"], budget}
    else
      values([key, value], depth, budget, mode)
    end
  end

  defp value(tuple, depth, budget, mode) when is_tuple(tuple) do
    items = for index <- 0..31, index < tuple_size(tuple), do: elem(tuple, index)
    values(items, depth, budget, mode)
  end

  defp value(list, depth, budget, mode) when is_list(list) do
    sample = Enum.take(list, 2_049)

    if sample != [] and List.ascii_printable?(sample) do
      value(List.to_string(sample), depth, budget, mode)
    else
      values(list, depth, budget, mode)
    end
  end

  defp value(binary, _depth, budget, mode)
       when is_binary(binary) and mode in [:value, :matched_value],
       do: {"[binary #{byte_size(binary)} bytes]", budget}

  defp value(binary, _depth, {nodes, bytes}, _mode) when is_binary(binary) do
    result = text(binary, min(bytes, 2_048))
    {result, {nodes, max(0, bytes - byte_size(result))}}
  end

  defp value(value, _depth, budget, _mode)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: {value, budget}

  defp value(atom, _depth, budget, _mode) when is_atom(atom),
    do: {Atom.to_string(atom), budget}

  defp value(_value, _depth, budget, _mode), do: {"[opaque term]", budget}

  defp fields(map, depth, budget, mode) do
    map
    |> Enum.take(32)
    |> Enum.map_reduce(budget, fn {key, value}, budget ->
      key = key(key)

      if Regex.match?(@private_key, key) and not (mode == :exception and key == "message") do
        {{key, "[redacted]"}, budget}
      else
        field_mode =
          cond do
            # Matched containers remain data even when their values resemble errors.
            mode == :matched_value ->
              :matched_value

            mode == :exception and key in ["term", "value", "actual", "map", "enum"] ->
              :matched_value

            true ->
              :diagnostic
          end

        {value, budget} = sanitize(value, depth + 1, budget, field_mode)
        {{key, value}, budget}
      end
    end)
    |> then(fn {pairs, budget} -> {Map.new(pairs), budget} end)
  end

  defp values(list, depth, budget, mode) do
    list
    |> Enum.take(32)
    |> Enum.map_reduce(budget, &sanitize(&1, depth + 1, &2, mode))
  end

  defp key(key) when is_atom(key), do: key |> Atom.to_string() |> text(96)
  defp key(key) when is_binary(key), do: text(key, 96)
  defp key(_key), do: "[opaque key]"

  defp render(value), do: inspect(value, limit: 50, printable_limit: 2_048)

  defp text(_value, 0), do: "[truncated]"

  defp text(value, limit) do
    # Bound input before regex work; repair a cut UTF-8 codepoint or binary data.
    value = binary_part(value, 0, min(byte_size(value), limit))

    value =
      case :unicode.characters_to_binary(value) do
        valid when is_binary(valid) -> valid
        {_error_or_incomplete, valid, _rest} -> valid <> "[truncated binary]"
      end

    value
    |> then(&Regex.replace(@private_key_block, &1, "[redacted private key]"))
    |> then(&Regex.replace(@url_userinfo, &1, "\\1[redacted]@"))
    |> then(&Regex.replace(@bearer, &1, "\\1 [redacted]"))
    |> then(&Regex.replace(@assignment, &1, "\\1[redacted]"))
    |> then(&Regex.replace(@known_token, &1, "[redacted]"))
    |> then(&Regex.replace(@payload_assignment, &1, "\\1[redacted]"))
  end
end
