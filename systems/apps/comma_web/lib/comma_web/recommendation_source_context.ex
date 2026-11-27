defmodule CommaWeb.RecommendationSourceContext do
  @moduledoc false

  # Context travels apart from record data so descriptions cannot displace the
  # member's candidate identities. Each record is bounded independently so
  # unrelated items entering or leaving the source never alter another record's
  # pooled context or version fingerprint. Routine applies its per-source prompt
  # budget when projecting model candidates (`Comma.RecommendationMemberSelection`).
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

    bounded = Comma.JsonText.fit(text, @record_bytes)

    Map.put(record, "context", %{
      "scope" => scope,
      "text" => bounded,
      "truncated" => bounded != text
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

  # Keep only the contexts of records whose links survived `data` bounding,
  # without cross-item truncation.
  def retain(contexts, data) do
    allowed = Comma.RecommendationContract.http_urls(data)
    Map.filter(contexts, fn {url, _context} -> MapSet.member?(allowed, url) end)
  end
end
