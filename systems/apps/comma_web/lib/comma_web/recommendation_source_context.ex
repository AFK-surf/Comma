defmodule CommaWeb.RecommendationSourceContext do
  @moduledoc false

  # Context has a separate byte budget so descriptions cannot displace the
  # member's candidate identities. It is run-local evidence, never memory.
  @max_bytes 16_384
  @record_bytes 1_200
  @urls ~w(url webUrl html_url htmlLink webViewLink permalink)

  def attach(record, fields, scope \\ "record_excerpt") do
    text =
      fields
      |> Enum.flat_map(fn key ->
        case record[key] do
          nil -> []
          "" -> []
          value when is_binary(value) -> [key <> ": " <> value]
          value -> [key <> ": " <> Jason.encode!(value)]
        end
      end)
      |> Enum.join("\n")

    Map.put(record, "context", %{
      "scope" => scope,
      "text" => prefix(text, @record_bytes),
      "truncated" => byte_size(text) > @record_bytes
    })
  end

  def separate(data) when is_map(data) do
    contexts =
      case data["context"] do
        %{"text" => text} = context when is_binary(text) and text != "" ->
          case Enum.find_value(@urls, &data[&1]) do
            url when is_binary(url) -> %{url => context}
            _ -> %{}
          end

        _ ->
          %{}
      end

    data
    |> Map.delete("context")
    |> Enum.reduce({%{}, contexts}, fn {key, value}, {data, contexts} ->
      {value, nested} = separate(value)
      {Map.put(data, key, value), Map.merge(contexts, nested)}
    end)
  end

  def separate(data) when is_list(data) do
    {values, contexts} =
      Enum.map_reduce(data, %{}, fn value, contexts ->
        {value, nested} = separate(value)
        {value, Map.merge(contexts, nested)}
      end)

    {values, contexts}
  end

  def separate(data), do: {data, %{}}

  # The budget is for the text the model reads. A context reaches the model
  # inside its candidate, so the URL keys do not count. A short text leaves
  # its unused share to the longer ones.
  def retain(contexts, data) do
    allowed = Comma.RecommendationContract.http_urls(data)
    contexts = contexts |> Map.take(MapSet.to_list(allowed)) |> Enum.sort()

    overhead =
      contexts
      |> Enum.map(fn {_url, context} ->
        context |> Map.put("text", "") |> Map.put("truncated", false)
      end)
      |> Jason.encode!()
      |> byte_size()

    allowances = allowances(contexts, max(@max_bytes - overhead, 0))

    Map.new(contexts, fn {url, context} ->
      text = fit(context["text"], allowances[url])

      {url,
       context
       |> Map.put("text", text)
       |> Map.update!("truncated", &(&1 or text != context["text"]))}
    end)
  end

  # Shortest texts first: each takes what it needs, up to an even share of
  # what is left.
  defp allowances(contexts, budget) do
    contexts
    |> Enum.map(fn {url, context} -> {url, encoded_size(context["text"])} end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.with_index()
    |> Enum.reduce({budget, %{}}, fn {{url, size}, index}, {budget, allowances} ->
      allowance = min(size, div(budget, length(contexts) - index))
      {budget - allowance, Map.put(allowances, url, allowance)}
    end)
    |> elem(1)
  end

  # JSON escaping can cost more than UTF-8. Keep the serialized budget exact.
  defp fit(text, budget) do
    if encoded_size(text) <= budget do
      text
    else
      text
      |> String.codepoints()
      |> Enum.reduce_while({[], 0}, fn char, {kept, size} ->
        size = size + encoded_size(char)
        if size <= budget, do: {:cont, {[char | kept], size}}, else: {:halt, {kept, size}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()
    end
  end

  defp encoded_size(text), do: byte_size(Jason.encode!(text)) - 2

  defp prefix(text, bytes) when byte_size(text) <= bytes, do: text

  defp prefix(text, bytes) do
    value = binary_part(text, 0, max(bytes, 0))
    if String.valid?(value), do: value, else: prefix(value, byte_size(value) - 1)
  end
end
