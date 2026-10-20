defmodule CommaWeb.ProactiveSourceProjection do
  @moduledoc """
  Bounds a plugin MCP read for a proactive watch.

  A plugin MCP returns the provider's full object (a GitHub pull request is
  often 15-30 KB) or plain text. The watch program compares the fresh read with
  the last settled observation and passes both to `decide`, which takes at most
  12 KiB, and the Loop checkpoint holds at most 16 KiB. The projection keeps
  scalar facts, short text and the first list items, drops provider link
  noise, and always returns one JSON object within the budget. It is evidence
  for change detection; the Router re-reads the exact source before it acts.
  """

  @budget 3_000
  @noise ~w(node_id _links avatar_url gravatar_id)
  # GitHub returns many API links per object; the page link stays.
  @kept_urls ~w(html_url url)
  @passes [{1_000, 20, 3}, {300, 8, 3}, {160, 4, 2}, {80, 2, 1}]

  @doc "Project MCP tool content (JSON or plain text) into one bounded JSON object."
  @spec project(String.t()) :: map()
  def project(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, data} when is_map(data) -> fit(data)
      {:ok, data} when is_list(data) -> fit(%{"items" => data})
      _ -> %{"text" => cut(content, @budget - 64)}
    end
  end

  def project(_content), do: %{}

  # Provider failures stay visible to the watch, which treats them as
  # incomplete evidence.
  defp fit(%{"error" => error} = data) when error not in [nil, false],
    do: %{"error" => shrink(error, 300, 4, 2), "successful" => data["successful"] == true}

  defp fit(data) do
    Enum.find_value(@passes, fn {text, items, depth} ->
      projected = shrink(data, text, items, depth)
      if byte_size(Jason.encode!(projected)) <= @budget, do: projected
    end) || %{"text" => cut(Jason.encode!(shrink(data, 80, 2, 1)), @budget - 64)}
  end

  defp shrink(map, text, items, depth) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, kept ->
      with true <- is_binary(key) and key not in @noise and not url_noise?(key),
           value when value != :drop <- shrink_value(value, text, items, depth - 1) do
        Map.put(kept, key, value)
      else
        _ -> kept
      end
    end)
  end

  defp shrink(list, text, items, depth) when is_list(list) do
    list
    |> Enum.take(items)
    |> Enum.map(&shrink_value(&1, text, items, depth - 1))
    |> Enum.reject(&(&1 == :drop))
  end

  defp shrink(value, text, items, depth), do: shrink_value(value, text, items, depth)

  defp shrink_value(value, _text, _items, depth)
       when (is_map(value) or is_list(value)) and depth < 0,
       do: :drop

  defp shrink_value(value, text, items, depth) when is_map(value) or is_list(value),
    do: shrink(value, text, items, depth)

  defp shrink_value(value, text, _items, _depth) when is_binary(value), do: cut(value, text)
  defp shrink_value(value, _text, _items, _depth), do: value

  defp url_noise?(key), do: String.ends_with?(key, "_url") and key not in @kept_urls

  defp cut(text, limit) when byte_size(text) <= limit, do: text
  defp cut(text, limit), do: valid_prefix(binary_part(text, 0, limit)) <> "…"

  # A byte cut can land inside a multi-byte character; drop its lead bytes.
  defp valid_prefix(bytes) do
    if String.valid?(bytes),
      do: bytes,
      else: valid_prefix(binary_part(bytes, 0, byte_size(bytes) - 1))
  end
end
