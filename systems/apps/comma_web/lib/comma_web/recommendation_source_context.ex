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

  def retain(contexts, data) do
    allowed = Comma.RecommendationContract.http_urls(data)
    contexts = contexts |> Map.take(MapSet.to_list(allowed)) |> Enum.sort()

    empty =
      Map.new(contexts, fn {url, context} ->
        {url, context |> Map.put("text", "") |> Map.put("truncated", false)}
      end)

    allowance =
      max(div(@max_bytes - byte_size(Jason.encode!(empty)), max(length(contexts), 1)), 0)

    Map.new(contexts, fn {url, context} ->
      text = fit(context["text"], allowance)

      {url,
       context
       |> Map.put("text", text)
       |> Map.update!("truncated", &(&1 or text != context["text"]))}
    end)
  end

  # JSON escaping can cost more than UTF-8. Keep the serialized budget exact.
  defp fit(text, budget) do
    if byte_size(Jason.encode!(text)) - 2 <= budget,
      do: text,
      else: fit(prefix(text, div(byte_size(text), 2)), budget)
  end

  defp prefix(text, bytes) when byte_size(text) <= bytes, do: text

  defp prefix(text, bytes) do
    value = binary_part(text, 0, max(bytes, 0))
    if String.valid?(value), do: value, else: prefix(value, byte_size(value) - 1)
  end
end
