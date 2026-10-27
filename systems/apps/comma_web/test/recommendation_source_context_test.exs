defmodule CommaWeb.RecommendationSourceContextTest do
  use SystemsClock.Case, async: true
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
    assert byte_size(Jason.encode!(Map.values(contexts))) <= 16_384

    assert Enum.all?(contexts, fn {_, value} ->
             value["truncated"] and String.valid?(value["text"]) and value["text"] != ""
           end)

    retained = put_in(data, ["records"], Enum.take(data["records"], 2))
    assert map_size(Context.retain(contexts, retained)) == 2
    assert MapSet.size(Comma.RecommendationContract.http_urls(data)) == 40
  end

  test "long links and short records leave the budget to the longer texts" do
    link =
      &("https://outlook.office365.com/owa/?ItemID=" <>
          String.duplicate("AAMkAGI2%3D", 20) <> "#{&1}")

    body =
      "\u200B Saved report: C:\\Users\\me\\AppData\\ErrorReports\\1.json " <>
        "Error: capture.diskWriteFailed. " <> String.duplicate("Stack frame. ", 100)

    mail =
      for id <- 1..40,
          do:
            Context.attach(%{"url" => link.(id), "body" => body}, ["body"]) |> Map.delete("body")

    events =
      for id <- 41..60,
          do:
            Context.attach(%{"url" => link.(id), "note" => "Room #{id}"}, ["note"])
            |> Map.delete("note")

    {data, contexts} = Context.separate(%{"messages" => mail, "items" => events})
    contexts = Context.retain(contexts, data)
    assert byte_size(Jason.encode!(Map.values(contexts))) <= 16_384

    for id <- 1..40 do
      assert contexts[link.(id)]["truncated"]
      assert contexts[link.(id)]["text"] =~ "capture.diskWriteFailed"
    end

    for id <- 41..60, do: assert(contexts[link.(id)]["text"] == "note: Room #{id}")
  end
end
