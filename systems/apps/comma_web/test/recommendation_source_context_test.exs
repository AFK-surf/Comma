defmodule CommaWeb.RecommendationSourceContextTest do
  use SystemsClock.Case, async: true
  alias Comma.{RecommendationDraft, RecommendationMemberSelection}
  alias CommaWeb.RecommendationSourceContext, as: Context

  test "long contextual prose cannot displace candidates, drift across unrelated records, or enter references" do
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
    retained_all = Context.retain(contexts, data)
    assert length(data["records"]) == 40
    assert map_size(retained_all) == 40

    assert Enum.all?(retained_all, fn {_, value} ->
             value["truncated"] and String.valid?(value["text"]) and value["text"] != "" and
               byte_size(Jason.encode!(value["text"])) - 2 <= 1_200
           end)

    # Dropping unrelated records keeps every surviving record's context identical.
    retained = put_in(data, ["records"], Enum.take(data["records"], 2))
    retained_two = Context.retain(contexts, retained)
    assert map_size(retained_two) == 2

    for url <- Map.keys(retained_two) do
      assert retained_two[url] == retained_all[url]
    end

    assert MapSet.size(Comma.RecommendationContract.http_urls(data)) == 40
  end

  test "Routine model candidates budget per-source contexts and leave unused share to longer texts" do
    link =
      &("https://outlook.office365.com/owa/?ItemID=" <>
          String.duplicate("AAMkAGI2%3D", 20) <> "#{&1}")

    body =
      "\u200B Saved report: C:\\Users\\me\\AppData\\ErrorReports\\1.json " <>
        "Error: capture.diskWriteFailed. " <> String.duplicate("Stack frame. ", 100)

    mail =
      for id <- 1..40 do
        %{"webUrl" => link.(id), "subject" => "Mail #{id}", "body" => body}
        |> Context.attach(["body"])
        |> Map.delete("body")
      end

    events =
      for id <- 41..60 do
        %{"webUrl" => link.(id), "subject" => "Event #{id}", "note" => "Room #{id}"}
        |> Context.attach(["note"])
        |> Map.delete("note")
      end

    {data, contexts} = Context.separate(%{"messages" => mail, "items" => events})
    retained = Context.retain(contexts, data)

    # Pool retention preserves each record's independent context without cross-item shrinking.
    for id <- 1..40 do
      assert retained[link.(id)]["truncated"]
      assert byte_size(Jason.encode!(retained[link.(id)]["text"])) - 2 <= 1_200
      assert byte_size(retained[link.(id)]["text"]) > 1_000
    end

    fact = %{
      "sourceId" => "outlook-1",
      "toolkit" => "outlook",
      "appName" => "Outlook",
      "data" => data,
      "contexts" => retained
    }

    evidence = %{"outlook-1" => Enum.map(1..60, link)}
    draft_context = RecommendationDraft.prepare([fact], evidence, "member")
    model_candidates = RecommendationMemberSelection.model_candidates(draft_context)
    model_contexts = Enum.map(model_candidates, & &1["context"])

    assert length(model_contexts) == 60
    assert byte_size(Jason.encode!(model_contexts)) <= 16_384

    by_title = Map.new(model_candidates, &{&1["title"], &1["context"]})

    for id <- 1..40 do
      assert by_title["Mail #{id}"]["truncated"]
      assert by_title["Mail #{id}"]["text"] =~ "capture.diskWriteFailed"
    end

    for id <- 41..60 do
      assert by_title["Event #{id}"]["text"] == "note: Room #{id}"
      refute by_title["Event #{id}"]["truncated"]
    end
  end
end
