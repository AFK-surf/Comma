defmodule CommaWeb.RecommendationSourceContextTest do
  use ExUnit.Case, async: true
  alias CommaWeb.RecommendationSourceContext, as: Context

  test "long contextual prose cannot displace candidates, exceed its budget, or enter references" do
    records =
      for id <- 1..40 do
        %{
          "url" => "https://example.com/issues/#{id}",
          "title" => "Issue #{id}",
          "description" => String.duplicate("报价\\\"中文\n", 1_000)
        }
        |> Context.attach(["description"])
        |> Map.delete("description")
      end

    {data, contexts} = Context.separate(%{"records" => records})
    contexts = Context.retain(contexts, data)
    assert length(data["records"]) == 40
    assert map_size(contexts) == 40
    assert byte_size(Jason.encode!(contexts)) <= 16_384

    assert Enum.all?(contexts, fn {_, value} ->
             value["truncated"] and String.valid?(value["text"]) and value["text"] != ""
           end)

    retained = put_in(data, ["records"], Enum.take(data["records"], 2))
    assert map_size(Context.retain(contexts, retained)) == 2
    assert MapSet.size(Comma.RecommendationContract.http_urls(data)) == 40
  end
end
